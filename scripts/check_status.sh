#!/usr/bin/env bash
# check_status.sh <slug> <domain> <region> [--profile <name>]

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <slug> <domain> <region> [--profile <name>]"
  exit 1
fi

SLUG="$1"
DOMAIN="$2"
REGION="$3"
shift 3

AWS_OPTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) AWS_OPTS+=(--profile "$2"); shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
AWS_OPTS+=(--region "$REGION")

command -v aws >/dev/null || { echo "ERROR: aws CLI not installed"; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not installed"; exit 1; }

TOPIC_NAME="${SLUG}-ses-events"
USER_NAME="ses-sender-${SLUG}"

echo "=== Project: ${SLUG} (${DOMAIN}) in ${REGION} ==="
echo

ACCOUNT=$(aws sesv2 get-account "${AWS_OPTS[@]}")
PROD=$(echo "$ACCOUNT" | jq -r '.ProductionAccessEnabled')
SENT=$(echo "$ACCOUNT" | jq -r '.SendQuota.SentLast24Hours')
QUOTA=$(echo "$ACCOUNT" | jq -r '.SendQuota.Max24HourSend')
echo "Account:           production=${PROD}, sent ${SENT}/${QUOTA} (last 24h)"

if IDENTITY=$(aws sesv2 get-email-identity --email-identity "$DOMAIN" "${AWS_OPTS[@]}" 2>/dev/null); then
  VERIFY=$(echo "$IDENTITY" | jq -r '.VerifiedForSendingStatus')
  DKIM_STATUS=$(echo "$IDENTITY" | jq -r '.DkimAttributes.Status')
  DKIM_ENABLED=$(echo "$IDENTITY" | jq -r '.DkimAttributes.SigningEnabled')
  MAIL_FROM_DOM=$(echo "$IDENTITY" | jq -r '.MailFromAttributes.MailFromDomain // "(none)"')
  MAIL_FROM_STATUS=$(echo "$IDENTITY" | jq -r '.MailFromAttributes.MailFromDomainStatus // "n/a"')
  CONFIG_SET=$(echo "$IDENTITY" | jq -r '.ConfigurationSetName // "(none)"')

  echo "Identity:          verified=${VERIFY}, DKIM=${DKIM_STATUS} (signing=${DKIM_ENABLED})"
  echo "MAIL FROM:         ${MAIL_FROM_DOM} (${MAIL_FROM_STATUS})"
  echo "Configuration set: ${CONFIG_SET}"
else
  echo "Identity:          NOT FOUND — run setup_project.sh first"
  exit 1
fi

TOPIC_ARN=$(aws sns list-topics "${AWS_OPTS[@]}" | jq -r --arg name "$TOPIC_NAME" '.Topics[] | select(.TopicArn | endswith(":" + $name)) | .TopicArn')
if [ -n "$TOPIC_ARN" ]; then
  echo "SNS topic:         ${TOPIC_ARN}"
  aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" "${AWS_OPTS[@]}" \
    | jq -r '.Subscriptions[] | "  -> \(.Protocol)  \(.Endpoint)  [\(.SubscriptionArn)]"'
else
  echo "SNS topic:         NOT FOUND"
fi

EVENT_DESTS=$(aws sesv2 get-configuration-set-event-destinations --configuration-set-name "$SLUG" "${AWS_OPTS[@]}" 2>/dev/null || echo '{"EventDestinations":[]}')
COUNT=$(echo "$EVENT_DESTS" | jq -r '.EventDestinations | length')
echo "Event destinations: ${COUNT}"
echo "$EVENT_DESTS" | jq -r '.EventDestinations[] | "  -> \(.Name)  enabled=\(.Enabled)  types=\(.MatchingEventTypes | join(","))"'

if aws iam get-user --user-name "$USER_NAME" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "IAM user:          ${USER_NAME}"
  aws iam list-access-keys --user-name "$USER_NAME" "${AWS_OPTS[@]}" \
    | jq -r '.AccessKeyMetadata[] | "  -> \(.AccessKeyId)  \(.Status)  created \(.CreateDate)"'
else
  echo "IAM user:          NOT FOUND"
fi

echo

if [ "$DKIM_STATUS" != "SUCCESS" ] || [ "$MAIL_FROM_STATUS" != "SUCCESS" ]; then
  echo "Verification incomplete. Re-print DNS:  cat output/${SLUG}/dns.txt"
  echo "Common causes:"
  echo "  - DNS not yet propagated (minutes to hours)"
  echo "  - CNAMEs entered with zone suffix appended by provider (Cloudflare auto-appends)"
  echo "  - Verify with: dig CNAME <token>._domainkey.${DOMAIN}"
fi
