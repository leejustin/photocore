# Photo Engine

Photo Engine is a local-first photo culling and editing system designed for Apple Silicon. It will import folders of JPEG/HEIC photographs, identify exact and near duplicates, group bursts and scenes, compute explainable quality signals, produce a diverse shortlist, apply restrained edits, and export finished JPEGs without modifying the source files.

The first product surface is a simple native macOS application. The processing engine is being designed as a set of independent Swift packages so the same pipeline can later power personal camera workflows, venue capture systems, background workers, and command-line batch processing.

## Current status

The first local vertical slice is implemented: folder discovery, JPEG/HEIC metadata, oriented thumbnails, exact/near-duplicate grouping, Vision feature vectors, quality signals, deterministic shortlisting, analysis caching, edited JPEG export, JSON manifests, a CLI, and a simple SwiftUI shell.

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
- SQLite through a narrow persistence adapter.
- Versioned JSON manifests for portable pipeline inputs and outputs.

## Try it locally

Build the command-line engine:

```bash
swift build
swift run photo-engine smoke-test
swift run photo-engine catalog /path/to/photos
swift run photo-engine run /path/to/photos --profile trip --target 60 --output ./exports/trip
```

Launch the simple Mac UI:

```bash
swift run photo-engine-mac
```

The current environment has Swift Command Line Tools but not the XCTest runtime from full Xcode, so verification currently uses the built-in smoke-test command. The package is structured so XCTest targets can be added when the full Xcode toolchain is available.

## Repository policy

This repository is local-only. No Git remote is configured and nothing should be pushed without an explicit future decision by the owner.

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
