#!/usr/bin/env bash
# init_account.sh <region> [--profile <name>]
#
# One-time per AWS account setup:
#   1. Confirms the account is in PRODUCTION mode (exits if sandbox).
#   2. Enables account-level suppression list for BOUNCE + COMPLAINT
#      (AWS-managed safety net across every project on this account).
#
# Idempotent. Safe to re-run.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <region> [--profile <name>]"
  exit 1
fi

REGION="$1"
shift
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

echo "=== SES account init in ${REGION} ==="

CALLER=$(aws sts get-caller-identity "${AWS_OPTS[@]}")
ACCOUNT_ID=$(echo "$CALLER" | jq -r .Account)
echo "    AWS account: ${ACCOUNT_ID}"

ACCOUNT=$(aws sesv2 get-account "${AWS_OPTS[@]}")
PROD=$(echo "$ACCOUNT" | jq -r '.ProductionAccessEnabled')

if [ "$PROD" != "true" ]; then
  echo
  echo "ERROR: This SES account is still in SANDBOX mode."
  echo "       Request production access via the SES console (Account dashboard"
  echo "       → Request production access) and re-run this script."
  exit 2
fi
echo "    Production mode: yes"

aws sesv2 put-account-suppression-attributes \
  --suppressed-reasons BOUNCE COMPLAINT \
  "${AWS_OPTS[@]}" >/dev/null
echo "    Suppression list (BOUNCE + COMPLAINT): enabled"

SEND=$(echo "$ACCOUNT" | jq -r '.SendingEnabled')
if [ "$SEND" != "true" ]; then
  echo
  echo "WARNING: Account-level sending is disabled. Check the SES console."
  exit 3
fi

QUOTA=$(echo "$ACCOUNT" | jq -r '.SendQuota.Max24HourSend')
RATE=$(echo "$ACCOUNT" | jq -r '.SendQuota.MaxSendRate')
echo "    Sending: enabled  (${QUOTA}/24h, ${RATE}/sec)"

echo
echo "Account ready. Run setup_project.sh for each project."
