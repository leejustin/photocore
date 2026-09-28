# Photo Engine

Photo Engine is a local-first photo culling and editing system designed for Apple Silicon. It imports folders of JPEG/HEIC and camera RAW photographs, identifies exact and near duplicates, groups timestamped bursts, computes explainable quality signals, produces a diverse shortlist, applies restrained edits (built-in looks, imported LUTs, or Lightroom XMP presets), and exports finished JPEGs.

The Mac app is a culling studio: a photo grid, a keyboard cull, basic develop controls, and Lightroom XMP sidecars. The processing engine stays in independent Swift modules so the same Vision pipeline can run in the app, the CLI, or a localhost worker that a phone or hosted front end can call.

## Current status

The local vertical slice is implemented: folder discovery, JPEG/HEIC metadata, stable asset identities, exact/near-duplicate grouping using Vision's supported feature-print distance, bounded parallel analysis with exact-content reuse, subject/face quality signals, configurable culling presets, deterministic shortlisting, persistent keep/protect/exclude overrides, versioned binary analysis caching, durable SQLite sessions and artifact accounting, five edited-JPEG looks, sanitized metadata, measured JSON manifests, a conservative exact-duplicate cleanup preview with explicit system-Trash execution, a CLI, and a SwiftUI shell.

Start with:

- [Engine implementation plan](./outputs/photo-engine-implementation-plan.md)
- [Local Photo Curator specification](./outputs/local-photo-curator-spec.md)
- [Venue Photo Content Service specification](./outputs/venue-photo-content-subscription-spec.md)
- [Hybrid processing platform specification](./outputs/hybrid-photo-processing-platform-spec.md)

## Initial technical direction

- Swift 6 with strict concurrency.
- Swift Package Manager for the engine, CLI, and tests.
- SwiftUI for the macOS interface.
- Image I/O for metadata and downsampled previews.
- Vision for similarity, faces, capture quality, and aesthetics.
- Core ML for optional replaceable scoring models.
- Core Image and Accelerate for editing and image statistics.
- A narrow persistence adapter backed by SQLite for durable sessions/artifacts plus a compact binary property-list analysis cache that can be evicted.
- Versioned JSON manifests for portable pipeline inputs and outputs.

## Try it locally

Build the command-line engine:

```bash
swift build
swift run photo-engine smoke-test
swift run photo-engine-checks
swift run photo-engine catalog /path/to/photos
swift run photo-engine run /path/to/photos --profile trip --cull balanced --target 60 --style natural --size compact --base raw --output ./exports/trip
swift run photo-engine calibrate /path/to/photos --sheet /tmp/photocore-calibrate.jpg
swift run photo-engine compare-render /path/to/manifest.json --count 6 --sheet /tmp/photocore-compare.jpg
```

`--base raw` decodes a RAW master with Core Image. `--base camera` starts from the camera JPEG beside that RAW, when one exists. `calibrate` prints Vision feature-print distances and can write a contact sheet. `compare-render` writes the current recipe beside the camera JPEG so a shoot can be judged on real frames.

Launch the Mac studio:

```bash
swift run photo-engine-mac
```

After a run, Photocore opens **Confirm**: a short queue of moments where two frames are close or a keeper looks soft or blinky. Return keeps the suggestion. **Look** previews built-in looks, imported `.cube` LUTs or Lightroom `.xmp` presets live on your keepers. **Deliver** exports finished JPEGs into a new folder under `~/Pictures/Photocore`, with stars and color labels embedded for Lightroom. It can optionally write `.xmp` sidecars beside RAW/HEIC originals, and never replaces an existing sidecar. **Album** (⌘4) browses every photo; double-click or Space opens a large view with burst survey and eye zoom. **Adjust** (⌘D) offers basic sliders for one photo, and that edit is used on delivery. Technical misses (extreme blur, blank frames, unusable exposures, single-subject blinks) are hidden as *Unusable*. ⌘/ lists every shortcut.

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

Person identity, a learned ranker, and lens-profile chromatic aberration beyond `CIRAWFilter` stay out of scope. Automatic culling never modifies source photographs; cleanup is limited to an explicit, verified exact-duplicate Trash action. Occasion profiles change which technical rejects are hard-hidden (creative keeps unusual frames; group events protect faces). Record a release-build owner run in `outputs/evaluation-log.md` when the Pycon and Italy slices are measured again.

## Repository policy

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
