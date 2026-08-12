#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}
DERIVED_DATA="$ROOT/.build/DerivedData"

swift test --package-path "$ROOT/Packages/AbyssCore" --jobs 2
swift test --package-path "$ROOT/Packages/AbyssIPC" --jobs 2
swift test --package-path "$ROOT/Packages/AbyssControl" --jobs 2
swift test --package-path "$ROOT/Packages/AbyssFilterRuntime" --jobs 2

xcodebuild \
  -quiet \
  -project "$ROOT/Abyss.xcodeproj" \
  -scheme Abyss-Dev \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 2 \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

"$ROOT/Scripts/verify-built-products.sh" \
  "$DERIVED_DATA/Build/Products/Release/Abyss.app"

echo "PASS: local package tests and Apple silicon package inspection"
