#!/bin/zsh
# Builds, signs and notarizes Rift, and writes the Sparkle update feed. With
# --publish it also tags the version and creates the GitHub release that
# installed copies of Rift update from.
#
# usage: Scripts/release.sh [--publish] [--download-base URL] [--feed-url URL]
#
# Everything private comes from this Mac, never from the repository:
#   - the Developer ID Application identity, and its team, from the keychain
#   - the Developer ID provisioning profiles for the app and the filter
#   - the notarytool keychain profile named by RIFT_NOTARY_PROFILE (default: rift)
#   - Sparkle's update-signing key named by RIFT_SPARKLE_ACCOUNT (default: rift)
#
# --download-base points the feed at another download location, and --feed-url
# points the built app at another feed. Both are for testing an update before
# publishing it.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

PUBLISH=0
DOWNLOAD_BASE=""
FEED_URL=""
while (( $# )); do
  case $1 in
    --publish) PUBLISH=1 ;;
    --download-base) DOWNLOAD_BASE=${2:?}; shift ;;
    --feed-url) FEED_URL=${2:?}; shift ;;
    *) print -u2 "usage: Scripts/release.sh [--publish] [--download-base URL] [--feed-url URL]"; exit 2 ;;
  esac
  shift
done

fail() { print -u2 -- "release: $*"; exit 1; }
setting() { awk -F' = ' -v key="$1" '$1 == key { print $2 }' Configuration/Base.xcconfig; }

NOTARY_PROFILE=${RIFT_NOTARY_PROFILE:-rift}
SPARKLE_ACCOUNT=${RIFT_SPARKLE_ACCOUNT:-rift}
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
GROUP=$(setting RIFT_APP_GROUP)
MINIMUM_OS=$(setting MACOSX_DEPLOYMENT_TARGET)
TAG="v$VERSION"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[[ -n $VERSION && -n $BUILD && -n $GROUP && -n $REPO ]] || fail "couldn't read the version or repository"

if (( PUBLISH )); then
  [[ $(git branch --show-current) == main ]] || fail "publish from main"
  [[ -z $(git status --porcelain --untracked-files=no) ]] || fail "commit or stash changes first"
  [[ -z $DOWNLOAD_BASE && -z $FEED_URL ]] || fail "--download-base and --feed-url are for testing; don't publish with them"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG already exists; raise MARKETING_VERSION and CURRENT_PROJECT_VERSION"
  fi
fi

IDENTITY=$(security find-identity -v -p codesigning \
  | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
[[ -n $IDENTITY ]] || fail "no Developer ID Application identity in the keychain"
TEAM=$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<< "$IDENTITY")
[[ -n $TEAM ]] || fail "couldn't read the team from the signing identity"

OUT=".build/release/$VERSION-$BUILD"
DERIVED=.build/DerivedData-Release
rm -rf "$OUT"
mkdir -p "$OUT"

# The newest Developer ID profile for a bundle. Developer ID profiles cover all devices.
profile_for() {
  local bundle=$1 best="" best_expiry="" file expiry
  local scratch=$(mktemp)
  for file in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile(N) \
    "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile(N); do
    security cms -D -i "$file" > "$scratch" 2>/dev/null || continue
    [[ $(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$scratch" 2>/dev/null) \
      == "$TEAM.$bundle" ]] || continue
    [[ $(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$scratch" 2>/dev/null) == true ]] || continue
    expiry=$(plutil -extract ExpirationDate raw "$scratch")
    if [[ $expiry > $best_expiry ]]; then best=$file; best_expiry=$expiry; fi
  done
  rm -f "$scratch"
  [[ -n $best ]] || fail "no Developer ID provisioning profile for $bundle"
  print -r -- "$best"
}

# Signing entitlements from the Release entitlements, with the team filled in.
entitlements_for() {
  local source=$1 bundle=$2 output=$3
  sed -e "s/\$(RIFT_APP_GROUP)/$GROUP/g" -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle/g" "$source" > "$output"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $TEAM.$bundle" \
    -c "Add :com.apple.developer.team-identifier string $TEAM" "$output"
}

print "Building Rift $VERSION ($BUILD)"
xcodebuild -workspace Rift.xcworkspace -scheme Rift-Dev -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES DEVELOPMENT_TEAM="$TEAM" TeamIdentifierPrefix="$TEAM." \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; fail "build failed"; }

PRODUCTS="$DERIVED/Build/Products/Release"
APP="$OUT/Rift.app"
EXTENSION="$APP/Contents/Library/SystemExtensions/io.rift.firewall.filter.systemextension"
CLI="$APP/Contents/Helpers/riftctl"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$PRODUCTS/Rift.app" "$APP"
[[ -z $FEED_URL ]] || plutil -replace SUFeedURL -string "$FEED_URL" "$APP/Contents/Info.plist"
for symbols in "$PRODUCTS"/*.dSYM; do ditto "$symbols" "$OUT/${symbols:t}"; done

cp "$(profile_for io.rift.firewall)" "$APP/Contents/embedded.provisionprofile"
cp "$(profile_for io.rift.firewall.filter)" "$EXTENSION/Contents/embedded.provisionprofile"
entitlements_for Configuration/RiftApp-Release.entitlements io.rift.firewall "$OUT/app.entitlements"
entitlements_for Configuration/RiftFilter-Release.entitlements io.rift.firewall.filter "$OUT/filter.entitlements"

print "Signing with $IDENTITY"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
# Inside out: Sparkle's helpers, then Sparkle, the CLI, the filter, and the app.
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --identifier io.rift.firewall.cli "$CLI"
sign --entitlements "$OUT/filter.entitlements" "$EXTENSION"
sign --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
# Without this exception the sandboxed app can't reach Sparkle's installer, and
# updates download but never install.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'io.rift.firewall-spki' \
  || fail "the app is missing Sparkle's installer entitlement"
Scripts/verify-built-products.sh "$APP"

print "Notarizing"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
# Save the whole response before checking it; reading it through a pipe that
# stops at the first match would end notarytool early and look like a failure.
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
  > "$OUT/notarize.log" 2>&1 || { cat "$OUT/notarize.log"; fail "notarytool failed"; }
grep -q 'status: Accepted' "$OUT/notarize.log" || { cat "$OUT/notarize.log"; fail "Apple didn't accept the build"; }
xcrun stapler staple "$APP" >/dev/null
spctl --assess --type execute "$APP" || fail "Gatekeeper rejected the notarized app"
rm "$OUT/notarize.zip"

ARCHIVE="Rift-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ARCHIVE"
SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -path '*/Sparkle/bin/sign_update' -type f | head -1)
[[ -x $SIGN_UPDATE ]] || fail "Sparkle's sign_update tool is missing"
SIGNATURE=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$OUT/$ARCHIVE")
[[ $SIGNATURE == *'sparkle:edSignature='* ]] || fail "couldn't sign the update"

BASE=${DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG}
cat > "$OUT/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rift</title>
    <item>
      <title>Rift $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <enclosure url="$BASE/$ARCHIVE" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
FEED
print "Built $OUT/$ARCHIVE and $OUT/appcast.xml"

(( PUBLISH )) || exit 0
print -n "Publish Rift $VERSION ($BUILD) to github.com/$REPO? Installed copies will update to it. [y/N] "
read -q || { print; fail "not published"; }
print
awk '/^## Unreleased/ { keep = 1; next } /^## / { keep = 0 } keep' CHANGELOG.md > "$OUT/notes.md"
git tag -a "$TAG" -m "Rift $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$OUT/$ARCHIVE" "$OUT/appcast.xml" --title "Rift $VERSION" --notes-file "$OUT/notes.md"
print "Published $TAG"
