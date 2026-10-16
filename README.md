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

## Install

See [docs/IPHONE.md](docs/IPHONE.md): download the IPA from a green
**iPhone standalone** Actions run and sideload it.

## Develop

The app is SwiftUI in `ios/RKMotion`, with unit and UI tests in
`ios/RKMotionTests` and `ios/RKMotionUITests`. The Xcode project is generated:

```bash
python3 scripts/generate-ios-project.py   # after adding or removing a .swift file
python3 scripts/check-ios-store.py        # metadata and translation checks
bash scripts/build-ios.sh simulator       # on a Mac with Xcode
```

CI (`.github/workflows/ios.yml`) builds, runs the tests on a simulator and
produces the unsigned IPA on every pull request that touches the app.

## License

RK Motion started from the open-source Sofit codebase; see [LICENSE](LICENSE).
