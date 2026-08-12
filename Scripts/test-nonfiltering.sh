#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}
DERIVED_DATA="$ROOT/.build/DerivedData"

swift test --package-path "$ROOT/Packages/RiftCore" --jobs 2
swift test --package-path "$ROOT/Packages/RiftIPC" --jobs 2
swift test --package-path "$ROOT/Packages/RiftControl" --jobs 2
swift test --package-path "$ROOT/Packages/RiftFilterRuntime" --jobs 2

xcodebuild \
  -quiet \
  -project "$ROOT/Rift.xcodeproj" \
  -scheme Rift-Dev \
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
  "$DERIVED_DATA/Build/Products/Release/Rift.app"

echo "PASS: local package tests and Apple silicon package inspection"
