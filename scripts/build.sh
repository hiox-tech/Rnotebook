#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-edmund-source.py
python3 scripts/verify-language-tools.py
python3 scripts/generate-third-party-notices.py --check
python3 scripts/generate-help-book.py
python3 scripts/update-xcode-project.py
arch="${ARCHS:-arm64}"
derived="${RNOTEBOOK_DERIVED_DATA:-.build/Rnotebook}"
host="$(uname -m)"
if [ "$arch" = "$host" ]; then destination="platform=macOS,arch=$arch"; else destination="platform=macOS"; fi
exec xcodebuild -project Rnotebook.xcodeproj -scheme Rnotebook -configuration "${1:-Debug}" \
    -destination "$destination" -derivedDataPath "$derived" \
    ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
