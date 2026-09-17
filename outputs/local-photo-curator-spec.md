# Local Photo Curator

## Product and Engineering Specification

**Status:** Draft 1  
**Date:** September 7, 2026  
**Working title:** Local Photo Curator  
**Primary platform:** macOS on Apple silicon  
**Initial media scope:** JPEG still photographs  
**Initial validation camera:** Sony α7C  
**Long-term camera scope:** Camera-independent  

---

## 1. Executive summary

Local Photo Curator is a local-first macOS application that turns a large camera shoot into a substantially smaller, edited, ready-to-enjoy album with minimal human review.

The product is designed for people who enjoy taking photographs but dislike the work that follows: importing, comparing near-identical frames, finding missed focus and closed eyes, deciding how many photographs to keep, applying repetitive corrections, exporting, and cleaning up storage.

The central product promise is:

> Take photographs freely. Connect the camera or insert the card. Receive a small, representative, lightly edited album. Review only the decisions the system is uncertain about.

For a representative 500-photo casual shoot, a successful result might contain:

- 50–100 automatically selected and edited photographs.
- 5–15 ambiguous moments requiring a human decision.
- The remainder hidden in a recoverable rejection area.
- No destructive changes to the camera card or source files.

The application is primarily a **culling system**, with automatic editing as a secondary capability. Approximately 70% of product intelligence and development effort should be devoted to grouping, comparison, selection, confidence, story coverage, and personalization. Automatic editing should be intentionally restrained, consistent, and safe for JPEG source material.

The core system does not require a large language model. It uses computer-vision models, deterministic image analysis, ranking algorithms, a lightweight personalized preference model, and conventional image-processing operations. An optional language layer may be considered later for natural-language instructions, but it is not part of the initial architecture.

---

## 2. Problem statement

### 2.1 User problem

Digital cameras make it inexpensive to capture hundreds of photographs, particularly when continuous shooting is enabled. The cost has moved from capture to review. A casual event, walk, trip, or family gathering can produce hundreds or thousands of files that require repetitive comparisons before the photographer can enjoy or share the results.

Existing workflows commonly require the user to:

1. Copy the card manually.
2. Wait for thumbnails or previews to render.
3. Review every photograph.
4. Compare bursts one frame at a time.
5. Identify technical failures.
6. Decide whether visually similar frames are meaningfully different.
7. Apply repetitive corrections.
8. Export the results.
9. Decide what to archive or delete.

The most painful stage is culling. The user does not primarily want faster keyboard shortcuts for manual culling; the user wants to avoid seeing most photographs at all.

### 2.2 Product opportunity

Modern on-device vision frameworks can perform visual similarity, face detection, face-quality assessment, image-aesthetic analysis, segmentation, and efficient model inference. Apple Vision provides feature prints for comparing images, face capture quality, and image-aesthetics analysis. Core ML can execute local models using the CPU, GPU, and Neural Engine. Core Image can process and render images locally. Relevant Apple documentation includes:

- [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore/)
- [Vision image feature prints](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest)
- [Vision image-aesthetics scoring](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest)
- [Vision face capture quality](https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest)
- [Core ML](https://developer.apple.com/documentation/coreml)
- [Core Image](https://developer.apple.com/documentation/coreimage)

The opportunity is not merely to score photographs independently. It is to interpret a shoot as a sequence of moments, compare alternatives within each moment, preserve representative coverage, and involve the photographer only when the correct decision is genuinely ambiguous.

---

## 3. Product vision

Local Photo Curator should feel more like a point-and-shoot finishing service than a desktop photo editor.

The ideal experience is:

1. The photographer takes photographs without worrying about the future editing workload.
2. The photographer inserts an SD card or connects a camera.
3. The application identifies the shoot and begins importing automatically.
4. The user optionally selects an intent mode and culling strength.
5. The application groups, evaluates, selects, edits, and prepares the album locally.
6. The application asks the user to resolve only low-confidence comparisons.
7. The final album is exported to a selected folder or photo library.
8. Rejected originals remain recoverable for a configurable retention period.

The product should be judged primarily by the amount of attention it removes from the workflow, not by the number of editing controls it exposes.

---

## 4. Goals and non-goals

### 4.1 Goals

1. Reduce the number of photographs the user must manually inspect by at least 70% in Balanced mode on supported casual-shoot categories.
2. Preserve unique moments even when the photograph is technically imperfect.
3. Select the strongest frame or small set of frames from repetitive bursts.
4. Surface uncertain decisions rather than hiding uncertainty.
5. Apply consistent, restrained, scene-aware edits to selected JPEGs.
6. Support multiple cameras and lenses without building the product around one specific body.
7. Run locally on Apple silicon without requiring an internet connection.
8. Preserve source files and make rejection recoverable.
9. Learn the photographer's selection and editing preferences over time.
10. Make the common workflow require no more than one or two choices per shoot.

### 4.2 Non-goals for the initial release

1. Replacing Lightroom, Capture One, Photoshop, or a professional RAW developer.
2. Providing a full manual editing interface with dozens of sliders.
3. Permanently deleting photographs without a retention window and explicit policy.
4. Performing generative face replacement, expression synthesis, or scene reconstruction.
5. Uploading photographs to a cloud service for analysis.
6. Supporting video culling or editing.
7. Guaranteeing correct aesthetic decisions without personalization.
8. Providing professional wedding-delivery, client-proofing, or commercial studio workflow features.
9. Requiring an LLM for core operation.

---

## 5. Product principles

### 5.1 Culling is the product

The core value is reducing review work. Editing features must not distract from or delay the culling experience.

### 5.2 Compare moments, not isolated files

A photograph cannot be evaluated solely by an independent global score. The system must compare each image with nearby and visually related alternatives.

### 5.3 Preserve meaning before technical perfection

A unique emotional moment should not be discarded merely because it is slightly noisy or imperfectly framed. Technical quality is one signal, not the entire objective.

### 5.4 Hide confidently; delete cautiously

High-confidence rejects may be removed from the user's normal view. Permanent deletion should occur only according to a clear, recoverable storage policy.

### 5.5 Make uncertainty visible

The system should ask for help when two frames are close, when a photograph is unusual, when models disagree, or when a potentially meaningful image is technically weak.

### 5.6 Modes express intent

The user should choose the kind of photography being performed, not tune model thresholds or editing parameters.

### 5.7 Personalization should be passive

Every override is training data. The user should not need to complete a separate machine-learning setup exercise.

### 5.8 Local by default

Photographs, face representations, preferences, and models remain on the device unless the user explicitly exports or shares an album.

### 5.9 Unknown cameras must still work

Camera-specific profiles improve results, but the general workflow must function using standard JPEG pixels and EXIF metadata.

---

## 6. Target users and use cases

### 6.1 Primary user

An enthusiast or casual photographer who owns an interchangeable-lens camera, enjoys taking photographs, and does not enjoy post-processing hundreds of files.

Characteristics:

- Shoots JPEG or is willing to use JPEG for casual photography.
- Uses multiple lenses.
- May use burst mode for people or action.
- Values candid moments and attractive output more than pixel-level editing control.
- Wants local processing for privacy, speed, and independence from subscription services.
- Is willing to correct a small number of uncertain choices.

### 6.2 Primary scenarios

#### A. Group hangout

The photographer captures friends, group combinations, candid reactions, food, activities, and a few group portraits. The system should prioritize expressions, face quality, representation of participants, and distinct social moments.

#### B. Trip or vacation

The photographer captures people, locations, architecture, landscapes, food, signs, details, and transitions throughout the day. The system should create a visually varied narrative rather than selecting only technically perfect portraits.

#### C. Creative walk

The photographer experiments with light, framing, reflections, silhouettes, motion, and unusual subjects. The system should preserve intentional ambiguity and avoid treating every unconventional exposure or blur as failure.

#### D. Everyday life

The photographer wants a concise record of ordinary moments with little configuration. The system should balance people, objects, places, and image quality.

#### E. Action or children

The photographer captures short bursts of movement. The system should identify peak action, subject sharpness, good expressions, and meaningful temporal variation.

---

## 7. Experience modes

The application separates **intent mode** from **culling strength**. These are independent controls.

### 7.1 Intent modes

#### 7.1.1 Hangout

Optimized for friends, family, casual events, and social gatherings.

Selection behavior:

- Strong preference for open eyes and good expressions.
- Local face clustering to improve participant coverage.
- Retain different group combinations.
- Retain candid interactions and reactions.
- Aggressively collapse repetitive posed sequences.
- Preserve camera-rated images unconditionally.
- Treat slight technical imperfection as acceptable when emotional value is high.

Editing behavior:

- Protect skin tones.
- Gentle warmth.
- Moderate contrast.
- Conservative sharpening on faces.
- Avoid excessive saturation or skin smoothing.

#### 7.1.2 Trip

Optimized for travel, day trips, sightseeing, and narrative coverage.

Selection behavior:

- Prefer diversity of location, subject, scale, and time.
- Retain establishing, medium, and detail photographs.
- Avoid excessive landmark repetition.
- Preserve environmental portraits and contextual photographs.
- Weight chronological and geographic coverage when metadata permits.
- Keep visually distinctive frames even without people.

Editing behavior:

- Natural but richer color.
- Stronger highlight and shadow management.
- Lens and perspective corrections where safe.
- Landscape and architecture-aware contrast.
- Conservative sky treatment.

#### 7.1.3 Creative

Optimized for artistic photography and visual experimentation.

Selection behavior:

- Increase weight on composition, light, novelty, and visual relationships.
- Reduce penalties for intentional motion blur, grain, darkness, silhouettes, and unconventional framing.
- Preserve alternative compositions when they differ meaningfully.
- Avoid using face quality as the dominant criterion.
- Treat out-of-distribution images cautiously and route them to review rather than rejecting them.

Editing behavior:

- More expressive tone and color while remaining reversible.
- Preserve intentional low-key or high-key exposure.
- Avoid automatically normalizing every image to the same brightness.
- Permit monochrome or stronger-look routing when explicitly selected.

#### 7.1.4 Everyday

General-purpose default.

Selection behavior:

- Balance technical quality, people, aesthetics, uniqueness, and coverage.
- Use conservative assumptions when intent is unclear.
- Provide the lowest-configuration experience.

Editing behavior:

- Neutral white balance.
- Moderate exposure and tone correction.
- Natural color and sharpening.

#### 7.1.5 Action

Optimized for sports, pets, children, and motion.

Selection behavior:

- Identify peak movement within bursts.
- Prefer subject sharpness over background sharpness.
- Retain multiple action phases when meaningfully different.
- Detect occlusion and awkward partial crops.
- Increase tolerance for high ISO and background motion.

Editing behavior:

- Targeted noise reduction.
- Crisp subject detail.
- Slightly stronger midtone contrast.
- Avoid smearing texture through excessive denoising.

#### 7.1.6 Document

Optimized for comprehensive chronological coverage.

Selection behavior:

- Conservative rejection.
- At least one photograph per detected moment.
- Preserve chronological continuity.
- Remove only obvious duplicates and severe failures by default.

Editing behavior:

- Minimal, faithful correction.
- Neutral rendering.
- No automatic creative crop.

### 7.2 Initial visible modes

To prevent choice overload, the first release should expose only:

- Hangout
- Trip
- Creative
- Everyday

Action and Document may appear under an expanded menu until usage demonstrates demand.

### 7.3 Culling strength

#### Keep more

- Remove exact duplicates and obvious failures.
- Keep most unique compositions and expressions.
- Review borderline technical failures.
- Expected result is a complete record rather than a small highlight album.

#### Balanced

- Default.
- Select the best small set per moment.
- Preserve narrative and participant coverage.
- Route close comparisons to review.

#### Tight

- Produce a highlight album.
- Select fewer variations per moment.
- Require stronger uniqueness for secondary selections.
- Never violate hard safeguards for rated photographs and unique moments.

The keep percentage is a prior, not a quota. A 100-image shoot with 100 distinct moments may retain far more images than a 100-image burst of one subject.

### 7.4 Illustrative mode weights

The following weights are conceptual starting values and must be calibrated using labeled shoots:

| Mode | Technical | Faces and expression | Aesthetics | Uniqueness | Story coverage | Action timing |
|---|---:|---:|---:|---:|---:|---:|
| Hangout | 20 | 35 | 10 | 15 | 15 | 5 |
| Trip | 20 | 15 | 20 | 20 | 25 | 0 |
| Creative | 10 | 5 | 35 | 30 | 15 | 5 |
| Everyday | 25 | 20 | 20 | 20 | 15 | 0 |
| Action | 30 | 15 | 10 | 15 | 10 | 20 |
| Document | 15 | 15 | 10 | 10 | 45 | 5 |

These weights should be modified by culling strength, detected content, model confidence, and learned user preference.

---

## 8. User experience specification

### 8.1 First-run experience

The application requests only the permissions required to import and write output. The first run should explain:

- Processing occurs locally.
- Source files are not modified.
- Rejected images are recoverable.
- The user can select a default intent mode, culling strength, output location, and retention duration.

Recommended defaults:

- Mode: Everyday
- Cull strength: Balanced
- Output size: 16 megapixels when downsizing is enabled
- Output color space: sRGB
- Reject retention: 30 days
- Camera-rated photographs: Always keep
- Automatic lens corrections: On
- Automatic crop: Suggestions only
- Network access: Off

### 8.2 Import initiation

Supported initiation methods:

1. Insert an SD card.
2. Connect a camera through USB.
3. Drag a folder onto the application.
4. Select a source folder.
5. Place files in an optional watched folder.

When a source is detected, the application displays a compact import sheet:

- Detected device or folder.
- Estimated photograph count.
- New photographs versus previously imported photographs.
- Intent mode.
- Culling strength.
- Selected look.
- Destination.
- Primary action: **Process automatically**.

If defaults are configured, the user may enable zero-touch import and suppress this sheet.

### 8.3 Processing view

Processing should be progressive rather than modal. The user can close the main window while work continues.

Visible stages:

1. Copying and verifying.
2. Building previews.
3. Finding moments and bursts.
4. Comparing photographs.
5. Preparing edits.
6. Waiting for review or ready to export.

The application should show useful output as early as possible. It must not require completion of full-resolution edits before displaying the initial selection.

### 8.4 Shoot summary

The summary is the primary destination after processing. It presents:

- Imported count.
- Automatically selected count.
- Number of ambiguous moment groups.
- Hidden/rejected count.
- Estimated storage after export.
- Active mode, culling strength, and look.
- Confirmation that source files remain intact.

Primary actions:

- Review uncertain choices.
- Export selected photographs.
- View all selected photographs.

Secondary actions:

- Change culling strength and recalculate.
- Change look and re-render previews.
- Inspect hidden photographs.
- Restore a rejected photograph.

### 8.5 Ambiguous-moment review

The review queue contains groups, not individual files. Each group shows two to six related frames with one or more suggestions.

For every group, the user can:

- Keep the suggested best frame.
- Keep two suggested alternatives.
- Keep all.
- Reject all.
- Select different frames manually.
- Mark the moment as important.

The application may display a concise reason such as:

- “Sharpest eyes and cleanest expression.”
- “Similar quality; these frames have different expressions.”
- “Unique moment, but subject focus is uncertain.”
- “Creative framing differs enough to preserve both.”

Reasons should be derived from actual signals and never generated as unsupported prose.

Keyboard interactions:

- Left/right arrows: Move among frames.
- Space: Toggle selected frame.
- Return: Accept suggestion and continue.
- 1: Keep one.
- 2: Keep two.
- A: Keep all.
- R: Reject group.
- Z: Undo.

Touch interactions for a future local mobile interface:

- Swipe right: Keep suggestion.
- Swipe up: Keep multiple.
- Swipe left: Reject group.
- Tap a frame: Select or deselect.

### 8.6 Selected album review

The selected album should default to a contact sheet. It should not force users through full-screen individual review.

Features:

- Chronological or story order.
- Moment stacks showing hidden alternatives.
- Before/after edit preview.
- Favorite and lock controls.
- Restore alternatives.
- Change look for one photograph or the entire shoot.
- Export readiness indicator.

### 8.7 Look selection

The initial interface should provide three to five visual look cards rather than editing sliders.

Suggested initial looks:

- Natural
- Everyday warm
- Soft daylight
- Clean contrast
- Clean monochrome

Selecting a look defines a target rendering style. Per-image exposure, white balance, tone, and correction remain adaptive.

Advanced editing controls may exist behind an optional panel, but they are not part of the primary journey.

### 8.8 Camera-side input

The application should honor standardized rating and protection metadata where available.

Rules:

- Rated photographs are hard keeps by default.
- Protected photographs are never deleted or moved into an expiring rejection area.
- Ratings influence personalization.
- Missing or manufacturer-specific ratings must not block import.

The Sony α7C supports assigning Rating to a playback custom key, allowing the photographer to mark important images in-camera. See [Sony's rating documentation](https://helpguide.sony.net/ilc/2020/v1/en/contents/TP1000153431.html).

### 8.9 Notifications

Optional local notifications:

- Import safely completed.
- Review is ready.
- Finished album is ready.
- Reject retention expires soon.
- Source was disconnected before verification.

No periodic status notifications should be shown for normal background progress.

---

## 9. Functional requirements

### 9.1 Import and source safety

**FR-IMP-001:** The system shall import JPEG files from folders and mounted removable media.  
**FR-IMP-002:** The system shall support connected-camera discovery and import when the camera and operating system expose compatible interfaces.  
**FR-IMP-003:** The system shall never delete files from a camera or card during initial import.  
**FR-IMP-004:** The system shall compute a content checksum for each imported source file.  
**FR-IMP-005:** The system shall verify that the destination copy matches the source before marking import complete.  
**FR-IMP-006:** The system shall resume an interrupted import without duplicating verified files.  
**FR-IMP-007:** The system shall detect previously imported content using checksum and source metadata.  
**FR-IMP-008:** The system shall preserve original filenames and capture metadata unless the user selects a renaming policy.  
**FR-IMP-009:** The system shall support a user-configurable destination structure.  
**FR-IMP-010:** The system shall show source-disconnection errors without corrupting the catalog.

### 9.2 Metadata

**FR-META-001:** The system shall parse standard EXIF capture time, orientation, dimensions, camera, lens, focal length, aperture, shutter speed, ISO, exposure compensation, flash state, and GPS when present.  
**FR-META-002:** The system shall parse rating and protection metadata where available.  
**FR-META-003:** The system shall preserve an unmodified copy of source metadata.  
**FR-META-004:** The system shall tolerate malformed and manufacturer-specific metadata.  
**FR-META-005:** The system shall permit the user to remove GPS metadata from exported files.

### 9.3 Duplicate detection

**FR-DUP-001:** The system shall identify exact byte-for-byte duplicates using a cryptographic checksum.  
**FR-DUP-002:** The system shall identify visually equivalent derivatives such as resized or recompressed copies.  
**FR-DUP-003:** The system shall distinguish derived duplicates from burst alternatives.  
**FR-DUP-004:** The system shall retain provenance so the user can inspect why files were grouped.  
**FR-DUP-005:** Exact duplicates shall not be permanently deleted without a configured storage action.

### 9.4 Moment grouping

**FR-GRP-001:** The system shall group photographs using capture-time proximity and visual similarity.  
**FR-GRP-002:** The system shall adapt time-gap thresholds to observed shooting cadence.  
**FR-GRP-003:** The system shall split a group when the scene or subject changes materially.  
**FR-GRP-004:** The system shall merge temporally separated files when strong visual evidence indicates one continuing moment.  
**FR-GRP-005:** The user shall be able to split or merge moment groups.  
**FR-GRP-006:** Grouping corrections shall become personalization signals.

### 9.5 Culling

**FR-CULL-001:** The system shall score technical quality, subject quality, aesthetic quality, uniqueness, and coverage separately.  
**FR-CULL-002:** The system shall rank photographs primarily within their moment group.  
**FR-CULL-003:** The system shall choose a variable number of keepers per moment.  
**FR-CULL-004:** The system shall preserve rated and protected photographs.  
**FR-CULL-005:** The system shall retain at least one candidate from every unique moment unless every file is an exact duplicate or unreadable.  
**FR-CULL-006:** The system shall treat Creative mode technical failures more conservatively.  
**FR-CULL-007:** The system shall consider participant and story coverage when the selected mode requires it.  
**FR-CULL-008:** The system shall produce a confidence value for every selected/rejected boundary.  
**FR-CULL-009:** Low-confidence boundaries shall be routed to review.  
**FR-CULL-010:** The system shall record reason codes for decisions.  
**FR-CULL-011:** The user shall be able to recalculate a shoot under a different mode or culling strength without reimporting.  
**FR-CULL-012:** Recalculation shall preserve manual locks and explicit ratings.

### 9.6 Editing

**FR-EDIT-001:** Editing shall occur only after initial culling unless a low-resolution preview is needed.  
**FR-EDIT-002:** The system shall preserve source JPEGs.  
**FR-EDIT-003:** The system shall support lens-profile and image-based chromatic-aberration correction.  
**FR-EDIT-004:** The system shall support shading and distortion correction where a reliable profile exists.  
**FR-EDIT-005:** The system shall apply scene-aware exposure, white balance, tone, color, noise reduction, and sharpening.  
**FR-EDIT-006:** The system shall apply a selected look consistently while adapting parameters to each photograph.  
**FR-EDIT-007:** The system shall avoid aggressive JPEG recovery that produces clipping, banding, halos, or color artifacts.  
**FR-EDIT-008:** The system shall provide before/after comparison.  
**FR-EDIT-009:** The system shall support automatic straightening suggestions.  
**FR-EDIT-010:** Automatic crop shall be configurable as Off, Suggestions, or Apply.  
**FR-EDIT-011:** The system shall store edit parameters and pipeline version for reproducible re-rendering.

### 9.7 Export

**FR-EXP-001:** The system shall export JPEG.  
**FR-EXP-002:** The system shall offer original-resolution and downsized export.  
**FR-EXP-003:** Default downsized output shall target approximately 16 megapixels without upscaling.  
**FR-EXP-004:** Default color space shall be sRGB.  
**FR-EXP-005:** The user shall be able to preserve or remove GPS metadata.  
**FR-EXP-006:** Export shall preserve capture date, camera, lens, exposure, and copyright metadata when available.  
**FR-EXP-007:** Export shall never overwrite an existing unrelated file silently.  
**FR-EXP-008:** A completed export shall include a machine-readable shoot manifest.

### 9.8 Reject storage and recovery

**FR-RET-001:** Rejected photographs shall remain recoverable for a default of 30 days.  
**FR-RET-002:** The system shall distinguish hidden, rejected, duplicate, and pending-deletion states.  
**FR-RET-003:** The user shall be able to restore any retained source.  
**FR-RET-004:** Permanent deletion shall require a configured policy and a verified destination boundary.  
**FR-RET-005:** Protected, rated, locked, or unresolved photographs shall never be automatically deleted.  
**FR-RET-006:** The system shall warn before a large first-time deletion.  
**FR-RET-007:** The application shall maintain an audit record of disposal actions without storing deleted image contents.

### 9.9 Personalization

**FR-PERS-001:** Manual frame selections shall be captured as pairwise preference observations.  
**FR-PERS-002:** Restoring a rejected photograph shall be treated as a high-weight correction signal.  
**FR-PERS-003:** Personalization shall be mode-aware.  
**FR-PERS-004:** Personalization data shall remain local.  
**FR-PERS-005:** The user shall be able to disable, reset, export, and import preference data.  
**FR-PERS-006:** Model updates shall not retroactively change locked shoots unless requested.  
**FR-PERS-007:** The system shall show when a recommendation is strongly influenced by learned preference.

---

## 10. Culling intelligence design

### 10.1 Overview

The culling engine is a staged pipeline. Running expensive analysis on every full-resolution photograph is unnecessary and inefficient. The system should use embedded previews or downscaled source images for most inference, then run subject-specific or full-resolution checks only on finalists and ambiguous comparisons.

Pipeline:

```text
Metadata and checksums
        ↓
Fast preview extraction
        ↓
Exact and perceptual duplicate detection
        ↓
Temporal and visual moment grouping
        ↓
Fast technical and semantic analysis
        ↓
Within-moment ranking
        ↓
Shoot-level coverage optimization
        ↓
Confidence and uncertainty routing
        ↓
Selected / review / hidden
```

### 10.2 Stage A: preview extraction

Requirements:

- Decode EXIF orientation correctly.
- Prefer an embedded camera preview when its size and quality meet analysis requirements.
- Otherwise generate a preview with a long edge between approximately 1,024 and 2,048 pixels.
- Preserve aspect ratio.
- Store a color-managed display preview.
- Avoid repeated JPEG decoding by caching a versioned preview.

Recommended analysis sizes:

- 256–384 pixels for rough hashing and scene change.
- 768–1,024 pixels for general embeddings, faces, aesthetics, and composition.
- 1,600–2,048 pixels for technical focus checks.
- Full resolution only for final subject-focus arbitration, correction, and export.

### 10.3 Stage B: exact and derived duplicate detection

#### Exact duplicates

Use SHA-256 or an equivalent cryptographic checksum over the original file bytes.

#### Derived duplicates

Use multiple signals:

- Perceptual hash distance.
- Vision feature-print or equivalent embedding distance.
- Aspect ratio.
- Capture time.
- Camera and source filename relationships.
- Pixel-level alignment check for close candidates.

Derived duplicate classification must distinguish:

- Same photograph recompressed.
- Same photograph resized.
- Same photograph with minor edit.
- RAW/JPEG representations if RAW support is later added.
- Distinct frames captured milliseconds apart.

The last category is a burst, not a duplicate.

### 10.4 Stage C: moment segmentation

Moment grouping is a change-point-detection problem over the chronological photo stream.

For each adjacent pair, calculate:

- Time delta.
- Visual embedding distance.
- Face-set overlap.
- Subject/object overlap.
- Camera/lens continuity.
- Focal-length and exposure change.
- Background similarity.
- Optional location distance.

A boundary probability is calculated for every adjacent pair. Groups can then be refined with non-adjacent nearest-neighbor relationships.

The time threshold must be adaptive:

- During a rapid burst, a two-second gap may indicate a new action phase.
- During a slow portrait session, a ten-second gap may still belong to the same pose.
- During a trip, photographs taken minutes apart may represent the same location but different moments.

The data model should distinguish:

- **Burst:** Highly similar frames captured rapidly.
- **Moment:** Semantically continuous sequence.
- **Scene:** Broader location or activity containing multiple moments.
- **Shoot:** Complete import session or user-defined collection.

### 10.5 Stage D: technical analysis

Technical signals are stored separately so modes can use them differently.

#### Global sharpness

- Multi-scale edge energy.
- Frequency-domain high-frequency content.
- Blur-kernel or motion-direction estimate.
- Comparison with neighboring frames of the same scene.

Global sharpness alone is insufficient because shallow depth of field can produce a deliberately blurred background.

#### Subject sharpness

- Detect primary faces, people, animals, or salient subjects.
- Evaluate sharpness inside subject and eye regions.
- Compare subject-region sharpness across burst alternatives.
- Penalize focus on the background only when the subject is confidently identified.

#### Exposure quality

- Highlight and shadow clipping by channel.
- Skin-region clipping.
- Dynamic-range occupancy.
- Local contrast.
- Severe color cast.
- Backlighting and intentional low/high-key classification.

Exposure should be judged relative to the moment. If every frame is dark, the system should avoid rejecting the entire moment without review.

#### Noise and artifacts

- Luminance and chroma noise estimate.
- Compression artifact estimate.
- Banding probability.
- Lens flare or veiling glare indicators.
- Chromatic fringe estimate.

#### Faces and expressions

- Face count and size.
- Face capture quality.
- Eye visibility and estimated open/closed state.
- Gaze direction.
- Head pose.
- Smile/expression naturalness where reliable.
- Occlusion.
- Face sharpness.
- Consistency across all important faces in a group portrait.

The system must avoid treating smiles as universally better. Expression quality should primarily compare technical face usability and learned user preference.

#### Composition and aesthetics

- General aesthetic score.
- Salient subject placement.
- Horizon angle.
- Edge intersections and accidental truncation.
- Background clutter.
- Subject separation.
- Symmetry or intentional asymmetry.
- Learned compositional preference.

### 10.6 Stage E: within-moment ranking

For image `i` in moment `m`, compute a feature vector:

```text
x(i) = {
  technical quality,
  subject quality,
  face/expression quality,
  composition,
  aesthetic score,
  uniqueness within moment,
  camera rating,
  semantic content,
  mode context,
  user preference features
}
```

The initial ranker may be a calibrated gradient-boosted model, logistic pairwise ranker, or small neural ranking head. The final choice should be based on evaluation quality, calibration, interpretability, and Core ML compatibility rather than model novelty.

Pairwise preference is central:

```text
P(i preferred over j | mode, user)
```

This formulation reflects the actual task: choosing among related alternatives.

### 10.7 Stage F: variable keeper count

The engine must determine both ordering and keeper count.

Selection begins with the strongest candidate in each unique moment. Additional candidates are added when their marginal value exceeds the active threshold:

```text
marginal value(candidate) =
    quality gain
  + expression difference
  + action-phase difference
  + composition difference
  + story contribution
  + user-preference gain
  - visual redundancy
```

Examples:

- Four nearly identical portraits with one clear winner: keep one.
- Two portraits with different strong expressions: keep two.
- Twenty-frame jump sequence: keep takeoff, peak, and landing only if each contributes.
- Three group portraits: keep the best all-face frame and optionally one strong candid alternative.
- One technically weak but unique interaction: keep or route to review.

### 10.8 Stage G: shoot-level coverage optimization

Moment winners are assembled into a coherent album. The system should maximize overall album utility under a soft size budget:

```text
maximize:
    sum(selected quality)
  + subject coverage
  + participant coverage
  + scene coverage
  + chronological coverage
  + visual diversity
  + mode-specific value
  - redundancy
```

Constraints and safeguards:

- Preserve all rated or locked photographs.
- Preserve at least one candidate per unique moment unless unreadable.
- Do not allow one frequent participant to suppress all others in Hangout mode.
- Do not allow landscapes or portraits to dominate an entire Trip album merely because their aesthetic model scores are higher.
- Maintain chronological coherence unless the user requests a highlights-only ordering.
- Preserve unusual images when out-of-distribution confidence is low.

This stage may be implemented as greedy submodular selection, constrained optimization, or another explainable diversity-aware method.

### 10.9 Stage H: confidence and review routing

Confidence should measure whether the **decision boundary** is trustworthy, not merely whether the selected frame has a high score.

Factors that reduce confidence:

- Small ranking margin between selected and rejected frames.
- Disagreement between technical, aesthetic, and personalized rankers.
- Uncertain eye-state or subject detection.
- Multiple important faces with conflicting best frames.
- Out-of-distribution image style.
- Unique but technically poor moment.
- Unknown camera orientation or malformed metadata.
- Large change from the user's historical behavior.
- Creative mode with unconventional exposure or blur.

Review groups should be prioritized by expected value of user attention:

```text
review priority =
  probability of changing the result
  × importance of the moment
  × consequence of a wrong rejection
```

The queue should have a configurable attention budget. If the user wants at most ten decisions, the system selects the ten comparisons where human input matters most and makes conservative choices elsewhere.

### 10.10 Decision reason codes

Every decision should store structured reason codes, for example:

- `EXACT_DUPLICATE`
- `DERIVED_DUPLICATE`
- `BURST_REDUNDANT`
- `MISSED_SUBJECT_FOCUS`
- `SEVERE_CAMERA_SHAKE`
- `EYES_CLOSED`
- `FACE_OCCLUDED`
- `EXPOSURE_FAILURE`
- `WEAKER_EXPRESSION`
- `WEAKER_COMPOSITION`
- `LOW_AESTHETIC_SCORE`
- `STORY_REDUNDANT`
- `UNIQUE_MOMENT_SAFEGUARD`
- `CAMERA_RATED_KEEP`
- `USER_LOCKED_KEEP`
- `PERSONAL_PREFERENCE_KEEP`
- `LOW_CONFIDENCE_REVIEW`

User-facing explanations are templates populated from these verified reason codes.

---

## 11. Personalization design

### 11.1 Learning signals

Strong signals:

- Selecting frame B when frame A was suggested.
- Restoring a rejected photograph.
- Rejecting an automatic keeper.
- Locking or favoriting a photograph.
- Changing keeper count within a moment.
- Repeatedly selecting a particular look.

Moderate signals:

- Changing crop or rotation.
- Adjusting the entire shoot's culling strength.
- Exporting a photograph at original resolution.

Weak signals:

- Viewing a photograph for a long time.
- Opening hidden alternatives without changing selection.

Weak signals should not modify the model without corroboration.

### 11.2 Pairwise preference records

When a user chooses B over A within a moment, store:

- Anonymous local image identifiers.
- Mode and culling strength.
- Relevant feature differences.
- Model versions.
- Original suggestion.
- User selection.
- Timestamp.
- Confidence.

Storing source embeddings is optional. If stored, they must remain local and be versioned.

### 11.3 Cold start

The initial experience uses a general ranker and conservative uncertainty thresholds. Optional onboarding can accelerate personalization by presenting 20–50 pairwise comparisons drawn from imported historical photographs.

Onboarding must be skippable.

### 11.4 Mode-specific preference

Preferences may differ by mode. For example:

- The user may prefer candid imperfection in Hangout mode.
- The same user may prefer strong geometry in Creative mode.
- Trip mode may emphasize comprehensive coverage.

Maintain a shared base preference model plus mode-specific adjustments. Avoid creating entirely isolated models until enough data exists.

### 11.5 Guardrails

- Do not learn from bulk actions that may have been made for storage reasons unless the user confirms they represent preference.
- Do not infer sensitive identity labels.
- Face clusters remain unnamed unless the user explicitly names them in a future feature.
- Provide “Why am I seeing this?” and “Forget this preference” controls.
- Provide a complete personalization reset.

---

## 12. Automatic editing design

### 12.1 Editing philosophy

The goal is a pleasant finished photograph, not maximal manipulation. JPEG sources have less recoverable tonal and color information than RAW, so the system must favor small, high-confidence corrections.

The source JPEG is decoded once into a managed working representation. Editing should occur in a high-precision linear or otherwise appropriate working space, with a single final encode.

### 12.2 Processing order

Recommended conceptual order:

1. Decode and orient.
2. Read embedded color profile.
3. Determine camera/lens profile availability.
4. Apply geometric lens correction when reliable.
5. Apply chromatic-aberration correction.
6. Apply shading correction when appropriate.
7. Estimate white balance and color cast.
8. Apply conservative exposure normalization.
9. Apply highlight/shadow and tone curve.
10. Apply local subject/face/sky adjustments where allowed by the look.
11. Apply color rendering and selected look.
12. Apply noise reduction.
13. Apply output-aware sharpening.
14. Straighten and crop.
15. Resize.
16. Convert to output color space.
17. Encode once.
18. Write selected metadata and edit manifest.

### 12.3 Lens corrections

Lens identity should be obtained from EXIF when possible. Corrections may use:

- Reliable camera-provided compensation metadata.
- A bundled or separately licensed lens profile.
- A user-selected lens mapping remembered for future imports.
- Image-based purple/green fringe detection.

Chromatic-aberration correction priority:

1. Detect whether the camera likely applied correction already.
2. Avoid double correction.
3. Use known lateral correction for supported lens/body combinations.
4. Detect residual purple/green fringing near high-contrast edges.
5. Apply conservative desaturation or channel alignment only in affected regions.
6. Reject the correction if it produces halos or removes legitimate saturated edges.

The Sony α7C can apply shading, chromatic-aberration, and distortion compensation for compatible lenses. See [Sony Lens Compensation](https://helpguide.sony.net/ilc/2020/v1/en/contents/TP1000153444.html). This should be treated as an optimization, not a product dependency.

### 12.4 White balance

Combine:

- Camera white-balance metadata.
- Neutral-region estimation.
- Face/skin plausibility when people are present.
- Scene classification.
- Neighbor consistency within the same moment.

Do not independently normalize every frame in a burst if doing so creates visible color inconsistency. Estimate a shared moment-level illuminant, then allow small frame-level corrections.

### 12.5 Exposure and tone

Use:

- Histogram and percentile analysis.
- Salient-subject exposure.
- Face luminance.
- Channel clipping.
- Scene type.
- Selected look.

JPEG guardrails:

- Avoid large shadow lifts in noisy or compressed regions.
- Avoid highlight recovery claims where channels are fully clipped.
- Avoid strong local contrast that creates halos.
- Preserve intentional low-key/high-key rendering in Creative mode.
- Maintain consistency across a moment and scene.

### 12.6 Color

Color adjustments should separate technical correction from style:

- Technical layer: white balance, cast correction, camera-profile normalization.
- Style layer: saturation, hue relationships, tone curve, warmth, monochrome conversion.

Skin protection must constrain hue and saturation changes in detected face/skin regions. The system should not perform face reshaping or beauty retouching.

### 12.7 Noise reduction and sharpening

Estimate noise using ISO, exposure metadata, and pixel statistics. Apply spatially adaptive luminance/chroma reduction. Sharpen based on output resolution rather than source resolution alone.

Faces and low-texture regions should receive conservative sharpening. Hair, fabric, architecture, and landscape detail can receive stronger treatment when artifacts remain controlled.

### 12.8 Crop and straighten

Straightening may be automatically applied when confidence is high and crop loss is low.

Creative crop should initially default to Suggestions because crop intent is subjective. Crop scoring may use:

- Horizon.
- Face and body truncation.
- Saliency.
- Subject placement.
- Aspect-ratio target.
- Edge distractions.
- Mode.

### 12.9 Looks

Each look should define:

- Target tone curve.
- White-balance bias.
- Color transform.
- Saturation behavior.
- Skin constraints.
- Local contrast.
- Sharpening character.
- Grain policy.
- Black-and-white conversion policy where applicable.

Looks are parameterized transforms, not fixed filters. Two photographs under different lighting should appear related without receiving identical numeric adjustments.

### 12.10 Edit reproducibility

Store:

- Pipeline version.
- Model version.
- Look identifier and version.
- All calculated parameters.
- Lens profile identifier and version.
- Crop and rotation.
- Output parameters.

This allows re-rendering after application updates while preserving the original result when desired.

---

## 13. Camera and lens compatibility

### 13.1 Compatibility tiers

#### Tier 1: Pixel-compatible

Any readable JPEG can be imported, culled, and generally edited.

#### Tier 2: Metadata-aware

The camera provides standard EXIF sufficient for capture grouping and exposure-aware analysis.

#### Tier 3: Profile-aware

The body/lens combination has tested color and lens-correction behavior.

#### Tier 4: Direct-import validated

The application has verified connected-camera import, ratings, and relevant manufacturer metadata.

The user should see these capabilities separately. An unknown camera should not be labeled “unsupported” when pixel-level culling still works.

### 13.2 Initial Sony α7C validation

Validate:

- Large Fine and Large Extra Fine JPEG import.
- Orientation.
- Burst timestamps and filename sequences.
- Rating metadata behavior.
- Sony E-mount lens identification.
- In-camera lens compensation interaction.
- Multiple Sony and third-party lenses.
- USB and card-reader import.

Sony offers JPEG Extra Fine, Fine, and Standard. The 64GB capacity estimate is approximately 3,400 Large Extra Fine or 6,100 Large Fine images, making Large Fine a sensible default for this casual workflow. See [Sony JPEG Quality](https://helpguide.sony.net/ilc/2020/v1/en/contents/TP1000153485.html) and [Sony recordable-image estimates](https://helpguide.sony.net/ilc/2020/v1/en/contents/TP1000139983.html).

### 13.3 Unknown and manual lenses

If lens identity is absent:

- General culling continues normally.
- The application offers a one-time optional lens mapping.
- Image-based fringe detection remains available.
- Geometric correction remains disabled unless confidence is sufficient.
- The mapping is stored by camera, focal-length pattern, and user-defined label.

### 13.4 Compatibility test matrix

Test across:

- Sony, Canon, Nikon, Fujifilm, Panasonic, OM System, Leica, and smartphone JPEGs.
- Native, third-party, adapted, zoom, and prime lenses.
- Full-frame, APS-C, Micro Four Thirds, and smartphone sensors.
- sRGB and Display P3 embedded profiles.
- Missing, malformed, and manufacturer-specific metadata.
- Cameras with clock drift or incorrect time zones.

---

## 14. Technical architecture

### 14.1 Recommended implementation stack

For a production macOS application:

- Swift and SwiftUI for the application and user interface.
- ImageCaptureCore for compatible camera discovery and import.
- File system APIs for mounted cards and folders.
- Image I/O for metadata and efficient image-source access.
- Vision for built-in similarity, face, saliency, quality, and aesthetics primitives where available.
- Core ML for custom culling and editing models.
- Core Image and Metal-backed processing for editing and rendering.
- SQLite for the local catalog, using a well-tested Swift database layer.
- Structured concurrency and actors for job coordination.
- An isolated worker process or XPC service for decoding, inference, and rendering stability.

### 14.2 Major components

```text
Mac application
├── Import coordinator
│   ├── Device discovery
│   ├── Card/folder scanner
│   ├── Copy and verification
│   └── Duplicate-aware resume
├── Catalog service
│   ├── SQLite metadata
│   ├── Shoot manifests
│   ├── Decision history
│   └── Personalization records
├── Media worker
│   ├── Preview extraction
│   ├── Metadata parsing
│   ├── Vision/Core ML inference
│   └── Feature cache
├── Culling engine
│   ├── Duplicate detection
│   ├── Moment grouping
│   ├── Ranking
│   ├── Coverage selection
│   └── Confidence routing
├── Editing engine
│   ├── Lens correction
│   ├── Global adjustments
│   ├── Local masks
│   ├── Looks
│   └── Export rendering
├── Personalization service
│   ├── Pairwise preference log
│   ├── Local model updates
│   └── Reset/export controls
└── User interface
    ├── Import sheet
    ├── Shoot summary
    ├── Ambiguous review
    ├── Selected album
    └── Recovery and settings
```

### 14.3 Process isolation

Image decoders and ML workloads should run outside the primary UI process where practical. A malformed JPEG, memory spike, model failure, or rendering crash must not corrupt the catalog or terminate import coordination.

The worker API should be idempotent. Jobs can be retried using immutable input identifiers and versioned outputs.

### 14.4 Job scheduling

Priorities:

1. Import integrity and checksum verification.
2. Visible thumbnail generation.
3. Current review-group analysis.
4. Shoot-wide fast analysis.
5. Selected-image final analysis.
6. Full-resolution rendering.
7. Background personalization updates.
8. Cache maintenance.

The scheduler should use bounded concurrency based on memory, thermal state, power source, and chip capabilities. An 8GB machine should process fewer full-resolution images concurrently than a 24GB machine.

### 14.5 Progressive computation

The system should avoid waiting for complete import when safe:

- Metadata and previews may be extracted after each file is verified.
- Preliminary groups may form during import.
- Groups remain provisional until nearby capture times are sufficiently complete.
- The UI may show early suggestions with a “still analyzing” state.
- Final selection is committed only after shoot completeness or user confirmation.

### 14.6 Model registry

Every model record includes:

- Identifier.
- Semantic version.
- Supported input shape and color preprocessing.
- Supported hardware/OS requirements.
- Checksum and signature.
- Output schema.
- Calibration version.
- Fallback model.

Model updates must be independently reversible. A catalog entry stores the model version responsible for each decision.

### 14.7 Fallback behavior

If an advanced model cannot run:

- Preserve import and exact duplicate detection.
- Fall back to deterministic sharpness/exposure metrics.
- Reduce automatic rejection aggressiveness.
- Increase review routing.
- Disable unavailable editing masks without failing the shoot.

Degraded capability must be visible in the summary.

---

## 15. Data model

### 15.1 Core entities

#### Shoot

- `id`
- `name`
- `created_at`
- `capture_start`
- `capture_end`
- `source_ids`
- `mode`
- `cull_strength`
- `look_id`
- `processing_state`
- `pipeline_version`
- `selection_revision`
- `retention_policy_id`

#### Asset

- `id`
- `shoot_id`
- `source_path`
- `managed_path`
- `source_filename`
- `sha256`
- `perceptual_hash`
- `byte_size`
- `pixel_width`
- `pixel_height`
- `capture_time`
- `camera_make`
- `camera_model`
- `lens_make`
- `lens_model`
- `focal_length`
- `aperture`
- `shutter_speed`
- `iso`
- `orientation`
- `rating`
- `protected`
- `gps_present`
- `import_state`
- `disposal_state`

#### FeatureSet

- `asset_id`
- `feature_version`
- `embedding_reference`
- `technical_metrics`
- `face_metrics`
- `semantic_metrics`
- `aesthetic_metrics`
- `artifact_metrics`
- `created_at`

#### Scene

- `id`
- `shoot_id`
- `sequence_index`
- `start_time`
- `end_time`
- `semantic_summary_codes`
- `representative_asset_id`

#### Moment

- `id`
- `scene_id`
- `sequence_index`
- `moment_type`
- `group_confidence`
- `representative_asset_id`
- `manual_grouping_state`

#### MomentMembership

- `moment_id`
- `asset_id`
- `membership_score`
- `sequence_index`

#### CullDecision

- `asset_id`
- `selection_revision`
- `state`: selected, alternate, review, hidden, rejected
- `rank_within_moment`
- `global_album_rank`
- `decision_confidence`
- `reason_codes`
- `model_versions`
- `manual_override`
- `locked`

#### EditRecipe

- `asset_id`
- `recipe_version`
- `look_id`
- `lens_profile_id`
- `parameters`
- `crop`
- `rotation`
- `mask_references`
- `render_state`

#### PreferenceObservation

- `id`
- `mode`
- `preferred_asset_id`
- `nonpreferred_asset_id`
- `context_moment_id`
- `signal_type`
- `weight`
- `model_version_before`
- `created_at`

#### ExportRecord

- `id`
- `shoot_id`
- `asset_id`
- `destination_path`
- `output_checksum`
- `output_dimensions`
- `quality`
- `color_space`
- `metadata_policy`
- `completed_at`

### 15.2 File layout

Illustrative managed-library layout:

```text
Library/
├── Originals/
│   └── 2026/2026-09-07 Sunday Walk/
├── Exports/
│   └── 2026/2026-09-07 Sunday Walk/
├── Cache/
│   ├── Previews/
│   ├── Features/
│   ├── Masks/
│   └── Renders/
├── Manifests/
├── Models/
├── Catalog.sqlite
└── Backups/
```

Originals may remain in a user-managed destination rather than an application library. The catalog must use durable file bookmarks or equivalent scoped references when appropriate.

### 15.3 Shoot manifest

Every completed shoot should have a portable JSON manifest containing:

- Shoot settings.
- Original checksums.
- Selected and hidden states.
- Moment and scene membership.
- Manual locks.
- Edit recipe versions.
- Export records.
- Application and model versions.

The manifest must not contain image embeddings or face representations by default.

---

## 16. State machines

### 16.1 Shoot processing state

```text
DETECTED
  → COPYING
  → VERIFYING
  → ANALYZING_FAST
  → GROUPING
  → RANKING
  → SELECTING
  → ANALYZING_FINALISTS
  → PREVIEW_RENDERING
  → REVIEW_READY or READY_TO_EXPORT
  → EXPORTING
  → COMPLETE
```

Any processing state may transition to `PAUSED`, `CANCELLED`, or `ERROR_RECOVERABLE`. Catalog corruption or unverifiable copies transition to `ERROR_BLOCKING` and must not continue to disposal.

### 16.2 Asset import state

```text
DISCOVERED → COPYING → COPIED → VERIFIED → AVAILABLE
```

Failure states:

- `SOURCE_MISSING`
- `COPY_FAILED`
- `CHECKSUM_MISMATCH`
- `UNREADABLE`
- `UNSUPPORTED_ENCODING`

### 16.3 Asset disposal state

```text
ACTIVE
  → HIDDEN
  → REJECTED_RETAINED
  → PENDING_DELETION
  → DELETED
```

Restoration is permitted from every state except `DELETED`. Movement to `DELETED` is prohibited when the asset is rated, protected, locked, unresolved, unverified, or the last available copy according to the active storage policy.

---

## 17. Non-functional requirements

### 17.1 Performance

Performance targets are engineering acceptance budgets, not claims about an existing implementation.

Reference workload:

- 1,000 24-megapixel JPEG photographs.
- Mixed burst, portrait, travel, indoor, and outdoor content.
- Internal SSD destination.
- M1 with 16GB unified memory as the baseline supported-performance machine.

Targets:

- Display the first verified thumbnails within 10 seconds after the first batch becomes available.
- Maintain responsive scrolling and review while background inference runs.
- Complete preview-based grouping and first-pass culling within 15 minutes after import on the reference M1 system.
- Re-render a low-resolution look preview for a single image within 500 milliseconds when cached inputs are available.
- Begin final export within 2 seconds of confirmation.
- Never load all full-resolution images simultaneously.
- Keep memory bounded and avoid sustained swapping on supported 16GB configurations.
- Pause or reduce concurrency under critical thermal or memory pressure.

An M3-class system should benefit from increased inference/render concurrency, but correctness must not depend on chip generation.

### 17.2 Reliability

- Import and catalog operations must be crash-resumable.
- Every destructive transition must be transactional.
- Source verification must survive application restarts.
- Model or renderer crashes must not corrupt the shoot state.
- Export must use temporary files followed by atomic placement where the destination supports it.
- The application must maintain automatic catalog backups.

### 17.3 Privacy

- Core processing requires no network connection.
- Face representations and preference data remain local.
- Network access is disabled by default except optional update checks if the distribution model requires them.
- Analytics are opt-in and must never include photographs, thumbnails, embeddings, face data, filenames, paths, GPS, or EXIF payloads.
- The user can delete all cached analysis and personalization data.

### 17.4 Accessibility

- Full keyboard navigation.
- VoiceOver labels for frames, selection states, reasons, confidence, and actions.
- Color-independent status encoding.
- Adjustable thumbnail size.
- Reduced-motion support.
- No essential information available only on hover.

### 17.5 Compatibility

- Apple silicon native.
- Baseline behavior on M1.
- Scalable concurrency on newer chips.
- Unknown-camera fallback.
- Graceful handling of missing metadata.
- Versioned analysis so operating-system framework changes do not silently invalidate prior decisions.

---

## 18. Safety and data-loss prevention

### 18.1 Immutable-source rule

The application does not edit source files in place. All edits are represented as recipes and rendered to new output files.

### 18.2 Verified-copy rule

No source is considered safely imported until the destination checksum matches the source checksum.

### 18.3 Last-copy rule

The application must not automatically delete what it believes is the only remaining copy of a source photograph.

### 18.4 Retention rule

The default workflow hides rejects for 30 days. Permanent cleanup is a separate background operation with explicit settings and a visible recovery deadline.

### 18.5 High-value safeguard

The following assets cannot enter automatic deletion:

- Rated.
- Protected.
- Manually locked.
- Unique moment representative.
- Low-confidence rejection.
- Manually restored.
- Unverified import.
- Unknown-source-provenance asset.

### 18.6 Auditability

The system records:

- When a file was imported and verified.
- Why it was hidden or rejected.
- Manual overrides.
- When it entered pending deletion.
- When and where an export was created.
- When permanent disposal occurred.

---

## 19. Evaluation framework

### 19.1 Why evaluation must precede polish

Culling quality is the primary product risk. A beautiful interface cannot compensate for repeatedly discarding the photographs the user values. Build an evaluation harness and labeled dataset before investing heavily in advanced editing.

### 19.2 Dataset structure

Each evaluation shoot should include:

- Original chronological files.
- Human-defined scenes and moments.
- Exact/derived duplicate labels.
- Technical failure labels.
- Ranked preferences within each moment.
- Required story-coverage photographs.
- Acceptable alternative selections.
- User-marked irreplaceable moments.
- Preferred keeper-count range.

The evaluation set must include:

- Group events.
- Trips.
- Creative walks.
- Children and action.
- Landscapes and architecture.
- Low light.
- Backlighting.
- Mixed skin tones.
- Glasses, hats, masks, and partial occlusion.
- Intentional motion blur and unusual exposure.
- Multiple camera brands and lenses.

### 19.3 Core culling metrics

#### Review reduction

Percentage of source photographs the user never needs to inspect.

#### Review-group rate

Number of ambiguous moment groups shown per 100 source photographs.

#### Top-choice agreement

Percentage of moments where the system's first selection matches a human-preferred or acceptable top choice.

#### Keeper-set agreement

Similarity between system and human keeper sets, allowing multiple acceptable alternatives.

#### Unique-moment recall

Percentage of human-labeled unique moments represented in the selected or review set.

#### Rescue rate

Percentage of automatically hidden images later restored by the user.

#### Catastrophic miss rate

Percentage of human-labeled irreplaceable or required photographs placed into high-confidence rejection.

#### Redundancy rate

Percentage of selected album pairs judged unnecessarily similar.

#### Participant coverage

For Hangout mode, representation of distinct local face clusters and group combinations relative to the labeled set.

#### Story coverage

For Trip and Document modes, representation of scenes, moments, time periods, and subject categories.

### 19.4 Initial quality gates

Before enabling Tight mode by default:

- Unique-moment recall should exceed 99% on the internal supported-scenario set.
- Catastrophic high-confidence rejection should be below 0.5%.
- At least 80% of suggested top frames should be accepted without change on calibrated supported scenarios.
- Balanced mode should reduce manually inspected frames by at least 70%.
- Confidence calibration should ensure low-confidence cases are substantially more likely to be overridden than high-confidence cases.

These are product gates and should be revised only through documented evaluation, not relaxed to meet a schedule.

### 19.5 Editing metrics

- User preference for edited versus source JPEG in blinded comparisons.
- Cross-frame consistency within a moment.
- Skin-tone plausibility.
- Highlight/shadow artifact rate.
- Chromatic-fringe reduction without edge desaturation.
- Halo and oversharpening rate.
- Export color correctness.
- Edit override rate by look and scene type.

---

## 20. Testing strategy

### 20.1 Unit tests

- EXIF parsing.
- Orientation transforms.
- Checksums and duplicate lookup.
- State transitions.
- Retention-policy guards.
- Selection constraints.
- Reason-code generation.
- Manifest serialization and migration.
- Output naming collision handling.

### 20.2 Golden-image tests

Maintain licensed or internally created golden files covering cameras, lenses, color spaces, orientations, and metadata variants.

Validate:

- Pixel output tolerances.
- Lens correction.
- Fringe correction.
- Tone and color transforms.
- Resize and sharpening.
- Metadata preservation/removal.

### 20.3 Model regression tests

Every model update runs against frozen evaluation shoots and reports:

- Moment grouping changes.
- Selection-set changes.
- Confidence changes.
- Unique-moment losses.
- Participant/story coverage changes.
- Performance and memory changes.

A model update that improves average ranking but creates new catastrophic misses must not ship without mitigation.

### 20.4 Fault-injection tests

- Remove the card during copy.
- Corrupt a destination file before verification.
- Terminate the worker during inference.
- Terminate the app during export.
- Fill the destination disk.
- Deny permissions.
- Introduce a malformed JPEG.
- Make the catalog temporarily unavailable.
- Change destination paths.
- Simulate model load failure.

### 20.5 Usability tests

Measure:

- Time from card insertion to starting processing.
- Number of configuration choices per shoot.
- Number of frames manually inspected.
- Number of review groups.
- Time to resolve each group.
- Trust in hidden/rejected results.
- Use of recovery.
- Understanding of modes and culling strength.
- Whether reasons help or distract.

---

## 21. Observability

Local diagnostics should include:

- Import throughput.
- Preview decode time.
- Inference time by model and compute unit.
- Moment count and size distribution.
- Selection count by reason code.
- Review routing count.
- Render time by stage.
- Peak memory.
- Thermal/concurrency reductions.
- Recoverable error counts.

Diagnostic export must redact filenames, paths, EXIF, image content, embeddings, faces, GPS, and preference examples unless the user explicitly chooses to include specific material.

---

## 22. Rollout plan

### Phase 0: Evaluation foundation

Deliverables:

- Labeled-shoot schema.
- Evaluation runner.
- Baseline metrics.
- Initial cross-camera fixture library.
- Privacy and data-handling decisions.

Exit criterion:

- The team can compare two culling algorithms reproducibly on the same shoots.

### Phase 1: Safe ingest and catalog

Deliverables:

- Folder and card import.
- Checksums and resume.
- Metadata parsing.
- Preview generation.
- Shoot catalog.
- Source-safety workflow.

Exit criterion:

- Repeated interrupted imports produce one verified catalog record per source without data loss.

### Phase 2: Baseline culling engine

Deliverables:

- Exact and derived duplicates.
- Moment grouping.
- Sharpness and exposure signals.
- Face quality and aesthetics.
- Within-moment ranking.
- Basic confidence routing.

Exit criterion:

- Balanced mode achieves meaningful review reduction without violating unique-moment safeguards on the evaluation set.

### Phase 3: Culling-first product experience

Deliverables:

- Intent modes.
- Cull strength.
- Shoot summary.
- Ambiguous-moment review.
- Selected album.
- Hidden/recovery view.
- Recalculation and undo.

Exit criterion:

- Test users can process a shoot without reviewing every photograph and understand where rejected files remain.

### Phase 4: Basic editing and export

Deliverables:

- Natural and warm looks.
- Exposure, white balance, tone, color, sharpening, and noise reduction.
- Lens-aware CA correction.
- Straightening suggestions.
- JPEG export and manifests.

Exit criterion:

- Edited output wins blinded comparisons against unedited camera JPEGs without unacceptable artifact rates.

### Phase 5: Personalization

Deliverables:

- Pairwise preference recording.
- Local preference model.
- Mode-specific adaptation.
- Preference explanation/reset/export.

Exit criterion:

- Repeat users show a measurable reduction in overrides versus the general model.

### Phase 6: Expanded compatibility and convenience

Candidate deliverables:

- Direct-camera validation across major brands.
- Additional lens profiles.
- Watched-folder automation.
- Local-network phone/tablet review.
- Photo-library export.
- Optional RAW+JPEG pairing without changing the JPEG-first experience.

---

## 23. Risks and mitigations

### 23.1 Incorrectly rejecting meaningful photographs

**Risk:** The system favors technical quality over emotional value.  
**Mitigation:** Unique-moment safeguards, camera rating support, confidence routing, recoverable retention, and personalization.

### 23.2 Over-aggressive burst collapse

**Risk:** Different expressions or action phases are treated as duplicates.  
**Mitigation:** Separate exact duplicates, derived duplicates, bursts, and moments; include expression and temporal diversity in marginal keeper value.

### 23.3 Generic aesthetic bias

**Risk:** A general aesthetics model produces conventional, homogeneous albums.  
**Mitigation:** Limit aesthetics to one signal, increase novelty/coverage weights, provide Creative mode, and learn user preference.

### 23.4 Face-analysis bias

**Risk:** Eye, face-quality, or expression models perform unevenly across people or conditions.  
**Mitigation:** Diverse evaluation, model calibration, group-relative comparison, low-confidence routing, and prohibition on face quality as the sole rejection reason.

### 23.5 Intentional blur or darkness treated as failure

**Risk:** Creative images are incorrectly rejected.  
**Mitigation:** Creative mode, scene-relative evaluation, out-of-distribution safeguards, and technical-factor transparency.

### 23.6 JPEG editing artifacts

**Risk:** Aggressive recovery creates banding, noise, halos, or unnatural color.  
**Mitigation:** Conservative adjustment limits, single final encode, artifact detection, and per-stage rollback.

### 23.7 Double lens correction

**Risk:** The camera already corrected a JPEG and the application applies the correction again.  
**Mitigation:** Detect body/lens and correction metadata where possible, evaluate residual distortion/fringing, and prefer no correction when confidence is low.

### 23.8 Storage and deletion trust

**Risk:** Users do not trust automated culling because they fear data loss.  
**Mitigation:** Immutable originals, verified copies, 30-day retention, clear counts, locks, restoration, audit history, and no card deletion.

### 23.9 Thermal throttling on fanless systems

**Risk:** Sustained analysis and rendering slow significantly.  
**Mitigation:** Preview-first inference, bounded concurrency, thermal-aware scheduling, and editing only selected photographs.

### 23.10 Framework and OS behavior changes

**Risk:** Apple framework revisions alter feature outputs or supported behavior.  
**Mitigation:** Pin supported request revisions where possible, version features and decisions, maintain golden tests, and provide custom-model fallbacks.

---

## 24. Product success metrics

Primary metric:

> **Human review minutes per 100 source photographs.**

Supporting metrics:

- Percentage of source photographs never manually inspected.
- Ambiguous groups per 100 photographs.
- Automatic top-choice acceptance rate.
- Restore-from-reject rate.
- Unique-moment recall.
- Catastrophic miss rate.
- Final album redundancy.
- Time from import completion to shareable album.
- Percentage of shoots exported without opening advanced editing.
- Repeat usage after three shoots.
- Personalization improvement over time.

Avoid optimizing only for raw keep percentage. A system can appear aggressive while producing a poor or incomplete album.

---

## 25. Recommended MVP definition

The MVP should be deliberately narrow but prove the hardest value proposition.

### Included

- macOS Apple-silicon application.
- Folder and SD-card JPEG import.
- Sony α7C as the initial direct-camera test fixture.
- Cross-camera EXIF-based fallback.
- Exact and near-duplicate detection.
- Temporal/visual moment grouping.
- Technical quality, faces, aesthetics, and uniqueness signals.
- Hangout, Trip, Creative, and Everyday modes.
- Keep more, Balanced, and Tight strength.
- Variable keepers per moment.
- Shoot-level coverage selection.
- Confidence-based review queue.
- Camera-rated hard keeps.
- Hidden/recoverable reject area.
- Natural and Everyday warm edits.
- Exposure, white balance, tone, color, noise, sharpening, and CA correction.
- JPEG export at original or approximately 16MP.
- Local-only operation.
- Decision and edit manifests.

### Excluded

- RAW development.
- Video.
- Cloud sync.
- Generative edits.
- Named face recognition.
- Full manual editing suite.
- Automatic permanent deletion enabled by default.
- Natural-language/LLM interface.
- Professional client workflow.

### MVP proof point

For a 500-image Hangout or Trip shoot, a user should be able to receive a concise edited album while making fewer than 15 group-level decisions and without inspecting the majority of source frames.

---

## 26. Recommended defaults for the initial user

For the use case that motivated this specification:

- Camera capture: Large Fine JPEG.
- Intent mode: Hangout for group events; Trip for travel; Creative for deliberate photo walks.
- Culling strength: Tight for group events, Balanced for trips, Balanced for Creative.
- Look: Everyday warm for people; Natural for trips and Creative.
- Lens correction: Automatic.
- Chromatic-aberration correction: Automatic.
- Crop: Suggestions.
- Output: 16MP sRGB JPEG, quality tuned for high visual quality rather than archival identity.
- Favorites: Preserve original-resolution JPEG as well.
- Rated/protected images: Always keep.
- Reject retention: 30 days.
- Permanent deletion: Off until the user has completed multiple shoots and explicitly enables it.

---

## 27. Open decisions

The following decisions do not block the architectural direction but should be resolved through prototype testing:

1. What is the desired default final-album size for a 500-photo Hangout shoot?
2. Should zero-touch import immediately use the previous mode or ask once per card?
3. Should the selected album preserve chronological order or offer an automatically arranged story order?
4. Is a 12MP, 16MP, or full-resolution default export preferred?
5. Should originals be managed inside the application library or remain in a visible user folder?
6. Should the application offer a local iPhone/iPad review interface in the first production release?
7. How much explanation should accompany automated decisions?
8. Should automatic crop ever apply without review?
9. Which camera brands and lens families are required for the first public compatibility promise?
10. Should personalization be global per user, per mode, per camera, or a combination?
11. What minimum supported macOS version provides the required Vision capabilities with acceptable fallback coverage?
12. Will the application be distributed through the Mac App Store, direct download, or both?

Recommended initial answers are encoded in the MVP and default sections above.

---

## 28. Final product statement

Local Photo Curator is successful when the photographer stops thinking about post-processing while taking photographs.

The product should not encourage the user to shoot less merely to avoid later work. It should make abundant capture inexpensive in attention as well as storage. Its intelligence should be evaluated by the photographs it safely hides, the meaningful moments it preserves, the small number of questions it asks, and the consistency of the finished album.

The defining experience is not “AI edits my photographs.” It is:

> I took hundreds of photographs, connected my camera, and shortly afterward had a small album I genuinely liked—without spending my evening culling it.
