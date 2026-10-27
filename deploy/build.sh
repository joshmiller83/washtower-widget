#!/bin/bash
# Build the relay in release mode and stage it in $DATA_DIR/bin. No sudo.
# The swap is atomic, so a running relay keeps its old binary until it restarts.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ $EUID -ne 0 ]] || die "run without sudo"

say "Testing the relay first"
swift test --package-path "$RELAY_DIR" >/dev/null 2>&1 \
  || die "relay tests failed; not deploying (see: swift test --package-path Relay)"

say "Building $PRODUCT (release)"
swift build -c release --package-path "$RELAY_DIR" --product "$PRODUCT"
built="$(swift build -c release --package-path "$RELAY_DIR" --show-bin-path)/$PRODUCT"
[[ -x "$built" ]] || die "no binary at $built"

mkdir -p "$DATA_DIR"/{bin,logs}
chmod 700 "$DATA_DIR"
cp "$built" "$BIN.new"
mv -f "$BIN.new" "$BIN"
git -C "$REPO_DIR" rev-parse --short HEAD > "$DATA_DIR/bin/VERSION" 2>/dev/null || echo unknown > "$DATA_DIR/bin/VERSION"
git -C "$REPO_DIR" diff --quiet -- Relay Shared 2>/dev/null || echo "dirty" >> "$DATA_DIR/bin/VERSION"
say "Staged $BIN ($(tr '\n' ' ' < "$DATA_DIR/bin/VERSION"))"
