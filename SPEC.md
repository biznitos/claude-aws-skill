# aws-ses — Technical Specification

This document defines the contract every implementation must meet. Quickstarts implement this spec in idiomatic code for specific languages. If you're porting to an unsupported language, read this end-to-end before writing anything.

## 1. AWS resource naming

Given a project slug `<slug>` (lowercase, `[a-z][a-z0-9-]*`) and sender domain `<domain>`:

| Resource | Name |
|---|---|
| SES email identity | `<domain>` |
| SES configuration set | `<slug>` |
| SES event destination | `<slug>-sns` |
| Custom MAIL FROM | `mail.<domain>` |
| SNS topic | `<slug>-ses-events` |
| IAM user | `ses-sender-<slug>` |
| IAM inline policy | `ses-send-<slug>` |

All resources tagged with `project=<slug>` for auditability.

## 2. Environment variables

Prefix: `<UPPER_SLUG>_` where `UPPER_SLUG` is the slug uppercased with dashes converted to underscores.

| Variable | Source | Use |
|---|---|---|
| `<UPPER_SLUG>_SES_REGION` | input | AWS region for SES + SNS calls |
| `<UPPER_SLUG>_SES_ACCESS_KEY` | generated | IAM user access key id |
| `<UPPER_SLUG>_SES_SECRET_KEY` | generated | IAM user secret access key |
| `<UPPER_SLUG>_SES_CONFIGURATION_SET` | `<slug>` | stamped on every outgoing email |
| `<UPPER_SLUG>_SES_FROM_EMAIL` | input | default From address |
| `<UPPER_SLUG>_SES_REPLY_TO` | input | default Reply-To address |
| `<UPPER_SLUG>_SES_SNS_TOPIC_ARN` | generated | checked against incoming webhook payloads |
| `<UPPER_SLUG>_SES_WEBHOOK_SECRET` | generated (32 random bytes, hex) | compared against URL path segment |

The implementation reads these at startup or per-request. Never log the secret key or webhook secret.

## 3. Webhook auth: URL secret

### Subscribed URL

The script subscribes a URL of the form:

```
<base-url><webhook-path-prefix>/<secret>
```

Example: `https://yehro.com/webhooks/ses/8f3b2c1d4e5a6b7c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c`

The `<secret>` is 32 random bytes (`openssl rand -hex 32`) — 64 hex chars, URL-safe.

### Handler route

Mount the route as a wildcard:

```
POST <webhook-path-prefix>/:token
```

### Auth check

In the handler, **before any other work**:

1. Extract `:token` from the URL.
2. Constant-time compare against `<UPPER_SLUG>_SES_WEBHOOK_SECRET`.
3. If mismatch → return **404 Not Found** (not 401/403; 404 reveals less).
4. If match → proceed to parsing.

Every language has a constant-time comparison primitive:

| Language | Function |
|---|---|
| Node | `crypto.timingSafeEqual(a, b)` (Buffers, equal length) |
| Ruby | `ActiveSupport::SecurityUtils.secure_compare(a, b)` |
| Python | `hmac.compare_digest(a, b)` |
| Go | `subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1` |
| Elixir | `Plug.Crypto.secure_compare(a, b)` |

Plain `==` is **not** acceptable — it leaks information about how many leading characters match.

## 4. Webhook handler flow

After auth passes:

```
1. Read raw request body (SNS sends Content-Type: text/plain)
2. Parse as JSON. Bad JSON → 400.
3. Check payload["TopicArn"] matches expected ARN. Mismatch → 400.
4. Dispatch on payload["Type"]:
   - "SubscriptionConfirmation": fetch SubscribeURL (with host check), return 200
   - "Notification": enqueue/process the event, return 200
   - "UnsubscribeConfirmation": log + return 200
   - anything else: log + return 200
5. Return 200 as quickly as possible. Heavy work goes to a background job.
```

### SubscribeURL host check

When auto-confirming a subscription, the `SubscribeURL` field is a URL the handler must GET. **Before fetching**, verify the host with this exact regex:

```
^https://sns\.[a-z0-9-]+\.amazonaws\.com/.*$
```

If the host fails the check, **do not** make the HTTP request. Without this check, an attacker who can POST to your webhook (despite the URL secret — e.g., URL leaked to a log aggregator) could force your server to make HTTP requests to arbitrary internal hosts (SSRF).

### Return code semantics

- **200** for: auth passed AND payload understood (including ignored types like UnsubscribeConfirmation, and successful enqueue).
- **400** for: missing/wrong token (use 404 instead), bad JSON, TopicArn mismatch, missing required fields.
- **404** for: missing or wrong URL token.
- **500** for: transient infrastructure failure (DB down, job queue down) — SNS will retry with backoff.

Critical: never return 4xx or 5xx for a *successfully parsed event we don't care about*. Return 200 and ignore. SNS retries 4xx/5xx aggressively; we don't want a flood for events we deliberately drop.

## 5. SES event schemas

SNS Notification wrapper:

```json
{
  "Type": "Notification",
  "MessageId": "...",
  "TopicArn": "arn:aws:sns:us-east-1:123456789012:yehro-ses-events",
  "Message": "<JSON string — the SES event>",
  "Timestamp": "2026-05-11T01:23:45.678Z",
  ...
}
```

The actual SES event is the `Message` field, double-encoded JSON. Parse it separately.

### Bounce

```json
{
  "eventType": "Bounce",
  "mail": {
    "timestamp": "...",
    "messageId": "...",
    "source": "noreply@yehro.com",
    "destination": ["bad@example.com"],
    "tags": { "configuration-set": ["yehro"], ... }
  },
  "bounce": {
    "bounceType": "Permanent",        // or "Transient" or "Undetermined"
    "bounceSubType": "General",       // General, NoEmail, Suppressed, MailboxFull, ...
    "bouncedRecipients": [
      {
        "emailAddress": "bad@example.com",
        "action": "failed",
        "status": "5.1.1",
        "diagnosticCode": "smtp; 550 5.1.1 user unknown"
      }
    ],
    "timestamp": "...",
    "feedbackId": "..."
  }
}
```

**Action**: For each `bouncedRecipients[*].emailAddress`:
- If `bounceType == "Permanent"` → upsert into suppression list with `reason = "bounce_permanent"`.
- Otherwise → upsert with `reason = "bounce_transient"`. (Stored for visibility; **not** used to block sends.)

### Complaint

```json
{
  "eventType": "Complaint",
  "mail": { ... },
  "complaint": {
    "complainedRecipients": [{ "emailAddress": "user@example.com" }],
    "complaintFeedbackType": "abuse",
    "timestamp": "...",
    "feedbackId": "..."
  }
}
```

**Action**: For each `complainedRecipients[*].emailAddress` → upsert with `reason = "complaint"`.

### Delivery

```json
{
  "eventType": "Delivery",
  "mail": { ... },
  "delivery": {
    "timestamp": "...",
    "processingTimeMillis": 1234,
    "recipients": ["user@example.com"],
    "smtpResponse": "250 OK ...",
    "reportingMTA": "..."
  }
}
```

**Action**: log informationally. Do not touch suppression list.

### Send, Reject, RenderingFailure, DeliveryDelay

- **Send**: SES accepted the message. Log at debug.
- **Reject**: SES refused to send (usually content-policy / virus). Log at error. Message never left SES.
- **RenderingFailure**: SES template rendering broke (only relevant if using SES templates). Log at error.
- **DeliveryDelay**: SES still trying. Log at warning.

None of these touch the suppression list.

## 6. Suppression list

### Schema

Table name: `ses_suppressions`. Columns:

| Column | Type | Constraints |
|---|---|---|
| `id` | bigint / serial | primary key |
| `email` | string | NOT NULL, unique (lowercased before insert) |
| `reason` | string | NOT NULL, one of: `bounce_permanent`, `bounce_transient`, `complaint`, `manual` |
| `reason_detail` | text | nullable; JSON string with event context (diagnostic code, message id, etc.) |
| `last_event_at` | timestamp (UTC) | NOT NULL |
| `event_count` | integer | NOT NULL, default 1 |
| `created_at` | timestamp (UTC) | NOT NULL |
| `updated_at` | timestamp (UTC) | NOT NULL |

Indexes:
- `UNIQUE (email)` — required, drives upsert semantics
- `INDEX (reason)` — for filtering
- `INDEX (last_event_at)` — for purging old transient bounces

### Upsert semantics

On record:
- Lowercase the email before insert/query.
- Serialize `detail_map` to a JSON string for `reason_detail`.
- `INSERT … ON CONFLICT (email) DO UPDATE SET reason = EXCLUDED.reason, reason_detail = EXCLUDED.reason_detail, last_event_at = EXCLUDED.last_event_at, updated_at = EXCLUDED.updated_at, event_count = ses_suppressions.event_count + 1`.

Important: a transient bounce **can** overwrite a permanent bounce (and vice versa). This is correct — if we got a permanent bounce yesterday and a transient retry succeeds today, the address is recovering. The latest event wins.

### Pre-send check

Before delivering any message, for each recipient (To + Cc + Bcc):
1. Lowercase the address.
2. Query: `SELECT 1 FROM ses_suppressions WHERE email = ? AND reason IN ('bounce_permanent', 'complaint', 'manual') LIMIT 1`.
3. If any recipient matches → **do not send**. Return a "dropped" status to the caller. Do not partially send (don't strip the bad address and send to the rest).

The implementation should expose two send functions:
- `deliver(message)` — raw send, no suppression check (for the rare case you need to bypass it).
- `deliver_checked(message)` — wraps `deliver`, returns one of `{:ok, _}`, `{:error, _}`, `{:dropped, :suppressed, [addresses]}`.

Outbound application code always uses `deliver_checked`.

## 7. Configuration-set stamping

Every outgoing email **must** be stamped with the project's configuration set. Without this stamp, the email sends fine but the events do not route to the project's SNS topic — bounces/complaints become invisible.

In SDK terms, the parameter is `ConfigurationSetName`. In the AWS SES v2 `SendEmail` action it's a top-level field. In the v1 `SendRawEmail` action it's passed as a header `X-SES-CONFIGURATION-SET` on the raw MIME message.

Library-specific:
- Nodemailer + @aws-sdk: pass `ConfigurationSetName` in the `SendEmailCommand` params.
- Rails ActionMailer + aws-sdk-rails: set `default configuration_set_name: ENV[...]` in the mailer.
- Python + boto3: `client.send_email(..., ConfigurationSetName=...)`.
- Go aws-sdk-go-v2: `ConfigurationSetName` field on `SendEmailInput`.
- Swoosh AmazonSES adapter: `put_provider_option(:configuration_set_name, name)`.

The pre-send wrapper (`deliver_checked` in this skill's convention) is responsible for stamping it — application code that composes the email shouldn't need to remember.

## 8. Background processing

Webhook handler returns 200 fast. Event processing (parse SES event, route to handler, update DB) happens asynchronously.

The pattern is "fan in, fan out":
- Webhook handler: validate auth + envelope, enqueue one job per notification, return 200.
- Background worker: pull job, parse `Message`, dispatch to event-type handler, update suppression list.

Acceptable queue backends: anything the app already uses. The quickstarts use the most common per language (Bull for Node, Sidekiq for Rails, Celery/RQ for Python, channels for Go, Oban for Elixir).

If the app has **no** background job system, inline processing is acceptable for low volume (<1 event/sec) as long as event-handler work is fast (<100ms). Above that, add a queue — otherwise the webhook starts timing out under load and SNS retries pile up.

## 9. Test protocol

SES provides simulator addresses. They do not bill, do not affect reputation, do not require recipient verification.

| Address | Triggers |
|---|---|
| `success@simulator.amazonses.com` | Send + Delivery events |
| `bounce@simulator.amazonses.com` | Send + Bounce (Permanent) events |
| `ooto@simulator.amazonses.com` | Send + Delivery + Bounce (Transient, "AutoReply") events |
| `complaint@simulator.amazonses.com` | Send + Delivery + Complaint events |
| `suppressionlist@simulator.amazonses.com` | Send + Bounce (Permanent, SubType "OnAccountSuppressionList") events |

End-to-end test (after deploy + DNS + verification):

1. From the running app, send three emails:
   - To `success@simulator.amazonses.com` (config set stamped).
   - To `bounce@simulator.amazonses.com`.
   - To `complaint@simulator.amazonses.com`.
2. Wait 30 seconds.
3. Query `ses_suppressions`:
   - `success@…` → no row.
   - `bounce@…` → row with `reason = 'bounce_permanent'`.
   - `complaint@…` → row with `reason = 'complaint'`.
4. Attempt to send another email to `bounce@simulator.amazonses.com`. The send function (`deliver_checked`) should return a "dropped — suppressed" result without contacting SES.

All four points pass → the pipeline works.

## 10. Logging recommendations

Log levels:
- `info`: outgoing sends, deliveries, transient bounces, subscription confirmations.
- `warning`: delivery delays, unsuppress operations, repeated transient bounces.
- `error`: permanent bounces (with diagnostic code), complaints, SES Reject, RenderingFailure, webhook parse failures, DB errors during event processing.

Never log:
- The webhook secret.
- The SES secret access key.
- Recipient email addresses in `info` level (PII; only at `debug`).

## 11. Idempotency

Every operation must be safe to repeat:
- Webhook hits: SNS may deliver the same notification more than once. Suppression upsert handles this (event_count just increments).
- Setup script: re-running detects existing resources and skips.
- Teardown script: missing resources are skipped silently.
- Send: SES message ids are unique per `SendEmail` call; deduping is the application's responsibility if it retries failed sends.
