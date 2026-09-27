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
swift run photo-engine run /path/to/photos --profile trip --cull balanced --target 60 --style natural --size compact --output ./exports/trip
```

Launch the Mac studio:

```bash
swift run photo-engine-mac
```

After a run, the album is already chosen. Confirm only shows moments where two frames are close, or a keeper looks soft / blinky. Return keeps the suggestion. Technical trash (extreme blur, blank frames, unusable exposures, single-subject blinks) never becomes a suggestion. RAW+JPEG pairs collapse to the RAW master; iPhone HEIC is supported and Live Photo movies / screenshot-named files are skipped. One look is applied from the Look workspace — built-ins, imported `.cube` LUTs, or Lightroom `.xmp` develop presets, with optional auto-straighten. Hand off packs finished JPEGs and writes XMP beside each master (including RAW) without modifying image pixels.

Run the same pipeline as a loopback worker. It reads a folder that already exists on this Mac; it does not upload photographs. Set `PHOTO_ENGINE_TOKEN` to require `Authorization: Bearer`.

```bash
swift run photo-engine serve --port 8787
curl http://127.0.0.1:8787/v1/health
curl -X POST http://127.0.0.1:8787/v1/jobs \
  -H 'Content-Type: application/json' \
  -d '{"sourcePath":"/path/to/photos","profile":"groupEvent","cull":"balanced","target":40}'
```

A hosted service can be this same binary on an Apple Silicon worker, with upload and accounts added in front. Vision stays on the Mac either way.

Each run is written beneath `<output>/runs/<timestamp>-<id>/`, so rerunning with a smaller target cannot leave stale JPEGs in the current shortlist. Analysis and export never modify source files. Camera, lens, exposure, and capture metadata are retained in exports while GPS and XMP location metadata are removed by default. The optional cleanup action is separate and only proposes verified byte-identical copies.

`photo-engine-checks` is a fixture-driven regression executable that exercises grouping, bounded burst duration, deterministic selection, culling/style controls, Vision descriptor round-trips, durable catalog records, stable IDs, corrupt-file reporting, isolated outputs, metadata sanitization, warm-cache metrics, and unsafe output paths. It is deliberately runnable with the standalone Swift Command Line Tools installed on this machine; it can be migrated to XCTest/Swift Testing without changing the fixture coverage when the app moves into an Xcode project.

Quality calibration against real labeled shoots, RAW/ARW support, person identity grouping, lens-profile chromatic-aberration correction, and side-by-side correction tools remain intentionally separate follow-up work. Automatic culling never modifies source photographs; cleanup is limited to an explicit, verified exact-duplicate Trash action. Occasion profiles change which technical rejects are hard-hidden (creative keeps unusual frames; group events protect faces).

## Repository policy

This repository is local-only. No Git remote is configured and nothing should be pushed without an explicit future decision by the owner.

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
