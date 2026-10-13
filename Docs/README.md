# Practice Room

An iOS app for learning K-pop choreography: slow down and loop official dance practice videos,
find tutorials ranked for how learnable they are, and record yourself against a reference you own.

## Build

Requirements: macOS with Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 16+ device
(the camera doesn't work in the Simulator).

```sh
brew install xcodegen
cd PracticeRoom
# put your Apple Developer Team ID in project.yml → settings.base.DEVELOPMENT_TEAM
xcodegen generate
open PracticeRoom.xcodeproj
```

XcodeGen writes `Supporting/Info.plist` from the `info.properties` block in `project.yml`, including
all the camera, microphone and photo-library usage strings.

## YouTube API key (optional)

Without a key the app still works: routines whose catalog entry has a verified
`knownPracticeVideoID` play straight away, and for the rest you paste links yourself. With a key,
it finds the official dance practice video for every routine and ranks tutorials automatically.

1. Google Cloud Console → create a project → enable **YouTube Data API v3**.
2. Credentials → create an **API key**. Restrict it to the YouTube Data API. Don't add an HTTP
   referrer restriction, because the app doesn't send one.
3. Either build it in, or paste it on the device:
   - **Built in (recommended):** GitHub repo → Settings → Secrets and variables → Actions → new
     repository secret named `YOUTUBE_API_KEY`. CI passes it to `xcodebuild`, it lands in
     Info.plist as `YouTubeAPIKey`, and every install works with no setup. Anyone holding the .ipa
     can extract it, so keep it restricted to the YouTube Data API.
   - **On the device:** Settings → YouTube → paste the key → Save. A pasted key replaces the
     built-in one. "Test the key" costs 1 quota unit.

Quota: a routine costs about 200 units the first time you open it (two searches plus a details call),
then nothing for a week because results are cached. The default daily quota is 10,000.

## The two playback engines

| | YouTube embed | Your own files |
|---|---|---|
| Speed 0.25x–2x | ✓ | ✓ |
| A/B loop, saved sections | ✓ | ✓ |
| Mirror | — | ✓ |
| Frame step | — | ✓ |
| Record over it (stacked / side-by-side / ghost) | — | ✓ |
| Export take with music | — | ✓ |

This split is intentional (see `PlaybackCapabilities`). The embedded player follows YouTube's terms:
no mirroring, no drawing over it, no audio capture. Files the user imports, and marks as their own
footage, purchased, openly licensed or from their instructor, get every tool.

## Layout

```
Sources/
  App/            entry point, tab root
  Models/         Choreography, LibraryItem/Recording, settings, tutorials
  Data/           AppStore (single source of truth), JSON persistence, bundled catalog
  Services/       YouTube Data API client, tutorial ranker, keychain
  Player/         shared PlaybackController + YouTube and AVPlayer engines, transport UI
  Capture/        CameraRecorder (countdown, auto-stop), RecordingComposer (export/mux)
  Features/
    Discover/     catalog browse + search
    Choreography/ routine page: reference player, sections, tutorials, sheets
    Library/      import from Photos/Files, provenance, link to routine
    Studio/       full-screen practice + recording on owned media
    Takes/        review, rate, annotate, export, share
    Settings/
    Onboarding/   first-launch rights explainer
Resources/catalog.json   seed routines (search intents, no hardcoded video IDs)
```

## Typical flow

1. **Discover** → pick a routine → the reference video loads. Set A/B, slow to 0.5x, then use
   **Mark section** to save "chorus" or "killing part".
2. **Library** → **+** → import your own class recording or a licensed file → link it to that routine.
3. On the routine page, **Open Studio** → choose Stacked or Ghost → set a loop → tap record. The
   countdown gives you time to get to your mark. Capture starts the reference on the 1, and recording
   stops by itself at the end of the loop.
4. **Takes** → rate it, add a note, **Export** with the music laid under it (sped back to real tempo if
   you danced slowed), then share or save to Photos.
