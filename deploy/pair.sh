#!/bin/bash
# Pair the phone: shows the relay's URL and key as a QR code (a washtower://pair link)
# in Preview. Scan it with the iPhone's camera; the WashTower app opens and saves it.
# The key is never printed. No sudo. The key is made on first use and then reused,
# so pairing a second phone shows the same code.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ -x "$BIN" ]] || die "$BIN missing; run deploy/build.sh first"
relay_env
link="$("$BIN" pair --url "https://$PUBLIC_HOSTNAME" 2>/dev/null | grep '^washtower://pair' | tail -1)"
[[ -n "$link" ]] || die "couldn't make a pairing link (try: $BIN pair --url https://$PUBLIC_HOSTNAME)"
out="$(mktemp -d)/washtower-pair.png"
swift "$DEPLOY_DIR/qr.swift" "$link" "$out" || die "couldn't draw the QR code"
say "Scan this with the iPhone's camera, then close it: $out"
open -a Preview "$out"
