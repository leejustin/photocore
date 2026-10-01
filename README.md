# Photocore

**Finish the trip.** Photocore turns a camera roll into a finished trip: the best photos, edited, laid out as a shared online book with a short diary of where you went, plus an Instagram set ready to post.

- **Free, on the iPhone.** Pick a trip and Photocore culls it on the device, asks about a few close calls, and saves the keepers as a Photos album. Nothing is uploaded or copied.
- **Paid, hosted.** "Finish the trip" uploads only the keepers to a Photocore server, which edits them, writes the diary and captions, publishes the book, and builds the Instagram pack. Guests can leave notes and hearts and add their own photos, which are culled into the book.
- **The Mac studio** stays the owner and pro tool, and the same engine runs the server.

The engine is one set of Swift packages that runs on the iPhone, the Mac app, the CLI and the server.

## Current status

Built and tested on branch `feat/consumer-trip-book` (see [the build plan](./outputs/consumer-build-plan.md) and [the evaluation log](./outputs/evaluation-log.md)):

| Part | State |
|---|---|
| Engine on iOS and macOS | Culls on both; 40 Swift tests pass on Mac and the iPhone simulator |
| iPhone app (`Apps/PhotocoreiOS`) | Trips found from capture dates, streamed cull, swipe review, Photos album, set aside and restore, finish card |
| Trip book | Chapters by local day and place, diary and captions, owner edits, guest notes and hearts, Instagram pack |
| Paid finish server | Trip upload, finish job, preview, public book pages, guest uploads |
| Not built yet | Payments (StoreKit), accounts, publishing books to object storage, Android, a live Claude run |

The original specifications are still useful background:

- [Engine implementation plan](./outputs/photo-engine-implementation-plan.md)
- [Local Photo Curator specification](./outputs/local-photo-curator-spec.md)
- [Hybrid processing platform specification](./outputs/hybrid-photo-processing-platform-spec.md)

## The iPhone app

```bash
xcrun simctl addmedia booted /path/to/some/*.JPG
Scripts/ios-app.sh -PhotocoreAutoOpen YES
```

`Scripts/ios-app.sh` builds `Apps/PhotocoreiOS`, installs it on the booted simulator, grants Photos access and launches it. To run on a phone, open `Apps/PhotocoreiOS/PhotocoreiOS.xcodeproj` and set your team.

How it stays safe on a real camera roll:

- **One trip at a time, capped.** Trips are found by 20-hour gaps, need 20 photos, and split above 21 days or 1,500 photos. Trips queue and cull one after another.
- **Streamed, not copied.** Thumbnails are read from Photos in batches, analyzed in memory and dropped. Only about 5 KB of analysis per photo is stored, and a killed app resumes from the last batch.
- **Guards.** It refuses to start under 200 MB free, pauses when the phone is hot, and slows down in Low Power Mode.
- **Nothing is deleted by culling.** "Set aside" hides the other photos in a "Photocore · Set aside" album and can restore them with one tap. Favorites, edited, shared and album photos are never set aside. Deleting is a separate step, at most 500 at a time, through the iOS confirmation into Recently Deleted (30 days). Every step is logged.

## The trip book

```bash
swift run photo-engine book /path/to/trip --tone warm --theme book --output ./exports/trip-book
```

This culls the folder, reads scene labels, smart crops and place names for the keepers, writes the diary, renders finished photos, and writes `index.html` plus `instagram/` (1080 x 1350 carousel, 1080 x 1920 stories, `caption.txt`).

The diary is written by Claude when `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) is set, using `claude-opus-5-5` with structured output and server-side refusal fallbacks. Claude sees only the keepers' facts (place, time of day, scene labels, number of people) and 512-pixel thumbnails, never file names or the whole roll, and is told not to identify people or invent events. Without a key, on refusal, or on an outage, an offline writer produces plain captions from the same facts. Owner edits are stored apart from generated text, so regenerating never overwrites them.

Local time in the book follows a GPS place's time zone first, then the camera's recorded UTC offset. Cameras often stay on home time while traveling.

## The paid finish server

`photocore-server` adds these routes (full list in `Sources/PhotoEngineServer/openapi.yaml`):

| Route | Auth | Purpose |
|---|---|---|
| `POST /v2/trips` | Server token | Start a finish; returns the owner token once |
| `PUT /v2/trips/{id}/photos/{name}` | Server token | Upload a keeper (JPEG or HEIC, 60 MB, 400 per trip) |
| `POST /v2/trips/{id}/finish` | Server token | Queue the finish job |
| `POST /v2/preview` | Server token | Render one photo with the paid edit, for the upsell |
| `GET /b/{slug}/` | Public link | The book page, photos and Instagram files |
| `POST /b/{slug}/edits` | Owner token | Edit the title, intro, headings, diary or a caption |
| `/b/{slug}/guest/...` | Public link | Notes, hearts and guest photo uploads, with count and size limits |

Book pages are public to anyone with the unguessable link, so only expose the server where that is intended. Today that means the tailnet setup below. Publishing books to object storage behind a CDN is the planned production path.

```bash
PHOTO_ENGINE_TOKEN=dev-token ANTHROPIC_API_KEY=... swift run photocore-server
Scripts/ios-app.sh -PhotocoreServerURL http://localhost:8787 -PhotocoreServerToken dev-token
```

## Technical direction

- Swift 6 with strict concurrency.
- Swift Package Manager for the engine, CLI, and tests.
- SwiftUI for the macOS interface.
- Image I/O for metadata and downsampled previews.
- Vision for similarity, faces, capture quality, and aesthetics.
- Core ML for optional replaceable scoring models.
- Core Image and Accelerate for editing and image statistics.
- A narrow persistence adapter backed by SQLite for durable sessions/artifacts plus a compact binary property-list analysis cache that can be evicted.
- Versioned JSON manifests for portable pipeline inputs and outputs.

## Engine commands

Build the command-line engine:

```bash
swift build
swift run photo-engine smoke-test
swift run photo-engine-checks
swift run photo-engine catalog /path/to/photos
swift run photo-engine run /path/to/photos --profile trip --cull balanced --target 60 --style natural --size compact --base raw --output ./exports/trip
swift run photo-engine calibrate /path/to/photos --sheet /tmp/photocore-calibrate.jpg
swift run photo-engine compare-render /path/to/manifest.json --count 6 --sheet /tmp/photocore-compare.jpg
swift run photo-engine eval /path/to/photos --profile trip --target 40
swift test
Scripts/ios-engine-test.sh
```

`--base raw` decodes a RAW master with Core Image. `--base camera` starts from the camera JPEG beside that RAW, when one exists. `calibrate` prints Vision feature-print distances and can write a contact sheet. `compare-render` writes the current recipe beside the camera JPEG so a shoot can be judged on real frames.

## The Mac studio and worker

Launch the Mac studio:

```bash
swift run photo-engine-mac
# or a real .app with icon (opens after build):
./Scripts/package-app.sh
```

After a run, Photocore opens **Confirm**: a short queue of moments where two frames are close or a keeper looks soft or blinky. Return keeps the suggestion. **Look** previews built-in looks, imported `.cube` LUTs or Lightroom `.xmp` presets, optional **Match my style** from your graded JPEGs, album exposure balance, and a quiet portrait **Retouch** pass. **Deliver** exports finished JPEGs under `~/Pictures/Photocore` with rename patterns, an optional local proof gallery (face filter + sneak peek), and a cull report; stars and color labels are embedded for Lightroom. It can optionally write `.xmp` sidecars beside RAW/HEIC originals, and never replaces an existing sidecar. **Album** (⌘4) browses every photo with spray-can Pick/Hide; double-click or Space opens a large view with burst survey and eye zoom. **Adjust** (⌘D) offers basic sliders for one photo. Culling learns from your P/X/stars (**taste memory**), syncs second-shooter cameras, and boosts key faces. Technical misses are hidden as *Unusable*. ⌘/ lists every shortcut.

Run the same pipeline as a loopback worker. It reads a folder that already exists on this Mac; it does not upload photographs. `photo-engine serve` binds to `127.0.0.1` only. Every route requires `Authorization: Bearer`. `PHOTO_ENGINE_TOKEN` is the shared secret (a session token is printed when it is unset). `PHOTO_ENGINE_ALLOWED_ROOTS` is a colon-separated list of directories a source folder may live under, defaulting to `~/Pictures`. `PHOTO_ENGINE_ALLOWED_ORIGINS` is a comma-separated list of browser `Origin` values; the default is none, and the server does not send a wildcard CORS header. Clients cannot choose an output path. Jobs write under `~/Library/Application Support/Photocore/worker-runs`.

```bash
swift run photo-engine serve --port 8787
curl -H "Authorization: Bearer $PHOTO_ENGINE_TOKEN" http://127.0.0.1:8787/v1/health
curl -X POST http://127.0.0.1:8787/v1/jobs \
  -H "Authorization: Bearer $PHOTO_ENGINE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sourcePath":"/path/to/photos","profile":"groupEvent","cull":"balanced","target":40}'
```

A hosted service can be this same binary on an Apple Silicon worker, with upload and accounts added in front. Vision stays on the Mac either way.

The v2 API is `photocore-server`, bound to `127.0.0.1:8787`. Install it as a LaunchAgent so Vision and Core Image run in the logged-in user session (`outputs/deploy/com.photocore.server.plist`). `ProcessType` is `Interactive` so those frameworks stay at full priority. Do not install it as a LaunchDaemon.

```bash
cp .build/release/photocore-server /usr/local/bin/
cp outputs/deploy/com.photocore.server.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.photocore.server.plist
```

`PHOTO_ENGINE_TOKEN_FILE` points at a mode-600 file. If that file is missing, the server generates a token and creates it. The token is not printed when it comes from the file. `PHOTO_ENGINE_ALLOWED_ROOTS` is a colon-separated list of directories a `sourcePath` may live under.

Expose the API on a tailnet, and only there:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Put the frontend origin (the Tailscale MagicDNS name, or a dev server) in `PHOTO_ENGINE_ALLOWED_ORIGINS`. Do not bind the server to `0.0.0.0` or forward a router port.

Each run is written beneath `<output>/runs/<timestamp>-<id>/`, so rerunning with a smaller target cannot leave stale JPEGs in the current shortlist. Analysis and export never modify source files. Camera, lens, exposure, and capture metadata are retained in exports while GPS and XMP location metadata are removed by default. The optional cleanup action is separate and only proposes verified byte-identical copies.

`photo-engine-checks` is a fixture-driven regression executable that exercises grouping, bounded burst duration, deterministic selection, culling/style controls, Vision descriptor round-trips, durable catalog records, stable IDs, corrupt-file reporting, isolated outputs, metadata sanitization, warm-cache metrics, and unsafe output paths. It is deliberately runnable with the standalone Swift Command Line Tools installed on this machine; it can be migrated to XCTest/Swift Testing without changing the fixture coverage when the app moves into an Xcode project.

Vision feature-print revision 2, measured on 512–1024 px thumbnails:

| Shoot | Same moment, ≤ 3 s apart | Unrelated, > 5 min apart |
|---|---|---|
| Night event (Pycon) | p50 **0.45** (p10 0.34, p90 0.60) | p1 **0.58**, p50 1.05 |
| Daytime travel (Italy, RAW) | p50 **0.29** (p10 0.18, p90 0.56) | p1 **0.58**, p50 1.06 |

Pairs at 0.30–0.47 were the same shot repeated. 0.52–0.57 were the same scene with a different composition. A same-shot threshold of about **0.50**, and a same-moment threshold of about **0.62** only when frames are within 3 seconds, is what the profiles use. Older Hamming-scale cutoffs of 7–10 were 15–20× too large for this distance.

Vision face signals are not fully deterministic on borderline faces (see the evaluation log); a single shared face-detection pass is the planned fix. Person identity, a learned ranker, and lens-profile chromatic aberration beyond `CIRAWFilter` stay out of scope. Automatic culling never modifies source photographs; cleanup is limited to an explicit, verified exact-duplicate Trash action. Occasion profiles change which technical rejects are hard-hidden (creative keeps unusual frames; group events protect faces). Record a release-build owner run in `outputs/evaluation-log.md` when the Pycon and Italy slices are measured again.

## Repository policy

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
