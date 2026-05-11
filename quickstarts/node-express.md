# Node + Express quickstart

For projects with `package.json` using Express. If using Fastify, Koa, or Hono, the structure is the same; adapt route registration and middleware.

## Dependencies

```bash
npm install @aws-sdk/client-sesv2 express knex pg
# OR if using a different db:
# npm install @aws-sdk/client-sesv2 express prisma   # Prisma
# npm install @aws-sdk/client-sesv2 express drizzle-orm  # Drizzle
```

If the project already has an HTTP client and DB driver, use those. The patterns below assume Knex + Postgres; trivially portable.

## Env vars

All variables must be set before the app starts. Replace `YEHRO` with `<UPPER_SLUG>` (your project slug, uppercased).

```
YEHRO_SES_REGION=us-east-1
YEHRO_SES_ACCESS_KEY=AKIA...
YEHRO_SES_SECRET_KEY=...
YEHRO_SES_CONFIGURATION_SET=yehro
YEHRO_SES_FROM_EMAIL=noreply@yehro.com
YEHRO_SES_REPLY_TO=support@yehro.com
YEHRO_SES_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123:yehro-ses-events
YEHRO_SES_WEBHOOK_SECRET=<64 hex chars from setup_project.sh>
```

## Migration

`migrations/<timestamp>_create_ses_suppressions.js`:

```javascript
exports.up = async (knex) => {
  await knex.schema.createTable('ses_suppressions', (t) => {
    t.bigIncrements('id');
    t.string('email').notNullable().unique();
    t.string('reason').notNullable();
    t.text('reason_detail');
    t.timestamp('last_event_at', { useTz: true }).notNullable();
    t.integer('event_count').notNullable().defaultTo(1);
    t.timestamps(true, true);
    t.index('reason');
    t.index('last_event_at');
  });
};
exports.down = (knex) => knex.schema.dropTable('ses_suppressions');
```

## Suppression list — `src/suppressions.js`

```javascript
const knex = require('./db');  // your existing knex instance

const PERMANENT_REASONS = ['bounce_permanent', 'complaint', 'manual'];

async function suppressed(email) {
  const row = await knex('ses_suppressions')
    .where({ email: email.toLowerCase() })
    .whereIn('reason', PERMANENT_REASONS)
    .first('id');
  return !!row;
}

async function record(email, reason, detail = {}) {
  const e = email.toLowerCase();
  const now = new Date();
  const detailJson = JSON.stringify(detail);

  // Postgres ON CONFLICT upsert. MySQL: replace with INSERT ... ON DUPLICATE KEY UPDATE.
  return knex.raw(
    `INSERT INTO ses_suppressions (email, reason, reason_detail, last_event_at, event_count, created_at, updated_at)
     VALUES (?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT (email) DO UPDATE SET
       reason = EXCLUDED.reason,
       reason_detail = EXCLUDED.reason_detail,
       last_event_at = EXCLUDED.last_event_at,
       updated_at = EXCLUDED.updated_at,
       event_count = ses_suppressions.event_count + 1`,
    [e, reason, detailJson, now, now, now]
  );
}

async function unsuppress(email) {
  return knex('ses_suppressions').where({ email: email.toLowerCase() }).del();
}

module.exports = { suppressed, record, unsuppress, PERMANENT_REASONS };
```

## Mailer — `src/mailer.js`

```javascript
const { SESv2Client, SendEmailCommand } = require('@aws-sdk/client-sesv2');
const { suppressed } = require('./suppressions');

const env = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`Missing env var: ${k}`);
  return v;
};

// Replace YEHRO with your <UPPER_SLUG>.
const PREFIX = 'YEHRO_';

const client = new SESv2Client({
  region: env(`${PREFIX}SES_REGION`),
  credentials: {
    accessKeyId: env(`${PREFIX}SES_ACCESS_KEY`),
    secretAccessKey: env(`${PREFIX}SES_SECRET_KEY`),
  },
});

const FROM = env(`${PREFIX}SES_FROM_EMAIL`);
const REPLY_TO = env(`${PREFIX}SES_REPLY_TO`);
const CONFIG_SET = env(`${PREFIX}SES_CONFIGURATION_SET`);

/**
 * Raw send. Does not check suppression list. Caller is responsible.
 * `message` = { to, cc?, bcc?, subject, text, html?, replyTo? }
 */
async function deliver(message) {
  const toAddrs = [].concat(message.to);
  const ccAddrs = [].concat(message.cc || []);
  const bccAddrs = [].concat(message.bcc || []);

  const cmd = new SendEmailCommand({
    FromEmailAddress: FROM,
    ReplyToAddresses: [message.replyTo || REPLY_TO],
    Destination: {
      ToAddresses: toAddrs,
      CcAddresses: ccAddrs,
      BccAddresses: bccAddrs,
    },
    Content: {
      Simple: {
        Subject: { Data: message.subject, Charset: 'UTF-8' },
        Body: {
          Text: { Data: message.text, Charset: 'UTF-8' },
          ...(message.html && { Html: { Data: message.html, Charset: 'UTF-8' } }),
        },
      },
    },
    ConfigurationSetName: CONFIG_SET,
  });

  return client.send(cmd);
}

/**
 * Suppression-aware send. Returns one of:
 *   { ok: true, messageId }
 *   { ok: false, error }
 *   { dropped: true, reason: 'suppressed', addresses: [...] }
 */
async function deliverChecked(message) {
  const all = [].concat(message.to, message.cc || [], message.bcc || []);
  const blocked = [];
  for (const addr of all) {
    if (await suppressed(addr)) blocked.push(addr);
  }
  if (blocked.length) {
    return { dropped: true, reason: 'suppressed', addresses: blocked };
  }
  try {
    const resp = await deliver(message);
    return { ok: true, messageId: resp.MessageId };
  } catch (err) {
    return { ok: false, error: err };
  }
}

module.exports = { deliver, deliverChecked };
```

## Event processor — `src/sesEventProcessor.js`

```javascript
const { record } = require('./suppressions');

async function processEvent(event) {
  switch (event.eventType) {
    case 'Bounce': {
      const { bounceType, bounceSubType, bouncedRecipients = [], feedbackId } = event.bounce;
      const reason = bounceType === 'Permanent' ? 'bounce_permanent' : 'bounce_transient';
      for (const r of bouncedRecipients) {
        await record(r.emailAddress, reason, {
          type: bounceType,
          subtype: bounceSubType,
          diagnostic: r.diagnosticCode,
          status: r.status,
          messageId: event.mail?.messageId,
          feedbackId,
        });
        console.log(`[ses] ${bounceType} bounce: ${r.emailAddress} (${bounceSubType})`);
      }
      return;
    }
    case 'Complaint': {
      const { complainedRecipients = [], complaintFeedbackType, feedbackId } = event.complaint;
      for (const r of complainedRecipients) {
        await record(r.emailAddress, 'complaint', {
          feedbackType: complaintFeedbackType,
          messageId: event.mail?.messageId,
          feedbackId,
        });
        console.warn(`[ses] COMPLAINT: ${r.emailAddress} (${complaintFeedbackType || 'unspecified'})`);
      }
      return;
    }
    case 'Delivery':
      console.log(`[ses] delivered: ${(event.delivery.recipients || []).join(', ')} (msg ${event.mail?.messageId})`);
      return;
    case 'Send':
      return;
    case 'Reject':
      console.error(`[ses] REJECT (msg ${event.mail?.messageId}): ${event.reject?.reason}`);
      return;
    case 'RenderingFailure':
      console.error(`[ses] rendering failure: ${JSON.stringify(event.failure)}`);
      return;
    case 'DeliveryDelay':
      console.warn(`[ses] delivery delay (msg ${event.mail?.messageId}): ${event.deliveryDelay?.delayType}`);
      return;
    default:
      console.log(`[ses] unhandled event type: ${event.eventType}`);
  }
}

module.exports = { processEvent };
```

## Webhook handler — `src/routes/sesWebhook.js`

```javascript
const crypto = require('crypto');
const express = require('express');
const { processEvent } = require('../sesEventProcessor');

const router = express.Router();

const env = (k) => process.env[k];
const PREFIX = 'YEHRO_';  // <-- change to your <UPPER_SLUG>_
const WEBHOOK_SECRET = env(`${PREFIX}SES_WEBHOOK_SECRET`);
const EXPECTED_TOPIC_ARN = env(`${PREFIX}SES_SNS_TOPIC_ARN`);

const SNS_HOST_RE = /^sns\.[a-z0-9-]+\.amazonaws\.com$/;

function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

// IMPORTANT: SNS sends Content-Type: text/plain. We need the raw body.
// Express's express.json() only parses application/json, so text/plain passes
// through unparsed. We use express.text() to read it.
router.post(
  '/webhooks/ses/:token',
  express.text({ type: '*/*', limit: '256kb' }),
  async (req, res) => {
    // 1. URL secret check — first thing, constant time
    if (!constantTimeEqual(req.params.token, WEBHOOK_SECRET)) {
      return res.status(404).send('Not Found');
    }

    // 2. Parse body
    let payload;
    try {
      payload = JSON.parse(req.body);
    } catch (e) {
      return res.status(400).send('Bad JSON');
    }

    // 3. TopicArn check
    if (payload.TopicArn !== EXPECTED_TOPIC_ARN) {
      console.warn(`[ses_webhook] TopicArn mismatch: ${payload.TopicArn}`);
      return res.status(400).send('Bad TopicArn');
    }

    // 4. Dispatch by Type
    try {
      switch (payload.Type) {
        case 'SubscriptionConfirmation':
          await confirmSubscription(payload);
          return res.status(200).send('OK');
        case 'Notification': {
          // For low volume, process inline. For higher volume, enqueue
          // (Bull, BullMQ, AWS SQS, etc.) and return 200 immediately.
          const event = JSON.parse(payload.Message);
          await processEvent(event);
          return res.status(200).send('OK');
        }
        case 'UnsubscribeConfirmation':
          console.warn(`[ses_webhook] UnsubscribeConfirmation for ${payload.TopicArn}`);
          return res.status(200).send('OK');
        default:
          console.log(`[ses_webhook] unknown Type: ${payload.Type}`);
          return res.status(200).send('OK');
      }
    } catch (err) {
      console.error('[ses_webhook] processing error:', err);
      // Return 500 so SNS retries with backoff. Be sure your processing is idempotent.
      return res.status(500).send('Internal Server Error');
    }
  }
);

async function confirmSubscription(payload) {
  const url = new URL(payload.SubscribeURL);
  if (url.protocol !== 'https:' || !SNS_HOST_RE.test(url.hostname)) {
    console.error(`[ses_webhook] refusing to fetch SubscribeURL with bad host: ${url.hostname}`);
    return;
  }
  const resp = await fetch(payload.SubscribeURL);
  if (resp.ok) {
    console.log(`[ses_webhook] subscription confirmed for ${payload.TopicArn}`);
  } else {
    console.error(`[ses_webhook] confirmation GET returned ${resp.status}`);
  }
}

module.exports = router;
```

In your `app.js` / `server.js`:

```javascript
const sesWebhook = require('./routes/sesWebhook');
app.use(sesWebhook);
```

If your app uses CSRF middleware globally, exempt `/webhooks/ses/*` from it. The URL-secret check is the auth mechanism.

## Sending mail

```javascript
const { deliverChecked } = require('./mailer');

const result = await deliverChecked({
  to: 'user@example.com',
  subject: 'Welcome',
  text: 'Hi there\n',
  html: '<p>Hi there</p>',
});

if (result.ok) {
  console.log('sent', result.messageId);
} else if (result.dropped) {
  console.log('not sent (suppressed):', result.addresses);
} else {
  console.error('send failed:', result.error);
}
```

## Test

```javascript
// 1. send → 'success@simulator.amazonses.com' — no suppression row, message arrives at simulator
// 2. send → 'bounce@simulator.amazonses.com' — ~30s later, row with reason='bounce_permanent'
// 3. send → 'complaint@simulator.amazonses.com' — ~30s later, row with reason='complaint'
// 4. send → 'bounce@simulator.amazonses.com' again — deliverChecked returns { dropped: true, ... }
```
