# Elixir + Phoenix quickstart

For Phoenix apps with Ecto + Postgres. Uses Swoosh for sending, Oban for background processing, Finch for the SubscribeURL fetch. Replace `YourApp` / `your_app` with your app's module / OTP name and `YEHRO` with your `<UPPER_SLUG>`.

## Dependencies — `mix.exs`

```elixir
defp deps do
  [
    # ... existing deps
    {:swoosh, "~> 1.25"},
    {:gen_smtp, "~> 1.2"},        # required by Swoosh AmazonSES adapter
    {:finch, "~> 0.18"},          # for SubscribeURL fetch
    {:oban, "~> 2.18"}            # if not already present
  ]
end
```

```bash
mix deps.get
```

If you already use a different job library (Exq, Verk, Honeydew), substitute it — the pattern is "controller enqueues, worker processes."

## Env vars

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

In `config/runtime.exs`:

```elixir
config :your_app, YourApp.Mailer,
  adapter: Swoosh.Adapters.AmazonSES,
  region: System.fetch_env!("YEHRO_SES_REGION"),
  access_key: System.fetch_env!("YEHRO_SES_ACCESS_KEY"),
  secret: System.fetch_env!("YEHRO_SES_SECRET_KEY")

config :your_app, :ses,
  from_email: System.fetch_env!("YEHRO_SES_FROM_EMAIL"),
  reply_to: System.fetch_env!("YEHRO_SES_REPLY_TO"),
  configuration_set: System.fetch_env!("YEHRO_SES_CONFIGURATION_SET"),
  webhook_secret: System.fetch_env!("YEHRO_SES_WEBHOOK_SECRET"),
  topic_arn: System.fetch_env!("YEHRO_SES_SNS_TOPIC_ARN")

config :your_app, Oban,
  repo: YourApp.Repo,
  queues: [emails: 14, ses_events: 20],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]
```

Add Finch to `application.ex`:

```elixir
def start(_type, _args) do
  children = [
    YourApp.Repo,
    {Finch, name: YourApp.Finch},
    {Oban, Application.fetch_env!(:your_app, Oban)},
    YourAppWeb.Endpoint
    # ... existing children
  ]
  Supervisor.start_link(children, strategy: :one_for_one, name: YourApp.Supervisor)
end
```

## Migration

```bash
mix ecto.gen.migration create_ses_suppressions
```

```elixir
defmodule YourApp.Repo.Migrations.CreateSesSuppressions do
  use Ecto.Migration

  def change do
    create table(:ses_suppressions) do
      add :email,         :string, null: false
      add :reason,        :string, null: false
      add :reason_detail, :text
      add :last_event_at, :utc_datetime_usec, null: false
      add :event_count,   :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ses_suppressions, [:email])
    create index(:ses_suppressions, [:reason])
    create index(:ses_suppressions, [:last_event_at])
  end
end
```

```bash
mix ecto.migrate
```

## Suppression schema — `lib/your_app/suppressions/suppression.ex`

```elixir
defmodule YourApp.Suppressions.Suppression do
  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(bounce_permanent bounce_transient complaint manual)
  @permanent ~w(bounce_permanent complaint manual)

  schema "ses_suppressions" do
    field :email,         :string
    field :reason,        :string
    field :reason_detail, :string
    field :last_event_at, :utc_datetime_usec
    field :event_count,   :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  def reasons,    do: @reasons
  def permanent,  do: @permanent

  def changeset(s, attrs) do
    s
    |> cast(attrs, [:email, :reason, :reason_detail, :last_event_at, :event_count])
    |> update_change(:email, &String.downcase/1)
    |> validate_required([:email, :reason, :last_event_at])
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint(:email)
  end
end
```

## Suppression context — `lib/your_app/suppressions.ex`

```elixir
defmodule YourApp.Suppressions do
  import Ecto.Query
  alias YourApp.Repo
  alias YourApp.Suppressions.Suppression

  @permanent Suppression.permanent()

  def suppressed?(email) when is_binary(email) do
    e = String.downcase(email)
    Repo.exists?(
      from s in Suppression, where: s.email == ^e and s.reason in ^@permanent
    )
  end

  def record(email, reason, detail \\ %{}) do
    e = String.downcase(email)
    now = DateTime.utc_now()
    detail_json = Jason.encode!(detail)

    attrs = %{
      email: e,
      reason: reason,
      reason_detail: detail_json,
      last_event_at: now,
      event_count: 1
    }

    %Suppression{}
    |> Suppression.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [reason: reason, reason_detail: detail_json, last_event_at: now, updated_at: now],
        inc: [event_count: 1]
      ],
      conflict_target: :email
    )
  end

  def unsuppress(email) do
    e = String.downcase(email)
    Repo.delete_all(from s in Suppression, where: s.email == ^e)
  end

  def list_permanent do
    Repo.all(from s in Suppression, where: s.reason in ^@permanent, order_by: [desc: s.last_event_at])
  end
end
```

## Mailer — `lib/your_app/mailer.ex`

```elixir
defmodule YourApp.Mailer do
  use Swoosh.Mailer, otp_app: :your_app
  import Swoosh.Email
  alias YourApp.Suppressions

  @ses_cfg fn -> Application.fetch_env!(:your_app, :ses) end

  @doc """
  Suppression-aware send.
  Returns:
    {:ok, %Swoosh.Email{}}
    {:error, term}
    {:dropped, :suppressed, [addresses]}
  """
  def deliver_checked(%Swoosh.Email{} = email) do
    addrs = recipients(email)
    blocked = Enum.filter(addrs, &Suppressions.suppressed?/1)

    if blocked != [] do
      {:dropped, :suppressed, blocked}
    else
      email
      |> stamp_config_set()
      |> __MODULE__.deliver()
    end
  end

  defp stamp_config_set(email) do
    name = @ses_cfg.()[:configuration_set]
    put_provider_option(email, :configuration_set_name, name)
  end

  defp recipients(email) do
    (email.to ++ email.cc ++ email.bcc)
    |> Enum.map(fn
      {_name, addr} -> addr
      addr when is_binary(addr) -> addr
    end)
  end
end
```

## Email composer — `lib/your_app/emails.ex`

```elixir
defmodule YourApp.Emails do
  import Swoosh.Email

  defp cfg, do: Application.fetch_env!(:your_app, :ses)

  def welcome(to_address, name) do
    new()
    |> to(to_address)
    |> from(cfg()[:from_email])
    |> reply_to(cfg()[:reply_to])
    |> subject("Welcome!")
    |> text_body("Hi #{name},\n\nWelcome aboard.\n")
    |> html_body("<p>Hi #{name},</p><p>Welcome aboard.</p>")
  end
end
```

## Event worker — `lib/your_app/workers/ses_event_worker.ex`

```elixir
defmodule YourApp.Workers.SesEventWorker do
  use Oban.Worker, queue: :ses_events, max_attempts: 5
  require Logger
  alias YourApp.SesEventProcessor

  @impl true
  def perform(%Oban.Job{args: %{"message" => message_json}}) do
    event = Jason.decode!(message_json)
    SesEventProcessor.process(event)
  end
end
```

## Event processor — `lib/your_app/ses_event_processor.ex`

```elixir
defmodule YourApp.SesEventProcessor do
  require Logger
  alias YourApp.Suppressions

  def process(%{"eventType" => "Bounce", "bounce" => bounce} = event) do
    btype = bounce["bounceType"]
    bsub  = bounce["bounceSubType"]
    reason = if btype == "Permanent", do: "bounce_permanent", else: "bounce_transient"

    for r <- bounce["bouncedRecipients"] || [] do
      Suppressions.record(r["emailAddress"], reason, %{
        type: btype,
        subtype: bsub,
        action: r["action"],
        status: r["status"],
        diagnostic: r["diagnosticCode"],
        message_id: get_in(event, ["mail", "messageId"]),
        feedback_id: bounce["feedbackId"]
      })
      Logger.info("[ses] #{btype} bounce: #{r["emailAddress"]} (#{bsub})")
    end
    :ok
  end

  def process(%{"eventType" => "Complaint", "complaint" => complaint} = event) do
    for r <- complaint["complainedRecipients"] || [] do
      Suppressions.record(r["emailAddress"], "complaint", %{
        feedback_type: complaint["complaintFeedbackType"],
        message_id: get_in(event, ["mail", "messageId"]),
        feedback_id: complaint["feedbackId"]
      })
      Logger.warning("[ses] COMPLAINT: #{r["emailAddress"]} (#{complaint["complaintFeedbackType"]})")
    end
    :ok
  end

  def process(%{"eventType" => "Delivery"} = event) do
    recips = (event["delivery"]["recipients"] || []) |> Enum.join(", ")
    Logger.info("[ses] delivered: #{recips} (msg #{get_in(event, ["mail", "messageId"])})")
    :ok
  end

  def process(%{"eventType" => "Send"} = event) do
    Logger.debug("[ses] send accepted (msg #{get_in(event, ["mail", "messageId"])})")
    :ok
  end

  def process(%{"eventType" => "Reject"} = event) do
    Logger.error("[ses] REJECT (msg #{get_in(event, ["mail", "messageId"])}): #{get_in(event, ["reject", "reason"])}")
    :ok
  end

  def process(%{"eventType" => "RenderingFailure"} = event) do
    Logger.error("[ses] rendering failure: #{inspect(event["failure"])}")
    :ok
  end

  def process(%{"eventType" => "DeliveryDelay"} = event) do
    Logger.warning("[ses] delivery delay: #{get_in(event, ["deliveryDelay", "delayType"])}")
    :ok
  end

  def process(%{"eventType" => other}) do
    Logger.info("[ses] unhandled event type: #{other}")
    :ok
  end
end
```

## Webhook controller — `lib/your_app_web/controllers/ses_webhook_controller.ex`

```elixir
defmodule YourAppWeb.SesWebhookController do
  use YourAppWeb, :controller
  require Logger
  alias YourApp.Workers.SesEventWorker

  @sns_host_re ~r/\Asns\.[a-z0-9-]+\.amazonaws\.com\z/

  def receive(conn, %{"token" => token}) do
    expected = Application.fetch_env!(:your_app, :ses)[:webhook_secret]

    if Plug.Crypto.secure_compare(token, expected) do
      handle(conn)
    else
      conn |> send_resp(404, "Not Found") |> halt()
    end
  end

  defp handle(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 256 * 1024)

    with {:ok, payload} <- Jason.decode(raw),
         :ok <- check_topic(payload) do
      dispatch(conn, payload)
    else
      {:error, %Jason.DecodeError{}} ->
        send_resp(conn, 400, "Bad JSON")
      {:error, :topic_mismatch} ->
        send_resp(conn, 400, "Bad TopicArn")
    end
  rescue
    e ->
      Logger.error("[ses_webhook] processing error: #{inspect(e)}")
      send_resp(conn, 500, "Internal Server Error")
  end

  defp check_topic(%{"TopicArn" => arn}) do
    expected = Application.fetch_env!(:your_app, :ses)[:topic_arn]
    if arn == expected, do: :ok, else: {:error, :topic_mismatch}
  end
  defp check_topic(_), do: {:error, :topic_mismatch}

  defp dispatch(conn, %{"Type" => "SubscriptionConfirmation"} = p) do
    confirm_subscription(p)
    send_resp(conn, 200, "OK")
  end

  defp dispatch(conn, %{"Type" => "Notification", "Message" => message}) do
    %{message: message}
    |> SesEventWorker.new()
    |> Oban.insert()

    send_resp(conn, 200, "OK")
  end

  defp dispatch(conn, %{"Type" => "UnsubscribeConfirmation", "TopicArn" => arn}) do
    Logger.warning("[ses_webhook] UnsubscribeConfirmation for #{arn}")
    send_resp(conn, 200, "OK")
  end

  defp dispatch(conn, payload) do
    Logger.info("[ses_webhook] unknown Type: #{inspect(payload["Type"])}")
    send_resp(conn, 200, "OK")
  end

  defp confirm_subscription(%{"SubscribeURL" => url, "TopicArn" => arn}) do
    uri = URI.parse(url)

    if uri.scheme == "https" and Regex.match?(@sns_host_re, to_string(uri.host)) do
      req = Finch.build(:get, url)
      case Finch.request(req, YourApp.Finch) do
        {:ok, %{status: s}} when s in 200..299 ->
          Logger.info("[ses_webhook] subscription confirmed for #{arn}")
        {:ok, %{status: s}} ->
          Logger.error("[ses_webhook] confirmation GET returned #{s}")
        {:error, e} ->
          Logger.error("[ses_webhook] confirmation GET failed: #{inspect(e)}")
      end
    else
      Logger.error("[ses_webhook] refusing SubscribeURL with bad host: #{inspect(uri.host)}")
    end
  end
end
```

## Router — `lib/your_app_web/router.ex`

Add a CSRF-free pipeline (SNS POSTs without browser cookies and uses `Content-Type: text/plain`):

```elixir
pipeline :sns_webhook do
  plug :accepts, ["json", "text"]
end

scope "/", YourAppWeb do
  pipe_through :sns_webhook
  post "/webhooks/ses/:token", SesWebhookController, :receive
end
```

Do **not** put this in the `:browser` pipeline — CSRF protection will reject it.

## Endpoint — `lib/your_app_web/endpoint.ex`

Phoenix's `Plug.Parsers` by default only parses `application/json` and `application/x-www-form-urlencoded`. SNS sends `text/plain`. The controller reads the raw body itself via `Plug.Conn.read_body/2`, so as long as no other parser has consumed it first, this works. If you've customized the parsers, ensure `:text/plain` either passes through or that the raw body is preserved:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],     # <-- IMPORTANT: lets text/plain pass through unparsed
  json_decoder: Phoenix.json_library()
```

## Test

```elixir
iex> alias YourApp.{Mailer, Emails, Suppressions}

# 1. delivery
iex> Mailer.deliver_checked(Emails.welcome("success@simulator.amazonses.com", "T"))
{:ok, %Swoosh.Email{...}}

# 2. bounce
iex> Mailer.deliver_checked(Emails.welcome("bounce@simulator.amazonses.com", "T"))
{:ok, _}
# wait 30s
iex> Suppressions.suppressed?("bounce@simulator.amazonses.com")
true

# 3. complaint
iex> Mailer.deliver_checked(Emails.welcome("complaint@simulator.amazonses.com", "T"))
{:ok, _}
# wait 30s
iex> Suppressions.suppressed?("complaint@simulator.amazonses.com")
true

# 4. suppression takes effect
iex> Mailer.deliver_checked(Emails.welcome("bounce@simulator.amazonses.com", "T"))
{:dropped, :suppressed, ["bounce@simulator.amazonses.com"]}
```
