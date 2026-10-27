#!/bin/bash
# One screen of everything about the relay. No sudo.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
set +e

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  state="$(launchctl print "system/$LABEL" 2>/dev/null | awk -F'= ' '/^\tstate/ {print $2; exit}')"
  printf 'Daemon:    %s loaded (%s)\n' "$LABEL" "${state:-?}"
else
  printf 'Daemon:    %s not loaded (sudo deploy/install-service.sh)\n' "$LABEL"
fi
if [[ -f "$PLIST" ]] && ! render_plist | cmp -s - "$PLIST"; then
  printf 'Config:    config.env differs from the installed plist; run sudo deploy/install-service.sh\n'
fi
printf 'Binary:    %s (%s)\n' "$BIN" "$(tr '\n' ' ' < "$DATA_DIR/bin/VERSION" 2>/dev/null || echo 'not built')"
printf 'Local:     %s\n' "$(curl -fsS --max-time 5 "$LOCAL_URL/v1/health" 2>/dev/null || echo DOWN)"
printf 'Public:    %s\n' "$(curl -fsS --max-time 10 "https://$PUBLIC_HOSTNAME/v1/health" 2>/dev/null || echo DOWN)"

if [[ -x "$BIN" ]]; then
  relay_env
  "$BIN" status
fi

echo
echo "Last log lines ($LOG_FILE):"
tail -n 10 "$LOG_FILE" 2>/dev/null
