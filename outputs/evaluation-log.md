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
