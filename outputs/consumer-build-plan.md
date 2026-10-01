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
| 2 | On-device consumer engine: Photos library ingest, screenshot/document filter, auto-enhance, resumable chunked cull | todo |
| 3 | iOS app: trip picker, cull progress, swipe queue, keepers to a Photos album; build and run in simulator | todo |
| 4 | Engine upgrades: masked local edits (person segmentation), scene labels, saliency crops, place names | todo |
| 5 | Trip book: sections from moments, static HTML book, AI diary and captions (Claude API + offline fallback), Instagram pack | todo |
| 6 | Server routes for paid finish (keeper upload, shortlist job, preview edit, book publish, guest photos), app upsell screen, README aligned | todo |

## Running the iOS engine test

`.swiftpm/` is gitignored, so the `EngineTests` scheme lives in
`Scripts/ios-engine-test.sh`, which writes it before running `xcodebuild test`.

## Log

- Chunk 1: added `.iOS(.v18)`; replaced AppKit image fallback in StyleMatcher with Image I/O; guarded the loopback `LocalCurationServer` to macOS; added `PhotoEngineAppleTests` (Swift Testing) that runs the full pipeline on synthetic JPEGs.
