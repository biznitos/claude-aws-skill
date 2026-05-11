#!/usr/bin/env bash
# setup_project.sh \
#   --slug <slug> \
#   --domain <domain> \
#   --region <region> \
#   --base-url <https://app.example.com> \
#   --webhook-path <prefix, e.g. /webhooks/ses> \
#   --from <noreply@example.com> \
#   --reply-to <support@example.com> \
#   [--profile <aws-profile-name>]
#
# Provisions one project's AWS resources, namespaced by slug. Generates a
# 256-bit random webhook secret and appends it to the webhook path. The
# full URL (path + secret) is what gets subscribed to SNS.

set -euo pipefail

SLUG=""
DOMAIN=""
REGION=""
BASE_URL=""
WEBHOOK_PATH=""
FROM_EMAIL=""
REPLY_TO=""
PROFILE_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)         SLUG="$2"; shift 2 ;;
    --domain)       DOMAIN="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --base-url)     BASE_URL="$2"; shift 2 ;;
    --webhook-path) WEBHOOK_PATH="$2"; shift 2 ;;
    --from)         FROM_EMAIL="$2"; shift 2 ;;
    --reply-to)     REPLY_TO="$2"; shift 2 ;;
    --profile)      PROFILE_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Validation ---
for V in SLUG DOMAIN REGION BASE_URL WEBHOOK_PATH FROM_EMAIL REPLY_TO; do
  if [ -z "${!V}" ]; then
    echo "ERROR: --${V,,} is required"; exit 1
  fi
done
[[ "$SLUG" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "ERROR: slug must match ^[a-z][a-z0-9-]*$"; exit 1; }
[[ "$BASE_URL" =~ ^https:// ]] || { echo "ERROR: base-url must start with https://"; exit 1; }
[[ "$WEBHOOK_PATH" =~ ^/ ]] || { echo "ERROR: webhook-path must start with /"; exit 1; }
# Strip any trailing slash from base-url and webhook-path to avoid double slashes
BASE_URL="${BASE_URL%/}"
WEBHOOK_PATH="${WEBHOOK_PATH%/}"

command -v aws     >/dev/null || { echo "ERROR: aws CLI not installed"; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: jq not installed"; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl not installed"; exit 1; }

AWS_OPTS=(--region "$REGION")
[ -n "$PROFILE_NAME" ] && AWS_OPTS+=(--profile "$PROFILE_NAME")

# Derived names
UPPER_SLUG=$(echo "$SLUG" | tr 'a-z-' 'A-Z_')
CONFIG_SET="$SLUG"
TOPIC_NAME="${SLUG}-ses-events"
USER_NAME="ses-sender-${SLUG}"
POLICY_NAME="ses-send-${SLUG}"
EVENT_DEST_NAME="${SLUG}-sns"
MAIL_FROM="mail.${DOMAIN}"

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_OPTS[@]}" --query Account --output text)
IDENTITY_ARN="arn:aws:ses:${REGION}:${ACCOUNT_ID}:identity/${DOMAIN}"

OUT_DIR="./output/${SLUG}"
mkdir -p "$OUT_DIR"

# Generate or reuse webhook secret
SECRET_FILE="${OUT_DIR}/.webhook_secret"
if [ -f "$SECRET_FILE" ]; then
  WEBHOOK_SECRET=$(cat "$SECRET_FILE")
  echo "Reusing existing webhook secret from ${SECRET_FILE}"
else
  WEBHOOK_SECRET=$(openssl rand -hex 32)
  echo "$WEBHOOK_SECRET" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  echo "Generated new webhook secret (saved to ${SECRET_FILE})"
fi

WEBHOOK_URL="${BASE_URL}${WEBHOOK_PATH}/${WEBHOOK_SECRET}"

echo
echo "=== SES project setup ==="
echo "    Slug:       ${SLUG}"
echo "    Domain:     ${DOMAIN}"
echo "    Region:     ${REGION}"
echo "    Account:    ${ACCOUNT_ID}"
echo "    Webhook:    ${BASE_URL}${WEBHOOK_PATH}/<secret>"
echo

# =============================================================================
# 1. Configuration set
# =============================================================================
echo "[1/7] Configuration set: ${CONFIG_SET}"
if aws sesv2 get-configuration-set --configuration-set-name "$CONFIG_SET" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "      exists, skipping"
else
  aws sesv2 create-configuration-set \
    --configuration-set-name "$CONFIG_SET" \
    --sending-options SendingEnabled=true \
    --reputation-options ReputationMetricsEnabled=true \
    --tags "Key=project,Value=${SLUG}" \
    "${AWS_OPTS[@]}" >/dev/null
  echo "      created"
fi

# =============================================================================
# 2. Email identity (Easy DKIM 2048)
# =============================================================================
echo "[2/7] Email identity: ${DOMAIN}"
if aws sesv2 get-email-identity --email-identity "$DOMAIN" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "      exists, skipping creation"
else
  aws sesv2 create-email-identity \
    --email-identity "$DOMAIN" \
    --configuration-set-name "$CONFIG_SET" \
    --dkim-signing-attributes "NextSigningKeyLength=RSA_2048_BIT" \
    --tags "Key=project,Value=${SLUG}" \
    "${AWS_OPTS[@]}" >/dev/null
  echo "      created with Easy DKIM (2048-bit)"
fi

aws sesv2 put-email-identity-configuration-set-attributes \
  --email-identity "$DOMAIN" \
  --configuration-set-name "$CONFIG_SET" \
  "${AWS_OPTS[@]}" >/dev/null

aws sesv2 put-email-identity-mail-from-attributes \
  --email-identity "$DOMAIN" \
  --mail-from-domain "$MAIL_FROM" \
  --behavior-on-mx-failure USE_DEFAULT_VALUE \
  "${AWS_OPTS[@]}" >/dev/null
echo "      MAIL FROM: ${MAIL_FROM}"

# =============================================================================
# 3. SNS topic with locked-down policy
# =============================================================================
echo "[3/7] SNS topic: ${TOPIC_NAME}"
TOPIC_ARN=$(aws sns create-topic \
  --name "$TOPIC_NAME" \
  --tags "Key=project,Value=${SLUG}" \
  "${AWS_OPTS[@]}" \
  --query TopicArn --output text)
echo "      arn: ${TOPIC_ARN}"

TOPIC_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSESPublish",
      "Effect": "Allow",
      "Principal": {"Service": "ses.amazonaws.com"},
      "Action": "sns:Publish",
      "Resource": "${TOPIC_ARN}",
      "Condition": {"StringEquals": {"AWS:SourceAccount": "${ACCOUNT_ID}"}}
    },
    {
      "Sid": "AllowOwnerManage",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${ACCOUNT_ID}:root"},
      "Action": ["sns:GetTopicAttributes","sns:SetTopicAttributes","sns:Subscribe","sns:Unsubscribe","sns:ListSubscriptionsByTopic","sns:DeleteTopic"],
      "Resource": "${TOPIC_ARN}"
    }
  ]
}
JSON
)
aws sns set-topic-attributes \
  --topic-arn "$TOPIC_ARN" \
  --attribute-name Policy \
  --attribute-value "$TOPIC_POLICY" \
  "${AWS_OPTS[@]}" >/dev/null
echo "      topic policy locked to account SES publisher"

# =============================================================================
# 4. SNS HTTPS subscription
# =============================================================================
echo "[4/7] SNS subscription: ${BASE_URL}${WEBHOOK_PATH}/<secret>"
EXISTING=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" "${AWS_OPTS[@]}" \
  | jq -r --arg url "$WEBHOOK_URL" '.Subscriptions[] | select(.Endpoint == $url) | .SubscriptionArn' \
  | head -1)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "PendingConfirmation" ]; then
  echo "      already subscribed and confirmed: ${EXISTING}"
elif [ "$EXISTING" = "PendingConfirmation" ]; then
  echo "      existing subscription pending confirmation; SNS retries for up to 3 days"
else
  SUB_ARN=$(aws sns subscribe \
    --topic-arn "$TOPIC_ARN" \
    --protocol https \
    --notification-endpoint "$WEBHOOK_URL" \
    "${AWS_OPTS[@]}" \
    --query SubscriptionArn --output text)
  echo "      created (${SUB_ARN})"
  echo "      SNS is POSTing SubscriptionConfirmation to your webhook now."
  echo "      Your handler will auto-confirm if the endpoint is live and the URL secret matches."
fi

# =============================================================================
# 5. SES event destination -> SNS
# =============================================================================
echo "[5/7] SES event destination: ${EVENT_DEST_NAME}"
EVENT_DEST_BODY=$(cat <<JSON
{
  "Enabled": true,
  "MatchingEventTypes": ["SEND","REJECT","BOUNCE","COMPLAINT","DELIVERY","RENDERING_FAILURE","DELIVERY_DELAY"],
  "SnsDestination": {"TopicArn": "${TOPIC_ARN}"}
}
JSON
)

if aws sesv2 create-configuration-set-event-destination \
     --configuration-set-name "$CONFIG_SET" \
     --event-destination-name "$EVENT_DEST_NAME" \
     --event-destination "$EVENT_DEST_BODY" \
     "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  echo "      created"
else
  aws sesv2 update-configuration-set-event-destination \
    --configuration-set-name "$CONFIG_SET" \
    --event-destination-name "$EVENT_DEST_NAME" \
    --event-destination "$EVENT_DEST_BODY" \
    "${AWS_OPTS[@]}" >/dev/null
  echo "      updated existing"
fi

# =============================================================================
# 6. IAM user + scoped policy
# =============================================================================
echo "[6/7] IAM user: ${USER_NAME}"
USER_EXISTS=false
if aws iam get-user --user-name "$USER_NAME" "${AWS_OPTS[@]}" >/dev/null 2>&1; then
  USER_EXISTS=true
  echo "      exists, reusing"
else
  aws iam create-user --user-name "$USER_NAME" \
    --tags "Key=project,Value=${SLUG}" "Key=purpose,Value=ses-sender" \
    "${AWS_OPTS[@]}" >/dev/null
  echo "      created"
fi

POLICY_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SendFromDomainViaConfigSet",
      "Effect": "Allow",
      "Action": ["ses:SendEmail", "ses:SendRawEmail"],
      "Resource": [
        "${IDENTITY_ARN}",
        "arn:aws:ses:${REGION}:${ACCOUNT_ID}:configuration-set/${CONFIG_SET}"
      ],
      "Condition": {
        "StringLike": {"ses:FromAddress": "*@${DOMAIN}"}
      }
    }
  ]
}
JSON
)

aws iam put-user-policy \
  --user-name "$USER_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" \
  "${AWS_OPTS[@]}" >/dev/null
echo "      policy attached"

# =============================================================================
# 7. Access keys
# =============================================================================
echo "[7/7] Access keys"
KEY_COUNT=$(aws iam list-access-keys --user-name "$USER_NAME" "${AWS_OPTS[@]}" --query 'length(AccessKeyMetadata)' --output text)

ACCESS_KEY=""
SECRET_KEY=""
if [ "$KEY_COUNT" -ge 2 ]; then
  echo "      User already has 2 access keys (AWS max). Existing:"
  aws iam list-access-keys --user-name "$USER_NAME" "${AWS_OPTS[@]}" \
    --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status,Created:CreateDate}' --output table
  echo "      Delete one with: aws iam delete-access-key --user-name ${USER_NAME} --access-key-id AKIA..."
  echo "      Skipping key creation."
else
  KEY_JSON=$(aws iam create-access-key --user-name "$USER_NAME" "${AWS_OPTS[@]}")
  ACCESS_KEY=$(echo "$KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
  SECRET_KEY=$(echo "$KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')
  echo "      created"
fi

# =============================================================================
# Output files
# =============================================================================

IDENTITY_JSON=$(aws sesv2 get-email-identity --email-identity "$DOMAIN" "${AWS_OPTS[@]}")
DKIM_TOKENS=$(echo "$IDENTITY_JSON" | jq -r '.DkimAttributes.Tokens[]')

case "$REGION" in
  us-east-1) SES_SPF_INCLUDE="amazonses.com"; FEEDBACK_MX="feedback-smtp.us-east-1.amazonses.com" ;;
  *)         SES_SPF_INCLUDE="${REGION}.amazonses.com"; FEEDBACK_MX="feedback-smtp.${REGION}.amazonses.com" ;;
esac

# Human-readable DNS
{
  echo "DNS records for ${DOMAIN}"
  echo "================================"
  echo
  echo "DKIM (3 CNAMEs)"
  echo "---------------"
  for T in $DKIM_TOKENS; do
    echo "  Type:  CNAME"
    echo "  Name:  ${T}._domainkey.${DOMAIN}"
    echo "  Value: ${T}.dkim.amazonses.com"
    echo
  done
  echo "Custom MAIL FROM"
  echo "----------------"
  echo "  Type:     MX"
  echo "  Name:     ${MAIL_FROM}"
  echo "  Priority: 10"
  echo "  Value:    ${FEEDBACK_MX}"
  echo
  echo "  Type:  TXT"
  echo "  Name:  ${MAIL_FROM}"
  echo "  Value: \"v=spf1 include:${SES_SPF_INCLUDE} ~all\""
  echo
  echo "DMARC (start in monitoring mode)"
  echo "--------------------------------"
  echo "  Type:  TXT"
  echo "  Name:  _dmarc.${DOMAIN}"
  echo "  Value: \"v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}\""
} > "${OUT_DIR}/dns.txt"

# BIND zone file fragment
{
  echo "; SES DNS records for ${DOMAIN}"
  echo "; Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "\$TTL 300"
  echo
  echo "; --- DKIM ---"
  for T in $DKIM_TOKENS; do
    echo "${T}._domainkey.${DOMAIN}.    IN  CNAME   ${T}.dkim.amazonses.com."
  done
  echo
  echo "; --- Custom MAIL FROM ---"
  echo "${MAIL_FROM}.                    IN  MX  10  ${FEEDBACK_MX}."
  echo "${MAIL_FROM}.                    IN  TXT     \"v=spf1 include:${SES_SPF_INCLUDE} ~all\""
  echo
  echo "; --- DMARC ---"
  echo "_dmarc.${DOMAIN}.                IN  TXT     \"v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}\""
} > "${OUT_DIR}/zone.bind"

# Env vars
{
  echo "# SES env vars for project: ${SLUG}"
  echo "# Paste into .env / dokku config:set / fly secrets set / etc."
  echo "# DO NOT commit to git."
  echo
  echo "${UPPER_SLUG}_SES_REGION=${REGION}"
  if [ -n "$ACCESS_KEY" ]; then
    echo "${UPPER_SLUG}_SES_ACCESS_KEY=${ACCESS_KEY}"
    echo "${UPPER_SLUG}_SES_SECRET_KEY=${SECRET_KEY}"
  else
    echo "# ${UPPER_SLUG}_SES_ACCESS_KEY=<existing — see IAM console>"
    echo "# ${UPPER_SLUG}_SES_SECRET_KEY=<existing — cannot retrieve; rotate if lost>"
  fi
  echo "${UPPER_SLUG}_SES_CONFIGURATION_SET=${CONFIG_SET}"
  echo "${UPPER_SLUG}_SES_FROM_EMAIL=${FROM_EMAIL}"
  echo "${UPPER_SLUG}_SES_REPLY_TO=${REPLY_TO}"
  echo "${UPPER_SLUG}_SES_SNS_TOPIC_ARN=${TOPIC_ARN}"
  echo "${UPPER_SLUG}_SES_WEBHOOK_SECRET=${WEBHOOK_SECRET}"
  echo
  echo "# For reference (do NOT set as env vars):"
  echo "# Webhook prefix path (mounted in your app's router): ${WEBHOOK_PATH}/:token"
  echo "# Full subscribed URL: ${WEBHOOK_URL}"
} > "${OUT_DIR}/env.txt"
chmod 600 "${OUT_DIR}/env.txt"

# Summary
cat <<EOF

==============================================================================
  DONE
==============================================================================

  Project:           ${SLUG}
  Domain:            ${DOMAIN}
  Config set:        ${CONFIG_SET}
  SNS topic:         ${TOPIC_ARN}
  IAM user:          ${USER_NAME}
  Webhook prefix:    ${WEBHOOK_PATH}/:token
  Subscribed URL:    ${BASE_URL}${WEBHOOK_PATH}/<secret-in-env.txt>

  Output files in:   ${OUT_DIR}/
    env.txt          all env vars (chmod 600)
    dns.txt          DNS records (human-readable)
    zone.bind        BIND zone fragment (importable to Cloudflare etc.)
    .webhook_secret  the raw secret (chmod 600; rerun-safe)

==============================================================================
  NEXT STEPS
==============================================================================

  1. Add DNS records:
       cat ${OUT_DIR}/dns.txt

  2. Set env vars from ${OUT_DIR}/env.txt on your production host.

  3. Redeploy so the app has the new credentials.

  4. Poll status:
       ./scripts/check_status.sh ${SLUG} ${DOMAIN} ${REGION}${PROFILE_NAME:+ --profile ${PROFILE_NAME}}

  5. Test:
       Send from your app to bounce@simulator.amazonses.com — a row
       should appear in ses_suppressions within 30 seconds.

EOF
