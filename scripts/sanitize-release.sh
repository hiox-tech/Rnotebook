#!/bin/bash
# Strip build-machine paths/debug symbols from a built app and ad-hoc re-sign it.
# Usage: scripts/sanitize-release.sh <path-to-Rnotebook.app>
set -euo pipefail
APP="${1:?usage: sanitize-release.sh Rnotebook.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW="$APP/Contents/PlugIns/RnotebookPreview.appex"
strip -S "$APP/Contents/MacOS/Rnotebook"
strip -S "$PREVIEW/Contents/MacOS/RnotebookPreview"
for tool in "$APP"/Contents/Resources/LanguageTools/air-* "$APP"/Contents/Resources/LanguageTools/raven-*; do
    [ -f "$tool" ] && strip -S "$tool" && codesign --force --sign - "$tool"
done
# Keep the Quick Look sandbox entitlements; the shipping app itself has none.
codesign --force --sign - --entitlements "$ROOT/QuickLook/Preview.entitlements" "$PREVIEW"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
if grep -R -a -q '/Users/' "$APP/Contents/MacOS/Rnotebook" "$PREVIEW/Contents/MacOS/RnotebookPreview"; then
    echo "sanitize-release: build path remains in executable" >&2
    exit 1
fi
echo "sanitized: $APP"
