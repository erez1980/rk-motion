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
rk_xcode=$(xcodebuild -version | awk '/^Xcode / {print $2}')
rk_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
if [ "${rk_xcode%%.*}" -lt 26 ] || [ "${rk_sdk%%.*}" -lt 26 ]; then
  echo "Xcode 26+ and iOS SDK 26+ are required for this Store-ready branch (found Xcode $rk_xcode / SDK $rk_sdk)." >&2
  exit 2
fi
python3 "$rk_root/scripts/check-ios-store.py"
mkdir -p "$rk_output"
rk_args=(-project "$rk_root/ios/RKMotion.xcodeproj" -scheme RKMotion -configuration Release -derivedDataPath "$rk_output/DerivedData")
case "$rk_mode" in
  simulator)
    xcodebuild "${rk_args[@]}" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
    echo "Standalone simulator app: $rk_output/DerivedData/Build/Products/Release-iphonesimulator/RKMotion.app"
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
  store)
    : "${RK_DEVELOPMENT_TEAM:?Set RK_DEVELOPMENT_TEAM to your paid Apple Developer team ID}"
    : "${RK_BUNDLE_ID:?Set RK_BUNDLE_ID to your registered App Store bundle ID}"
    : "${RK_BUILD_NUMBER:?Set RK_BUILD_NUMBER to a new positive integer for each upload}"
    case "$RK_BUILD_NUMBER" in ''|*[!0-9]*) echo 'RK_BUILD_NUMBER must be a positive integer' >&2; exit 2 ;; esac
    test "$RK_BUILD_NUMBER" -gt 0
    rk_background_args=()
    if [ "${RK_ENABLE_BACKGROUND_GPU:-0}" = 1 ]; then
      rk_background_args=(CODE_SIGN_ENTITLEMENTS="$rk_root/ios/RKMotion/BackgroundGPU.entitlements" RK_BACKGROUND_GPU_ENABLED=YES)
    fi
    xcodebuild "${rk_args[@]}" "${rk_background_args[@]}" -sdk iphoneos -destination 'generic/platform=iOS' \
      -archivePath "$rk_output/RKMotion-Store.xcarchive" -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$RK_DEVELOPMENT_TEAM" PRODUCT_BUNDLE_IDENTIFIER="$RK_BUNDLE_ID" \
      CURRENT_PROJECT_VERSION="$RK_BUILD_NUMBER" archive
    RK_EXPORT_OPTIONS="$rk_output/StoreExportOptions.plist" python3 - <<'PY'
import os, plistlib
with open(os.environ['RK_EXPORT_OPTIONS'], 'wb') as f:
    plistlib.dump({'method': 'app-store-connect', 'destination': 'export',
                  'teamID': os.environ['RK_DEVELOPMENT_TEAM'], 'signingStyle': 'automatic',
                  'manageAppVersionAndBuildNumber': False}, f)
PY
    xcodebuild -exportArchive -archivePath "$rk_output/RKMotion-Store.xcarchive" \
      -exportPath "$rk_output/Store" -exportOptionsPlist "$rk_output/StoreExportOptions.plist" \
      -allowProvisioningUpdates
    echo "Signed distribution export: $rk_output/Store"
    echo "Validate the archive in Xcode Organizer, then upload only when authorized. This script never uploads."
    ;;
  *) echo "Usage: $0 [unsigned|simulator|store]" >&2; exit 2 ;;
esac
