# RK Motion: standalone iPhone editor

Version 0.15.0 requires iOS 17+. All video analysis, timeline editing, audio
mixing, and movie export run on the iPhone using AVFoundation. No Mac server,
Wi-Fi connection, pairing, Python, FFmpeg, cloud API, or model key is needed.
The Mac is used only to sign/install the IPA. Photos stored only in iCloud
may need to download through the system picker before they can be imported.
Once the source is local, editing and exporting work offline.

## Install from the iPhone (SideStore)

Every green build of `main` is published as a public
[GitHub Release](https://github.com/erez1980/rk-motion/releases) with the IPA
and a SideStore/AltStore source at:

```
https://github.com/erez1980/rk-motion/releases/latest/download/source.json
```

SideStore signs the IPA on the iPhone with your own Apple Account, so installs
and updates happen on the phone without a cable.

One-time setup (the only step that needs a computer, once):

1. Install SideStore with its installer as described at
   [docs.sidestore.io](https://docs.sidestore.io/) and sign in with your Apple
   Account. Enable Settings → Privacy & Security → **Developer Mode** when iOS
   asks, and trust your account under Settings → General → VPN & Device
   Management.
2. In SideStore open **Sources → +** and paste the URL above.

Then, from the iPhone only:

3. Open the RK Motion source and tap **Get** (later **Update** when a new build
   appears). The first install asks you to approve the Apple Account signing.
4. A free Apple Account signs for seven days; SideStore's **Refresh All**
   (or its automatic refresh) renews it on the phone. Updating over the
   existing app keeps your local projects; deleting the app removes them.

A paid Apple Developer account lasts a year per signing instead of seven days.

## Install using your Mac (Sideloadly)

1. Download the IPA from the newest
   [Release](https://github.com/erez1980/rk-motion/releases/latest).
2. Connect/unlock your iPhone by USB and accept **Trust This Computer**.
3. Open [Sideloadly](https://sideloadly.io/), choose the iPhone, drag in the IPA,
   and enter/verify your Apple Account yourself. Start signing/installing.
4. Follow iOS prompts to trust the developer under Settings → General →
   VPN & Device Management and enable Developer Mode if requested.

The IPA is unsigned and must be signed before it can run on a standard iPhone.
Use the same signing account and bundle ID for updates, without deleting the
app, to preserve your local projects.

Sources: [Apple signing](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web),
[Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account),
[SideStore docs](https://docs.sidestore.io/), [Sideloadly FAQ](https://sideloadly.io/faq.html).

## On-device workflow

- Import from Photos or Files. The original is retained in the app's local
  storage for future edits. Leave enough space for the source and exports.
- Analyze activity using two small preview samples per second and per-second
  audio RMS. Scores use 65% motion / 35% loudness, with robust normalization.
  These are activity suggestions for review, not semantic riding judgments.
- Or choose **keep the whole video**, which skips activity detection.
- Preview the original directly, trim/select/reorder clips, add manual clips,
  change detection sensitivity, and undo/redo edits. Projects save locally.
- Add local music files; the playlist loops to fill the movie and fades out.
  Choose source framing or portrait crop, quality cap, playback speed, and
  hard cuts or dissolves. Small sources are not enlarged.
- Export one composition locally to MP4, including framing, speed,
  transitions, music, and closing fade. Save to Photos or share the file.

The 0.15 editor adds a project library, visual clip trimming, composition
preview with music, revision-guarded autosave, per-export deletion and explicit
temporary-file cleanup. Activity suggestions are chronological and padded
windows are merged to avoid repeating footage. Exports display actual dimensions.

Keep default/personal unsigned builds in the foreground for long processing jobs. It prevents
automatic screen locking while processing, and uses the system's limited
background grace period if you switch apps. iOS can suspend/terminate long
work. On background expiration the operation is canceled safely; reopen
and retry from the saved source/edit. This version does not promise
unlimited background processing or push notifications. An optional iOS 26
continuous-task integration is available for paid signed builds with Background
GPU Access, compatible device support and the explicit build flag. See
[Store release setup](APP_STORE_RELEASE.md). It remains subject to system
expiration and requires actual lock/app-switch testing before release.

Exports target SDR BT.709 at 30 fps for compatibility. Native decoders read
MOV/MP4, supported HEVC, and orientation metadata. Actual Dolby Vision/HDR
appearance, very long/large recordings, thermal behavior, and unsupported
codec variants must be verified on the target iPhone. The source is retained.

## Build

Full Xcode with the iOS SDK is required locally:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-ios.sh unsigned
```

Open `ios/RKMotion.xcodeproj` to install directly through Xcode: choose your
Personal Team and a unique bundle ID, select the connected iPhone, Build/Run.
The generator in `scripts/generate-ios-project.py` includes the app and
XCTest target; regenerating may overwrite personal signing settings.

CI builds simulator/device targets and runs native tests. The tests create a
rotated movie and audio locally, analyze the source, export a trimmed/dissolved
movie with speed and music, validate dimensions/duration/audio, and reject
out-of-range edits. Separate tests check local persistence and timeline math.
Physical installation, Photos saving, signing renewal, and device performance
still require actual iPhone verification.

RK Motion is iPhone-only: the earlier Mac/Windows desktop editor was removed
from this repository in October 2026, and its projects are not migrated into
the app.
