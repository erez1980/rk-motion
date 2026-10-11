# RK Motion on iPhone

The native companion requires iOS 17+. The Mac runs the video engine; this
is not an independent on-phone editor. Both devices must be on the same
reachable Wi-Fi network. Keep the Mac awake while processing.

## Install the IPA with your Mac

1. Download `RK-Motion-unsigned.ipa` from the successful **iPhone companion**
   GitHub Actions run. Unzip the Actions artifact ZIP to obtain the IPA.
2. Connect the iPhone by USB, unlock it, and accept **Trust This Computer**.
3. Open [Sideloadly](https://sideloadly.io/) on the Mac, choose the iPhone,
   drag the IPA into its app field, and enter your Apple Account yourself.
4. Start signing/installing and complete account verification yourself.
5. Follow iOS prompts to trust the developer under **Settings → General →
   VPN & Device Management**. If requested, enable **Developer Mode** under
   **Settings → Privacy & Security**, then restart and confirm.
6. Open RK Motion. Allow local network access; camera access is needed only
   for QR scanning. Photos add permission is requested when saving an export.

The input IPA is unsigned. A standard iPhone requires signing before it can
run. Free Personal Team profiles expire after seven days; renew/reinstall or
configure Sideloadly refresh. Keep the same signing account/bundle identifier
for updates to preserve the app's data. Do not delete the app to update it.

Sources: [Apple code signing](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web),
[Apple Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account),
[Sideloadly signing/refresh FAQ](https://sideloadly.io/faq.html).

## Start the matching Mac backend

Use this branch's backend, not an older desktop release:

```sh
git clone --branch codex/iphone-companion https://github.com/erez1980/rk-motion.git
cd rk-motion
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[lan]'
# FFmpeg and ffprobe must already be on PATH, e.g. brew install ffmpeg
rk-motion --ui --lan
```

The Mac browser has a pairing button. Scan its private QR with the native
app, or paste the complete pairing link including the fragment. Codes expire
in ten minutes; reopen pairing on the Mac to refresh an expired code.
Do not share the private link. The app enrolls a device token in Keychain
and validates the server certificate fingerprint plus host and validity.
If the Mac address/certificate changes, pair again.

## Editing flow

Choose a movie from Photos or Files. Uploads use file-backed 8MB chunks; open
the app and tap resume after a disconnection. The Mac confirms committed
byte offsets. Uploads can continue using iOS background transfers, but iOS
controls scheduling and may stop transfers after force-quitting the app.

Analysis and exports run on the Mac. Reopen the app to reconnect to status.
Download the smaller preview for playback, trim/select/reorder clips, add
music, select aspect/quality/speed, and export. Download the export as a local
file, then save to Photos or share it. Projects and edits survive Mac restarts.
Concurrent edit saves are rejected instead of silently overwriting another
client; reconnect before editing after a conflict.

The app does not promise continuous analysis polling or completion alerts
while suspended. Mac sleep, Wi-Fi client isolation, VPN/firewall rules, or
low disk space can interrupt the flow. A failed transfer can be resumed;
processing interrupted by restarting the Mac must be retried.

## Build locally with Xcode

Full Xcode and its iOS platform are required; Command Line Tools are insufficient.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-ios.sh unsigned
# Output: build/ios/RK-Motion-unsigned.ipa
```

For direct installation, open `ios/RKMotion.xcodeproj`, select the RKMotion
target, choose a unique bundle identifier and your Personal Team under
Signing & Capabilities, connect/select the iPhone, then Build and Run.
`scripts/generate-ios-project.py` regenerates the committed Xcode project if
Swift source files are added. Reapply personal signing settings afterward.

## Verification limits

CI compiles simulator and device targets, archives the device app, and
packages the IPA. Backend integration tests cover upload, processing,
persistence, ranges, authorization, export, and compatible codecs.
Physical iPhone installation, background suspension, HEVC/HDR recordings,
large transfers, Photos saving, and signing renewal require device testing.
HDR tone mapping has not been implemented: use SDR recordings for now.
