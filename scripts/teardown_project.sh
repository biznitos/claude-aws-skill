#!/usr/bin/env bash
# teardown_project.sh <slug> <domain> <region> [--profile <name>]
#
# Removes all AWS resources for a project. Does NOT touch DNS or app code.

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

USER_NAME="ses-sender-${SLUG}"
POLICY_NAME="ses-send-${SLUG}"
CONFIG_SET="$SLUG"
TOPIC_NAME="${SLUG}-ses-events"
EVENT_DEST_NAME="${SLUG}-sns"

echo "=== Tearing down: ${SLUG} (${DOMAIN}) in ${REGION} ==="
read -p "Type the slug '${SLUG}' to confirm: " CONFIRM
[ "$CONFIRM" = "$SLUG" ] || { echo "Aborted."; exit 1; }
echo

if aws iam get-user --user-name "$USER_NAME" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "[1] Deleting IAM access keys for ${USER_NAME}"
  for KEY_ID in $(aws iam list-access-keys --user-name "$USER_NAME" "${AWS_OPTS[@]}" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$KEY_ID" "${AWS_OPTS[@]}"
    echo "    deleted ${KEY_ID}"
  done
  aws iam delete-user-policy --user-name "$USER_NAME" --policy-name "$POLICY_NAME" "${AWS_OPTS[@]}" 2>/dev/null || true
  aws iam delete-user --user-name "$USER_NAME" "${AWS_OPTS[@]}"
  echo "    user deleted"
else
  echo "[1] IAM user ${USER_NAME}: not present"
fi

echo "[2] Removing event destination ${EVENT_DEST_NAME}"
aws sesv2 delete-configuration-set-event-destination \
  --configuration-set-name "$CONFIG_SET" \
  --event-destination-name "$EVENT_DEST_NAME" \
  "${AWS_OPTS[@]}" 2>/dev/null || echo "    (not present)"

TOPIC_ARN=$(aws sns list-topics "${AWS_OPTS[@]}" | jq -r --arg name "$TOPIC_NAME" '.Topics[] | select(.TopicArn | endswith(":" + $name)) | .TopicArn')
if [ -n "$TOPIC_ARN" ]; then
  echo "[3] Deleting SNS topic ${TOPIC_ARN}"
  for SUB in $(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" "${AWS_OPTS[@]}" --query 'Subscriptions[?SubscriptionArn!=`PendingConfirmation`].SubscriptionArn' --output text); do
    aws sns unsubscribe --subscription-arn "$SUB" "${AWS_OPTS[@]}" || true
  done
  aws sns delete-topic --topic-arn "$TOPIC_ARN" "${AWS_OPTS[@]}"
  echo "    deleted"
else
  echo "[3] SNS topic ${TOPIC_NAME}: not present"
fi

echo "[4] Deleting configuration set ${CONFIG_SET}"
aws sesv2 delete-configuration-set --configuration-set-name "$CONFIG_SET" "${AWS_OPTS[@]}" 2>/dev/null \
  || echo "    (not present)"

echo "[5] Deleting email identity ${DOMAIN}"
aws sesv2 delete-email-identity --email-identity "$DOMAIN" "${AWS_OPTS[@]}" 2>/dev/null \
  || echo "    (not present)"

echo
echo "Done. DNS and app code were NOT touched."
echo "Local webhook secret is in output/${SLUG}/.webhook_secret if you want to remove it."
