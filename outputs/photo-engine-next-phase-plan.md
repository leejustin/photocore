# Photo Engine: dependable culling, simple review, and storage reduction

Status: implementation handoff; the repository now contains a verified first vertical slice of the work described here. Remaining items are called out honestly in the README and final handoff.

## 1. Product objective

Make taking photographs enjoyable without creating a second job sorting, editing, and managing files. A user imports a shoot, receives an edited and substantially reduced collection, reviews only meaningful uncertainties, and can deliberately reduce the storage occupied by originals and generated artifacts.

Primary workflow: local macOS application on Apple Silicon, using JPEG/HEIC images from arbitrary cameras and phones. Sony A7C is an important evaluation source, not a product restriction. Keep the engine modular for future workers and capture applications. An LLM, account, network service, cloud storage, and subscription backend are not required for this phase.

### Implementation constraints

- Keep everything local. Do not configure a Git remote or push anything.
- Use small, coherent Git commits after verified milestones. Preserve unrelated user changes.
- Retain Swift, SwiftUI, Vision, Image I/O, Core Image, and the current module boundaries where sensible.
- Never modify source photographs during analysis, preview, or export.
- Culling decisions never authorize source deletion. Cleanup is an explicit, separately approved workflow.
- Do not claim an algorithm is calibrated, subject-aware, or reliable merely because it runs.
- Do not invent quality measurements when a model or input is unavailable. Represent unavailable signals and confidence explicitly.
- Do not download personal photographs or commit real photo collections. Generate synthetic test fixtures; keep user evaluation sets outside Git.
- Read applicable AGENTS.md files before implementing. Review current source rather than assuming every observation below remains current.
- This is an implementation plan, not authority to publish, deploy, train on private data, or purchase services.

## 2. Current baseline and gaps

Baseline commits: `3d6fade` and `e2532cc`. The package contains Core, Apple, Persistence, CLI, SwiftUI executable, and a fixture-based regression executable.

Implemented baseline: metadata import, whole-image sharpness heuristic, Vision aesthetics and face capture quality, encoded Vision feature prints, exact-content hashes, time-bounded representative clustering, shortlist scoring, modest JPEG edits, binary cache, separate output directories per run, import warnings, and simple bucket browsing.

Important limitations to address:

1. The Vision revision-2 distance thresholds were changed to 8–10 without calibration. Verify the actual scale empirically before relying on them. A passing self-distance check does not establish a useful threshold.
2. Near-duplicate grouping accepts perceptual-hash similarity OR Vision similarity. Low-detail images and semantically similar but distinct moments can be incorrectly grouped.
3. Time windows use the latest cluster member; long chains can extend a burst indefinitely even with a fixed visual representative. Bound total duration as well.
4. Whole-image Laplacian energy is a texture-sensitive heuristic, not a dependable subject-focus detector. Its current comment overstates validation.
5. Selection recomputes comparisons against all already selected images on each iteration, and the Apple distance function decodes both descriptors on every comparison.
6. Group representative tie-breaking depends on unordered dictionaries in places. Identical inputs/settings should produce stable decisions.
7. Import retains all thumbnails until the run completes. The binary cache loads and rewrites the complete collection.
8. IDs depend on relative path, size, and sampled content; renaming a file changes its ID. Head/tail signatures can miss middle-of-file edits. The cache still uses unchecked sendability around mutable state.
9. Every run produces another set of exports. There is no durable session, saved user correction, cleanup ledger, or artifact retention policy.
10. The UI renders source thumbnails in small rows; it lacks keep/swap/undo, full-size comparison, edited previews, and a focused uncertainty queue.
11. Cancellation is not consistently checked during discovery/grouping/selection. A folder can be changed while processing. Progress delivery and security-scoped access lifetimes need review, particularly for lazy thumbnails after a run.
12. The regression executable has eight checks. Its fixtures do not establish face quality, subject focus, distance calibration, large-library performance, or safe cleanup behavior.

## 3. Product decisions

### Three independent controls

| Control | Values | Responsibility |
|---|---|---|
| Occasion | Everyday, Group event, Trip, Creative | Coverage priorities and tolerance for photographic intent |
| Culling | Gentle, Balanced, Highlights | Redundancy, variations per moment, quality requirements |
| Look | Natural, Warm, Vibrant, Soft, Black & white | Rendering only |

Default: Everyday, Balanced, Natural. Remember the last settings, but display them before processing. Advanced controls remain collapsed.

An optional approximate target count influences selection, but is not a mandatory quota. Do not pad an album with obvious failures or discard protected unique moments solely to hit a number. Explain when the result differs from the requested count.

Changing occasion or culling reuses analysis. Changing style reuses selection. None of these actions automatically creates a new full-resolution export or changes source files.

### Culling presets

| Preset | Behavior |
|---|---|
| Gentle | Collapse exact copies and strong near-duplicates; keep useful pose/expression variations and uncertain unique moments |
| Balanced | Prefer one or a few strong photos per moment while preserving people, scene, and chronological coverage |
| Highlights | Produce a compact representative album with fewer repetitive poses and scenes; preserve explicitly protected items |

Do not assign universal keep percentages. Show the actual estimated selection count after analysis. Put quality strictness and alternates-per-moment in advanced settings only if testing shows users need them.

### Decision categories

- Selected: recommended for the final collection.
- Alternate: a valid variation of a selected moment.
- Needs attention: consequential uncertainty, such as a unique but soft image or a group shot with competing face quality.
- Excluded: redundant or low-value material. Exclusion alone does not mean safe to delete.
- Protected: user intent that overrides automatic selection and cleanup eligibility.

Avoid making every photo below a numerical target a review task. Users should be able to finish without inspecting all excluded photos.

## 4. Architecture and data contracts

Split large single-source files along these responsibilities as features require it; avoid a rewrite without a concrete benefit.

### Core domain

Introduce Codable, Sendable value types with explicit schema versions:

- `SessionID`, `AssetID`, `ContentID`: separate a shoot, a catalog occurrence, and exact file contents.
- `SourceReference`: canonical location, volume/file resource identity where available, size, modification data, verified content digest, access/bookmark reference.
- `AnalysisConfiguration`: request revisions, input sizes, algorithm/model versions, crop policy, and a reproducible fingerprint.
- `QualityAssessment`: named signals, availability, confidence, evidence regions, and limitations. Avoid one unexplained universal quality number.
- `SubjectRegion`: normalized coordinates with an explicit orientation/coordinate convention, type, salience, and confidence.
- `FaceAssessment`: region, capture quality, optional eye state/focus measurements and their confidence. Identity is a separate optional reference.
- `MomentGroup`: members, representative, temporal bounds, similarity evidence, and stable identity within a session.
- `CurationSettings`: occasion, aggressiveness, optional approximate count, protection and coverage rules.
- `CurationDecision`: category, reason codes, confidence, automatic recommendation, and separately stored user override.
- `StyleRecipe`: preset/version, intensity, automatic corrections, output color space, and ordered deterministic operations.
- `ExportSpecification`: size limit, quality/encoding settings, format, metadata policy, recipe version.
- `ArtifactRecord`: owner session, type, source/content dependencies, recipe/settings fingerprint, file location, size, and lifecycle state.
- `CleanupPlan` and `CleanupOperation`: explicit targets, verified retained replacements, estimated bytes, protection checks, approval snapshot, and execution/recovery status.

Keep Apple observations in the Apple adapter. Core accepts typed providers for visual distance and signal production. Do not leak Vision serialization details into selection logic or portable manifests.

### Persistence

Use SQLite through a narrow adapter for sessions, assets, analyses, decisions, overrides, artifacts, and cleanup operations. Prefer a minimal system SQLite integration or a deliberately justified dependency. Do not spread SQL across the UI.

- Use migrations, transactions, parameterized statements, and one defined concurrency owner (actor or serialized queue).
- Store descriptor/crop data as binary blobs or referenced files, not repeated JSON arrays.
- Upsert changed records, rather than rewriting the entire catalog.
- Invalidate only the analysis components whose inputs or versions changed.
- Record source access bookmarks for reopening sessions on macOS.
- Preserve manual decisions across rescoring and app restarts.
- Treat old caches as expendable; existing source photos and exports must remain usable.
- Migrate earlier manifests only when unambiguous. Otherwise offer read-only legacy import rather than silently changing their semantics.

File identity strategy: retain a catalog occurrence ID across ordinary path changes when filesystem identity supports it; content hashes connect copies but must not collapse distinct source occurrences into one mutable file record. Full hashes are required for exact duplicate and destructive cleanup decisions. Sampled signatures may serve only as optimization hints.

## 5. Culling pipeline

### Stage A: discovery and cheap screening

Enumerate incrementally; report unreadable files and directories; check cancellation. Collect metadata, orientation, timestamps/offsets, dimensions, and filesystem identity. Detect already cataloged inputs and engine-owned generated artifacts. Avoid importing the application's outputs into their own source session.

Compute streaming full content hashes where required, grouping byte-identical files before expensive image analysis. Reuse one content analysis across identical files while retaining per-occurrence metadata/location records.

### Stage B: broad analysis

Use bounded, aspect-ratio-preserving, correctly oriented previews for coarse exposure, composition, perceptual hashes, and supported Vision requests. Benchmark whether each Vision request benefits from a full source or a downsampled input; do not blindly downgrade face detail to a tiny preview.

Analyze each signal independently enough that an optional request failure becomes a visible missing signal rather than aborting an entire shoot. A failure to read/decode the source is a file issue, not a low quality score.

### Stage C: subject quality

Use faces first for people images; otherwise use saliency/foreground/object evidence when supported. Keep subject detection replaceable. A saliency map is a candidate region, not proof of the photographer's intention.

Extract higher-resolution crops only for plausible keepers and uncertain comparisons. Evaluate face/subject sharpness separately from background detail. Use the same effective crop scale when comparing burst alternatives. Store uncertainty when subjects are tiny, occluded, or ambiguous.

For people, combine face capture quality with separately validated eye-state and focus signals when available. Group-photo ranking should account for poor important faces (for example, a lower quantile plus average), not just average face quality. Avoid automatically prioritizing every tiny background face.

Do not label blur as camera shake, motion, or missed focus unless the method can distinguish it with evaluated confidence. Start with `subject appears soft`, and route unique uncertain photos to attention. Creative mode must tolerate intentional motion, silhouette, shallow depth of field, and unusual exposure.

### Stage D: moment grouping

Build candidates by capture time, source context, camera identity when available, and coarse visual evidence. Handle missing timestamps conservatively. Include an explicit assumption for timezone-less EXIF dates; changing that assumption must invalidate temporal grouping.

- Exact duplicates: verified full digest equality, independent of time.
- Near duplicates: calibrated visual distance plus corroborating evidence, with safeguards against low-detail hash collisions.
- Bursts: related photos over bounded total duration, with representative/diameter constraints preventing chains.
- Scene/moment coverage: a separate looser relation; photos can share a scene without being interchangeable.

Bound candidate comparisons and active cluster storage. Use deterministic tie-breakers based on stable IDs. Preserve evidence explaining why a photo was grouped. Recalibration must not erase manual overrides.

### Stage E: selection and coverage

Rank within moments first, then select across the shoot. Consider technical quality, aesthetic signal, distinctness, chronology, scene coverage, and optional people coverage. Treat receipts/signs/reference images as a separate useful category.

Apply protection and unique-moment rules before approximate target pressure. Do not enforce arbitrary absolute score cutoffs across unrelated photo genres. Low-confidence automatic exclusions should be less aggressive than high-confidence redundancy removal.

Build a compact attention queue around ambiguous moments, not individual-file volume. Record whether a decision is due to blur, an equivalent better alternative, redundancy, coverage, or user instruction. Keep confidence separate from quality.

## 6. Performance plan

1. Decode each Vision descriptor once per analysis/curation session; cache decoded observations within a bounded lifetime. Validate request revision compatibility.
2. Maintain each candidate's maximum similarity to the selected set and update it only against the newly selected photo. Target approximately O(N × K) comparisons instead of O(N × K²).
3. Use an active time-window structure for grouping rather than moving items in an array of all historical clusters. Measure candidate counts.
4. Stream discovery and use a bounded queue of analysis previews. Release buffers promptly; use autorelease pools around image-heavy work where measurements justify them.
5. Reuse exact-content analysis and skip unchanged components. Avoid thumbnail decoding on a cache hit if it is unnecessary.
6. Limit concurrent expensive work according to available memory, pixel dimensions, thermal state, and user foreground activity. Provide automatic defaults with an advanced worker limit for benchmarks.
7. Render low-resolution previews first; full-resolution selected outputs only at finalization. Reuse CIContext and compiled resources safely.
8. Give preview work priority over background analysis. Debounce settings changes and cancel stale preview/selection tasks.
9. Make cancellation cooperative throughout discovery, hashing, grouping, selection, rendering, and persistence boundaries. Finish or roll back transactions cleanly.
10. Record stage timings, processed megapixels, cache hit rates, distance comparison counts, and peak resident memory locally. No telemetry upload.

Benchmark cold import, warm reopen, culling-setting change, style-preview change, and final export on 100, 1,000, and 10,000-photo collections where available. Use realistic 24 MP DSLR JPEGs and phone HEICs, not only system thumbnails. Compare worker counts before promising M1/M3 speedups.

Provisional UX budgets: cached setting changes should feel interactive (aim for under one second for a typical 1,000-photo shoot); preview requests should prioritize the visible image; cancellation should acknowledge immediately and stop at a documented safe boundary. Report measured hardware/results instead of declaring these budgets met without evidence.

## 7. Session workflow and UI

### Add a shoot

One welcome/drop surface with `Choose photos` and folder/card support. Show the three main controls and a destination/session name. Advanced options contain approximate count and output preferences. Remember defaults without hiding them.

A camera card workflow must verify local copies before offering card cleanup. Direct camera tethering/import protocols are a later adapter; folder and mounted-card import is sufficient initially.

### Processing

Show meaningful stages, overall progress where measurable, elapsed time, and Cancel. Do not invent an ETA before enough throughput data exists. Allow background processing, but prevent mismatched source/results state when a new folder is chosen. Each event carries its session/run identifier so old progress cannot overwrite a newer result.

### Collection

Use a large adaptive grid with preserved photographic aspect ratios. Default to selected images; organize by moments or chronology. Show a concise summary such as `428 photos → 62 selected · 7 moments need attention`.

- Primary actions: review attention, adjust culling, choose look, finish.
- Secondary access: all photos, alternates, excluded, reference photos, and diagnostics.
- Never default to filenames and numerical scores as the primary content.
- Use neutral backgrounds, restrained accent color, clear typography, accessible contrast, keyboard navigation, and reduced-motion support.
- Show edited-preview state clearly; avoid making a source thumbnail appear to be the final edited export.

### Compare and correct

Side-by-side candidates with synchronized zoom and subject/face crop shortcuts. Actions: Keep, Swap, Exclude, Protect, Undo. Show short explanations and optional detailed evidence. Persist corrections immediately. Recuration respects overrides until the user explicitly resets them.

Provide useful keyboard shortcuts, but complete the workflow with a mouse. A large collection should not require opening every image. Include an optional quick full-selection slideshow before finalizing.

### Finish

Show selected count, estimated export size, format/dimensions, metadata policy, and retention choice. Separate `Export collection` from `Review cleanup`. Export failure must leave sources untouched and previous valid outputs usable.

UI acceptance requires running the app and inspecting actual rendered screens, not just compiling SwiftUI. Verify small/large windows, dark/light appearance, empty state, processing, cancellation, warnings, results, comparison, and cleanup preview.

## 8. Styles and export

Initial looks: Natural (default), Warm, Vibrant, Soft, Black & white. Each has a versioned deterministic recipe and intensity control. Separate technical corrections (exposure, white balance, highlight handling) from creative styling. Aim for coherent burst rendering and plausible skin color without flattening intentional light.

Style changes must not rerun culling or change source pixels. Preview and full-resolution render use the same recipe/color-management path. Use a deliberate output color space, usually sRGB for shared JPEGs, and test orientation and HDR/HEIC conversion.

Offer simple output presets such as Full size and Compact, with explicit long-edge/quality settings available under Advanced. Estimate size from representative renders; avoid claiming fixed savings from JPEG quality alone.

Track artifacts by content, recipe, and output-specification fingerprints. Reuse identical exports. New settings create a new revision only when needed; do not create a directory per preview. Retire obsolete app-owned artifacts according to policy.

Metadata: preserve useful camera/lens/exposure/date and chosen copyright fields; normalize orientation and dimensions after rendering. Strip GPS by default. Sanitize location-bearing nested metadata as well as the primary GPS dictionary, or document exactly what the policy covers. Test EXIF/TIFF/IPTC/XMP handling instead of assuming a shallow dictionary copy is sufficient.

Chromatic aberration: investigate a profile-backed correction or bounded defringing module. Specify supported formats/lenses, test real edge cases, and expose availability honestly. Universal JPEG lens correction is not a prerequisite for shipping the first styles.

## 9. Storage lifecycle and cleanup

### Storage policies

| Policy | Retained material |
|---|---|
| Preserve originals | All sources; app caches and obsolete exports may be managed |
| Keep selected originals | Selected/protected originals plus finished exports; approved rejected-source cleanup |
| Compact memories | Verified finished JPEGs plus explicitly protected originals; approved eligible-source cleanup |

Default to Preserve originals until the user chooses otherwise. Make future-session defaults explicit; changing a policy does not retroactively delete old files.

### Lifecycle

Analyze → review/override → finalize exports → verify replacements → generate cleanup preview → user approves exact plan → execute recoverable operations → record outcome.

The cleanup preview lists categories, file counts, bytes, retention deadlines, protected exceptions, and retained destinations. Differentiate logical file sizes from actual disk space freed, especially for APFS clones, shared content, external volumes, and Trash. Moving to Trash does not immediately reclaim disk space.

Before each source cleanup operation:

1. Resolve the exact file identity and canonical path; reject changed or unexpected targets.
2. Verify required exports by decoding them and confirming dimensions/content linkage and successful manifest/catalog commit.
3. Apply protection, unresolved-issue, source-role, and retention rules.
4. Record intent transactionally before mutation and completion afterward.
5. Use system Trash where supported. If unavailable, stop that operation and report the limitation rather than silently permanently deleting.

Do not recursively remove arbitrary source directories. Clean up only known files from an approved plan. Handle partial failures and restart recovery idempotently. Offer recovery instructions and an operation history. Trash restoration is best-effort and must not be advertised as guaranteed after the OS/user empties Trash.

For app-generated artifacts, keep an ownership ledger and configurable cache budget. Evict least-recently-used recreatable previews and superseded exports; never infer ownership from a filename alone. Do not count retained original copies elsewhere as savings.

## 10. Optional people grouping

This is a later capability, not supplied by the current Vision face detection/capture-quality requests.

Pipeline: detect face → align crop → licensed local embedding model → confidence-aware clustering → optional user naming and merge/split corrections. Small, occluded, or ambiguous faces can remain unassigned. Never force every face into a person group.

People features: anonymous groups, optional names, filters, `include everyone`, and explicitly chosen people priorities. Store locally; support removing names/embeddings and disabling future processing. Evaluate commercial model-weight licensing before integration, including the prospective venue use case.

People grouping must not block ordinary culling. Do not implement identity guesses from generic image feature prints. Evaluate matching quality across lighting, pose, resolution, age differences, and diverse subjects before using identity coverage aggressively.

## 11. Evaluation and regression strategy

### Functional regressions

- Exact-copy grouping across paths/timestamps and analysis reuse.
- Stable deterministic decisions under reordered input and tied scores.
- Near-duplicate false positives for low-detail/color-block images and distinct moments.
- Burst chain/time-span limits and missing/timezone-offset timestamps.
- Vision descriptor compatibility, serialization, and distance-scale calibration fixtures.
- Unique/protected images survive culling and approximate-count pressure.
- Manual keep/swap/exclude/undo persists through restart and recuration.
- Settings invalidation changes only dependent stages.
- Subject crops respect orientation and coordinates at all EXIF orientations.
- Corrupt inputs, optional Vision failures, permission loss, low disk space, cancellation, and interrupted export.
- Cache invalidation for content changes in the middle of a file and moved/renamed occurrences.
- Export reuse, source immutability, metadata/color/orientation correctness, and no accumulating preview exports.
- Cleanup refuses changed sources, unverified replacements, unknown files, protected photos, and stale approvals; resumes partial operations safely.

### Quality evaluation

Maintain a private labeled collection of bursts, portraits, group events, pets/action, low light, landscapes, reference images, intentional blur, and unique imperfect moments. Capture keeper preferences and acceptable alternatives; subjective cases may have more than one valid answer.

Measure valuable-photo exclusion rate, unnecessary repeats, moment/person coverage, burst winner agreement, uncertainty routing, and human review time. Separate results by occasion and aggressiveness. Choose thresholds on a calibration subset and report results on held-out shoots. Do not tune and evaluate on the same small collection.

Without a supplied real collection, implement the evaluation harness and synthetic regressions, mark quality calibration pending, and keep defaults conservative. Do not invent accuracy percentages or claim full focus/blink validation.

### Test tooling

Keep `swift run photo-engine-checks` working on the installed command-line toolchain. Expand meaningful fixture checks. Add a normal Swift Testing/XCTest target when the active toolchain can actually discover and execute tests. A zero-exit run that discovers zero tests is not a pass. Avoid hard-coded global toolchain modifications to make test discovery appear successful.

Release verification: warnings-as-errors build, regression checks with explicit counts, representative end-to-end processing, rendered UI inspection, and clean Git status. Document any unavailable hardware or private-data evaluation separately.

## 12. Delivery sequence and completion gates

### Phase 0 — measurement and correctness foundation

- Add stage/comparison/memory instrumentation and an evaluation manifest format.
- Verify Vision distance scale and replace unsupported thresholds with conservative, documented defaults.
- Fix deterministic ties, duplicate evidence requirements, burst total-duration bounds, and contradictory decision reasons.
- Establish baseline measurements and synthetic regressions before optimization.

Gate: identical inputs produce identical recommendations; regression cases do not collapse distinct low-detail images; distance behavior and remaining calibration uncertainty are documented.

### Phase 1 — durable sessions and responsive engine

- Add SQLite catalog/migrations, durable occurrence/content identities, source access handling, component cache invalidation, and artifact ownership.
- Decode descriptors once, incrementally update diversity, bound active grouping and import buffers, and support cancellation throughout.
- Store settings/overrides with each session and reopen without rerunning unchanged analysis.

Gate: restart/reopen preserves decisions; repeated setting changes produce no new exports; memory and comparison counts are measured; source change invalidation works.

### Phase 2 — better culling and meaningful controls

- Implement aggressiveness presets, approximate count, protection, moment coverage, utility collection, and attention queue.
- Add subject-region/crop analysis with explicit confidence. Incorporate group-face quality fairly.
- Keep optional blink/blur-cause classifiers behind evaluated capability flags until supported.

Gate: presets produce explainable differences without violating protection/coverage; focused review replaces reviewing every nonselected photo; evaluation harness reports quality results or explicitly pending calibration.

### Phase 3 — complete photo workflow and styles

- Implement the add/process/collection/compare/finish UI, large grid, edited previews, keep/swap/undo, keyboard navigation, and warnings.
- Add five versioned looks, intensity, output presets, color-managed previews/export, and artifact reuse.
- Inspect rendered UI across states and window sizes.

Gate: a user can import, review uncertain moments, correct selections, choose a look, and export without using the CLI or inspecting numerical scores.

### Phase 4 — storage reduction

- Implement storage accounting, retention policies, approved cleanup plans, system Trash operations, durable ledger, restart recovery, and cache budgets.
- Test all destructive paths against disposable fixtures only.

Gate: cleanup refuses unsafe/stale targets, reports partial outcomes accurately, and clearly distinguishes bytes moved to Trash from bytes actually reclaimed. Existing user libraries are not cleaned as part of development verification.

### Phase 5 — optional people and advanced corrections

- Evaluate and integrate a licensed local identity model if one meets requirements.
- Add anonymous groups, naming/merge/split, coverage preferences, and local data removal.
- Investigate lens-profile correction/defringing with real validation.

Gate: optional modules can be disabled without affecting the core workflow; licensing and quality limitations are documented. If prerequisites are unavailable, deliver adapter boundaries and an explicit remaining-work list rather than fake functionality.

## 13. Handoff instructions for the implementing agent

Work phase by phase. Start by inspecting the actual repository and reconciling this plan with current code. For each phase, implement a coherent vertical slice, verify its completion gate, update documentation, and commit locally. Keep a progress document listing completed gates, measured results, and remaining prerequisites.

Use the current architecture as a starting point, but prefer clear small components over extending the existing large files indefinitely. Do not claim completion for UI buttons backed by placeholders, settings that do not affect behavior, or tests that never ran.

When a real photo dataset, additional hardware, or licensed model is missing, complete independent engineering work and state the precise limitation. Do not replace measured confidence with optimistic defaults. Do not implement the cloud/venue subscription pivot in this phase.

The final handoff should include launch/test commands, local commits, demonstrated workflow, measured performance, storage behavior, and honestly remaining quality/model evaluation. Never push the repository.

## References

- Apple face-capture quality and its holistic limitations: https://developer.apple.com/documentation/vision/selecting-a-selfie-based-on-capture-quality
- Vision public APIs: https://developer.apple.com/documentation/vision
- Feature-print distance: https://developer.apple.com/documentation/vision/featureprintobservation/distance(to:)
- Existing plans in this repository provide product context; this document governs the next local implementation phase when details differ.
