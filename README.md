# claude-aws-ses

A free [Claude Code](https://claude.com/claude-code) skill that provisions Amazon SES end to end for any application. Sets up DKIM, SNS event handling, webhook verification, suppression lists, and scoped IAM in about ten minutes. Language agnostic, with quickstarts for Node, Rails, Python, Go, and Elixir.

**[Read the full write-up →](https://www.ericsonsmith.com/blog/how-claude-code-solves-the-aws-ses-email-setup-problem)**

## What it does

Tell Claude Code "set up AWS SES" inside your project. The skill walks through a handful of inputs, provisions all the AWS resources, writes the mailer, webhook handler, event processor, and suppression context into your project in the right language and style, and gives you DNS records to paste into your provider. Send a test email to `bounce@simulator.amazonses.com` and a row appears in your `ses_suppressions` table within thirty seconds. Try to send to the same address again and the mailer drops it before contacting SES.

## Why this exists

AWS SES is the cheapest transactional email option and quietly powers Resend, Loops, and several other modern email APIs underneath. The catch has always been that proper setup, meaning DKIM, SNS event destinations, bounce and complaint handling, a working suppression list, and a tightly scoped IAM user, took 4 to 16 hours of careful AWS work. This skill collapses that into a single guided session inside Claude Code.

## Install

```bash
git clone https://github.com/<your-username>/aws-ses.git ~/.claude/skills/aws-ses
```

Or download the zip and unzip into your Claude Code skills directory.

## Use

Inside any project where you want to add SES:

```
1. Open Claude Code in the project root.
2. Say: "set up AWS SES for this project"
3. Answer the prompts.
```

The skill handles the rest. See `SKILL.md` for the full nine-step protocol.

## What's included

```
aws-ses/
├── SKILL.md          Entry point that Claude Code reads first
├── SPEC.md           Language-agnostic technical contract
├── PORTING.md        Guide for stacks not covered by a quickstart
├── scripts/          AWS provisioning (bash + aws-cli)
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

## Requirements

* AWS CLI installed and authenticated
* `jq` and `openssl` available on PATH
* An AWS SES account in production mode (not sandbox)
* Claude Code, with a project that can serve an HTTPS webhook endpoint

## Languages supported out of the box

* Node.js with Express
* Ruby on Rails
* Python with FastAPI
* Go with stdlib `net/http`
* Elixir with Phoenix

For other languages, `PORTING.md` walks Claude Code through implementing the spec in your stack. The contract in `SPEC.md` is precise enough that the port usually lands correctly on the first try.

## How it handles webhook auth

Most SES integrations rely on SNS cryptographic signature verification, which requires fetching a certificate, parsing it, and reconstructing a canonical string in exactly the right field order. Easy to get subtly wrong, different in every language.

This skill takes a different approach. The setup script generates a 256-bit random secret and bakes it into the subscribed webhook URL. The handler routes `POST /webhooks/ses/:token` and compares the token in constant time against an env var. Wrong token returns a 404. Simpler, identical across every language, no crypto code at all. The tradeoff is keeping the URL out of access logs and error trackers, which is a non-issue on infrastructure you control.

Defense-in-depth checks (SNS topic ARN match, SubscribeURL host regex, idempotent suppression upserts) are still baked into every quickstart.

## Read more

[How Claude Code Solves the AWS SES Email Setup Problem](https://www.ericsonsmith.com/blog/how-claude-code-solves-the-aws-ses-email-setup-problem)

Covers the deliverability case for SES, the "I'll just run my own SMTP" trap, why the cost argument is misleading even at low volume, and how this skill was built.

## License

MIT. Use it, fork it, ship it.

## Author

Built by [Ericson Smith](https://www.ericsonsmith.com) with [Claude Code](https://claude.com/claude-code).
