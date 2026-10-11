#!/bin/bash
set -euo pipefail
rk_root="$(cd "$(dirname "$0")/.." && pwd)"
rk_mode="${1:-unsigned}"
rk_output="${RK_MOTION_BUILD_DIR:-$rk_root/build/ios}"
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "Full Xcode with iOS platform support is required. Command Line Tools alone cannot build an IPA." >&2
  echo "Install Xcode, then run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 $rk_mode" >&2
  exit 2
fi
mkdir -p "$rk_output"
rk_args=(-project "$rk_root/ios/RKMotion.xcodeproj" -scheme RKMotion -configuration Release -derivedDataPath "$rk_output/DerivedData")
case "$rk_mode" in
  simulator)
    xcodebuild "${rk_args[@]}" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
    echo "Simulator app: $rk_output/DerivedData/Build/Products/Release-iphonesimulator/RKMotion.app"
    ;;
  unsigned)
    xcodebuild "${rk_args[@]}" -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$rk_output/RKMotion.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
    rk_app="$rk_output/RKMotion.xcarchive/Products/Applications/RKMotion.app"
    test -d "$rk_app"
    rk_stage="$(mktemp -d "$rk_output/package.XXXXXX")"
    trap 'rm -rf "$rk_stage"' EXIT
    mkdir "$rk_stage/Payload"
    ditto "$rk_app" "$rk_stage/Payload/RKMotion.app"
    plutil -lint "$rk_stage/Payload/RKMotion.app/Info.plist"
    ditto -c -k --keepParent "$rk_stage/Payload" "$rk_output/RK-Motion-unsigned.ipa"
    echo "IPA: $rk_output/RK-Motion-unsigned.ipa"
    echo "This IPA must be signed before it can run on a standard iPhone. Use Xcode Personal Team or re-sign with Sideloadly."
    ;;
  *) echo "Usage: $0 [unsigned|simulator]" >&2; exit 2 ;;
esac
