# Hybrid Photo Processing Platform

## Local-Mac Compute, Low-Cost Object Storage, and Optional Oracle Control Plane

**Status:** Draft 1  
**Date:** September 7, 2026  
**Working title:** Venue Content Loop — Hybrid Deployment  
**Primary use case:** Managed phones at gyms and other venues, with automatic culling, editing, and social-content generation  
**Secondary use case:** Personal camera and phone ingestion into the same processing engine  
**Deployment model:** Durable cloud ingestion and coordination, local Apple Silicon processing, cloud delivery  
**Related specifications:** [Venue Photo Content Service](./venue-photo-content-subscription-spec.md) and [Local Photo Curator](./local-photo-curator-spec.md)

---

## 1. Executive summary

This document specifies a cost-minimized architecture for a photo-processing subscription in which customer devices upload photographs directly to inexpensive object storage and an operator-controlled Mac performs most computationally expensive work locally.

The intended initial deployment is:

```text
Managed Android or iOS capture app
              |
              | short-lived signed upload
              v
   S3-compatible object storage
              |
              | durable job metadata
              v
  Lightweight cloud control plane
              |
              | outbound polling / job lease
              v
        Local Mac worker
              |
              | selected originals, edits, manifests
              v
   S3-compatible object storage
              |
              v
 Customer review and delivery portal
```

The architecture deliberately separates three responsibilities:

1. **Object storage is the durable media buffer.** A phone can finish an upload even when the Mac is offline. No photograph is considered safely transferred until the object store has confirmed the object and the service has verified its integrity.
2. **The cloud control plane coordinates work.** It authenticates devices and users, issues upload grants, stores metadata, tracks jobs, manages retention, and exposes the customer dashboard. It does not need to proxy full-resolution image bytes.
3. **The Mac is a replaceable processing worker.** It downloads queued media over an outbound connection, culls and edits locally, uploads results, and purges its working set. The Mac is not the public API, the sole database, or the only copy of customer data.

This model is feasible on Apple Silicon. An M1-class Mac with adequate memory can support an early pilot when the pipeline analyzes previews first and performs full-resolution work only on likely keepers. An M3 or later system increases throughput but does not require a different design. A wired, always-on Mac mini with encrypted external scratch storage is a practical first production worker.

The recommended initial infrastructure is:

- **Backblaze B2** for original and derivative object storage when each original is normally downloaded once.
- **A small, replaceable cloud service** for API, queue, metadata, authentication, and scheduled cleanup.
- **Oracle Cloud Always Free Ampere compute** as an optional pilot control plane, not as a non-replaceable production dependency.
- **One operator-controlled Mac mini** as the first image-processing worker.
- **A managed Android application first**, followed by iOS when justified by customer demand.

Cloudflare R2 should remain a supported storage backend and may be preferable when downloads are frequent or unpredictable because it does not charge internet egress. Storage must sit behind an internal abstraction so the service can move tenants or new uploads between providers without changing the applications.

The commercial thesis is that object storage and coordination can remain extremely inexpensive while local hardware absorbs the variable inference and rendering workload. The architecture should preserve an uncomplicated path to cloud workers later if volume, geography, reliability commitments, or data-governance requirements make local processing inappropriate.

---

## 2. Goals

### 2.1 Product goals

The system must:

- Let a participant pick up a managed phone, take photographs, and put it back without handling files.
- Reliably remove uploaded media from constrained device storage only after confirmed transfer.
- Reduce hundreds of photographs to a small, varied, high-quality collection.
- Apply restrained, consistent edits automatically.
- Produce correctly sized social-media images, carousels, collages, and galleries.
- Give an authorized venue reviewer a fast approval workflow.
- Keep per-location infrastructure cost low enough to support healthy subscription margins.
- Continue accepting uploads while the processing Mac is unavailable.
- Support multiple capture devices, venues, and eventually multiple workers.
- Reuse the same culling and editing engine for personal camera imports.

### 2.2 Architecture goals

The architecture must:

- Keep image bytes out of the public API path whenever possible.
- Avoid permanent cloud GPU costs during the pilot.
- Treat all workers as disposable and replaceable.
- Use idempotent jobs so retries cannot corrupt or duplicate customer output.
- Allow the storage provider, processing location, and model versions to evolve independently.
- Keep tenant data isolated through object keys, authorization checks, and worker assignments.
- Use lifecycle rules and application-level retention to delete low-value media quickly.
- Retain enough provenance to explain why an image was selected, rejected, edited, or cropped.
- Allow a failed Mac to be replaced without losing jobs or customer media.
- Be operable by a very small team.

### 2.3 Business goals

The initial system should:

- Serve the first one to ten pilot locations from a single Mac where measured throughput permits.
- Keep incremental storage expense for a typical pilot location below a few dollars per month.
- Avoid commitments to expensive always-on compute before demand is proven.
- Produce auditable usage metrics for future plan limits and pricing.
- Identify the thresholds at which another Mac, a colocated worker, or cloud compute becomes cheaper or safer.

---

## 3. Non-goals

The initial release will not:

- Guarantee immediate processing while the local worker is offline.
- Replace a professional event photographer for contractual, editorial, or high-stakes work.
- Perform fully autonomous public posting without an explicit venue policy and approval configuration.
- Preserve every rejected original forever.
- Offer lossless RAW editing for venue-phone capture.
- Train a large language model.
- Depend on a general-purpose LLM to determine focus, exposure, duplicates, facial quality, or image similarity.
- Expose the local Mac directly to the public internet.
- Use the phone's personal camera roll or a consumer cloud-photo account as the canonical ingestion system.
- Promise cryptographic end-to-end encryption in which the service cannot access pixels; server-authorized processing necessarily requires decryption on an approved worker.
- Make Oracle's free tier a hard requirement for the product to function.

---

## 4. Design principles

### 4.1 Durable before clever

The system must make the original upload durable before starting culling, editing, or device cleanup. A less sophisticated selection algorithm with reliable ingestion is a viable product. A brilliant model that occasionally loses customer photographs is not.

### 4.2 Preview first, full resolution last

Most images will be rejected or represented by another member of a burst. The worker should use embedded previews or generated medium-resolution proxies for grouping and scoring, then decode and render full-resolution files only for selected or borderline images.

### 4.3 Local compute is an implementation choice

Job contracts cannot assume that the worker is a particular Mac. A compatible cloud container, another Mac, or a venue-local appliance must be able to claim the same job in the future.

### 4.4 Confidence controls automation

High-confidence duplicate removal can happen automatically. Low-confidence aesthetic decisions should be surfaced as a small review set or handled using a conservative keep policy. The goal is to remove culling labor without silently discarding unique moments.

### 4.5 Deletion is a first-class workflow

Retention is not an afterthought. Every object class must have a retention policy, legal-hold behavior, deletion status, and auditable reason for continued storage.

### 4.6 Customer outcomes, not model scores

The venue pays for a usable weekly content package. Internal metrics should ultimately connect processing decisions to approvals, downloads, publishes, and corrections—not merely image-quality benchmark scores.

---

## 5. Principal user journeys

### 5.1 Venue capture

1. A staff member or participant wakes the managed phone.
2. The application displays the venue's camera interface and brief consent guidance.
3. The participant selects an optional mode such as `Workout`, `Class`, `Group`, `Portrait`, or `Creative`.
4. The participant takes one or more photographs.
5. The application stores each capture in app-private storage and immediately creates a durable local upload record.
6. Upload begins when network and battery policies permit.
7. The phone shows `Uploading`, `Safely uploaded`, or `Needs attention`; it never implies safety merely because a request was initiated.
8. After the server verifies the object, the local original becomes eligible for deletion under the device policy.

### 5.2 Automatic processing

1. The service closes a capture session after an inactivity window or explicit action.
2. A session-level processing job becomes available.
3. The Mac worker claims a time-limited lease.
4. It downloads metadata and previews, groups visually related photographs, and scores technical and human-centered qualities.
5. It selects representatives subject to coverage, diversity, consent, and venue-policy constraints.
6. It applies a venue-approved editing preset and creates destination-specific derivatives.
7. It uploads selected originals, edited masters, social crops, collages, thumbnails, and a result manifest.
8. The cloud marks the result available for review only after every required artifact is verified.

### 5.3 Venue review

1. An authorized reviewer opens a daily or weekly collection.
2. The default view shows the small selected set, not the entire intake.
3. The reviewer approves, rejects, changes a crop, requests alternatives, or opens a burst when needed.
4. The reviewer downloads or schedules approved assets.
5. Reviewer actions become feedback signals, subject to the service's privacy and model-improvement policy.

### 5.4 Worker interruption

1. The Mac loses connectivity or power during a job.
2. Its lease expires after the configured heartbeat grace period.
3. Partially uploaded artifacts remain uncommitted and are not shown to customers.
4. The same or another worker claims the job.
5. It reads the manifest and object checksums, reuses valid completed stages, and resumes safely.

### 5.5 Device storage pressure

1. The phone approaches a configured storage threshold.
2. It prioritizes pending uploads and pauses nonessential local generation.
3. It deletes only server-confirmed captures whose safety delay has elapsed.
4. If all remaining media is unconfirmed, it warns the operator and refuses unsafe automated deletion.

---

## 6. System architecture

### 6.1 Component view

```text
┌──────────────────────────── Capture location ────────────────────────────┐
│                                                                         │
│  Managed phone                                                          │
│  ├── Camera UI                                                          │
│  ├── Consent/session metadata                                           │
│  ├── Encrypted app-private spool                                        │
│  ├── Resumable upload manager                                           │
│  └── Device-health reporter                                             │
│                                                                         │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ HTTPS; short-lived signed URLs
                                v
┌──────────────────────────── Cloud boundary ──────────────────────────────┐
│                                                                         │
│  API / control plane             S3-compatible object storage           │
│  ├── Device authentication       ├── originals                          │
│  ├── Upload authorization        ├── previews                           │
│  ├── Session/job orchestration   ├── edited masters                     │
│  ├── Worker leases               ├── social derivatives                 │
│  ├── Tenant policy               ├── manifests                          │
│  ├── Review API                  └── temporary multipart uploads         │
│  └── Retention scheduler                                                │
│                                                                         │
│  Metadata database + queue                                               │
│                                                                         │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ Outbound HTTPS initiated by worker
                                v
┌────────────────────────── Operator boundary ─────────────────────────────┐
│                                                                         │
│  Mac worker                                                             │
│  ├── Job agent                                                          │
│  ├── Encrypted scratch cache                                            │
│  ├── Preview extraction                                                  │
│  ├── Similarity / burst clustering                                      │
│  ├── Quality and content scoring                                        │
│  ├── Selection optimizer                                                │
│  ├── Editing and crop renderer                                          │
│  └── Artifact uploader and purge manager                                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Trust boundaries

The platform has four relevant trust boundaries:

- **Capture device:** physically accessible to venue users and therefore not fully trusted. Device credentials must be revocable and narrowly scoped.
- **Public cloud:** trusted to store encrypted objects and authoritative metadata. Administrative access must be controlled and audited.
- **Processing worker:** authorized to decrypt only the jobs it has leased. Local artifacts must be encrypted and automatically removed.
- **Customer portal:** tenant-authenticated and restricted to the customer's media, users, and approved integrations.

### 6.3 Canonical sources of truth

- Object storage is authoritative for uploaded and generated media bytes.
- The metadata database is authoritative for ownership, state, retention, consent, policy, jobs, and object references.
- The device database is authoritative only for pending local uploads.
- The Mac filesystem is never authoritative.
- A customer-facing collection is valid only when its committed manifest exists and the database points to the matching manifest version.

---

## 7. Capture applications

### 7.1 Platform sequence

The recommended sequence is Android first, especially for a venue-owned Google Pixel. Android provides practical managed-device and background-work options for a dedicated capture appliance. iOS should use the same API and object contracts when added.

The processing service must remain camera-independent. A capture record describes image format, dimensions, orientation, color profile, lens/camera metadata when present, timestamps, and application context. It must not assume a Pixel, Sony, Apple, or specific lens.

### 7.2 Capture format

For the venue product:

- Default to high-quality JPEG or HEIC/HEIF where the complete processing path supports it.
- Preserve orientation and color-profile metadata.
- Normalize unsupported formats during preview generation, not on the phone unless necessary.
- Do not capture RAW by default.
- Provide an administrative quality control balancing file size and editing headroom.
- Record whether a file has already received computational photography from the phone so the editing pipeline can avoid excessive processing.

For personal-camera imports, JPEG should remain the default low-friction path, while RAW support can be an optional capability of the local product.

### 7.3 Local spool

Each capture must be written atomically into app-private storage and paired with a database record containing:

- Locally generated capture UUID.
- Tenant, location, and device IDs.
- Session UUID.
- Local path or content reference.
- MIME type and byte length.
- SHA-256 checksum calculated incrementally where practical.
- Capture timestamp and monotonic sequence.
- Width, height, and orientation.
- Selected capture mode.
- Consent/release context reference.
- Upload state and retry count.
- Server object ID after authorization.
- Server verification timestamp.
- Local deletion eligibility timestamp.

The media file and record must survive application restart, OS process termination, temporary loss of connectivity, and device reboot.

### 7.4 Upload behavior

Uploads must be:

- Direct from the phone to object storage.
- Authorized using short-lived, single-purpose signed URLs or multipart credentials.
- Resumable for large objects and unreliable Wi-Fi.
- Idempotent using the capture UUID and checksum.
- Concurrency-limited to avoid degrading the venue network.
- Aware of battery, thermal, connectivity, and storage-pressure state.
- Able to continue in the background within platform limits.
- Confirmed by a final API call that supplies size, checksum, and storage upload identifier.

Permanent bucket credentials must never ship in the application.

### 7.5 Phone cleanup

A capture is eligible for local deletion only when all of the following are true:

- The upload has completed.
- The expected object exists in the correct tenant prefix.
- Server-observed length matches the capture record.
- The checksum or trusted multipart checksum matches.
- The safety delay has elapsed.
- The capture is not under a local support hold.

Recommended default device policy:

- Retain confirmed uploads for 48 hours.
- Begin cleanup at 70% allocated spool utilization.
- Aggressively clean eligible objects at 85%.
- Warn and restrict capture at 95% if non-eligible media occupies the remaining space.

### 7.6 Device management

The administrative console should expose:

- Last heartbeat.
- Application and OS version.
- Battery and charging state.
- Free storage.
- Pending object count and bytes.
- Oldest pending upload age.
- Network status.
- Camera permission status.
- Recent upload error class.
- Remotely configurable capture and retention policies.
- Credential revoke and device disable actions.

---

## 8. Object storage

### 8.1 Provider recommendation

The initial recommendation is Backblaze B2 because its low storage price and included egress allowance align with a workflow that downloads each original approximately once. Cloudflare R2 is the preferred alternative when customer delivery or worker reprocessing creates unpredictable egress.

Current reference pricing as of this specification date:

| Provider | Headline storage model | Egress characteristic | Suitability |
|---|---:|---|---|
| Backblaze B2 | Starts at $6.95/TB/month | Free up to three times average monthly storage | Recommended initial store |
| Cloudflare R2 Standard | $0.015/GB-month | Internet egress free | Recommended predictable-egress alternative |
| Hetzner Object Storage | Base bundle includes 1 TB storage and 1 TB egress | European regions | Attractive near or above bundle utilization |
| Wasabi | $7.99/TB-month with minimums | No egress fees under policy | Poor fit for short-lived originals because of minimum billed capacity and retention |
| Oracle Always Free Object Storage | 20 GB combined free allowance | Limited free-tier capacity | Useful only for experiments or small control artifacts |

Pricing changes over time and must be verified before vendor commitment. Sources: [Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing), [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/), [Hetzner Object Storage](https://www.hetzner.com/pressroom/object-storage/), [Wasabi pricing FAQ](https://wasabi.com/pricing/faq), and [Oracle Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

### 8.2 Storage abstraction

Application code must access media through a storage interface that supports:

- Create single-part upload grant.
- Create multipart upload grant.
- Complete or abort multipart upload.
- Head object.
- Generate authorized download grant.
- Server-side copy where supported.
- Delete object and version.
- Enumerate objects for reconciliation.
- Read provider checksum and version metadata.
- Configure or emulate lifecycle policy.

The database should store a logical `blob_id` separately from provider, bucket, region, and object key. Customer-facing APIs must never expose permanent provider credentials or rely on a provider-specific key format.

### 8.3 Bucket strategy

Initial deployment may use separate buckets for environment and object sensitivity:

- `originals-production`
- `derivatives-production`
- `temporary-production`
- Corresponding staging buckets

Tenant isolation should be enforced in the service and represented in keys:

```text
tenants/{tenant_id}/locations/{location_id}/sessions/{session_id}/
  originals/{capture_id}/{version_id}
  previews/{capture_id}/{pipeline_version}.jpg
  results/{run_id}/masters/{asset_id}.jpg
  results/{run_id}/social/{asset_id}/{format_id}.jpg
  results/{run_id}/manifest.json
```

Random, non-guessable IDs should be used. Original filenames can be retained as metadata but should not be relied upon for identity.

### 8.4 Immutability and versioning

Original media objects are immutable. Corrections create new metadata or derived objects. The system must not overwrite an original in place.

Generated artifacts are versioned by:

- Processing run.
- Pipeline version.
- Model bundle version.
- Venue style-preset version.
- Export-template version.
- Source object version/checksum.

This enables reproducibility, controlled reprocessing, and comparison between pipeline releases.

### 8.5 Retention classes

Recommended defaults:

| Object class | Default retention | Notes |
|---|---:|---|
| Abandoned multipart data | 1 day | Automatically abort |
| Temporary worker artifacts | 1–3 days | Never customer-visible |
| Obvious rejected originals | 7 days after committed result | Recovery grace period |
| Other non-selected originals | 30 days | Venue-configurable |
| Selected originals | 90 days | Longer plan option |
| Edited masters | Subscription lifetime plus exit grace | Customer deliverable |
| Social derivatives | Subscription lifetime plus exit grace | Regenerable, but cheap |
| Thumbnails | Subscription lifetime or regenerated | Small and useful for history |
| Audit manifests | Contractual retention period | Avoid embedding unnecessary personal data |

Application-level retention is required even when bucket lifecycle rules exist because legal holds, customer plan settings, pending review, and processing failures can override simple age-based deletion.

### 8.6 Storage reconciliation

A scheduled reconciler must identify:

- Database records whose object is missing.
- Objects without an owning database record.
- Incomplete multipart uploads.
- Objects past a confirmed deletion deadline.
- Retained objects missing a documented policy reason.
- Generated artifacts whose committed manifest is absent.

Orphaned objects should enter quarantine before deletion. Reconciliation must be rate-limited and observable.

---

## 9. Cloud control plane

### 9.1 Responsibilities

The control plane owns:

- Tenant, user, location, and device identity.
- Authentication and authorization.
- Upload authorization and finalization.
- Capture session state.
- Job creation and scheduling.
- Worker registration, capability matching, leases, and heartbeats.
- Venue policies and style presets.
- Collection review and publication state.
- Retention and deletion orchestration.
- Usage metering and subscription entitlements.
- Audit events.
- Operational health endpoints.

It should not receive or proxy normal full-resolution uploads or downloads. Those should flow directly between authorized clients and object storage.

### 9.2 Optional Oracle deployment

An Oracle Cloud Always Free Ampere instance may host the pilot control plane when capacity is available. Oracle currently advertises an Always Free Ampere A1 allocation totaling up to four OCPUs and 24 GB of memory, together with other limited free resources. See [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/).

This should be treated as a cost optimization, not a foundational product assumption:

- Package the API, queue consumer, scheduler, and portal as portable containers or conventional deployable services.
- Keep infrastructure definitions outside Oracle-specific consoles.
- Back up the database and critical configuration to a second provider.
- Monitor free-tier eligibility and resource reclamation risk.
- Never place the only encryption key, database backup, or operational credential on the VM.
- Maintain a documented migration path to a small paid VM or managed service.

Oracle Object Storage is not recommended as the primary free photo store because the Always Free allowance is only 20 GB of combined Standard, Infrequent Access, and Archive storage, with a limited monthly API allowance. It can hold control-plane backups or test data but will not meaningfully cover a busy venue.

### 9.3 API service

The API should be stateless except for local caches and should support horizontal replacement. Minimum routes are defined later in this document.

Recommended characteristics:

- HTTPS only.
- Structured request IDs.
- Tenant context derived from verified identity, never accepted blindly from a request body.
- Schema validation at every boundary.
- Idempotency keys for state-changing mobile and worker operations.
- Explicit rate limits by device, user, IP risk class, and tenant.
- Short-lived signed media access.
- Append-only security and processing audit events.

### 9.4 Database

A relational database is recommended because jobs, object references, review actions, permissions, and retention policies have strong relationships and transactional state transitions.

For a pilot, PostgreSQL on the control-plane VM can be acceptable if:

- Encrypted daily backups are copied off-host.
- Restore is tested.
- Write-ahead or frequent incremental backup limits data loss.
- Disk and inode utilization are monitored.
- Schema migrations are repeatable.

Before offering a meaningful uptime commitment, move to a managed or independently replicated database unless the team is prepared to operate PostgreSQL reliably.

### 9.5 Queue

The queue may begin as a PostgreSQL-backed job table using safe row locking and leases. This reduces moving parts at pilot scale. The contract must permit migration to a dedicated queue later.

Required queue behavior:

- At-least-once delivery.
- Capability-aware claiming.
- Priority and scheduled availability.
- Time-limited leases.
- Heartbeat-based lease renewal.
- Exponential retry with jitter.
- Maximum attempts and dead-letter state.
- Administrative retry and cancel.
- Dependency tracking between pipeline stages.
- Per-tenant fairness so one venue cannot starve others.

Exactly-once execution is not required; idempotent effects are.

---

## 10. Local Mac worker

### 10.1 Role

The Mac worker is a private compute appliance. It performs media-heavy and model-heavy processing but owns no irreplaceable state.

It must:

- Initiate all network connections outbound.
- Authenticate using a revocable worker credential and device-bound key where practical.
- Advertise supported pipeline versions, models, hardware, free disk, and concurrency.
- Claim only jobs compatible with its capabilities and data-region policy.
- Renew job leases while making progress.
- Use an encrypted, size-bounded scratch directory.
- Upload stage manifests and final artifacts idempotently.
- Purge media after successful completion or terminal failure grace period.
- Continue safely after restart.

### 10.2 Hardware profile

Pilot baseline:

- Apple Silicon Mac mini or equivalent.
- 16 GB unified memory preferred as a practical minimum.
- Wired Ethernet.
- Enough internal storage for the OS and application.
- Encrypted external SSD for scratch space if internal capacity is constrained.
- UPS for graceful shutdown during short outages.
- Separate non-administrator operating-system account for the worker.
- FileVault enabled.

An M1 system is suitable for proving the workflow. An M3 or newer system provides additional performance headroom. Actual venue capacity must be determined through representative benchmarks rather than processor labels alone.

### 10.3 Worker service lifecycle

The worker runs as a supervised background service:

1. Load configuration and validate the encrypted scratch volume.
2. Authenticate to the control plane.
3. Report capabilities and health.
4. Reconcile any interrupted local jobs with their cloud leases.
5. Poll or maintain a long-lived outbound channel for work.
6. Claim a job and receive short-lived access grants.
7. Execute pipeline stages with checkpoints.
8. Upload and verify artifacts.
9. Commit the result manifest.
10. Release the lease and purge the local working set.

The process supervisor should restart the worker after failure with bounded backoff. Automatic application updates should be staged and should not interrupt a job unless a security revocation requires it.

### 10.4 Scratch cache

Each job receives an isolated directory named by opaque job ID. The directory contains:

- Downloaded source objects.
- Extracted previews.
- Model inputs and intermediate metadata.
- Rendered outputs awaiting upload.
- A local checkpoint manifest.
- Logs scrubbed of unnecessary personal data.

Requirements:

- Encrypted at rest.
- Maximum total size configured.
- Per-job quota.
- No consumer cloud synchronization.
- Excluded from Time Machine and search indexing.
- Secure permissions limited to the worker user.
- Automatic cleanup after completion.
- Startup cleanup of stale directories, but only after reconciling job state.

Secure deletion guarantees on SSDs are complicated by wear leveling. The system should rely primarily on full-volume encryption plus key protection and normal deletion, not claim physical-bit erasure it cannot prove.

### 10.5 Concurrency

Initial concurrency should be conservative:

- One full session pipeline at a time.
- Parallel downloads and preview extraction within bounded limits.
- One or two full-resolution renders concurrently depending on memory pressure.
- Pause new claims when scratch utilization, memory pressure, temperature, or network errors exceed policy.

Concurrency should be tuned from observed memory, thermal, and latency data. Maximizing instantaneous utilization is less important than predictable unattended operation.

### 10.6 Multi-worker expansion

Additional workers can use the same queue. Scheduling attributes may include:

- Architecture and model support.
- Region and tenant data-boundary eligibility.
- Available disk.
- Current load.
- GPU/Neural Engine capability.
- Pipeline version.
- Maximum object dimensions.
- Priority class.

The control plane can initially allow any eligible worker to claim a job. Later it can prefer data locality, lower transfer cost, or faster turnaround.

---

## 11. Processing pipeline

### 11.1 Stage graph

```text
ingest verified
      |
      v
metadata + preview extraction
      |
      v
session segmentation
      |
      v
exact/near duplicate grouping
      |
      v
technical + human quality scoring
      |
      v
diversity-aware selection
      |
      +-------------> uncertain-choice review set
      |
      v
full-resolution edit
      |
      v
destination crop + collage generation
      |
      v
artifact validation
      |
      v
atomic result-manifest commit
```

### 11.2 Metadata and preview extraction

The worker reads:

- Pixel dimensions and orientation.
- Capture timestamp.
- Camera and lens information when available.
- Exposure parameters.
- GPS only when explicitly allowed and required.
- Embedded preview or thumbnail.
- Color profile.
- Format and codec information.

It creates a normalized preview, such as a 2,560-pixel long-edge image, for analysis. The preview retains sufficient resolution for faces and focus while reducing decode, transfer, and inference costs.

### 11.3 Session segmentation

The phone supplies an explicit session ID, but the worker may create scene subgroups using:

- Capture time gaps.
- Perceptual similarity.
- Dominant subjects or faces.
- Camera movement and framing changes.
- Capture-mode changes.

This prevents a single long venue session from being treated as one burst.

### 11.4 Duplicate and burst grouping

Grouping should combine:

- Cryptographic hashes for exact duplicates.
- Perceptual hashes for transforms or recompression.
- Image embeddings for semantic and visual similarity.
- Time proximity.
- Face-set overlap.
- Composition and camera metadata.

The service should distinguish:

- Exact duplicate.
- Near-identical burst.
- Same moment with meaningful expression change.
- Same subject but distinct composition.
- Semantically similar but independently valuable scene.

Only the first two categories are candidates for aggressive automatic reduction.

### 11.5 Quality signals

Candidate signals include:

- Global and subject-region sharpness.
- Motion blur and missed focus.
- Face and eye sharpness.
- Eyes open probability.
- Expression quality and face visibility.
- Severe underexposure or clipped highlights.
- White-balance plausibility.
- Obstruction and accidental framing.
- Subject prominence.
- Horizon and basic composition.
- Screenshot, accidental pocket shot, or unusable-frame detection.
- Venue-specific content value.

Scores should be stored as versioned structured data. A single opaque `quality_score` is insufficient for debugging and reviewer explanation.

### 11.6 Selection optimizer

Selection is not simply sorting by quality. It is a constrained optimization balancing:

- Technical quality.
- Expression and subject quality.
- Uniqueness.
- Coverage of people, activities, and moments.
- Diversity of framing and orientation.
- Destination suitability.
- Consent eligibility.
- Venue policy.
- Requested output count.

Example: if the ten individually highest-scoring images all show the same person performing the same exercise, the final set should retain fewer of them and include slightly lower-scoring images representing other participants and moments.

The optimizer should return:

- Selected images.
- Alternates associated with each selection.
- Automatic rejects with high-confidence reasons.
- Borderline images requiring optional review.
- Selection rationale codes.

### 11.7 Editing

The edit pipeline should be restrained and deterministic. Candidate operations:

- Orientation and color-space normalization.
- Exposure and contrast correction.
- Highlight recovery and shadow adjustment within safe bounds.
- White balance and tint correction.
- Lens distortion and vignetting correction where metadata/profile support exists.
- Chromatic-aberration reduction.
- Noise reduction.
- Sharpening appropriate to input and destination.
- Skin-tone protection.
- Venue-specific tone and color preset.
- Crop and horizon adjustment.
- Output-specific resize and compression.

The pipeline must avoid stacking a heavy computational-photography look on top of a phone image that is already strongly processed. Each operation should record parameters in the edit manifest.

### 11.8 Chromatic aberration

Chromatic-aberration correction is particularly relevant to imported camera JPEGs and should be implemented in two layers:

1. Apply a known camera/lens profile when metadata maps confidently to a supported profile.
2. Run a conservative content-based lateral-fringe detector near high-contrast edges when a profile is absent or incomplete.

Automatic correction must be capped to avoid desaturating legitimate colored edges, lighting, clothing, or gym signage. The system should retain a `correction_confidence` and permit venue or personal presets to disable the content-based layer.

### 11.9 Social output generation

Templates should support at minimum:

- Instagram portrait: 4:5.
- Square: 1:1.
- Story/Reel cover: 9:16.
- Landscape/web: configurable.
- Carousel sets with consistent treatment.
- Two-, three-, and four-image collages.

Crop generation must preserve protected subject regions and faces. A crop should fail into review instead of cutting through a face, hand, product, logo, or essential activity when no safe crop exists.

Text overlays, logos, and templates must respect safe areas and use venue-approved assets. The initial release should generate caption suggestions only if that feature is desired; an LLM may assist with copy, but it is not required for image selection or editing.

### 11.10 Result commit

The worker uploads artifacts under a unique `run_id`. It then uploads a manifest containing:

- Source object IDs and checksums.
- Pipeline and model versions.
- Selection decisions and reasons.
- Edit parameters.
- Artifact object IDs and checksums.
- Warnings and uncertainty.
- Processing timing.
- Worker ID.

The worker asks the control plane to commit the manifest. The control plane validates ownership, job lease, required artifacts, and object metadata in a transaction. Only after commit does the collection become available to reviewers.

---

## 12. LLM policy

An LLM is not required for the core product.

Use conventional image-processing and vision models for:

- Focus and blur.
- Exposure analysis.
- Face and eye detection.
- Expression signals.
- Image embeddings.
- Duplicate and scene grouping.
- Subject-aware crops.
- Technical corrections.
- Selection optimization.

An optional language or multimodal model may later support:

- Caption drafts.
- Content-calendar suggestions.
- Natural-language search.
- Human-readable selection explanations.
- Brand-voice adaptation.
- Detection of unusual contextual risks that simpler classifiers miss.

No core ingestion, safety, retention, or culling state transition should depend on an unavailable third-party LLM. Any generative output must be labeled internally with its provider/model version and remain reviewable.

---

## 13. Domain model

### 13.1 Core entities

#### Tenant

- `tenant_id`
- Name and billing identity.
- Default region.
- Subscription plan.
- Retention policy.
- Feature entitlements.
- Security and publishing policy.

#### Location

- `location_id`
- `tenant_id`
- Name, timezone, and brand preset.
- Capture and review configuration.
- Assigned processing region or worker pool.

#### Device

- `device_id`
- `location_id`
- Platform and hardware identity.
- Public key or credential reference.
- Application version.
- Status, health, and last heartbeat.
- Upload and cleanup policies.

#### Capture session

- `session_id`
- `location_id`, `device_id`.
- Start/end timestamps.
- Mode.
- Consent context.
- Processing status.
- Expected and received capture counts.

#### Capture

- `capture_id`
- `session_id`.
- Original object reference.
- Checksum, size, dimensions, format.
- Capture metadata.
- Upload verification state.
- Retention class and deletion deadline.
- Consent eligibility.

#### Processing job

- `job_id`
- Tenant/location/session reference.
- Type and priority.
- Required capability set.
- State and availability time.
- Attempt count.
- Lease owner and expiration.
- Pipeline version.
- Last error classification.

#### Processing run

- `run_id`
- `job_id`.
- Worker and model bundle.
- Stage statuses and timings.
- Manifest object reference.
- Commit state.

#### Asset

- `asset_id`
- Source capture or composite inputs.
- Role: preview, master, crop, collage, thumbnail.
- Object reference and checksum.
- Dimensions, format, and byte length.
- Edit and template version.
- Review state.

#### Collection

- `collection_id`
- Location and covered time period.
- Active processing run.
- Review/publish state.
- Selected asset ordering.

#### Consent context

- `consent_context_id`
- Policy version.
- Capture-flow or release method.
- Time and location applicability.
- Restrictions and revocation state.

#### Audit event

- Actor and tenant context.
- Event type.
- Target resource.
- Timestamp and request ID.
- Minimal before/after state where appropriate.
- Source IP/device/worker identifiers under retention policy.

### 13.2 Important invariants

- Every object belongs to exactly one tenant.
- A device may upload only for its assigned location.
- A worker may access only objects granted for a currently leased job.
- A capture cannot be marked verified without an existing matching object.
- A customer-visible collection must point to a committed manifest.
- Deletion must preserve audit metadata without retaining the deleted pixels.
- Consent-ineligible media cannot appear in publishable output.
- A processing retry cannot overwrite a previously committed run.

---

## 14. API outline

The exact representation may be REST, RPC, or a mixture. The important behavior is contractual.

### 14.1 Device APIs

```text
POST /v1/devices/enroll
POST /v1/devices/{device_id}/heartbeat
POST /v1/sessions
PATCH /v1/sessions/{session_id}
POST /v1/captures/upload-grants
POST /v1/captures/{capture_id}/complete
GET  /v1/devices/{device_id}/upload-state
POST /v1/devices/{device_id}/cleanup-receipts
```

`upload-grants` accepts metadata and an idempotency key, creates a pending capture, and returns either a single signed upload or multipart instructions. `complete` verifies the object before acknowledging durable ingestion.

### 14.2 Worker APIs

```text
POST /v1/workers/register
POST /v1/workers/{worker_id}/heartbeat
POST /v1/jobs/claim
POST /v1/jobs/{job_id}/lease/renew
POST /v1/jobs/{job_id}/checkpoint
POST /v1/jobs/{job_id}/artifact-grants
POST /v1/jobs/{job_id}/commit
POST /v1/jobs/{job_id}/fail
POST /v1/jobs/{job_id}/release
```

Job claims return object identifiers and short-lived access, not long-lived bucket credentials. The worker should renew grants for long jobs rather than receive multi-day access initially.

### 14.3 Portal APIs

```text
GET  /v1/locations/{location_id}/collections
GET  /v1/collections/{collection_id}
POST /v1/assets/{asset_id}/approve
POST /v1/assets/{asset_id}/reject
POST /v1/assets/{asset_id}/select-alternate
POST /v1/assets/{asset_id}/crop-adjustments
POST /v1/collections/{collection_id}/approve
POST /v1/collections/{collection_id}/export
POST /v1/collections/{collection_id}/publish
```

Media responses should generally contain short-lived signed URLs. Approval actions require optimistic concurrency so two reviewers cannot silently overwrite one another.

### 14.4 Administrative APIs

```text
GET  /v1/admin/workers
POST /v1/admin/workers/{worker_id}/revoke
GET  /v1/admin/jobs
POST /v1/admin/jobs/{job_id}/retry
POST /v1/admin/jobs/{job_id}/cancel
GET  /v1/admin/devices
POST /v1/admin/devices/{device_id}/disable
GET  /v1/admin/storage/reconciliation
POST /v1/admin/retention/preview
POST /v1/admin/retention/execute
```

Destructive administrative actions require strong authorization, audit logging, and explicit target resolution.

---

## 15. Job state machine

### 15.1 Primary states

```text
PENDING
  |
  v
AVAILABLE -----> CANCELLED
  |
  v
LEASED <------ lease expiry / retry
  |
  v
PROCESSING
  |
  +-----------> RETRY_WAIT
  |                 |
  |                 v
  |              AVAILABLE
  |
  +-----------> FAILED_TERMINAL
  |
  v
UPLOADING_RESULTS
  |
  v
VALIDATING
  |
  v
COMMITTED
```

### 15.2 Lease rules

- A claim transaction assigns `worker_id`, `lease_token`, and `lease_expires_at`.
- Only possession of the current lease token permits checkpoint, artifact grant, commit, fail, or release operations.
- The worker renews before half the lease duration has elapsed.
- A worker that loses its lease must stop customer-visible commits immediately.
- An expired job becomes claimable after a reconciliation delay.
- A late result from a former lease may upload into its unique run prefix but cannot be committed.

### 15.3 Retry classes

- **Transient network:** retry with exponential backoff.
- **Provider throttling:** honor retry hints and lower concurrency.
- **Worker resource pressure:** release with delayed availability.
- **Unsupported file:** quarantine capture and continue session if policy permits.
- **Model or renderer crash:** retry on another worker or model version, then dead-letter.
- **Integrity mismatch:** do not process; require re-upload or support review.
- **Authorization failure:** stop immediately and require credential repair.
- **Pipeline bug:** preserve diagnostic metadata without retaining local pixels longer than necessary.

---

## 16. Security and privacy

### 16.1 Encryption

- TLS for every network operation.
- Provider-managed or customer-managed encryption at rest for object storage.
- Database volume and backup encryption.
- FileVault and encrypted scratch storage on the Mac.
- Platform keychain or secure hardware-backed storage for device and worker private keys.
- Separate encryption/key-management concerns from storage-provider credentials.

Because an authorized worker must access pixels, the service should describe this accurately as encrypted in transit and at rest—not as zero-access end-to-end encryption.

### 16.2 Credential scope

- Mobile device credentials authorize metadata APIs for one device/location.
- Signed uploads are restricted to one object key, method, size range, content type, and short validity period where supported.
- Worker credentials permit claiming eligible jobs but not arbitrary bucket listing.
- Per-job download and upload grants expire quickly.
- Portal users receive role-based access within one or more tenants.
- Publishing integrations use separate revocable tokens and never share storage credentials.

### 16.3 Tenant isolation

Tenant isolation must exist at multiple layers:

- API authorization.
- Database row ownership.
- Object-key ownership checks.
- Signed-URL generation.
- Job assignment.
- Worker scratch directories.
- Logs and metrics.
- Customer exports.

Automated tests should attempt cross-tenant access for every object-bearing API.

### 16.4 Worker-site controls

A Mac processing customer media at a home or office becomes part of the production data-processing environment. Required controls include:

- Restricted physical access.
- Full-disk encryption.
- Automatic screen lock.
- Separate worker user.
- Minimal installed software.
- Security update policy.
- Firewall enabled with no public inbound service.
- No consumer backup or synchronization of scratch data.
- Central worker revocation.
- Local media purge verification.
- Incident procedure for theft or loss.

This arrangement may be acceptable for pilots, but larger customers may require a commercial facility, cloud processing, regional guarantees, or contractual security controls.

### 16.5 Consent and sensitive content

Consent design is product- and jurisdiction-dependent and requires legal review. The architecture must support:

- Venue-specific policy versions.
- Visible capture notices.
- Staff-controlled sessions.
- Subject opt-out mechanisms.
- Revocation workflow.
- Exclusion flags before publishing.
- Special treatment for minors.
- Manual report and removal.
- Location metadata stripping from public derivatives by default.

Face embeddings, if retained, may create additional biometric/privacy obligations. Prefer ephemeral face detection and session-local clustering unless persistent identity is an explicitly reviewed requirement.

### 16.6 Logging

Logs must not contain:

- Signed URLs.
- Access tokens.
- Image bytes.
- Full extracted EXIF blocks.
- Face embeddings.
- Customer captions or private notes unless necessary and governed.

Use opaque IDs and structured error codes. Debug-image retention must be off by default in production and explicitly authorized for support cases.

---

## 17. Reliability and failure handling

### 17.1 Required behavior

| Failure | Expected behavior |
|---|---|
| Venue Wi-Fi unavailable | Captures remain in encrypted phone spool and retry later |
| App terminated | Durable upload records resume under platform background rules |
| Duplicate upload request | Server returns or recreates the same logical capture safely |
| Object store temporarily unavailable | Phone/worker backs off; no local deletion |
| Mac offline | Jobs remain queued; upload intake continues |
| Mac loses power mid-job | Lease expires; run resumes or retries |
| Local SSD full | Worker stops claiming and reports degraded health |
| Oracle/control-plane VM unavailable | Existing uploads may pause authorization; no confirmed data is lost |
| Database loss | Restore from tested off-host backup; reconcile object store |
| Result upload partially completes | Uncommitted run stays invisible and is eventually cleaned |
| Bad pipeline release | Pin or roll back model/pipeline; reprocess affected runs |
| Worker credential compromised | Revoke worker and all active grants; investigate audit trail |

### 17.2 Backpressure

The system must measure queue age and stop pretending turnaround is immediate when capacity is constrained. Backpressure controls include:

- Limit job creation rate per tenant.
- Combine captures into efficient session jobs.
- Prioritize paid turnaround tiers.
- Delay nonessential derivative regeneration.
- Stop claiming new work when worker health is degraded.
- Display realistic collection readiness estimates.
- Add or enable a second worker before the backlog threatens retention or contractual targets.

### 17.3 Disaster recovery

At minimum:

- Database backups stored outside the control-plane VM.
- Configuration and infrastructure definitions versioned.
- Encryption recovery material stored securely and separately.
- Object inventory and database reconciliation tooling.
- Documented procedure for enrolling a replacement Mac.
- Regular restore exercise.
- Export of tenant configuration and manifests.

Recovery objectives should be explicit before paid launch. An early target might tolerate hours of control-plane recovery and a day of delayed processing while requiring no loss of confirmed originals.

---

## 18. Observability and operations

### 18.1 Product metrics

- Captures per location/day.
- Uploaded and verified percentage.
- Median time from capture to durable upload.
- Input-to-selection ratio.
- Images presented for manual review.
- Reviewer approval, alternate-selection, and rejection rates.
- Time spent reviewing a collection.
- Assets downloaded or published.
- Retention overrides and restore requests.

### 18.2 Worker metrics

- Heartbeat age.
- Queue age and depth.
- Jobs completed, retried, and failed.
- Stage duration distributions.
- Images processed per minute by stage.
- Preview and full-resolution decode time.
- Model-inference time.
- Render time.
- Download and upload throughput.
- Scratch disk utilization.
- Memory pressure and thermal state.
- Lease-renewal failures.
- Purge backlog.

### 18.3 Storage metrics

- Bytes by tenant and object class.
- Monthly uploaded/downloaded bytes.
- Request counts by operation class.
- Incomplete multipart bytes.
- Objects past retention deadline.
- Reconciliation mismatches.
- Estimated provider bill.

### 18.4 Alerts

Initial operator alerts:

- Worker heartbeat missing beyond threshold.
- Oldest available job exceeds turnaround target.
- Phone pending upload exceeds age threshold.
- Device free space below critical threshold.
- Object verification failures.
- Database backup missing or restore check failed.
- Scratch disk above threshold.
- Retention deletion failures.
- Sudden storage or egress cost anomaly.
- Cross-tenant authorization denial pattern.
- Dead-letter job created.

### 18.5 Operational console

The console should answer quickly:

- Are phones successfully uploading?
- Is the worker online?
- How old is the oldest unprocessed session?
- Which jobs are failing and why?
- How much media is awaiting deletion?
- What is estimated per-tenant cost?
- Can a job be retried without shell access?
- Can a compromised device or worker be revoked immediately?

---

## 19. Capacity and cost model

### 19.1 Storage formula

Let:

- `P` = captures per day.
- `S` = average original size in GB.
- `R` = original retention days.
- `K` = fraction selected.
- `D` = average derivative bytes per selected capture in GB.
- `RD` = derivative retention days or effective active-history period.

Approximate steady storage:

```text
original_gb   = P × S × R
derivative_gb = P × K × D × RD
total_gb      = original_gb + derivative_gb + thumbnails/manifests
```

For 5 MB originals and 30-day original retention:

| Captures/day | Approximate original storage |
|---:|---:|
| 100 | 15 GB |
| 300 | 45 GB |
| 1,000 | 150 GB |
| 5,000 | 750 GB |

At current headline storage rates, before free allowances and operations:

| Captures/day | Backblaze B2 | Cloudflare R2 Standard |
|---:|---:|---:|
| 300 | About $0.31/month | About $0.68/month |
| 1,000 | About $1.04/month | About $2.25/month |
| 5,000 | About $5.21/month | About $11.25/month |

These figures are directional. Actual costs include retained selected originals, derivatives, API operations, backups, failed uploads, reprocessing, support holds, and provider minimums. A cost meter based on actual object inventory and transfer logs must replace spreadsheet assumptions during the pilot.

### 19.2 Network model

Local processing moves each original through two internet legs:

1. Venue phone to object storage.
2. Object storage to Mac worker.

Results add a smaller Mac-to-storage transfer. This is economically reasonable while object-store egress is free or covered and the worker's internet connection has sufficient capacity.

Monitor:

- Operator ISP data caps.
- Mac-site download speed.
- Venue upload speed and burst congestion.
- Provider egress allowances.
- Reprocessing frequency, which may download an original more than once.

The worker should cache active job sources through completion but should not become a permanent archive.

### 19.3 Compute model

Benchmark the full pipeline on representative data:

- Low-light gym images.
- Fast motion.
- Group photographs.
- Portraits.
- Mixed Android/iOS devices.
- Large camera JPEGs.
- Sessions ranging from tens to thousands of photographs.

Measure separately:

- Preview extraction.
- Embedding inference.
- Face/eye processing.
- Clustering.
- Selection.
- Full-resolution editing.
- Social rendering.
- Network transfer.

Capacity is governed by peak queue age, not monthly average volume. A weekly event producing 3,000 images in an hour may be more demanding than a larger monthly volume distributed evenly.

### 19.4 Scaling thresholds

Add another worker or cloud capacity when any of these persists:

- Oldest queued job approaches the customer turnaround target.
- The primary worker averages more than approximately 60–70% duty cycle during required service hours.
- Maintenance cannot occur without violating turnaround expectations.
- A single worker failure creates unacceptable customer impact.
- Network transfer is the bottleneck.
- Customer contracts require geographic or facility controls the current worker site cannot provide.

Cloud processing may become preferable when orchestration, staffing, physical security, and multi-site networking cost more than elastic compute—even if the raw compute price is higher.

---

## 20. Deployment environments

### 20.1 Development

- Local API and database.
- Provider test bucket or isolated prefix.
- Mac worker in development mode.
- Synthetic and explicitly authorized test media.
- No production tenant credentials.

### 20.2 Staging

- Separate cloud project/account where possible.
- Separate buckets and encryption keys.
- One staging worker identity.
- Production-like retention with short windows.
- Pipeline canary and migration tests.
- No implicit access to production media.

### 20.3 Production pilot

- Portable control plane, optionally on Oracle Ampere Always Free.
- Off-host encrypted database backups.
- Backblaze B2 primary media store.
- Cloudflare R2 adapter tested as fallback.
- One production Mac worker plus documented replacement process.
- Administrative MFA.
- Central logs and alerts.
- Manual approval for every public publish.

### 20.4 Production growth

- Paid or managed control-plane hosting.
- Managed/replicated database.
- At least two workers or cloud overflow.
- Formal incident management.
- Regional storage and worker pools.
- Automated cost allocation.
- Tenant-level data residency controls.
- Service objectives and support escalation.

---

## 21. Build-versus-buy decisions

### 21.1 Build

- Capture application and durable local upload state.
- Tenant-aware ingestion APIs.
- Processing job contract.
- Culling, selection, and editing orchestration.
- Worker agent and manifest protocol.
- Venue review experience.
- Retention policy engine.
- Product-specific content templates and feedback loop.

### 21.2 Buy or adopt

- Object storage.
- Relational database hosting when financially justified.
- Authentication provider if it satisfies tenant and device requirements.
- Error monitoring.
- Transactional email.
- Payment and subscription infrastructure.
- Standard image codecs and metadata libraries.
- Established vision runtimes and foundation models with acceptable licenses.

### 21.3 Avoid premature infrastructure

Do not initially build:

- A custom distributed queue.
- A proprietary blob store.
- A Kubernetes deployment.
- A fleet scheduler more complex than capability-aware leases.
- A custom model-training platform.
- A global multi-region architecture.
- A permanent cloud GPU cluster.

---

## 22. Implementation phases

### Phase 0: Offline pipeline proof

**Purpose:** Prove that the output is valuable before building ingestion infrastructure.

Deliverables:

- Folder-based import on a Mac.
- Preview generation.
- Duplicate and burst grouping.
- Quality scoring.
- Diversity-aware shortlist.
- Basic edit preset.
- Instagram crops and a simple collage.
- HTML or local review report.
- Benchmark harness and labeled evaluation set.

Exit criteria:

- Test users prefer the selected set to a chronological sample.
- High-confidence automatic rejects have an acceptably low unique-moment loss rate.
- A representative session completes within the provisional turnaround target.

### Phase 1: Durable cloud ingestion

Deliverables:

- Android capture application.
- App-private durable spool.
- Device enrollment.
- Signed direct uploads to B2.
- Upload verification and safe local cleanup.
- Session and capture records.
- Basic device-health console.

Exit criteria:

- Captures survive app restart, reboot, Wi-Fi loss, and duplicate completion calls.
- No test capture is locally deleted before server verification.
- Storage reconciliation reports no unexplained objects.

### Phase 2: Remote Mac worker

Deliverables:

- Worker registration.
- PostgreSQL-backed queue.
- Job leases and heartbeats.
- Short-lived per-job object grants.
- Encrypted scratch workflow.
- Checkpointed processing.
- Idempotent artifact upload and atomic manifest commit.
- Worker health dashboard.

Exit criteria:

- Killing the worker at each pipeline stage results in a correct retry.
- Another enrolled worker can complete an abandoned job.
- The Mac can be replaced without data migration.

### Phase 3: Customer review product

Deliverables:

- Daily and weekly collections.
- Best-of view and optional alternates.
- Approval, rejection, and crop adjustment.
- Download package.
- Social dimensions and branded templates.
- Retention settings.
- Audit trail.

Exit criteria:

- A venue manager can review a week of content in a few minutes.
- The majority of selected images are approved without edit changes.
- Rejected source recovery works inside the grace window.

### Phase 4: Paid pilot

Deliverables:

- Subscription entitlements.
- Usage and cost metering.
- Backups and restore runbook.
- Operator alerts.
- Device replacement flow.
- Consent and removal workflow reviewed by counsel.
- Customer data export and account closeout.

Exit criteria:

- Multiple venues operate without cross-tenant leakage.
- Turnaround and reliability are measurable.
- Gross-margin assumptions use actual storage, network, support, and compute data.

### Phase 5: Resilience and scale

Deliverables:

- Second worker or cloud overflow worker.
- Managed database migration.
- Multiple storage regions/providers if needed.
- Automated canary pipeline rollout.
- Formal service objectives.
- Publishing integrations under explicit approval policy.

---

## 23. Testing strategy

### 23.1 Mobile tests

- Capture during no connectivity.
- Reboot with pending uploads.
- App update with a nonempty spool.
- Multipart interruption and resume.
- Duplicate submission.
- Corrupt local file.
- Expired signed URL.
- Storage pressure with confirmed and unconfirmed media.
- Device clock skew.
- Credential revocation.

### 23.2 Worker tests

- Process termination during every stage.
- Lease expiry and competing worker claim.
- Disk full.
- Object checksum mismatch.
- Unsupported or malicious file.
- Excessive dimensions/decompression bomb protections.
- Network loss during download and upload.
- Model initialization failure.
- Pipeline version mismatch.
- Invalid output artifact.
- Cleanup after success and failure.

### 23.3 Culling evaluation

Create consented benchmark sessions with human labels for:

- Exact duplicates.
- Burst membership.
- Best expression.
- Eye state.
- Focus failure.
- Unique moment importance.
- Desired representative set.
- Venue publishability.
- Crop safety.

Important metrics:

- Unique-moment false-reject rate.
- Duplicate reduction rate.
- Top-selection human preference.
- Coverage of distinct people/scenes.
- Reviewer correction rate.
- Percentage of sessions requiring expansion into rejects.

False rejection of a unique, valuable moment should be weighted much more heavily than retaining one extra near-duplicate.

### 23.4 Security tests

- Cross-tenant object access attempts.
- Reuse of expired or completed signed URLs.
- Device impersonation.
- Worker credential revocation.
- Unauthorized manifest commit.
- Object-key injection.
- Malicious metadata and filename handling.
- Oversized upload and content-type mismatch.
- Portal role escalation.
- Audit-log secret scanning.

### 23.5 Recovery tests

- Restore database to a clean host.
- Enroll a replacement worker.
- Rebuild customer collection state from database and manifests.
- Reconcile object-store inventory.
- Recover a recently rejected original.
- Verify expiry of an object past its grace period.

---

## 24. Acceptance criteria for the first end-to-end release

### Capture and upload

- A managed phone can capture at least 1,000 photographs across intermittent connectivity without losing durable queue state.
- Confirmed captures are uploaded directly to object storage without traversing the application server.
- Duplicate upload completion does not create duplicate logical captures.
- Local deletion never occurs before server verification and configured grace time.
- Operators can see device status and pending upload age.

### Worker

- A registered Mac can claim, process, and commit a session without inbound firewall configuration.
- Worker interruption at any pipeline stage produces a correct resume or retry.
- Revoking a worker prevents new job claims and invalidates renewable access.
- Local job media is purged after successful completion according to policy.
- No customer collection becomes visible before manifest validation.

### Culling and editing

- Exact duplicates are removed with no known false removals in the acceptance set.
- Near-duplicate bursts are reduced while retaining distinct expressions and compositions.
- The selected set respects configured output count and diversity constraints.
- Editing produces consistent, restrained results across representative lighting conditions.
- Social crops preserve protected faces and subjects or enter review.
- Selection reasons and pipeline versions are available for support diagnostics.

### Security and privacy

- Every object access is tenant-authorized.
- No permanent storage credentials exist in a mobile build or worker job payload.
- Storage, database backups, phones, and Mac scratch data are encrypted at rest.
- Customer media is absent from normal application logs.
- A tenant deletion request can be executed and audited across originals, derivatives, and metadata policy.

### Operations

- Database restore has been executed successfully from an off-host backup.
- Object-storage reconciliation completes and reports explainable results.
- Alerts fire for worker outage, old jobs, failed backups, and critical device storage.
- Per-tenant storage and processing usage can be estimated from measured records.

---

## 25. Key risks and mitigations

### 25.1 Local worker availability

**Risk:** Power, ISP, hardware, or OS failure delays every customer.

**Mitigation:** Durable queue and objects, conservative turnaround promise, UPS, monitoring, replacement procedure, and second worker before broader launch.

### 25.2 Free-tier dependence

**Risk:** Oracle capacity is unavailable, reclaimed, or policy changes.

**Mitigation:** Portable deployment, off-host backups, infrastructure automation, and a budgeted paid-host fallback.

### 25.3 Egress economics

**Risk:** Reprocessing or repeated downloads exceed storage-provider allowances.

**Mitigation:** Measure bytes by purpose, process originals once where possible, cache during an active run, retain reusable previews, support R2, and route delivery separately when economics justify it.

### 25.4 Incorrect culling

**Risk:** The system discards the only photograph of a meaningful moment.

**Mitigation:** Conservative confidence thresholds, grace-period retention, scene coverage constraints, alternates, and an explicit unique-moment loss metric.

### 25.5 Privacy at the operator site

**Risk:** Customer media is exposed on the Mac or through backups.

**Mitigation:** Encrypted isolated worker account, no consumer synchronization, strict purge, physical controls, access logs, and eventual migration for customers with stronger requirements.

### 25.6 Phone upload restrictions

**Risk:** Mobile OS background limits delay uploads.

**Mitigation:** Durable spool, platform-native background-transfer APIs, visible health, charging-dock assumptions, foreground catch-up, and realistic status messages.

### 25.7 Provider lock-in

**Risk:** Storage pricing or terms become unfavorable.

**Mitigation:** Logical blob IDs, S3-compatible adapter, no provider URLs in persistent customer records, inventory export, and tested copy/migration tooling.

### 25.8 Uncontrolled editing aesthetic

**Risk:** Automatic edits look inconsistent or artificial.

**Mitigation:** Restrained versioned presets, bounded corrections, venue calibration set, before/after QA, and rollback by pipeline version.

---

## 26. Product and architectural decisions

### Decision 1: Direct-to-object-storage uploads

**Chosen:** The mobile app uploads media using short-lived signed grants.  
**Reason:** Removes image bandwidth from the API server, reduces cost, and improves scalability.  
**Consequence:** Upload completion and integrity verification require a careful two-step protocol.

### Decision 2: Backblaze B2 as initial primary storage

**Chosen:** Use B2 for the first implementation, behind an adapter.  
**Reason:** Very low storage cost and an egress allowance suited to approximately one processing download per original.  
**Consequence:** Usage must be monitored; workloads with repeated egress may move to R2.

### Decision 3: Mac as an outbound worker

**Chosen:** The Mac claims jobs from the cloud and is never publicly addressed.  
**Reason:** Simplifies networking and security while making local Apple Silicon useful.  
**Consequence:** Processing pauses while the worker is offline, so storage and queue durability are mandatory.

### Decision 4: Oracle is optional coordination infrastructure

**Chosen:** Oracle Always Free may host the pilot API and queue but is not a required dependency.  
**Reason:** It can reduce early fixed costs.  
**Consequence:** Portability, backup, and a paid fallback must exist from the beginning.

### Decision 5: PostgreSQL job queue first

**Chosen:** Use leased rows for initial job orchestration.  
**Reason:** Reduces infrastructure during the pilot.  
**Consequence:** Queue operations need disciplined transactions and an upgrade path when scale demands it.

### Decision 6: No LLM in the critical culling path

**Chosen:** Use vision models, image processing, and explicit optimization.  
**Reason:** Better latency, determinism, cost, privacy, and offline compatibility for the actual signals.  
**Consequence:** Language features are separate optional services.

### Decision 7: JPEG/HEIC-first venue capture

**Chosen:** Do not capture RAW by default.  
**Reason:** Venue content benefits more from throughput and storage efficiency than maximal editing latitude.  
**Consequence:** Editing must work within already-processed phone imagery and avoid aggressive recovery.

---

## 27. Open questions

### Product

- What is the promised turnaround: minutes, same day, or next morning?
- Does each venue want continuous daily processing or scheduled content batches?
- How many final images should a typical day or week contain?
- Are customer reviewers approving assets only, or also captions and scheduled posts?
- How long should selected and rejected originals remain recoverable at each subscription tier?

### Capture

- Is the first device always venue-owned, enrolled, and charging?
- Will participants use the same device unattended, or will staff supervise it?
- Is in-app consent sufficient for the intended venues and jurisdictions?
- Should the app support short video in the first year?
- Should HEIC be retained or normalized to JPEG during ingestion?

### Processing

- Which exact Apple Silicon hardware will serve the pilot?
- What throughput does the representative benchmark show?
- Which vision and editing models have acceptable commercial licenses?
- How should the selection objective balance people coverage versus pure aesthetics?
- When does a low-confidence session require a human operator rather than venue review?

### Infrastructure

- Does the operator's ISP impose monthly caps or prohibit server-like commercial use?
- Is B2's effective egress allowance sufficient after retries and reprocessing?
- Should the database begin on Oracle or on a small managed provider for lower operational risk?
- What paid fallback host is preapproved if Oracle capacity becomes unavailable?
- At what queue-age threshold should a cloud overflow worker activate?

### Security and legal

- Are persistent face embeddings needed at all?
- What are the applicable biometric, publicity, employment, and minor-consent rules?
- What contractual data-residency promises will be made?
- What breach-notification and deletion-response timelines are required?
- Is processing at an operator-controlled residential location acceptable to pilot customers?

---

## 28. Recommended immediate next steps

1. Build the offline Mac pipeline and benchmark it on realistic gym and group-event sessions.
2. Measure selection quality with special emphasis on unique-moment false rejection.
3. Create the storage abstraction and implement B2 plus a basic R2 compatibility test.
4. Prototype signed direct upload and verified completion from one Android device.
5. Implement a leased PostgreSQL job and a minimal Mac worker heartbeat.
6. Prove interruption recovery by killing the worker during every pipeline stage.
7. Add retention simulation before enabling any automatic cloud deletion.
8. Run a one-location pilot while manually reviewing every generated collection.
9. Record actual bytes, processing time, corrections, and reviewer behavior.
10. Decide whether the second production worker should be another Mac or cloud overflow based on measured queue shape and reliability—not intuition.

---

## 29. Final recommendation

Build the first sellable version as a hybrid platform:

- A dedicated venue capture application owns capture state and upload reliability.
- Backblaze B2 stores originals and results durably at low cost.
- A lightweight, portable cloud control plane coordinates tenants, uploads, jobs, retention, and review.
- Oracle's free Ampere compute may host that control plane during the pilot, provided backups and a migration path exist.
- An encrypted, monitored Mac mini performs culling, editing, and content generation over outbound HTTPS.
- The review portal exposes a small, high-quality collection and keeps public publishing human-approved.

This is not merely a cheap prototype shortcut. If the worker protocol, object model, and queue are designed correctly, local compute becomes one interchangeable execution tier. The same product can later add a second Mac, a colocated appliance, or elastic cloud workers without rewriting the capture applications or customer experience.

The core technical promise should be:

> A capture is durable before the phone releases it, a processing worker is always replaceable, and no result becomes visible until its complete, verifiable manifest is committed.

