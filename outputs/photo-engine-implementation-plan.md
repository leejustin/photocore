# Photo Engine Implementation Plan

## Modular Local Culling, Scoring, Shortlisting, and JPEG Editing on Apple Silicon

**Status:** Approved planning baseline  
**Date:** September 17, 2026  
**Implementation target:** Native macOS application and reusable Swift engine  
**Initial inputs:** JPEG and HEIC/HEIF folders  
**Initial outputs:** Non-destructive shortlist, edited JPEGs, thumbnails, and versioned decision manifests  
**Repository policy:** Entirely local; no remote and no push  

---

## 1. Decision summary

Build the initial engine as a native Swift 6 codebase composed of small Swift Package Manager modules, with a SwiftUI macOS application and a command-line interface sharing the same orchestration API.

The first usable vertical slice will:

1. Import a folder without modifying it.
2. Catalog supported images and extract metadata.
3. Create efficient analysis previews.
4. Find exact duplicates.
5. Group near duplicates and bursts.
6. Compute independent, explainable quality signals.
7. Rank each burst and create a diversity-aware overall shortlist.
8. Show the results in a simple native interface.
9. Apply a restrained edit recipe to shortlisted images.
10. Export JPEGs and a machine-readable manifest.

This sequence validates the product's central value—removing culling labor—before adding RAW processing, advanced color tools, cloud synchronization, mobile capture, or a subscription control plane.

The source folder is always treated as read-only. The first version never deletes, moves, or overwrites a source photograph. “Rejected” means hidden from the shortlist and recorded in the local catalog, not removed from disk.

---

## 2. Why native Swift is the recommended foundation

### 2.1 Performance on Apple Silicon

Swift provides direct, low-overhead access to the frameworks most useful for this workload:

- **Image I/O** can read metadata and generate bounded thumbnails without decoding every full-resolution image into memory. Apple's Image I/O documentation describes `CGImageSource` as an efficient reader for common formats and exposes `CGImageSourceCreateThumbnailAtIndex` for thumbnail generation. [Image I/O documentation](https://developer.apple.com/documentation/imageio) and [thumbnail API](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex%28_%3A_%3A_%3A%29)
- **Vision** provides feature prints for similarity, face detection and capture quality, image aesthetics, saliency, and other replaceable analysis signals. Apple's own high-quality-thumbnail example combines aesthetics scores with feature-print distance to select strong, nonredundant frames—the same basic principle required by this engine. [Apple Vision thumbnail example](https://developer.apple.com/documentation/vision/generating-thumbnails-from-videos) and [feature-print request](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest)
- **Core ML** can schedule compatible models across the CPU, GPU, and Neural Engine. `MLComputeUnits.all` allows the system to choose among all available compute units, while other modes allow deliberate resource isolation. [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits)
- **Core Image** provides a lazy, GPU-capable filter graph. Apple recommends reusing `CIContext`, using smaller images where possible, and avoiding unnecessary CPU/GPU transfers. [Core Image performance guidance](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html)
- **Accelerate/vImage** provides vectorized CPU image operations, histogram work, convolution, resize, transforms, and format conversion without maintaining custom SIMD code. [vImage documentation](https://developer.apple.com/documentation/accelerate/vimage-library)

These frameworks are already optimized for Apple hardware. Using them avoids shipping a separate Python runtime, CUDA-oriented dependencies that do not apply to the Mac, an Electron renderer, or a cross-language bridge in the most performance-sensitive path.

### 2.2 Maintainability

The engine and UI can share:

- Domain types.
- Structured-concurrency primitives.
- Error handling.
- Progress reporting.
- Persistence models.
- Test fixtures.
- Edit recipes.
- Versioned manifests.

This is simpler for a small team than a Python process controlled by a web or native shell. Python can remain useful for offline model evaluation and conversion, but it should not be required by the installed application.

### 2.3 Modularity beyond the first Mac app

Swift is not being used as an excuse to fuse the engine to SwiftUI. The reusable boundary will consist of:

- Pure domain models.
- Small protocols for analysis, grouping, scoring, selection, rendering, and persistence.
- An event/progress stream.
- Versioned JSON job and result manifests.
- Deterministic configuration files.

The local CLI and Mac app will call the same `PhotoPipeline` service. A future cloud or venue worker may implement the same manifest contract in Swift, Python, or Rust without changing capture or review products.

---

## 3. Supported environment

### 3.1 Initial platform

- Apple Silicon only for the supported beta.
- Minimum macOS 15 unless a required API or implementation constraint forces a later target.
- Swift 6 language mode with strict concurrency warnings treated seriously from the start.
- Development toolchain currently available in this environment: Swift 6.3.2 on arm64 macOS, running on an M3 Max.

M1 remains a supported performance target. Newer hardware increases throughput but must not change output semantics.

### 3.2 Initial formats

Supported for the first release:

- JPEG/JFIF.
- HEIC/HEIF when readable by the operating system.
- Common embedded EXIF, TIFF, IPTC, and orientation metadata.

Deferred:

- RAW and Sony ARW.
- TIFF export.
- PNG as a photographic input workflow.
- Video.
- Live Photos.
- Photos-library integration.

The architecture will include an `ImageDecoder` protocol so RAW support can later use `CIRAWFilter`, which exposes draft scaling, lens correction, noise reduction, highlight recovery, sharpening, and supported-camera introspection. [CIRAWFilter documentation](https://developer.apple.com/documentation/coreimage/cirawfilter)

---

## 4. Repository and module layout

Planned layout:

```text
PhotoEngine/
├── Package.swift
├── README.md
├── Sources/
│   ├── PhotoEngineDomain/
│   ├── PhotoEnginePipeline/
│   ├── PhotoEngineImageIO/
│   ├── PhotoEngineAnalysis/
│   ├── PhotoEngineGrouping/
│   ├── PhotoEngineSelection/
│   ├── PhotoEngineEditing/
│   ├── PhotoEnginePersistence/
│   ├── PhotoEngineCLI/
│   └── PhotoEngineMacApp/
├── Tests/
│   ├── PhotoEngineDomainTests/
│   ├── PhotoEnginePipelineTests/
│   ├── PhotoEngineAnalysisTests/
│   ├── PhotoEngineGroupingTests/
│   ├── PhotoEngineSelectionTests/
│   ├── PhotoEngineEditingTests/
│   └── PhotoEngineIntegrationTests/
├── Fixtures/
│   ├── Synthetic/
│   └── Public/
├── Models/
│   ├── Bundled/
│   ├── Downloaded/       # ignored
│   └── Converted/        # ignored
├── Benchmarks/
├── Scripts/
└── outputs/
```

The exact target count may be reduced if compile boundaries add more friction than value. The important boundaries are domain, platform image access, analysis, selection, editing, persistence, and presentation. The UI must not directly call Vision, Core Image, SQLite, or filesystem traversal.

### 4.1 Module responsibilities

#### PhotoEngineDomain

Pure `Sendable` value types and identifiers:

- `PhotoID`, `ImportID`, `ClusterID`, `RunID`.
- `PhotoAsset`, `PhotoMetadata`, and source fingerprint.
- `AnalysisSignal`, score, confidence, and evidence.
- `DuplicateGroup`, `BurstGroup`, and `SceneGroup`.
- `SelectionDecision` and reason codes.
- `EditRecipe` and `ExportRecipe`.
- Pipeline and manifest versions.
- Mode/profile configuration.

No AppKit, SwiftUI, Vision, Core Image, database, or filesystem implementation belongs here.

#### PhotoEngineImageIO

- Enumerate supported files.
- Read metadata without a full decode.
- Resolve EXIF orientation.
- Generate cached thumbnails at requested sizes.
- Produce stable source fingerprints.
- Decode full resolution only for edit/export.
- Write JPEGs and selected safe metadata.

#### PhotoEngineAnalysis

- Exact byte hash.
- Perceptual hash.
- Vision feature print.
- Exposure/histogram statistics.
- Sharpness and motion-blur metrics.
- Face rectangles, landmarks, and capture-quality signal.
- Aesthetic/utility score when supported.
- Saliency/subject regions.
- Optional Core ML analyzer adapter.

Each analyzer implements an `PhotoAnalyzer` protocol and emits named, versioned signals. No analyzer decides whether an image is finally kept.

#### PhotoEngineGrouping

- Capture-time segmentation.
- Exact duplicate sets.
- Near-duplicate graph construction.
- Burst grouping.
- Scene grouping.
- Representative candidate ordering.

#### PhotoEngineSelection

- Normalize analyzer signals.
- Apply a profile's weights and gates.
- Rank within clusters.
- Produce a global shortlist using quality, similarity penalty, and coverage bonuses.
- Generate reason codes and alternatives.
- Enforce minimum/maximum output sizes.

#### PhotoEngineEditing

- Infer bounded edit parameters.
- Build a non-destructive `EditRecipe`.
- Render preview and full-resolution versions.
- Convert into an explicit output color space.
- Encode JPEG at a configured quality.
- Preserve allowed metadata while stripping unwanted location data by default.
- Add lens/chromatic-aberration adapters later.

#### PhotoEnginePersistence

- SQLite catalog and migrations.
- Analysis cache.
- Pipeline checkpoints.
- User overrides.
- Saved modes and export records.

The initial recommendation is GRDB behind repository protocols rather than raw SQLite calls spread throughout the code. GRDB is an actively maintained Swift SQLite toolkit with Swift Package Manager support; pinning a tested version and isolating it in one module contains dependency risk. [GRDB repository](https://github.com/groue/GRDB.swift)

#### PhotoEnginePipeline

- Orchestrate stages.
- Bound concurrency.
- Publish progress events.
- Respect cancellation and pause.
- Resume cached work.
- Commit stage results transactionally.
- Produce final manifests.

#### PhotoEngineCLI

Commands such as:

```text
photo-engine catalog <folder>
photo-engine analyze <library>
photo-engine shortlist <library> --profile trip
photo-engine export <library> --destination <folder>
photo-engine inspect <photo-id>
photo-engine benchmark <fixture>
```

The CLI is not secondary tooling: it makes the engine testable, scriptable, benchmarkable, and usable without the UI. Apple's Swift Argument Parser is the likely single CLI dependency. [Swift Argument Parser](https://github.com/apple/swift-argument-parser)

#### PhotoEngineMacApp

- SwiftUI scenes and views.
- Folder picker and security-scoped access where relevant.
- Progress and cancellation.
- Cluster/shortlist browser.
- Side-by-side comparison.
- Decision explanation.
- Mode settings.
- Export flow.

The app observes pipeline state but does not contain scoring rules.

---

## 5. Core contracts

The first implementation should establish contracts before sophisticated algorithms.

### 5.1 Analyzer

Conceptual interface:

```swift
public protocol PhotoAnalyzer: Sendable {
    var identifier: AnalyzerID { get }
    var version: SemanticVersion { get }
    var requiredInput: AnalysisInputKind { get }

    func analyze(
        asset: PhotoAsset,
        input: AnalysisInput,
        context: AnalysisContext
    ) async throws -> [AnalysisSignal]
}
```

Signals contain:

- Stable name.
- Value.
- Confidence.
- Analyzer/version.
- Optional region references.
- Optional diagnostic evidence.
- Timestamp and input fingerprint.

### 5.2 Grouper

```swift
public protocol PhotoGrouper: Sendable {
    func group(
        assets: [AnalyzedPhoto],
        configuration: GroupingConfiguration
    ) async throws -> PhotoGrouping
}
```

Grouping output must remain distinct from selection. One photo may belong to an exact-duplicate set, a burst, and a broader scene.

### 5.3 Scorer

```swift
public protocol PhotoScorer: Sendable {
    func score(
        photo: AnalyzedPhoto,
        profile: ScoringProfile
    ) -> CompositeScore
}
```

`CompositeScore` includes components rather than only a total. This lets the UI say that a photo led its burst because it was sharper and had stronger face quality, even though another candidate had a slightly higher aesthetic score.

### 5.4 Selector

```swift
public protocol ShortlistSelector: Sendable {
    func select(
        candidates: [ScoredPhoto],
        grouping: PhotoGrouping,
        profile: SelectionProfile
    ) throws -> Shortlist
}
```

The selector must be deterministic for identical inputs, versions, and configuration.

### 5.5 Editor

```swift
public protocol PhotoEditor: Sendable {
    func proposeRecipe(
        photo: AnalyzedPhoto,
        profile: EditingProfile
    ) async throws -> EditRecipe

    func render(
        source: PhotoSource,
        recipe: EditRecipe,
        destination: RenderDestination
    ) async throws -> RenderedAsset
}
```

Separating recipe inference from rendering allows preview rendering, deterministic re-export, and future cloud compatibility.

### 5.6 Pipeline event stream

The engine exposes `AsyncStream<PipelineEvent>` containing:

- Stage started/completed.
- Per-photo progress.
- Cache hit.
- Warning.
- Recoverable failure.
- Awaiting user decision.
- Export completed.

Both CLI and UI consume the same stream.

---

## 6. Catalog and persistence design

### 6.1 Source identity

Path alone is not identity because files can move or be renamed. The catalog will combine:

- File-system resource identifier when available.
- File size.
- Modification time.
- Fast sampled fingerprint for change detection.
- Full SHA-256 calculated lazily or while data is already being read.

The full content hash provides exact-deduplication identity. Cache keys also include analyzer and pipeline versions.

### 6.2 Proposed tables

- `imports`
- `photos`
- `source_files`
- `photo_metadata`
- `analysis_runs`
- `analysis_signals`
- `feature_vectors`
- `groups`
- `group_members`
- `scoring_runs`
- `scores`
- `selection_runs`
- `selection_decisions`
- `edit_recipes`
- `exports`
- `user_overrides`
- `schema_migrations`

Large thumbnails remain files in a managed cache; the database stores their keys, dimensions, and checksums. Small numeric vectors may be stored as blobs initially, with an explicit format and revision.

### 6.3 Cache invalidation

A cached result is valid only when these match:

- Source content fingerprint.
- Analyzer identifier and version.
- Analyzer configuration fingerprint.
- Relevant operating-system/Vision request revision when system behavior affects output.
- Input preview specification.

Scoring and selection can be rerun cheaply from stored signals when only profile weights change.

---

## 7. Processing pipeline

### 7.1 Stage A: discovery

- Enumerate files iteratively.
- Skip packages, hidden system material, exports, and unsupported types.
- Detect symlink loops and repeated file identities.
- Record unsupported or unreadable files as warnings.
- Do not hold the entire directory tree or file data in memory.

### 7.2 Stage B: metadata and thumbnails

- Open `CGImageSource` from URL.
- Read properties without eagerly decoding full pixels.
- Prefer embedded thumbnail when suitable; otherwise create a bounded thumbnail.
- Apply EXIF orientation during thumbnail creation.
- Generate two cache sizes initially: grid and analysis.
- Avoid decoding full resolution until export.

An analysis long edge around 2,048–2,560 pixels should be benchmarked. Faces in large group photographs may require a larger proxy or region-specific second pass.

### 7.3 Stage C: exact duplicates

- Calculate SHA-256 incrementally.
- Group identical content regardless of filename.
- Pick a canonical member without deleting any source.
- Prefer a stable, user-understandable canonical rule such as oldest original capture time, then shortest path, then lexical path.

### 7.4 Stage D: candidate-neighbor reduction

Do not compare every photo to every other photo. For large collections, all-pairs comparison is quadratic.

Construct plausible neighbor windows from:

- Capture-time proximity.
- Dimensions and orientation.
- Camera/device identity.
- Coarse perceptual hash buckets.
- Import/folder locality.

Vision feature-print distances are then computed only for plausible neighbors. A future approximate-nearest-neighbor index can replace this without changing grouping contracts.

### 7.5 Stage E: near duplicates and bursts

Use multiple signals:

- Time gap.
- Perceptual-hash distance.
- Vision feature-print distance.
- Face-set/subject overlap.
- Camera metadata.
- Framing change.

The thresholds must be calibrated from labeled photos, not hard-coded from intuition. Output categories:

- Exact duplicate.
- Near-identical duplicate.
- Same burst/moment.
- Same scene but distinct composition.
- Unrelated.

### 7.6 Stage F: quality analysis

Initial signals:

- Luminance mean and percentiles.
- Shadow and highlight clipping fractions.
- Color cast estimate.
- Global sharpness.
- Center/subject-region sharpness.
- Motion blur likelihood.
- Face count and areas.
- Face capture quality.
- Closed-eye or eye-visibility evidence when reliable.
- Aesthetic score and utility flag when available.
- Attention/object saliency.
- Aspect ratio and crop flexibility.

Apple describes face capture quality as a holistic signal incorporating factors such as lighting, blur, occlusion, expression, pose, and focus. It should be treated as one component, not duplicated as several independent votes. [Vision face-capture quality sample](https://developer.apple.com/documentation/vision/analyzing-a-selfie-and-visualizing-its-content)

### 7.7 Stage G: scoring

Scoring profiles are data, not branching application code.

Example modes:

#### Everyday

- Strong automatic dedupe.
- Favor people and clear expressions.
- Moderate shortlist size.
- Conservative edits.

#### Group event

- Strong face and coverage weighting.
- Keep alternatives when expressions differ.
- Penalize redundancy heavily.
- Avoid selecting only the same few people.

#### Trip

- Greater scene and location diversity.
- Retain environmental images without faces.
- More generous shortlist.
- Moderate aesthetic/composition weighting.

#### Creative

- Weaker conventional-exposure penalties.
- More tolerance for blur, silhouettes, grain, and unusual framing.
- Higher diversity and novelty reward.

Each profile defines:

- Hard failure gates.
- Signal normalization.
- Quality weights.
- Confidence behavior.
- Similarity thresholds.
- Per-burst keep count.
- Overall target ratio/count.
- Diversity lambda.
- Editing preset.

### 7.8 Stage H: shortlist

The first selector should use a deterministic greedy maximum-marginal-relevance strategy:

```text
next value = weighted quality
             - redundancy penalty against selected photos
             + missing-scene/person/orientation coverage bonus
             + unique-moment protection
```

Selection happens in two passes:

1. Select the best representative and justified alternates within each burst.
2. Select globally across burst representatives and standalone photos to meet output size and diversity goals.

The output contains:

- `keepers`
- `alternates`
- `review` for uncertain choices
- `hidden` high-confidence duplicates/failures
- reasons and confidence for every decision

The product should optimize the number of photos the person must examine, not merely the number kept.

### 7.9 Stage I: edit recipe

Initial automatic adjustments:

- Orientation and color-space normalization.
- Bounded exposure adjustment.
- Highlight/shadow tone curve.
- Conservative white-balance/tint correction.
- Modest saturation/vibrance adjustment.
- Noise reduction based on image conditions.
- Output-aware sharpening.
- Optional horizon adjustment when confidence is high.
- Output resize and JPEG compression.

Editing rules:

- Never bake edits into source files.
- Store every adjustment as an explicit recipe.
- Keep adjustments bounded and reversible.
- Prefer no adjustment to a low-confidence destructive adjustment.
- Render previews cheaply; full resolution only for exports.
- Use a shared `CIContext`, one linear working space, and minimize pixel transfers.

### 7.10 Stage J: JPEG export

- Create a new destination folder.
- Never overwrite without an explicit conflict policy.
- Use deterministic, sortable filenames.
- Encode sRGB JPEG initially for broad compatibility.
- Default quality should be empirically chosen around a high-quality setting, not maximum by habit.
- Preserve capture time, camera, lens, and exposure metadata when desired.
- Strip GPS by default for share-ready exports, with an opt-in preservation setting.
- Write a `manifest.json` mapping every output to its source, selection decision, recipe, and engine versions.

---

## 8. Chromatic-aberration and lens-correction plan

Chromatic-aberration correction matters to the intended product, but JPEG correction must be implemented cautiously.

### Phase 1

- Preserve camera and lens metadata.
- Detect obvious colored edge fringing as an analysis signal.
- Expose the signal in the inspector.
- Avoid automatic correction until evaluation fixtures exist.

### Phase 2

- Add profile-driven correction for RAW through `CIRAWFilter` where Apple reports lens correction support.
- Build a synthetic and real-world purple/green-fringe fixture set.
- Implement a conservative lateral-fringe correction as a replaceable edit operator for JPEG.
- Restrict correction to high-contrast edge neighborhoods and cap color displacement/desaturation.
- Provide before/after zoom inspection.

### Phase 3

- Add external lens-profile support only if measured coverage or quality justifies the maintenance cost.

An edge-based correction must not confuse neon lighting, colored clothing edges, signage, or deliberate color contrast with lens fringing.

---

## 9. UI plan

The first UI should be intentionally small and useful rather than a miniature Lightroom.

### 9.1 Primary layout

```text
┌──────────────┬──────────────────────────────────────┬───────────────┐
│ Library      │ Contact sheet / burst comparison     │ Inspector     │
│              │                                      │               │
│ All          │ [photo] [photo] [photo] [photo]      │ Why selected  │
│ Shortlist    │ [photo] [photo] [photo] [photo]      │ Score signals │
│ Review       │                                      │ Edit preview  │
│ Hidden       │                                      │ Alternatives  │
│ Bursts       │                                      │               │
└──────────────┴──────────────────────────────────────┴───────────────┘
│ Import folder │ Mode: Trip │ 127 / 620 analyzed │ Pause │ Export    │
└────────────────────────────────────────────────────────────────────┘
```

### 9.2 Essential interactions

- Choose folder.
- Choose mode.
- Start, pause, resume, or cancel processing.
- Filter by shortlist/review/hidden/burst.
- Open a burst comparison.
- Promote an alternate.
- Force keep or hide.
- Compare original and edit.
- Inspect reasons and signal values.
- Change target shortlist size and rerun selection without reanalyzing.
- Export selected edited JPEGs.

### 9.3 Deliberately omitted initially

- Pixel-level retouching.
- Layers and masks.
- Freeform curves editor.
- Cloud account.
- Mobile companion.
- Publishing integration.
- Complex library management.

The interface exists to establish trust in automation. “Why this photo?” and easy correction are more important than hundreds of controls.

---

## 10. Concurrency and performance plan

### 10.1 Bounded structured concurrency

Use Swift task groups and actors, but never launch one unrestricted task per source image. Each stage receives a concurrency budget based on:

- CPU count.
- Available memory.
- Thermal state where observable.
- Input dimensions.
- Analyzer resource class.

Proposed resource lanes:

- Metadata I/O.
- Thumbnail decode.
- CPU statistics/hash.
- Vision/Core ML inference.
- GPU/Core Image render.
- Disk encode/write.

An actor-based scheduler grants permits per lane and lowers concurrency under memory pressure.

### 10.2 Memory discipline

- Autorelease pools around Objective-C framework loops.
- Bounded thumbnail cache.
- Full-resolution decode only during export.
- Avoid holding `CGImage`, `CIImage`, and pixel buffers longer than a stage requires.
- Stream database results rather than loading entire libraries where possible.
- Measure resident memory on 8 GB and 16 GB M1-class constraints even if development occurs on a larger M3 Max.

### 10.3 Framework-specific choices

- Reuse `CIContext`; do not create one per photo.
- Reuse model instances where thread-safety permits.
- Use Image I/O thumbnail decode rather than full decode followed by resize.
- Combine compatible Vision requests for one input where that avoids repeated face detection.
- Supply detected face observations to downstream face-quality and landmark requests.
- Use Core ML `.all` by default, then benchmark `.cpuAndNeuralEngine` if GPU contention with Core Image harms throughput.
- Batch database writes in transactions.
- Persist each stage so a mode-weight change does not rerun expensive analysis.

### 10.4 Benchmark corpus

The benchmark suite should include consented or synthetic sets representing:

- Sony A7C JPEGs from multiple lenses.
- Modern iPhone and Pixel HEIC/JPEG.
- Bright daylight.
- Low-light interiors.
- Fast motion.
- Groups with expression changes.
- Landscapes and architecture.
- Intentionally creative blur/exposure.
- Exact copies and recompressed copies.
- Bursts ranging from 2 to 50 images.
- Collections of 100, 1,000, and 10,000 images.

Report:

- Wall-clock time per stage.
- Images/second.
- Peak resident memory.
- Cache hit behavior.
- Full-resolution render time.
- Energy/thermal behavior during sustained runs.
- Selection-quality metrics.

Performance gates should target M1 behavior; the M3 Max development machine is useful for iteration but cannot be the only benchmark.

---

## 11. Scoring quality and evaluation

### 11.1 Do not collapse signals too early

An aesthetic score cannot replace technical and contextual judgment. Store and evaluate signals separately so the engine can distinguish:

- Technically failed.
- Technically sound but redundant.
- Conventionally unusual but intentionally creative.
- Strong individual photo but harmful to collection diversity.
- Lower standalone score but unique moment.

### 11.2 Human-labeled evaluation

For each benchmark session, record:

- Exact-duplicate groups.
- Burst/scene membership.
- Human preferred representative per burst.
- Acceptable alternates.
- Unique images that must not be automatically hidden.
- Desired overall shortlist.
- Edit preference and unacceptable edit failures.

### 11.3 Primary quality metrics

- Exact-duplicate precision and recall.
- Burst-pair precision and recall.
- Preferred representative top-1/top-3 rate.
- Unique-moment false-hide rate.
- Shortlist reduction ratio.
- Human keep rate for automated shortlist.
- Human promotion rate from hidden/review.
- Coverage across labeled moments/people/scenes.
- Edit acceptance rate.

The highest-risk metric is unique-moment false hiding. Keeping an extra duplicate is annoying; hiding the only meaningful photograph is a trust-breaking error.

### 11.4 User corrections

Overrides are stored separately from model output:

- Forced keep.
- Forced hide.
- Preferred burst representative.
- Edit disabled/adjusted.
- Incorrect duplicate group.

This preserves original engine decisions for evaluation and makes future personalization possible without silently rewriting history.

---

## 12. Error-handling policy

Per-file failures should not normally abort an entire import.

Expected recoverable errors:

- Unsupported format.
- Corrupt metadata.
- Decode failure.
- Permission loss.
- File changed after discovery.
- Analyzer unavailable on current OS.
- Model load failure.
- Export name collision.

The pipeline records a structured issue, continues where safe, and displays a final issue summary. Fatal errors are limited to problems such as database corruption, destination unavailability with no recovery option, incompatible schema, or internal invariant violation.

Every error includes:

- Stable code.
- Stage.
- Affected asset when applicable.
- Retryability.
- User-facing summary.
- Diagnostic cause that avoids leaking private image content.

---

## 13. Testing plan

### 13.1 Unit tests

- Metadata normalization.
- Orientation mapping.
- Hash and fingerprint stability.
- Signal normalization.
- Profile parsing and validation.
- Scoring math.
- Deterministic selection.
- Coverage constraints.
- Manifest encoding/decoding.
- Filename conflict policy.
- Edit-recipe bounds.

### 13.2 Contract tests

Each analyzer must pass a shared contract:

- Stable identifier/version.
- Deterministic result for fixture and fixed request revision.
- Cancellation behavior.
- Structured error behavior.
- No mutation of source.
- Correct cache fingerprint.

### 13.3 Integration tests

- Import fixture folder through exported JPEGs.
- Resume after process interruption.
- Rerun selection without rerunning analysis.
- File rename/move detection.
- Source change invalidates relevant cache.
- Export manifest maps every output correctly.
- UI and CLI produce the same shortlist for the same profile.

### 13.4 Visual regression tests

- Render edit fixtures using a fixed recipe.
- Compare perceptual difference with tolerances rather than byte equality across OS/hardware.
- Inspect contact sheets for tone, clipping, skin color, halos, over-sharpening, and color fringing.
- Version expected output by renderer and OS behavior where necessary.

### 13.5 Performance tests

- Prevent accidental full-resolution decode during analysis.
- Enforce peak-memory budgets on representative collections.
- Track stage throughput over commits.
- Flag major regressions but allow explicit baseline updates with explanation.

---

## 14. Implementation sequence and clean commit plan

Each milestone should end in a buildable, tested commit. Avoid large commits that mix refactoring, new behavior, and fixture updates.

### Milestone 0: Repository foundation

Commits:

1. `chore: initialize local photo engine repository`
2. `chore: scaffold Swift package and test targets`
3. `ci: add local build test and format scripts`

Deliverables:

- Git repository with no remote.
- Ignore rules protecting source photos, generated exports, secrets, models, and local databases.
- Swift package skeleton.
- Basic build/test script.
- Architecture decision record for native Swift.

### Milestone 1: Domain and catalog

Commits:

1. `feat(domain): add photo catalog and pipeline value types`
2. `feat(image-io): discover supported photos and read metadata`
3. `feat(persistence): add catalog database and migrations`
4. `feat(cli): add catalog command`

Acceptance:

- Catalog a folder of JPEG/HEIC files.
- Reopening does not repeat unchanged metadata work.
- Source files remain untouched.
- Unit and integration tests pass.

### Milestone 2: Preview and deduplication

Commits:

1. `feat(image-io): add bounded thumbnail cache`
2. `feat(analysis): add exact and perceptual hashes`
3. `feat(analysis): add vision feature prints`
4. `feat(grouping): group exact and near duplicates`
5. `feat(cli): report duplicate groups`

Acceptance:

- Exact copies group regardless of filename.
- Labeled near-duplicate fixtures meet initial precision targets.
- Large-image analysis does not require full-resolution decode.

### Milestone 3: Quality scoring

Commits:

1. `feat(analysis): add exposure and clipping signals`
2. `feat(analysis): add sharpness and blur signals`
3. `feat(analysis): add face quality signals`
4. `feat(analysis): add aesthetic and saliency signals`
5. `feat(selection): add versioned scoring profiles`

Acceptance:

- Every score is explainable through components.
- Missing analyzers degrade gracefully.
- Profile changes reuse cached analysis.

### Milestone 4: Bursts and shortlist

Commits:

1. `feat(grouping): add burst and scene grouping`
2. `feat(selection): rank burst representatives`
3. `feat(selection): add diversity-aware shortlist`
4. `feat(cli): export shortlist manifest`

Acceptance:

- Same input/configuration produces the same shortlist.
- Unique-moment protection passes labeled fixtures.
- Target size and diversity constraints are respected.

### Milestone 5: Simple Mac UI

Commits:

1. `feat(app): add import and processing workflow`
2. `feat(app): add shortlist contact sheet`
3. `feat(app): add burst comparison and overrides`
4. `feat(app): add score explanation inspector`

Acceptance:

- A user can import, process, inspect, and correct a collection without the CLI.
- App remains responsive during analysis.
- Cancel and resume work.

### Milestone 6: Editing and export

Commits:

1. `feat(editing): add versioned edit recipes`
2. `feat(editing): add core image preview renderer`
3. `feat(editing): add full-resolution jpeg export`
4. `feat(app): add before-after and export flow`

Acceptance:

- Source files remain byte-identical.
- Exported files and manifest are complete and reproducible.
- Edits remain inside defined safety bounds.

### Milestone 7: Calibration and performance

Commits should separate benchmark fixtures, algorithm changes, and threshold updates.

Acceptance:

- Representative M1 benchmark completed.
- Peak memory and throughput documented.
- Selection metrics documented.
- Default thresholds derive from the evaluation set.

### Milestone 8: Chromatic aberration and RAW exploration

Only begin after the JPEG-first loop is reliable.

- Add CA detection fixtures.
- Add conservative JPEG operator behind a feature flag.
- Evaluate `CIRAWFilter` with Sony A7C ARW samples and supported lenses.
- Decide whether RAW belongs in the main app or a later optional module.

---

## 15. First vertical-slice definition

The first implementation sprint should end with a CLI, not the final UI. This produces a measurable engine faster and creates stable contracts for the app.

Command:

```text
photo-engine run ~/Pictures/TestSet \
  --profile everyday \
  --target 40 \
  --output ./exports/TestSet
```

Expected output:

```text
exports/TestSet/
├── contact-sheet.jpg
├── manifest.json
├── shortlist/
│   ├── 001_IMG_1234.jpg
│   └── ...
└── report.html
```

For the earliest vertical slice, exported shortlist images may be unedited copies or conservatively re-encoded previews. That slice proves cataloging, grouping, scoring, selection, progress, and manifest behavior before full-resolution editing complicates the loop.

Definition of done:

- Handles at least 500 mixed test JPEG/HEIC images.
- Finds exact duplicates.
- Produces plausible near-duplicate clusters.
- Emits at least sharpness, exposure, face-quality, aesthetics, and similarity signals where available.
- Creates a deterministic target-sized shortlist.
- Generates reason codes.
- Runs a second time substantially faster by using the cache.
- Never modifies or deletes sources.
- Passes tests and leaves no untracked media in Git.

---

## 16. Dependency policy

Prefer Apple system frameworks and the standard library. Add a package only when it removes meaningful maintenance burden and has:

- Active maintenance.
- A compatible license.
- Swift Package Manager support.
- A narrow, isolatable role.
- A pinned tested version.
- No hidden network or telemetry behavior.

Likely initial dependencies:

- GRDB for SQLite access, isolated in persistence.
- Swift Argument Parser for CLI parsing, isolated in CLI.

Avoid initially:

- General-purpose computer-vision frameworks.
- Embedded Python.
- Electron/Tauri.
- Cloud SDKs.
- Analytics SDKs.
- Dependency-injection frameworks.
- Large model hubs or runtime downloaders.

Model files require recorded source, license, checksum, conversion process, input normalization, and benchmark results before bundling.

---

## 17. Git workflow

### 17.1 Local-only rule

- Do not add a remote.
- Do not push.
- Do not authenticate to a Git host.
- Before every handoff, show `git remote -v` and verify it is empty unless the user later changes this rule.

### 17.2 Commit hygiene

- Commit only buildable, coherent changes.
- Run relevant tests before commit.
- Keep generated media, private fixtures, databases, models, and secrets ignored.
- Use conventional, descriptive messages such as `feat(selection): add burst representative ranking`.
- Do not rewrite shared history after a remote eventually exists without explicit permission.
- Tag meaningful evaluation baselines after the engine becomes functional.

### 17.3 Source-photo safety

Before adding files, inspect staged paths and file types. A pre-commit safety script should eventually reject:

- Common photo/video extensions outside approved public fixtures.
- SQLite database files.
- Large model binaries outside an approved bundled-model directory.
- `.env` and credential formats.
- Generated export directories.

---

## 18. Risks and responses

### Risk: Apple's scores are useful but not sufficient

**Response:** Treat every system API as a replaceable analyzer. Preserve individual signals and calibrate against labeled sessions.

### Risk: Vision output changes with OS revisions

**Response:** Record request revisions and OS context in cache/manifests, pin revisions where possible, and rerun evaluation before changing defaults.

### Risk: Swift limits access to some research models

**Response:** Use Python only for model research/conversion. Deploy selected models through Core ML behind `PhotoAnalyzer`.

### Risk: Feature-print comparison becomes quadratic

**Response:** Use time/hash buckets now; introduce approximate-nearest-neighbor indexing when benchmarks justify it.

### Risk: Native Swift narrows future server deployment

**Response:** Keep manifests language-neutral and algorithms behind contracts. The immediate product benefits from native performance; future server workers can implement the same job schema separately.

### Risk: Automatic edits damage already-processed phone images

**Response:** Use bounded recipes, detect input characteristics, expose before/after, and prefer no edit at low confidence.

### Risk: Developing on M3 Max hides M1 problems

**Response:** Establish explicit M1 memory and throughput benchmarks before calling a milestone complete.

### Risk: The UI grows into an editor suite

**Response:** Keep scope centered on trust, correction, and export. Advanced manual editing is not required to validate automatic culling.

---

## 19. Recommended next implementation action

After this planning commit, begin Milestone 0 by creating the Swift package and these first three targets:

1. `PhotoEngineDomain`
2. `PhotoEngineImageIO`
3. `PhotoEngineCLI`

The first coded acceptance test should create a temporary fixture folder, discover supported files, extract normalized metadata and oriented thumbnails, and prove that source bytes and timestamps remain unchanged.

Do not begin with model selection or visual polish. The first engineering objective is a safe, cacheable ingestion spine that every later analyzer, UI, and deployment mode can reuse.

