#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/create-project.py
build_directory="${LOCALSTT_BUILD_DIR:-build}"
signing_identity="$(python3 scripts/signing.py identity)"
xcodebuild -project LocalSTT.xcodeproj -scheme LocalSTT -configuration Release -derivedDataPath "$build_directory" CODE_SIGN_IDENTITY="$signing_identity" CODE_SIGN_STYLE=Manual REGISTER_APP_WITH_LAUNCH_SERVICES=NO build
printf '\nApp: %s/Build/Products/Release/local-wispr.app\n' "$build_directory"
