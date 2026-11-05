#!/bin/bash
# Local release: the universal app, notarised and stapled, inside a signed and
# notarised DMG at dist/release/remora-<version>-macos-universal.dmg.
#
# Local by design: the Developer ID key never leaves this Mac, and there is no
# other platform to build. Then:
#   gh release create v<version> dist/release/*.dmg --notes-file <notes>
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
VERSION="$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Remora/Version.swift)"
APP="dist/Remora.app"

# release-lib.sh is vendored from stoatworks-backend/release — edit it there.
source scripts/release-lib.sh
rl_init "Remora" remora "$VERSION" com.stoatworks.remora "$PWD/dist/release"
rl_mac_sign_ready || { echo "no Developer ID configured on this Mac" >&2; exit 1; }

# Both slices, or an Intel Mac downloads an app it cannot run.
archs="$(lipo -archs "$APP/Contents/MacOS/Remora")"
[[ "$archs" == *x86_64* && "$archs" == *arm64* ]] || { echo "not universal: $archs" >&2; exit 1; }

rl_mac_notarize "$APP"

stage="$(mktemp -d)"
ditto "$APP" "$stage/Remora.app"
rl_dmg macos-universal "$stage" --app "Remora.app"
DMG="$RL_OUT/remora-$VERSION-macos-universal.dmg"
rl_mac_notarize "$DMG"
rm -rf "$stage"

spctl -a -vv -t install "$DMG"
rl_summary
