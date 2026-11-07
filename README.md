# RK Motion

**An AI video editor that runs on your iPhone.** Pick a video, and RK Motion
works out what it is (a ride, a party, a trip, a talk, family moments), says
what it found, and cuts the best moments into one movie with your music.

Everything happens on the phone with Apple's own frameworks: no account, no
upload, no server.

## What it does

- **Reads the video.** One scan measures motion, loudness, music, speech,
  laughter and cheering, people in frame and the kind of place, then picks a
  content kind and shows the reasons. One tap re-edits it as another kind.
- **Cuts the moments.** Each kind weighs those signals its own way: speed and
  jumps for a ride, dancing and joy for a party, speech for a talk.
- **Adds music.** Songs from Files or YouTube, with a chosen start point, cuts
  on the beat, and the original sound kept or muted.
- **Exports** a finished movie with transitions, an opening title and a
  vertical or source frame, saved to Photos.

## Automatic studio (0.33.0)

Tap **Make my movie** in a project to choose complete moments, make a local
instrumental when no music is present, frame, check and export the movie.
The home-screen monthly movie also chooses its source media. System Photos
permission may be needed once; typing a prompt or choosing music is optional.
The studio offers three audience recipes, persistent version restore,
verified project ZIP backup/restore, conservative visual comparison and
an experimental audio-synchronized two-camera movie.

The full 10 + 20 roadmap is tracked honestly as implemented, partial or
research in [Automatic studio plan](docs/AUTOMATIC_STUDIO_PLAN.md).
For continuation, read [Engineering handoff](docs/AUTOMATIC_STUDIO_HANDOFF.md)
and [Original product research](docs/PRODUCT_AI_RESEARCH_2026-10-23.he.md).
These are proposals plus a working first implementation, not a claim that
all thirty capabilities have shipped. New image-model assistance is optional,
local-only and gated on SDK/OS/model availability.

## Install

Add this source in SideStore on the iPhone, then install and update from there:

```
https://github.com/erez1980/rk-motion/releases/latest/download/source.json
```

Every green build of `main` is published as a
[GitHub Release](https://github.com/erez1980/rk-motion/releases) with the IPA.
The one-time setup is in [docs/IPHONE.md](docs/IPHONE.md).

## Develop

The app is SwiftUI in `ios/RKMotion`, with unit and UI tests in
`ios/RKMotionTests` and `ios/RKMotionUITests`. The Xcode project is generated:

```bash
python3 scripts/generate-ios-project.py   # after adding or removing a .swift file
python3 scripts/check-ios-store.py        # metadata and translation checks
bash scripts/build-ios.sh simulator       # on a Mac with Xcode
```

CI (`.github/workflows/ios.yml`) builds, runs the tests on a simulator and
produces the unsigned IPA on every pull request that touches the app; on\n`main` it also publishes the IPA and the SideStore source as a Release.

## License

RK Motion started from the open-source Sofit codebase; see [LICENSE](LICENSE).
