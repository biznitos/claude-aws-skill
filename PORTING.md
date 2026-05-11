# PORTING — implementing this skill in an unsupported language

If the user's stack doesn't match any `quickstarts/*.md`, follow this guide to write idiomatic code for their language. Read `SPEC.md` first — it's the source of truth. This file covers the meta-questions: which libraries, which patterns, what mistakes to avoid.

## Before writing anything

1. **Inspect the project.** Look at the dependency manifest (`Cargo.toml`, `composer.json`, `pubspec.yaml`, whatever). What's already there?
   - Which web framework?
   - Which background job library, if any?
   - Which ORM or DB driver?
   - Which AWS SDK?
2. **Use what's there.** Do not add a second of anything. If they have one ORM, use it. If they have no background job system and the volume is low, inline processing is fine.
3. **Match the project's style.** Look at one existing controller/handler. Match its indentation, naming, error handling. Don't import a different paradigm.

## The four pieces, in dependency order

Build in this order. Each piece is testable on its own.

### 1. Suppression list (database)

The DB is the foundation. Without this, nothing else works.

- Create a migration matching SPEC §6's schema.
- Implement two functions:
  - `suppressed?(email)` — returns boolean, uses the index on `email` + filter on permanent reasons.
  - `record(email, reason, detail_map)` — upsert with `event_count` increment.
- Lowercase the email everywhere — at insert, at query, before comparison. Email addresses are case-insensitive in the local part per RFC 5321 §2.4, but in practice everyone treats them as case-insensitive; lowercasing avoids weird `User@domain.com` vs `user@domain.com` duplicates.

Test this in isolation before continuing:

```
record("test@x.com", "bounce_permanent", %{})
record("test@x.com", "complaint", %{})        # should update, event_count -> 2
suppressed?("test@x.com")                     # -> true
suppressed?("TEST@x.com")                     # -> true (lowercased)
suppressed?("nobody@x.com")                   # -> false
```

### 2. Mail sender

- Use the official AWS SDK for the language (`@aws-sdk/client-sesv2`, `boto3`, `aws-sdk-go-v2`, etc.).
- Construct a single `Mailer` / `EmailClient` / equivalent that:
  - Reads region + access key + secret from `<UPPER_SLUG>_SES_*` env vars at startup.
  - Has a `deliver(message)` raw function.
  - Has a `deliver_checked(message)` wrapper that queries the suppression list first and stamps the configuration set on the outgoing message.
- `deliver_checked` returns three states. Encode this in the language's idiom (Result, sum type, tagged tuple, exception with specific class — match what the project uses elsewhere).

Test by sending to `success@simulator.amazonses.com` with the configuration set stamped. The send should succeed, and in 30 seconds an event should appear on the SNS topic (you can verify with `aws sns subscribe` to a dummy email address temporarily, or via CloudWatch Logs on the SNS topic).

### 3. Webhook handler

This is the most error-prone part. Follow SPEC §3 and §4 precisely.

**Critical:**
- The route is a wildcard / parameterized path that captures the secret. The auth check is **the first thing** the handler does, before parsing the body.
- Use constant-time comparison — never plain `==`. Every language has it (SPEC §3).
- Read the raw body before parsing. SNS sends `Content-Type: text/plain` and many web frameworks try to parse JSON only when the content type matches; you may need to opt into reading the body.
- Check `TopicArn` against the expected env var.
- For `SubscriptionConfirmation`, regex-check the `SubscribeURL` host before fetching.

**Common framework pitfalls:**
- Frameworks with automatic CSRF protection (Rails, Django, Phoenix's `:browser` pipeline) will reject the webhook. Exempt the route or put it in a CSRF-free pipeline.
- Frameworks that auto-parse JSON based on the path (rarer) may double-consume the body. Read once, work from the parsed copy.
- API gateway / reverse proxy may strip trailing slashes — make sure the route matches whether or not there's a trailing slash.

### 4. Event processor

Pure function: takes parsed event JSON, dispatches by `eventType`. No I/O except calling the suppression list. Easy to unit test.

Walk through each event type in SPEC §5. Resist the urge to over-engineer; the spec is explicit about what each event type should do.

## Background job library — yes or no?

If the app already has one, use it. Pattern: webhook controller enqueues a job carrying the SNS `Message` field; worker parses + dispatches.

If the app does not have one:
- For low volume (<1 event/sec, which covers most apps), inline processing is fine. Webhook controller does the full pipeline before returning 200.
- Above that, the handler will start timing out under load. SNS retries timeouts aggressively, which causes more load, which causes more timeouts. Add a queue before this becomes a problem — even a single Redis with the language's standard queue library is enough.

## Defense in depth — what you should keep even with the URL secret

The URL secret is the primary auth. The following are cheap and catch other classes of error:

1. **TopicArn check** — catches misconfiguration (subscribing the wrong topic to your webhook). Free.
2. **SubscribeURL host regex** — prevents SSRF if the URL secret ever leaks. Free.
3. **Idempotent suppression upsert** — bounds the damage from replays. Free.
4. **Async processing** — webhook returns 200 fast; processing failures retry independently. Adds complexity but worth it above trivial volume.

## What you should NOT add

- **SNS cryptographic signature verification.** It's correct but: (a) requires cert fetching + parsing in every language; (b) adds dependencies; (c) is easy to get subtly wrong (canonical string field ordering, key length variations). The URL-secret approach is simpler, language-independent, and good enough when the URL isn't exposed in logs. If you're shipping a public framework where URL secrecy can't be guaranteed, then add signature verification — for one project on infrastructure the user controls, it's overkill.
- **A second background job library.** Use what's there.
- **A separate config-set per environment.** One config set per project. Test and production share the same SES account but use different sender domains (or test against the mailbox simulator, which works in production too without billing).

## Verification checklist

Before declaring the port done, run through this:

- [ ] `suppressed?("ANY@domain.com")` returns true after `record("any@domain.com", "complaint", {})`.
- [ ] Webhook returns 404 when called with a wrong URL secret.
- [ ] Webhook returns 200 when called with a correct URL secret and a valid `SubscriptionConfirmation` body — and the SNS subscription transitions from `PendingConfirmation` to confirmed.
- [ ] Webhook returns 400 when `TopicArn` doesn't match.
- [ ] Webhook returns 200 for a synthetic `Bounce` notification, and a row appears in `ses_suppressions` with `reason = 'bounce_permanent'`.
- [ ] Webhook returns 200 for a synthetic `Complaint` notification, row appears with `reason = 'complaint'`.
- [ ] `deliver_checked(msg)` to `bounce@simulator.amazonses.com` succeeds the first time, then returns "dropped — suppressed" the second time (after the bounce event has been processed).
- [ ] No logs anywhere contain the webhook secret or the AWS secret access key.

If all eight pass, the implementation is complete.
