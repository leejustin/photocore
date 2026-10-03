# Cull efficacy evaluation log

Owner runs. Source photographs stay outside git.

## 2026-09-30 — WorldMaster2026 (BJJ, 94 JPG)

Command:

```bash
swift run photo-engine eval "/Users/justin/Pictures/WorldMaster2026 copy" \
  --profile sports --cull balanced --target 40 \
  --output ./exports/WorldMaster2026-eval
```

| Metric | Value |
| --- | --- |
| Kept | 12 / 94 (87% culled) |
| Review | 0 |
| Alternates | 82 (71 near-dup, 11 same-moment) |
| Hidden | 0 |
| Moment groups | 15 |
| Wall time | ~2.3s (warm cache) |

Calibration on this shoot: neighbours ≤3s p50 **0.13**; unrelated >5min p50 **0.40** (venue-homogeneous mats). Default visual near-dup **0.50** alone would collapse the shortlist.

**Finding:** Pre-fix run kept **1** photo (hard same-moment used visual distance only). After requiring time corroboration for hard same-moment removal, kept **12** diverse match moments. Eye-check of `eval-kept.jpg` looks like a sensible sports delivery set.

## 2026-09-30 — Post_Pycon_TW slice (200 photos)

Command:

```bash
swift run photo-engine eval "/Users/justin/Pictures/Post_Pycon_TW" \
  --profile groupEvent --cull balanced --target 50 --limit 200 \
  --output ./exports/Post_Pycon_TW-eval
```

| Metric | Value |
| --- | --- |
| Kept | 50 / 200 (75% culled) |
| Review | 5 (2.5 / 100) |
| Alternates | 88 |
| Hidden | 57 (13 technical, 49 below cut) |
| Moment groups | 52 |
| Wall time | ~50.6s |

Eye-check: `eval-kept.jpg` covers portraits, food, landscape, camping variety. `eval-hidden-sample.jpg` is mostly weaker burst members and technical rejects — no obvious unique-moment-only-on-hidden from the sample sheet.

## Regression

`swift run photo-engine-checks` — 48 passed, including `distant lookalikes are not hard-removed`.

## 2026-10-01 — Vision face signals are not deterministic

Same 28 Pycon night photos (lion dance, temple), analyzed repeatedly in one process with `AppleAnalysisEngine`:

| Comparison | Photos whose face count or face quality differed |
| --- | --- |
| Serial vs serial | 3 / 28 |
| Serial vs parallel | 2 / 28 |
| Serial vs serial, Vision pinned to CPU | 1 / 28 |

Face quality moved by up to 0.49 on the same photo. Four uncached `eval` runs kept the same 6 photos, but one in four moved a borderline frame between review and hidden. On the iPhone simulator the keeper count moved between 3 and 4.

Cause: Vision's face capture quality and landmarks requests each detect faces on their own and the detector is noisy on borderline faces (masks, small faces). Not caused by threading or the analysis cache; the cache round-trips signals exactly (`CacheRoundTripTests`).

Follow-up: detect faces once with `VNDetectFaceRectanglesRequest`, pass them as `inputFaceObservations` to the quality and landmarks requests, and drop faces below a stable confidence. Then re-run this comparison.

Also found: the aesthetics model returns one constant near-zero score for every image in the iOS simulator. Aesthetics is now skipped in the simulator and the analysis cache is keyed by platform.

## 2026-10-01 — Vision deadlock under stacked culls

`swift test` hung (0% CPU) once chunk 4 added more Vision-heavy tests. Samples showed every gate holder parked in Vision's `VNControlledCapacityTasksQueue dispatchGroupWait`, one thread on the text detector's serial queue, and the remaining test threads blocked on `VisionCompute.gate`.

| Setup | Result |
| --- | --- |
| All suites serial (`--no-parallel`) | 25 pass in 3.4 s |
| Any single new test with the pipeline tests | Passes |
| Eight Vision tests in parallel, gate at 4 or 2 | Hangs every time |
| Vision suites nested in one `.serialized` suite | 8 of 8 runs pass, about 3 s each |

Cause: several culls at once, each with worker threads parked on the gate, starve Vision's internal queues of threads. Production never does this: the app culls one trip at a time and the server's job queue is serial. Every Vision caller, including Core Image auto adjustment (which uses Vision face detection), now goes through the gate, and text recognition runs exclusively.

Subject-aware finish on seven Pycon frames: masks on 3 of 7 (the lion dance, a portrait on a swing, a café table); none on the four landscapes and sunsets, which is correct. A 1.2% background blur melted framing tree trunks and looked fake, so the default finish has no blur and the portrait preset uses 0.3%.

## 2026-10-03 — Bound: photos of you, the browser pre-filter and the App Clip

**Face identity from Vision feature prints.** 300 frames of the Post_Pycon_TW shoot (read-only, downsampled), faces of at least 70 px, aligned by the eyes and cropped square with a 1.25x margin, revision-2 feature prints:

| Measure | Value |
| --- | --- |
| Faces found | 201 |
| Different people in the same photo | p5 0.59, p50 0.84 |
| Leader grouping under 0.5 | 175 groups, nearly all one person each |
| Nearest neighbours of a query face | The same person when clothes, glasses and light match; otherwise mixed with lookalikes |

The feature print sees clothing, glasses and light as much as the face, so it groups one person reliably within a trip and poorly across a selfie. The selfie plan was dropped: a friend taps their own face in the book, and faces under 0.5 from a tap are theirs. On a 40-frame book (19 faces), tapping the man in round sunglasses found both photos of him and nothing else. A face-embedding Core ML model can replace Vision (`PHOTOCORE_FACE_MODEL`); none is included because most published face weights are licensed for non-commercial use only.

**Browser pre-filter.** Ten generated files in the invite page: a three-frame burst with real EXIF times one second apart, a soft copy of it, a heavily blurred scene, a black frame, three distinct scenes, a different scene at the same second as the burst, and a text file. Kept: the sharpest burst frame, the three scenes and the same-second different scene. Skipped: two repeats, one blurry, one dark, one non-photo. "Add them anyway" sent the four photos too. Found and fixed on the way: the page's policy blocked `blob:` images, which would have made the filter upload everything without saying so.

**App Clip, end to end in the simulator.** Against a local server, a friend joined from the clip and picked 9 photos; the phone kept its best 3 and offered them (about 4 KB of feature print each); the server asked for 2, one being the same moment as another of the friend's offers five minutes apart; 7 never left the phone. Found and fixed: the keyboard covered Continue with no way to dismiss it.

**Web owner flow.** Eight photos from a web owner: the server kept 3 for the book and deleted the other 5; Keep through the test checkout made the page offer the full-size zip and drop the free footer.
