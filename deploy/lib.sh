#!/bin/bash
# Shared helpers for the deploy scripts. Sourced, not run.
# shellcheck disable=SC2034  # the variables are for the scripts that source this
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
RELAY_DIR="$REPO_DIR/Relay"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$DEPLOY_DIR/config.env" ]] || die "Missing deploy/config.env. Copy deploy/config.env.example and edit it."
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.env"

PRODUCT=washtower-relay
LABEL="$LABEL_PREFIX.washtower-relay"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BIN="$DATA_DIR/bin/$PRODUCT"
LOG_FILE="$DATA_DIR/logs/relay.log"
LOCAL_URL="http://$HOST:$PORT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# relay_env: the daemon's settings, for running relay commands by hand.
relay_env() {
  export WT_DATA_DIR="$DATA_DIR" WT_HOST="$HOST" WT_PORT="$PORT" \
    WT_THINQ_TOKEN_FILE="$THINQ_TOKEN_FILE" WT_COUNTRY="${COUNTRY:-US}" \
    WT_APNS_KEY_FILE="${APNS_KEY_FILE:-}" WT_APNS_KEY_ID="${APNS_KEY_ID:-}" \
    WT_APNS_TEAM_ID="${APNS_TEAM_ID:-}" WT_APNS_BUNDLE_ID="${APNS_BUNDLE_ID:-}" \
    WT_APNS_ENV="${APNS_ENV:-development}" WT_DISMISS_AFTER_MINUTES="${DISMISS_AFTER_MINUTES:-60}"
}

# render_plist: the LaunchDaemon plist for the current config.env, on stdout.
render_plist() {
  sed -e "s|__LABEL__|$LABEL|g" \
      -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
      -e "s|__DATA_DIR__|$DATA_DIR|g" \
      -e "s|__BIN__|$BIN|g" \
      -e "s|__LOG_FILE__|$LOG_FILE|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__THINQ_TOKEN_FILE__|$THINQ_TOKEN_FILE|g" \
      -e "s|__COUNTRY__|${COUNTRY:-US}|g" \
      -e "s|__APNS_KEY_FILE__|${APNS_KEY_FILE:-}|g" \
      -e "s|__APNS_KEY_ID__|${APNS_KEY_ID:-}|g" \
      -e "s|__APNS_TEAM_ID__|${APNS_TEAM_ID:-}|g" \
      -e "s|__APNS_BUNDLE_ID__|${APNS_BUNDLE_ID:-}|g" \
      -e "s|__APNS_ENV__|${APNS_ENV:-development}|g" \
      -e "s|__DISMISS_AFTER_MINUTES__|${DISMISS_AFTER_MINUTES:-60}|g" \
      "$DEPLOY_DIR/launchd/relay.plist.template"
}

# wait_for_health <seconds>: true once /v1/health answers.
wait_for_health() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    curl -fsS -o /dev/null --max-time 3 "$LOCAL_URL/v1/health" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
