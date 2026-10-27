#!/bin/bash
# Ship a new relay build: test, build, swap the binary, restart, check health. No sudo:
# the daemon runs as $SERVICE_USER, so that user can stop it and launchd's KeepAlive
# starts the new binary right away. (Settings changes need sudo deploy/install-service.sh.)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

"$DEPLOY_DIR/build.sh"

if [[ -f "$PLIST" ]] && ! render_plist | cmp -s - "$PLIST"; then
  warn "config.env has changed since the daemon was installed. Apply it with: sudo deploy/install-service.sh"
fi

if pgrep -u "$SERVICE_USER" -f "$BIN serve" >/dev/null; then
  say "Restarting the relay"
  pkill -TERM -u "$SERVICE_USER" -f "$BIN serve"
else
  warn "The relay isn't running. Install the daemon with: sudo deploy/install-service.sh"
  exit 1
fi

sleep 2
wait_for_health 60 || die "The new build didn't come up. See $LOG_FILE"
say "Running $(tr '\n' ' ' < "$DATA_DIR/bin/VERSION"): $(curl -fsS "$LOCAL_URL/v1/health")"
