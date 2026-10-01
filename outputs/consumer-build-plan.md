# Consumer build plan: "Finish the trip"

Branch: `feat/consumer-trip-book`. One chunk per hour. Each chunk ends with
`swift build`, `swift run photo-engine-checks`, `swift test`, the iOS simulator
test (`xcodebuild test -scheme EngineTests`), and a commit.

Product summary: free culling on the phone, paid hosted finish that turns the
keepers into an online photobook with an AI diary, guest contributions, and an
Instagram pack. See the product doc for the full story.

| # | Chunk | Status |
|---|---|---|
| 1 | Branch, commit eval work, engine libraries compile and pass a pipeline test on iOS | done |
| 2 | On-device consumer engine: Photos library ingest, screenshot/document filter, auto-enhance, resumable chunked cull | done |
| 3 | iOS app: trip picker, cull progress, swipe queue, keepers to a Photos album; build and run in simulator | done |
| 4 | Engine upgrades: masked local edits (person segmentation), scene labels, saliency crops, place names | done |
| 5 | Trip book: sections from moments, static HTML book, AI diary and captions (Claude API + offline fallback), Instagram pack | todo |
| 6 | Server routes for paid finish (keeper upload, shortlist job, preview edit, book publish, guest photos), app upsell screen, README aligned | todo |

## Running the iOS engine test

`.swiftpm/` is gitignored, so the `EngineTests` scheme lives in
`Scripts/ios-engine-test.sh`, which writes it before running `xcodebuild test`.

## Running the iOS app

`Scripts/ios-app.sh` builds `Apps/PhotocoreiOS`, installs it on the booted
simulator, grants Photos access and launches it. Seed photos first with
`xcrun simctl addmedia booted /path/*.JPG`. Launch options
`-PhotocoreAutoOpen YES` opens the newest trip and `-PhotocoreAutoSwipe YES`
opens the swipe review when the cull finishes. Screenshots go in the gitignored
`outputs/screenshots/ios/` because they show real library photos.

## Log

- Chunk 1: added `.iOS(.v18)`; replaced AppKit image fallback in StyleMatcher with Image I/O; guarded the loopback `LocalCurationServer` to macOS; added `PhotoEngineAppleTests` (Swift Testing) that runs the full pipeline on synthetic JPEGs.
- Chunk 2: `PhotoLibraryIngest` exports a trip from Photos to 1024 px JPEGs with date and GPS, skips screenshots, and keeps a `library-index.json` so resumed trips skip current files; `PhotoLibraryWriter` saves keepers as an album and Favorites. `UtilityShotDetector` drops receipts and menus (six or more text lines covering 6% of the frame; one large false box on shapes is ignored). `AutoEnhance` is the free-tier edit. The runner now checkpoints the analysis cache every `checkpointInterval` photos, so a cancelled or killed cull resumes. Found and fixed a Vision deadlock when two culls ran at once: all Vision analysis now shares a process-wide gate. 8 Swift tests pass on Mac and iPhone simulator.
- Chunk 3: iPhone app in `Apps/PhotocoreiOS` (hand-written Xcode project, local package reference). Home finds trips from capture dates (`TripDetector`: 20-hour gap, 20 photos minimum, runs over 21 days split at the largest pause), the trip screen reads, culls and shows keepers, the swipe sheet resolves close calls (`KeeperSelection`), and keepers save as a Photos album. Verified in the iPhone 18 Pro simulator with 140 Pycon photos: trips detected, cull ran, swipe worked, album saved. Fixed: simulator aesthetics returns a constant score, so it is skipped there and the cache is keyed by platform. Found and logged: Vision face signals vary between runs on the same photo (see evaluation log); follow-up is a single shared face detection pass. 18 tests pass on Mac and simulator.
- Chunk 4: photo metadata now carries GPS (optional, old manifests still decode). `SceneLabeler` (Vision classification, keepers only), `SaliencyCropper` (4:5, 9:16, 1:1 crops centered on attention saliency), `PlaceNamer` (1 km grid cells, one reverse-geocode per cell, disk cache). `SubjectAwareEdit` lifts the subject and quiets the background through a feathered foreground or person mask; `FinishRenderer` is the paid render (auto adjust, subject edit, optional crop). `TripFactsBuilder` writes `trip-facts.json` with time, place, labels, faces and crops per keeper for chunk 5. Fixed a test deadlock from stacked culls (see evaluation log): Vision suites are serialized and every Vision caller goes through the gate. 25 tests pass on Mac (5 runs) and iPhone simulator.
