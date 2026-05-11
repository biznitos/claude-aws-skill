# Python + FastAPI quickstart

For FastAPI apps. For Flask, Django, or Starlette, the structure is identical; adapt route registration and request body reading. SQLAlchemy + Postgres assumed; trivially portable to other ORMs / databases.

## Dependencies

```bash
pip install fastapi uvicorn boto3 sqlalchemy psycopg2-binary httpx
# or via poetry/uv:
# uv add fastapi uvicorn boto3 sqlalchemy psycopg2-binary httpx
```

If the app uses Celery / Dramatiq / RQ for background jobs, use it — the patterns below show inline processing for simplicity.

## Env vars

Replace `YEHRO` with your `<UPPER_SLUG>`.

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

If using Alembic:

```bash
alembic revision -m "create_ses_suppressions"
```

```python
# alembic/versions/<rev>_create_ses_suppressions.py
from alembic import op
import sqlalchemy as sa

def upgrade():
    op.create_table(
        "ses_suppressions",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("email", sa.String, nullable=False, unique=True),
        sa.Column("reason", sa.String, nullable=False),
        sa.Column("reason_detail", sa.Text),
        sa.Column("last_event_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("event_count", sa.Integer, nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_ses_suppressions_reason", "ses_suppressions", ["reason"])
    op.create_index("ix_ses_suppressions_last_event_at", "ses_suppressions", ["last_event_at"])

def downgrade():
    op.drop_table("ses_suppressions")
```

## Suppression — `app/suppressions.py`

```python
import json
from datetime import datetime, timezone
from typing import Iterable

from sqlalchemy import Column, BigInteger, String, Text, Integer, DateTime
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session, declarative_base

Base = declarative_base()

PERMANENT_REASONS = ("bounce_permanent", "complaint", "manual")
ALL_REASONS = PERMANENT_REASONS + ("bounce_transient",)


class SesSuppression(Base):
    __tablename__ = "ses_suppressions"
    id = Column(BigInteger, primary_key=True)
    email = Column(String, nullable=False, unique=True)
    reason = Column(String, nullable=False)
    reason_detail = Column(Text)
    last_event_at = Column(DateTime(timezone=True), nullable=False)
    event_count = Column(Integer, nullable=False, default=1)
    created_at = Column(DateTime(timezone=True), nullable=False)
    updated_at = Column(DateTime(timezone=True), nullable=False)


def suppressed(db: Session, email: str) -> bool:
    e = email.lower()
    row = (
        db.query(SesSuppression.id)
        .filter(SesSuppression.email == e)
        .filter(SesSuppression.reason.in_(PERMANENT_REASONS))
        .first()
    )
    return row is not None


def record(db: Session, email: str, reason: str, detail: dict | None = None) -> None:
    e = email.lower()
    now = datetime.now(timezone.utc)
    payload = {
        "email": e,
        "reason": reason,
        "reason_detail": json.dumps(detail or {}),
        "last_event_at": now,
        "event_count": 1,
        "created_at": now,
        "updated_at": now,
    }
    # Postgres ON CONFLICT. For MySQL use mysql.insert + on_duplicate_key_update.
    stmt = pg_insert(SesSuppression).values(**payload)
    stmt = stmt.on_conflict_do_update(
        index_elements=["email"],
        set_={
            "reason": stmt.excluded.reason,
            "reason_detail": stmt.excluded.reason_detail,
            "last_event_at": stmt.excluded.last_event_at,
            "updated_at": stmt.excluded.updated_at,
            "event_count": SesSuppression.event_count + 1,
        },
    )
    db.execute(stmt)
    db.commit()


def unsuppress(db: Session, email: str) -> int:
    e = email.lower()
    count = db.query(SesSuppression).filter(SesSuppression.email == e).delete()
    db.commit()
    return count


def list_blocked(db: Session, reasons: Iterable[str] = PERMANENT_REASONS) -> list[SesSuppression]:
    return (
        db.query(SesSuppression)
        .filter(SesSuppression.reason.in_(list(reasons)))
        .order_by(SesSuppression.last_event_at.desc())
        .all()
    )
```

## Mailer — `app/mailer.py`

```python
import os
from dataclasses import dataclass
from typing import Optional, Union

import boto3
from sqlalchemy.orm import Session

from app.suppressions import suppressed


def _env(key: str) -> str:
    v = os.environ.get(key)
    if not v:
        raise RuntimeError(f"Missing env var: {key}")
    return v


PREFIX = "YEHRO_"   # <-- change to your <UPPER_SLUG>_

_ses_client = None


def ses():
    global _ses_client
    if _ses_client is None:
        _ses_client = boto3.client(
            "sesv2",
            region_name=_env(f"{PREFIX}SES_REGION"),
            aws_access_key_id=_env(f"{PREFIX}SES_ACCESS_KEY"),
            aws_secret_access_key=_env(f"{PREFIX}SES_SECRET_KEY"),
        )
    return _ses_client


@dataclass
class Message:
    to: Union[str, list[str]]
    subject: str
    text: str
    html: Optional[str] = None
    cc: Optional[list[str]] = None
    bcc: Optional[list[str]] = None
    reply_to: Optional[str] = None


@dataclass
class Sent:
    message_id: str


@dataclass
class Dropped:
    addresses: list[str]
    reason: str = "suppressed"


@dataclass
class Failed:
    error: Exception


def deliver(msg: Message) -> Sent:
    """Raw send. No suppression check."""
    to = [msg.to] if isinstance(msg.to, str) else list(msg.to)
    body = {"Text": {"Data": msg.text, "Charset": "UTF-8"}}
    if msg.html:
        body["Html"] = {"Data": msg.html, "Charset": "UTF-8"}

    resp = ses().send_email(
        FromEmailAddress=_env(f"{PREFIX}SES_FROM_EMAIL"),
        ReplyToAddresses=[msg.reply_to or _env(f"{PREFIX}SES_REPLY_TO")],
        Destination={
            "ToAddresses": to,
            "CcAddresses": msg.cc or [],
            "BccAddresses": msg.bcc or [],
        },
        Content={"Simple": {"Subject": {"Data": msg.subject, "Charset": "UTF-8"}, "Body": body}},
        ConfigurationSetName=_env(f"{PREFIX}SES_CONFIGURATION_SET"),
    )
    return Sent(message_id=resp["MessageId"])


def deliver_checked(db: Session, msg: Message) -> Union[Sent, Dropped, Failed]:
    """Suppression-aware send."""
    to = [msg.to] if isinstance(msg.to, str) else list(msg.to)
    all_addrs = to + (msg.cc or []) + (msg.bcc or [])
    blocked = [a for a in all_addrs if suppressed(db, a)]
    if blocked:
        return Dropped(addresses=blocked)
    try:
        return deliver(msg)
    except Exception as e:
        return Failed(error=e)
```

## Event processor — `app/ses_event_processor.py`

```python
import logging
from sqlalchemy.orm import Session
from app.suppressions import record

log = logging.getLogger(__name__)


def process(db: Session, event: dict) -> None:
    et = event.get("eventType")

    if et == "Bounce":
        bounce = event["bounce"]
        btype = bounce.get("bounceType")
        bsub = bounce.get("bounceSubType")
        reason = "bounce_permanent" if btype == "Permanent" else "bounce_transient"
        for r in bounce.get("bouncedRecipients", []):
            record(db, r["emailAddress"], reason, {
                "type": btype, "subtype": bsub,
                "action": r.get("action"), "status": r.get("status"),
                "diagnostic": r.get("diagnosticCode"),
                "message_id": event.get("mail", {}).get("messageId"),
                "feedback_id": bounce.get("feedbackId"),
            })
            log.info(f"[ses] {btype} bounce: {r['emailAddress']} ({bsub})")

    elif et == "Complaint":
        complaint = event["complaint"]
        for r in complaint.get("complainedRecipients", []):
            record(db, r["emailAddress"], "complaint", {
                "feedback_type": complaint.get("complaintFeedbackType"),
                "message_id": event.get("mail", {}).get("messageId"),
                "feedback_id": complaint.get("feedbackId"),
            })
            log.warning(f"[ses] COMPLAINT: {r['emailAddress']} ({complaint.get('complaintFeedbackType')})")

    elif et == "Delivery":
        recipients = ", ".join(event.get("delivery", {}).get("recipients", []))
        log.info(f"[ses] delivered: {recipients} (msg {event.get('mail', {}).get('messageId')})")

    elif et == "Send":
        log.debug(f"[ses] send accepted (msg {event.get('mail', {}).get('messageId')})")

    elif et == "Reject":
        log.error(f"[ses] REJECT: {event.get('reject', {}).get('reason')}")

    elif et == "RenderingFailure":
        log.error(f"[ses] rendering failure: {event.get('failure')}")

    elif et == "DeliveryDelay":
        log.warning(f"[ses] delay: {event.get('deliveryDelay', {}).get('delayType')}")

    else:
        log.info(f"[ses] unhandled event type: {et}")
```

## Webhook route — `app/routes/ses_webhook.py`

```python
import hmac
import json
import logging
import os
import re
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy.orm import Session

from app.db import get_db
from app.ses_event_processor import process

router = APIRouter()
log = logging.getLogger(__name__)

PREFIX = "YEHRO_"   # <-- change
WEBHOOK_SECRET = os.environ.get(f"{PREFIX}SES_WEBHOOK_SECRET", "")
EXPECTED_TOPIC_ARN = os.environ.get(f"{PREFIX}SES_SNS_TOPIC_ARN", "")
SNS_HOST_RE = re.compile(r"^sns\.[a-z0-9-]+\.amazonaws\.com$")


def constant_time_eq(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())


@router.post("/webhooks/ses/{token}")
async def ses_webhook(token: str, request: Request, db: Session = Depends(get_db)):
    # 1. URL secret check — first, constant time
    if not constant_time_eq(token, WEBHOOK_SECRET):
        return Response(status_code=status.HTTP_404_NOT_FOUND)

    # 2. Parse raw body (SNS sends Content-Type: text/plain)
    raw = await request.body()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return Response(status_code=status.HTTP_400_BAD_REQUEST, content="Bad JSON")

    # 3. TopicArn check
    if payload.get("TopicArn") != EXPECTED_TOPIC_ARN:
        log.warning(f"[ses_webhook] TopicArn mismatch: {payload.get('TopicArn')}")
        return Response(status_code=status.HTTP_400_BAD_REQUEST, content="Bad TopicArn")

    # 4. Dispatch
    msg_type = payload.get("Type")
    try:
        if msg_type == "SubscriptionConfirmation":
            await _confirm_subscription(payload)
        elif msg_type == "Notification":
            event = json.loads(payload["Message"])
            process(db, event)
        elif msg_type == "UnsubscribeConfirmation":
            log.warning(f"[ses_webhook] UnsubscribeConfirmation for {payload.get('TopicArn')}")
        else:
            log.info(f"[ses_webhook] unknown Type: {msg_type}")
        return Response(status_code=status.HTTP_200_OK)
    except Exception:
        log.exception("[ses_webhook] processing error")
        # 500 so SNS retries with backoff. Processing must be idempotent.
        return Response(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR)


async def _confirm_subscription(payload: dict) -> None:
    url = payload["SubscribeURL"]
    parsed = urlparse(url)
    if parsed.scheme != "https" or not SNS_HOST_RE.match(parsed.hostname or ""):
        log.error(f"[ses_webhook] refusing to fetch SubscribeURL with bad host: {parsed.hostname}")
        return
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(url)
    if resp.is_success:
        log.info(f"[ses_webhook] subscription confirmed for {payload.get('TopicArn')}")
    else:
        log.error(f"[ses_webhook] confirmation GET returned {resp.status_code}")
```

Register in `main.py`:

```python
from app.routes.ses_webhook import router as ses_webhook_router
app.include_router(ses_webhook_router)
```

## Test

```python
from app.mailer import Message, deliver_checked

# 1. Success
deliver_checked(db, Message(to="success@simulator.amazonses.com", subject="t", text="t"))

# 2. Bounce
deliver_checked(db, Message(to="bounce@simulator.amazonses.com", subject="t", text="t"))
# wait 30s
db.query(SesSuppression).filter_by(email="bounce@simulator.amazonses.com").first()
# -> reason="bounce_permanent"

# 3. Complaint
deliver_checked(db, Message(to="complaint@simulator.amazonses.com", subject="t", text="t"))

# 4. Suppressed
deliver_checked(db, Message(to="bounce@simulator.amazonses.com", subject="t", text="t"))
# -> Dropped(addresses=["bounce@simulator.amazonses.com"])
```
