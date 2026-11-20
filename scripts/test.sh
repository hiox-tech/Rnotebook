#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-edmund-source.py
python3 scripts/verify-language-tools.py
python3 scripts/generate-third-party-notices.py --check
python3 scripts/generate-help-book.py
python3 scripts/update-xcode-project.py
exec xcodebuild -project Rnotebook.xcodeproj -scheme Rnotebook -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Rnotebook CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- RNOTEBOOK_APP_ID=org.hiox.Rnotebook.TestHost RNOTEBOOK_PREVIEW_ID=org.hiox.Rnotebook.TestHost.Preview "RNOTEBOOK_DISPLAY_NAME=Rnotebook Tests" test "$@"
