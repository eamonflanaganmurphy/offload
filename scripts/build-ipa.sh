#!/bin/sh
# Builds an unsigned Release build/Offload.ipa for SideStore, which re-signs it
# with your own Apple ID when it installs.
set -eu
cd "$(dirname "$0")/.."

[ -d Offload.xcodeproj ] || xcodegen generate

rm -rf build/Offload.xcarchive build/Payload build/Offload.ipa
xcodebuild archive \
  -project Offload.xcodeproj -scheme Offload -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Offload.xcarchive \
  -clonedSourcePackagesDirPath .spm \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  "$@"

mkdir build/Payload
cp -R build/Offload.xcarchive/Products/Applications/Offload.app build/Payload/
(cd build && zip -qry Offload.ipa Payload)
rm -rf build/Payload
echo "Built $(pwd)/build/Offload.ipa ($(du -h build/Offload.ipa | cut -f1))"
