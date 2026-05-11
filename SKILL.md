---
name: aws-ses
description: Use this skill to add AWS SES transactional email to any application — provisioning AWS resources (DKIM identity, configuration set, SNS topic, scoped IAM user), generating DNS records, wiring up code for sending mail and handling bounce/complaint/delivery webhooks, and testing end-to-end. Designed for the case where one AWS SES account serves many independent projects; everything is namespaced by project slug so projects do not interfere. Language-agnostic — works for Node, Rails, Python, Go, Elixir, or anything else with HTTP + a database. Triggers include "set up SES", "add email to this app", "wire up SES webhooks", "configure bounces and complaints", "provision SES for <domain>", "rotate SES credentials", any mention of Amazon SES, SNS event destinations, or transactional email with AWS. Assumes the SES account is already in production mode (not sandbox).
---

# AWS SES — multi-project, language-agnostic

This skill provisions AWS SES for one project (sharing an account with other projects), then writes the code in the user's stack of choice. Four moving parts:

1. **AWS setup** — shell scripts call AWS CLI to create namespaced resources.
2. **Mail sending** — uses the user's existing library (Nodemailer / ActionMailer / boto3 / Swoosh / etc.).
3. **Webhook handling** — receives SNS notifications, processes bounces and complaints, updates a suppression list.
4. **Testing** — sends to SES mailbox simulator addresses to verify each event path.

## Hard assumptions

- The AWS SES account is in **production mode** (not sandbox).
- The AWS CLI is installed and authenticated. The scripts accept an optional `--profile` flag.
- `jq` and `openssl` are installed (both are one-line installs on every OS).
- The target app has access to a SQL database (Postgres/MySQL/SQLite all fine). The suppression list lives in one table.
- The app can be deployed at an HTTPS URL before AWS provisioning runs (the webhook endpoint must be live to confirm the SNS subscription).

## Webhook auth

This skill uses a **URL-secret** for webhook authentication, not SNS cryptographic signature verification. The script generates a 256-bit random secret and bakes it into the subscribed URL:

```
https://yehro.com/webhooks/ses/8f3b2c1d4e5a6b7c...
                              ^^^^^^^^^^^^^^^^^^
                              random per project
```

The handler routes `POST /webhooks/ses/:token` and constant-time-compares `:token` against an env var. Wrong token → 404, request goes nowhere.

This is simpler than SNS signature verification, works identically in every language, and removes the only crypto code from the handler. Tradeoff: the URL is sensitive — keep it out of access logs, error trackers, and front-end code.

Defense-in-depth checks still included in every quickstart:
- `TopicArn` in message body must match expected ARN (catches accidental cross-wiring).
- On `SubscriptionConfirmation`, the `SubscribeURL` host must match `sns.<region>.amazonaws.com` (regex check; prevents SSRF).
- All operations are idempotent (suppression upsert by email), so replay attacks are bounded to "stale event reprocessed."

## Namespacing

Every AWS resource and env var includes the project slug. Two projects share one SES account with zero cross-talk:

| Resource | Pattern | Example (slug = `yehro`) |
|---|---|---|
| Configuration set | `<slug>` | `yehro` |
| SNS topic | `<slug>-ses-events` | `yehro-ses-events` |
| IAM user | `ses-sender-<slug>` | `ses-sender-yehro` |
| Inline policy | `ses-send-<slug>` | `ses-send-yehro` |
| SES event destination | `<slug>-sns` | `yehro-sns` |
| Env var prefix | `<UPPER_SLUG>_` | `YEHRO_SES_REGION` etc. |
| Webhook path | `<user-prefix>/<random-secret>` | `/webhooks/ses/8f3b...` |

The IAM user's policy is scoped to:
- `ses:SendEmail` / `ses:SendRawEmail` only
- On the project's identity ARN + the project's configuration set ARN
- With `ses:FromAddress` matching `*@<domain>`

A leaked sender key can only send from that project's domain via that project's config set. Events still route only to that project's SNS topic.

## Protocol

When invoked, follow these steps in order.

### Step 0: Verify AWS CLI

```bash
aws sts get-caller-identity
```

If this fails, stop. Tell the user to fix their AWS credentials before proceeding.

### Step 1: Gather inputs

Ask the user for all eight inputs below in one structured message. Validate before proceeding.

| # | Input | Example | Validation |
|---|---|---|---|
| 1 | Project slug | `yehro` | `^[a-z][a-z0-9-]*$` |
| 2 | App base URL | `https://yehro.com` | starts with `https://`, no trailing slash |
| 3 | Webhook path prefix | `/webhooks/ses` | leading slash; script appends `/<secret>` |
| 4 | Sender domain | `yehro.com` | bare domain, no protocol |
| 5 | Mail from | `noreply@yehro.com` | valid email; domain matches #4 (or subdomain) |
| 6 | Mail reply-to | `support@yehro.com` | valid email |
| 7 | SES region | `us-east-1` | a region where SES is available |
| 8 | AWS profile | `default` or named | optional; defaults to current shell |

### Step 2: Detect language

Look at the user's project root for these signals and pick the matching quickstart from `quickstarts/`:

| Signal | Quickstart |
|---|---|
| `package.json` | `node-express.md` |
| `Gemfile` with `gem "rails"` | `rails.md` |
| `pyproject.toml` / `requirements.txt` / `manage.py` | `python-fastapi.md` |
| `go.mod` | `go-stdlib.md` |
| `mix.exs` | `elixir-phoenix.md` |
| Anything else | Read `PORTING.md` + `SPEC.md` and write idiomatic code in their language |

If multiple match (e.g., a Node frontend + Rails backend), ask the user which one should send the mail.

### Step 3: One-time account init

```bash
./scripts/init_account.sh <region> [--profile <name>]
```

Idempotent. Confirms production mode, enables account-level suppression for bounces + complaints (AWS-managed safety net across all projects on this account). If the user has run this for this account before, the script detects and skips silently.

### Step 4: Write the code

Read the chosen quickstart and adapt it to the user's project. Replace placeholders:
- `<PROJECT_SLUG>` (lowercase) and `<UPPER_SLUG>` (env var prefix)
- App namespace / module / package matching the user's existing code
- File paths matching the user's directory layout

If the user has an existing background job system (Sidekiq, Bull, Celery, etc.) different from what the quickstart shows, **use what they have** — don't add a second job library. The pattern (enqueue webhook processing instead of doing it inline) is what matters, not the specific library.

Tell the user to:
1. Install any new dependencies the quickstart introduces.
2. Run the database migration for `ses_suppressions`.
3. Deploy with the env vars set (we'll fill them in at Step 5).
4. Verify the webhook endpoint returns 200 for a sanity GET.

The webhook endpoint must be live and routable before Step 5.

### Step 5: Provision AWS

```bash
./scripts/setup_project.sh \
  --slug <slug> \
  --domain <domain> \
  --region <region> \
  --base-url <https://...> \
  --webhook-path <prefix> \
  --from <noreply@...> \
  --reply-to <support@...> \
  [--profile <name>]
```

What this creates:
1. SES email identity for `<domain>` (Easy DKIM, 2048-bit).
2. Configuration set `<slug>` (reputation + sending enabled).
3. Custom MAIL FROM `mail.<domain>`.
4. SNS topic `<slug>-ses-events` with a locked-down topic policy.
5. SNS HTTPS subscription to `<base-url><webhook-path>/<generated-secret>`.
6. SES event destination on the config set → SNS topic. Matching events: `SEND, REJECT, BOUNCE, COMPLAINT, DELIVERY, RENDERING_FAILURE, DELIVERY_DELAY`.
7. IAM user `ses-sender-<slug>` with the scoped inline policy.
8. Access keys (printed once into `output/<slug>/env.txt`).

Outputs land in `./output/<slug>/`:
- `env.txt` — all env vars, prefixed, ready to paste into `.env` / `dokku config:set` / `fly secrets set`.
- `dns.txt` — DNS records in copy-paste form.
- `zone.bind` — BIND zone file, importable into Cloudflare / Route53 / etc.

### Step 6: DNS

Show the user `output/<slug>/dns.txt`. They add:
- 3 DKIM CNAMEs
- MX + SPF TXT on `mail.<domain>`
- DMARC TXT on `_dmarc.<domain>` (starts in monitoring mode `p=none`)

If their DNS provider supports BIND import (Cloudflare does), `output/<slug>/zone.bind` is one upload.

### Step 7: Set env vars and (re)deploy

The user copies `output/<slug>/env.txt` into their production env (Dokku, Fly, Render, Vercel, plain `.env`, whatever) and redeploys so the app has the new credentials.

### Step 8: Wait for verification

```bash
./scripts/check_status.sh <slug> <domain> <region> [--profile <name>]
```

Re-run until DKIM = `SUCCESS` and MAIL FROM = `SUCCESS`. Typically minutes; can take hours on slow DNS providers.

Also verifies the SNS subscription has been confirmed (the webhook controller auto-confirms on first POST). If still `PendingConfirmation`, the endpoint is unreachable or returning non-2xx — debug there.

### Step 9: Test end-to-end

SES provides three special simulator addresses that trigger specific events without involving real recipients:

- `success@simulator.amazonses.com` → triggers a `Delivery` event
- `bounce@simulator.amazonses.com` → triggers a `Bounce` event (permanent)
- `complaint@simulator.amazonses.com` → triggers a `Complaint` event

For each one:
1. Send a test email from your app's send function (with the project's config set stamped — automatic if you used the quickstart pattern).
2. Wait 10–30 seconds.
3. Check the `ses_suppressions` table.

Expected results:
- `success@…` → no row added (delivery is informational, not a suppression event).
- `bounce@…` → row with `reason = 'bounce_permanent'`.
- `complaint@…` → row with `reason = 'complaint'`.

If a row appears, the entire pipeline works: send → SES → SNS → your webhook → your event processor → DB.

If no row appears after 60s:
- Check SNS subscription is confirmed (Step 8).
- Check your app's logs for webhook hits.
- Check the request reached the right path (URL secret must match).

## Teardown

```bash
./scripts/teardown_project.sh <slug> <domain> <region> [--profile <name>]
```

Reverses Step 5 — deletes IAM user + keys, event destination, SNS topic + subscriptions, configuration set, email identity. Idempotent. Does **not** touch DNS or app code.

## Cross-project reputation note

SES tracks bounce and complaint rates **at the account level, not per identity**. If one project has a bad list and burns reputation, all projects on the same SES account suffer. Mitigations baked into this skill:

- App-level suppression list checked before every send.
- Account-level suppression auto-enabled (via `init_account.sh`) for AWS-detected bad addresses across all projects.
- Each project's events route only to its own SNS topic, so per-project monitoring is clean.

If two projects have very different risk profiles (e.g., transactional vs cold outbound), strongly consider separate AWS accounts. Use AWS Organizations.

## Out of scope

- Sandbox → production access (assumed already done).
- Dedicated IPs ($24.95/mo each; opt-in via console).
- Open/click tracking (adds tracking pixels and rewrites URLs; add `OPEN`/`CLICK` to `MatchingEventTypes` in `setup_project.sh` to opt in).
- DNS push automation (every provider has a different API; the BIND export is the lowest common denominator).

## File inventory

```
aws-ses/
├── SKILL.md                       (this file)
├── SPEC.md                        precise contract for any implementation
├── PORTING.md                     for languages without a quickstart
├── scripts/
│   ├── init_account.sh
│   ├── setup_project.sh
│   ├── check_status.sh
│   └── teardown_project.sh
└── quickstarts/
    ├── node-express.md
    ├── rails.md
    ├── python-fastapi.md
    ├── go-stdlib.md
    └── elixir-phoenix.md
```
