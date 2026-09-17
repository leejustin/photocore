# Photo Engine

Photo Engine is a local-first photo culling and editing system designed for Apple Silicon. It will import folders of JPEG/HEIC photographs, identify exact and near duplicates, group bursts and scenes, compute explainable quality signals, produce a diverse shortlist, apply restrained edits, and export finished JPEGs without modifying the source files.

The first product surface is a simple native macOS application. The processing engine is split into independent Swift modules so the same pipeline can later power personal camera workflows, venue capture systems, and command-line batch processing.

## Current status

The local vertical slice is implemented: folder discovery, JPEG/HEIC metadata, stable asset identities, exact/near-duplicate grouping using Vision's supported feature-print distance, face capture quality, bounded parallel analysis, explainable scoring, diverse shortlisting, versioned binary analysis caching, edited JPEG export, sanitized metadata, JSON manifests, a CLI, and a SwiftUI shell.

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
- Vision for similarity, faces, quality, saliency, and aesthetics.
- Core ML for optional replaceable scoring models.
- Core Image and Accelerate for editing and image statistics.
- A narrow persistence adapter currently backed by a compact binary property-list cache; SQLite remains an option when a durable user catalog is added.
- Versioned JSON manifests for portable pipeline inputs and outputs.

## Try it locally

Build the command-line engine:

```bash
swift build
swift run photo-engine smoke-test
swift run photo-engine-checks
swift run photo-engine catalog /path/to/photos
swift run photo-engine run /path/to/photos --profile trip --target 60 --output ./exports/trip
```

Launch the simple Mac UI:

```bash
swift run photo-engine-mac
```

Each run is written beneath `<output>/runs/<timestamp>-<id>/`, so rerunning with a smaller target cannot leave stale JPEGs in the current shortlist. Source files are never modified. Camera, lens, exposure, and capture metadata are retained in exports while GPS metadata is removed by default.

`photo-engine-checks` is a fixture-driven regression executable that exercises grouping, selection, stable IDs, corrupt-file reporting, isolated outputs, metadata sanitization, and unsafe output paths. It is deliberately runnable with the standalone Swift Command Line Tools installed on this machine; it can be migrated to XCTest/Swift Testing without changing the fixture coverage when the app moves into an Xcode project.

## Repository policy

This repository is local-only. No Git remote is configured and nothing should be pushed without an explicit future decision by the owner.

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
