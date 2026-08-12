#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}
typeset -A tracked

if [[ -n "${RIFT_TRACKED_MANIFEST:-}" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] && tracked[$path]=1
  done < "$RIFT_TRACKED_MANIFEST"
else
  while IFS= read -r -d $'\0' path; do
    tracked[$path]=1
  done < <(git -C "$ROOT" ls-files -z)
fi

failed=0
fail() {
  print -u2 -- "$1"
  failed=1
}

for required in \
  Rift.xcodeproj/project.pbxproj \
  Configuration/App-Info.plist \
  Configuration/Extension-Info.plist \
  App/RiftApp.swift \
  Extension/FilterDataProvider.swift \
  CLI/main.swift \
  Scripts/test-nonfiltering.sh \
  Scripts/release-local-audit.sh \
  Scripts/publication-preflight.sh \
  docs/release/build-signing.md \
  docs/security/threat-model.md \
  README.md LICENSE SECURITY.md \
  .github/workflows/nonfiltering.yml; do
  [[ -n "${tracked[$required]:-}" ]] || fail "publication inventory is missing: $required"
done

for prefix in Packages/RiftCore/ Packages/RiftIPC/ Packages/RiftControl/ \
  Packages/RiftFilterRuntime/; do
  found=0
  for path in ${(k)tracked}; do
    if [[ "$path" == "$prefix"* ]]; then
      found=1
      break
    fi
  done
  (( found )) || fail "publication inventory is missing package content: $prefix"
done

for path in ${(k)tracked}; do
  case "$path" in
    GOAL.md|docs/plans/*|docs/research/*|.agents/*|*/.agents/*)
      fail "publication inventory contains internal development material: $path"
      ;;
    .DS_Store|*/.DS_Store|inspiration_images/*|*/inspiration_images/*)
      fail "publication inventory contains non-redistributable reference material: $path"
      ;;
    .build/*|*/.build/*|.derived-data*/*|*/DerivedData/*|*.xcarchive/*|*.app/*|*.systemextension/*)
      fail "publication inventory contains build output: $path"
      ;;
    *.sqlite|*.sqlite-*|*.db|*.mmdb|*.csv|*.dmg|*.pkg)
      fail "publication inventory contains generated data or a binary package: $path"
      ;;
    *.p8|*.p12|*.pfx|*.cer|*.crt|*.key|*.pem|*.mobileprovision|*.provisionprofile|\
    .env|.env.*|*/.env|*/.env.*)
      fail "publication inventory contains a credential-shaped file: $path"
      ;;
    *.png|*.jpg|*.jpeg|*.heic|*.tiff)
      if [[ "$path" != *Assets.xcassets/* ]]; then
        fail "publication inventory contains an unapproved raster image: $path"
      fi
      ;;
  esac
done

forbidden_name="co""dex"
for path in ${(k)tracked}; do
  if [[ "${path:l}" == *"$forbidden_name"* ]]; then
    fail "publication inventory contains an internal tool reference in its path: $path"
  fi
done

if /usr/bin/git -C "$ROOT" grep --cached -I -n -i -e "$forbidden_name" --; then
  fail "publication inventory contains an internal tool reference"
fi

if (( failed )); then
  print -u2 -- "FAIL: tracked files are not a publishable Rift source inventory"
  exit 1
fi

echo "PASS: tracked files form the expected source-only publication inventory"
