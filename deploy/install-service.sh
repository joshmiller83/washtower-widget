#!/bin/bash
# One-time (and re-runnable) system setup. Needs root:
#   sudo deploy/install-service.sh
# Installs one launchd daemon, <prefix>.washtower-relay, that starts at boot without
# anyone logging in, runs `washtower-relay serve` as $SERVICE_USER with the WT_*
# settings from config.env, and is restarted whenever it exits.
# Run deploy/build.sh (without sudo) first. Rerun this after changing config.env
# (for example once the APNs key arrives): the settings live in the plist.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0"
[[ -x "$BIN" ]] || die "$BIN missing; run deploy/build.sh first (without sudo)"
sudo -u "$SERVICE_USER" test -r "$THINQ_TOKEN_FILE" \
  || warn "$SERVICE_USER can't read $THINQ_TOKEN_FILE; the relay will report a ThinQ error until it can"
if [[ -n "${APNS_KEY_FILE:-}" ]]; then
  sudo -u "$SERVICE_USER" test -r "$APNS_KEY_FILE" || warn "$SERVICE_USER can't read $APNS_KEY_FILE; push stays off"
fi

install -d -o "$SERVICE_USER" -g staff -m 700 "$DATA_DIR"
install -d -o "$SERVICE_USER" -g staff "$DATA_DIR"/{bin,logs}

tmp="$(mktemp)"
render_plist > "$tmp"
plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "the rendered plist is invalid (check config.env for & or < characters)"; }
install -o root -g wheel -m 644 "$tmp" "$PLIST"
rm -f "$tmp"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
say "Loaded $LABEL"

wait_for_health 60 || die "The relay didn't answer within a minute. See $LOG_FILE"
say "Done. Local: $LOCAL_URL/v1/health  Public: https://$PUBLIC_HOSTNAME/v1/health"
say "Next: deploy/tunnel-add-hostname.sh (once), then deploy/pair.sh to pair the phone"
