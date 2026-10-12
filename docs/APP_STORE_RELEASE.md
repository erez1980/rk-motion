# App Store / TestFlight release

The unsigned IPA is for personal sideload testing. A green unsigned workflow
does not establish that App Store Connect accepts the app.

## Prepared in the repository

- Xcode 26.3 CI, toolchain/SDK assertions and bundled privacy declarations.
- Opaque primary icon and local-only privacy policy / support screen.
- Signed archive/export mode, separate from unsigned builds, with an explicit
  owner-selected bundle ID and monotonically increasing upload build number.
- Native test result artifacts for diagnosing failures.

## Owner setup still required

1. Enroll in the paid Apple Developer Program. Register the chosen bundle ID
   and create the App Store Connect app. The existing personal sideload ID is
   not assumed to be owned by this account. Keep the ID stable for updates.
2. Sign in to Xcode with the authorized Apple account. Do not put credentials
   or signing private keys in source control.
3. Merge the privacy policy before using its main-branch public URL:
   https://github.com/erez1980/rk-motion/blob/main/docs/PRIVACY.md
   Confirm the support issue tracker is enabled and monitored. Set the same
   policy/support links in App Store Connect. No email identity is invented.
4. Review privacy answers against the actual shipped binary. The native app
   currently has no analytics/ads/account/backend. System Photos/iCloud and
   user-selected sharing are described separately in the policy.

## Build on an authorized Mac

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
export RK_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export RK_BUNDLE_ID=YOUR_REGISTERED_BUNDLE_ID
export RK_BUILD_NUMBER=4  # change to the next unused number for your app
bash scripts/build-ios.sh store
```

This signs and exports locally; it does not upload or publish. Open the
`build/ios/RKMotion-Store.xcarchive` in Xcode Organizer and Validate App.
When authorized, upload to App Store Connect and start with TestFlight.
Actual validation/signing has not been performed without the owner account.

## Release gate

- Native CI passes on the supported SDK; archive validation passes.
- Real-device import/edit/export/Photos/save/relaunch tested.
- HEVC, HDR appearance, 4K/60 input, long files and low storage tested.
- Background behavior matches the UI; no claim of unlimited background work.
- Accessibility, keyboard, RTL, rotation and permission rejection checked.
- Store description/screenshots accurately describe activity suggestions and
  the current SDR/30fps export. "Source resolution" is not lossless/HDR export.
- App Store privacy, age rating, screenshots, support link and review notes
  completed by the owner. Do not add desktop YouTube features to the native app.

The project generator can rewrite personal Xcode signing settings. Use the
environment overrides above for repeatable builds, and review generated diffs.
