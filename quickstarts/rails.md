# Rails quickstart

For Rails apps. Uses `aws-sdk-rails` for SES integration with ActionMailer, ActiveRecord for the suppression list, and inline processing in the webhook controller (switch to Sidekiq if already in your Gemfile, or add `perform_later` once volume grows).

## Gemfile

```ruby
gem "aws-sdk-rails", "~> 4.0"
gem "aws-sdk-sesv2"   # for direct SES v2 calls when needed
```

```bash
bundle install
```

If you already use Sidekiq / GoodJob / SolidQueue / Resque, use it — the patterns below show inline processing for simplicity. The webhook controller will enqueue a job per notification instead.

## Env vars

Replace `YEHRO` with your `<UPPER_SLUG>`. Use Rails credentials, `.env`, or your hosting provider's env-var system.

```
YEHRO_SES_REGION=us-east-1
YEHRO_SES_ACCESS_KEY=AKIA...
YEHRO_SES_SECRET_KEY=...
YEHRO_SES_CONFIGURATION_SET=yehro
YEHRO_SES_FROM_EMAIL=noreply@yehro.com
YEHRO_SES_REPLY_TO=support@yehro.com
YEHRO_SES_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123:yehro-ses-events
YEHRO_SES_WEBHOOK_SECRET=<64 hex chars>
```

## Migration

```bash
bin/rails g migration CreateSesSuppressions
```

```ruby
# db/migrate/<timestamp>_create_ses_suppressions.rb
class CreateSesSuppressions < ActiveRecord::Migration[7.1]
  def change
    create_table :ses_suppressions do |t|
      t.string    :email,         null: false
      t.string    :reason,        null: false
      t.text      :reason_detail
      t.datetime  :last_event_at, null: false
      t.integer   :event_count,   null: false, default: 1
      t.timestamps
    end
    add_index :ses_suppressions, :email, unique: true
    add_index :ses_suppressions, :reason
    add_index :ses_suppressions, :last_event_at
  end
end
```

```bash
bin/rails db:migrate
```

## Suppression model — `app/models/ses_suppression.rb`

```ruby
class SesSuppression < ApplicationRecord
  REASONS = %w[bounce_permanent bounce_transient complaint manual].freeze
  PERMANENT_REASONS = %w[bounce_permanent complaint manual].freeze

  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :reason, inclusion: { in: REASONS }
  validates :last_event_at, presence: true

  before_validation { self.email = email.to_s.downcase }

  scope :permanent, -> { where(reason: PERMANENT_REASONS) }

  def self.suppressed?(email)
    permanent.where(email: email.to_s.downcase).exists?
  end

  def self.record(email, reason, detail = {})
    e = email.to_s.downcase
    now = Time.current
    upsert(
      { email: e, reason: reason, reason_detail: detail.to_json,
        last_event_at: now, event_count: 1, created_at: now, updated_at: now },
      unique_by: :email,
      on_duplicate: Arel.sql(<<~SQL)
        reason = EXCLUDED.reason,
        reason_detail = EXCLUDED.reason_detail,
        last_event_at = EXCLUDED.last_event_at,
        updated_at = EXCLUDED.updated_at,
        event_count = ses_suppressions.event_count + 1
      SQL
    )
  end

  def self.unsuppress(email)
    where(email: email.to_s.downcase).destroy_all
  end
end
```

## ActionMailer config — `config/environments/production.rb`

```ruby
Rails.application.configure do
  # ... existing config

  config.action_mailer.delivery_method = :ses_v2
  config.action_mailer.ses_v2_settings = {
    region: ENV.fetch("YEHRO_SES_REGION"),
    access_key_id: ENV.fetch("YEHRO_SES_ACCESS_KEY"),
    secret_access_key: ENV.fetch("YEHRO_SES_SECRET_KEY"),
  }
  config.action_mailer.default_url_options = { host: "yehro.com", protocol: "https" }
end
```

`config/environments/development.rb`: keep your existing dev settings (letter_opener, etc.).

## Application mailer — `app/mailers/application_mailer.rb`

```ruby
class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("YEHRO_SES_FROM_EMAIL") },
          reply_to: -> { ENV.fetch("YEHRO_SES_REPLY_TO") }
  layout "mailer"

  # Stamp every outgoing message with the project's configuration set.
  # This is what routes events to the project's SNS topic.
  before_action :stamp_configuration_set

  private

  def stamp_configuration_set
    headers["X-SES-CONFIGURATION-SET"] = ENV.fetch("YEHRO_SES_CONFIGURATION_SET")
  end
end
```

## Suppression-aware delivery — `app/services/checked_mail.rb`

```ruby
module CheckedMail
  module_function

  # Returns:
  #   { ok: true }                      on success
  #   { dropped: true, addresses: [..] } if any recipient is suppressed
  #   { error: exception }              on SES failure
  def deliver(mail)
    all = Array(mail.to) + Array(mail.cc) + Array(mail.bcc)
    blocked = all.select { |addr| SesSuppression.suppressed?(addr) }

    if blocked.any?
      Rails.logger.info "[mailer] dropping send; suppressed: #{blocked.join(", ")}"
      return { dropped: true, addresses: blocked }
    end

    begin
      mail.deliver_now
      { ok: true }
    rescue => e
      Rails.logger.error "[mailer] send failed: #{e.message}"
      { error: e }
    end
  end
end
```

Usage:

```ruby
result = CheckedMail.deliver(UserMailer.welcome(user))
case
when result[:ok]      then # ...
when result[:dropped] then # log + move on
when result[:error]   then # retry or alert
end
```

## Event processor — `app/services/ses_event_processor.rb`

```ruby
module SesEventProcessor
  module_function

  def process(event)
    case event["eventType"]
    when "Bounce"
      handle_bounce(event)
    when "Complaint"
      handle_complaint(event)
    when "Delivery"
      Rails.logger.info "[ses] delivered: #{event.dig('delivery', 'recipients')&.join(', ')} (msg #{event.dig('mail', 'messageId')})"
    when "Send"
      Rails.logger.debug "[ses] send accepted (msg #{event.dig('mail', 'messageId')})"
    when "Reject"
      Rails.logger.error "[ses] REJECT (msg #{event.dig('mail', 'messageId')}): #{event.dig('reject', 'reason')}"
    when "RenderingFailure"
      Rails.logger.error "[ses] rendering failure: #{event['failure'].inspect}"
    when "DeliveryDelay"
      Rails.logger.warn "[ses] delivery delay (msg #{event.dig('mail', 'messageId')}): #{event.dig('deliveryDelay', 'delayType')}"
    else
      Rails.logger.info "[ses] unhandled event type: #{event['eventType']}"
    end
  end

  def self.handle_bounce(event)
    bounce = event["bounce"]
    type = bounce["bounceType"]
    subtype = bounce["bounceSubType"]
    reason = type == "Permanent" ? "bounce_permanent" : "bounce_transient"

    Array(bounce["bouncedRecipients"]).each do |r|
      SesSuppression.record(r["emailAddress"], reason, {
        type: type,
        subtype: subtype,
        action: r["action"],
        status: r["status"],
        diagnostic: r["diagnosticCode"],
        message_id: event.dig("mail", "messageId"),
        feedback_id: bounce["feedbackId"],
      })
      Rails.logger.info "[ses] #{type} bounce: #{r['emailAddress']} (#{subtype})"
    end
  end

  def self.handle_complaint(event)
    complaint = event["complaint"]
    Array(complaint["complainedRecipients"]).each do |r|
      SesSuppression.record(r["emailAddress"], "complaint", {
        feedback_type: complaint["complaintFeedbackType"],
        message_id: event.dig("mail", "messageId"),
        feedback_id: complaint["feedbackId"],
      })
      Rails.logger.warn "[ses] COMPLAINT: #{r['emailAddress']} (#{complaint['complaintFeedbackType'] || 'unspecified'})"
    end
  end
end
```

## Webhook controller — `app/controllers/ses_webhooks_controller.rb`

```ruby
require "active_support/security_utils"
require "net/http"

class SesWebhooksController < ActionController::API
  SNS_HOST_RE = /\Asns\.[a-z0-9-]+\.amazonaws\.com\z/

  # Skip everything; URL secret is the auth mechanism, body is raw.
  skip_forgery_protection if respond_to?(:skip_forgery_protection)

  def receive
    # 1. URL secret check — constant time
    unless ActiveSupport::SecurityUtils.secure_compare(
             params[:token].to_s,
             ENV.fetch("YEHRO_SES_WEBHOOK_SECRET")
           )
      return head :not_found
    end

    # 2. Parse body (raw, since Content-Type is text/plain)
    payload = begin
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      return head :bad_request
    end

    # 3. TopicArn check
    expected_arn = ENV.fetch("YEHRO_SES_SNS_TOPIC_ARN")
    unless payload["TopicArn"] == expected_arn
      Rails.logger.warn "[ses_webhook] TopicArn mismatch: #{payload['TopicArn']}"
      return head :bad_request
    end

    # 4. Dispatch
    case payload["Type"]
    when "SubscriptionConfirmation"
      confirm_subscription(payload)
      head :ok
    when "Notification"
      event = JSON.parse(payload["Message"])
      SesEventProcessor.process(event)
      head :ok
    when "UnsubscribeConfirmation"
      Rails.logger.warn "[ses_webhook] UnsubscribeConfirmation for #{payload['TopicArn']}"
      head :ok
    else
      Rails.logger.info "[ses_webhook] unknown Type: #{payload['Type']}"
      head :ok
    end
  rescue => e
    Rails.logger.error "[ses_webhook] processing error: #{e.class}: #{e.message}"
    head :internal_server_error
  end

  private

  def confirm_subscription(payload)
    url = URI.parse(payload["SubscribeURL"])
    unless url.scheme == "https" && SNS_HOST_RE.match?(url.host)
      Rails.logger.error "[ses_webhook] refusing to fetch SubscribeURL: bad host #{url.host}"
      return
    end
    resp = Net::HTTP.get_response(url)
    if resp.is_a?(Net::HTTPSuccess)
      Rails.logger.info "[ses_webhook] subscription confirmed for #{payload['TopicArn']}"
    else
      Rails.logger.error "[ses_webhook] confirmation GET: #{resp.code}"
    end
  end
end
```

## Route — `config/routes.rb`

```ruby
Rails.application.routes.draw do
  # ... existing routes
  post "/webhooks/ses/:token", to: "ses_webhooks#receive"
end
```

## Test

From `rails console`:

```ruby
# 1. Delivery — success simulator
UserMailer.welcome(User.new(email: "success@simulator.amazonses.com", name: "test")).deliver_now

# 2. Bounce
UserMailer.welcome(User.new(email: "bounce@simulator.amazonses.com", name: "test")).deliver_now
sleep 30
SesSuppression.find_by(email: "bounce@simulator.amazonses.com")
# => #<SesSuppression reason: "bounce_permanent", ...>

# 3. Complaint
UserMailer.welcome(User.new(email: "complaint@simulator.amazonses.com", name: "test")).deliver_now
sleep 30
SesSuppression.find_by(email: "complaint@simulator.amazonses.com")
# => #<SesSuppression reason: "complaint", ...>

# 4. Suppression takes effect
CheckedMail.deliver(UserMailer.welcome(User.new(email: "bounce@simulator.amazonses.com")))
# => { dropped: true, addresses: ["bounce@simulator.amazonses.com"] }
```
