# Venue Photo Content Service

## Product, Platform, and Subscription Specification

**Status:** Draft 1  
**Date:** September 7, 2026  
**Working title:** Venue Content Loop  
**Initial vertical:** Independent gyms and fitness studios  
**Business model:** Per-location software subscription with optional managed hardware  
**Capture platform:** Managed Android phone, initially validated with Google Pixel  
**Processing model:** Cloud-hosted, tenant-isolated, human-approved publishing  
**Related product:** [Local Photo Curator](./local-photo-curator-spec.md)

---

## 1. Executive summary

Venue Content Loop is a business-to-business subscription service that turns photographs captured throughout a venue's normal day into a small set of edited, branded, publish-ready content.

The initial customer is a gym that wants regular, authentic social content but does not have a dedicated photographer or social media employee. The gym places a managed Google Pixel in a visible charging dock. Staff or members use a purpose-built camera interface to capture workouts, classes, group photographs, coach demonstrations, and community moments. The phone uploads the photographs when network conditions permit. The service groups and culls repetitive images, selects the strongest representative moments, performs restrained edits, and creates ready-to-review deliverables such as:

- A daily or weekly highlight gallery.
- Instagram feed images.
- Carousel candidates.
- Story and Reel-cover crops.
- Branded collages.
- Website and newsletter images.
- Caption and post-package suggestions.

The venue's authorized reviewer approves, rejects, edits, downloads, schedules, or publishes the results. Public posting is never the default action immediately after capture.

The value proposition is:

> Fresh, authentic venue content without hiring a photographer, reviewing hundreds of images, or spending hours resizing and assembling posts.

The product reuses the culling, confidence, selection, editing, and model-evaluation foundation of Local Photo Curator. It adds a managed Android capture application, multi-tenant cloud infrastructure, consent and release tracking, brand-aware content generation, approval workflows, retention controls, billing, and social-platform integrations.

This is a credible adjacent product, not a replacement for the consumer local application. The two products should share an image-intelligence core while maintaining separate user experiences and data-handling architectures.

---

## 2. Product thesis and recommendation

### 2.1 Why this could be sellable

The customer is not buying AI culling. The customer is buying a reliable supply of usable marketing content with low staff effort.

The strongest outcome statement is:

> “Your venue produces a week of on-brand content while your staff continues running the business.”

The service is valuable when it removes four operational burdens:

1. Remembering to capture content.
2. Moving photos off a shared device.
3. Reviewing repetitive or poor photographs.
4. Preparing correct formats, layouts, and captions for publishing.

The product is less compelling if it merely creates a shared photo folder. Google Photos, Drive, Dropbox, and other services already move files. The differentiated product must deliver a small, attractive, consent-cleared, brand-ready content queue.

### 2.2 Recommended product shape

Build a dedicated capture application rather than relying on the stock Pixel Camera plus Google Photos synchronization.

A custom capture application provides:

- A clear consent or release step.
- Venue and device identity.
- Capture-session boundaries.
- Reliable upload state.
- Checksums and resumable transfer.
- Local storage-pressure management.
- Kiosk behavior.
- Restricted access to other venue/customer data.
- Immediate private claim/download links.
- Remote device health.
- Direct association between source images, permissions, and processing jobs.

The stock Camera application can remain an optional early prototype input, but it should not be the production control plane.

### 2.3 Recommended storage architecture

Use service-controlled object storage as the primary ingestion destination. Support Google Drive as an optional import/export and customer archive integration.

Do not make Google Photos the primary processing source. Since March 31, 2025, the Google Photos Library API generally limits listing and retrieval to app-created content; access to a user's full library requires explicit selection through the Picker API. Uploading app-created content remains possible, but the resulting workflow adds policy and API constraints without improving reliable ingestion. See [Google Photos API changes](https://developers.google.com/photos/support/updates).

Google Photos can free space occupied by safely backed-up media, and Pixel's Smart Storage can clear backed-up photos when storage is low. Those behaviors are useful as a consumer fallback, but a managed venue service should maintain its own verified upload and deletion state. See [Google Photos Free up space](https://support.google.com/photos/answer/6128843) and [Pixel Smart Storage](https://support.google.com/pixelphone/answer/2840863).

### 2.4 Publishing recommendation

Generate publish-ready assets automatically, but require venue approval before the first public posting workflow. Later, allow scheduled auto-publishing only for explicitly approved templates, sources, consent states, accounts, and content policies.

Meta's official Instagram API supports content publishing for professional accounts. Current API documentation requires appropriate business permissions, and media must be accessible to Meta during publishing. Carousel posts support up to ten media items and use a shared crop behavior based on the first item. These constraints must be implemented through a versioned platform adapter rather than hard-coded throughout the product. See [Meta's official Instagram API collection](https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api).

---

## 3. Product family strategy

### 3.1 Product A: Local Photo Curator

Audience:

- Individual photographers.
- Enthusiasts and families.
- Local-only privacy preference.
- DSLR, mirrorless, card, and folder workflows.

Business model candidates:

- Paid application.
- Individual subscription for continuous model and compatibility updates.
- Optional one-time purchase with paid major upgrades.

### 3.2 Product B: Venue Content Loop

Audience:

- Gyms and fitness studios.
- Community venues.
- Activity businesses.
- Hospitality and experience operators.
- Multi-location brands.

Business model:

- Monthly subscription per location.
- Usage allowance based on active stations, monthly captures, or generated content packs.
- Optional device rental, installation, brand setup, and managed publishing.

### 3.3 Shared capabilities

- Image decoding and metadata normalization.
- Exact and near-duplicate detection.
- Moment and burst grouping.
- Technical-quality assessment.
- Face and subject quality assessment.
- Aesthetic and uniqueness scoring.
- Mode-aware ranking.
- Coverage-aware selection.
- Decision confidence and reason codes.
- Editing recipes.
- Lens and chromatic-aberration correction.
- Crop and output composition.
- Model evaluation and regression datasets.

### 3.4 Product-specific capabilities

| Capability | Local Photo Curator | Venue Content Loop |
|---|---|---|
| Primary compute | User's Mac | Cloud workers, optional edge preprocessing |
| Primary storage | User-managed local storage | Tenant-isolated service storage |
| Capture | Camera/card/folder | Managed Android station and uploads |
| Identity | Single local user | Organizations, locations, devices, roles |
| Consent | User owns personal workflow | Capture, subject, marketing, and public-use states |
| Output | Personal albums | Branded marketing content packages |
| Publishing | Export | Approval, scheduling, and platform adapters |
| Billing | Individual | Per-location subscription and usage |
| Retention | Local user policy | Contractual tenant and subject-request policy |
| Support | Self-service | Device health and operational support |

### 3.5 Codebase strategy

Share portable model formats, feature schemas, evaluation tools, decision reason codes, editing-recipe schemas, and algorithmic test fixtures. Do not force the consumer application and SaaS backend into the same deployment runtime.

Recommended boundaries:

- `image-intelligence-spec`: Shared schemas and model contracts.
- `culling-evaluation`: Shared offline evaluation harness.
- `mac-curator`: Native consumer application.
- `android-capture`: Venue capture application.
- `venue-control-plane`: Multi-tenant API and workflow orchestration.
- `media-workers`: Containerized analysis, rendering, and composition workers.
- `venue-dashboard`: Browser-based review and administration interface.

---

## 4. Target customer and user roles

### 4.1 Initial customer profile

An independent gym or fitness studio with:

- One to five locations.
- An active Instagram business or creator account.
- Frequent classes or community activity.
- Limited time for content creation.
- Staff willing to encourage capture but not perform editing.
- A visually identifiable venue or brand.
- A need for authentic member/community content.

The best pilot customer already wants more content and posts inconsistently because the workflow is burdensome. A customer with no interest in marketing will not become successful merely because a camera is installed.

### 4.2 Buyer

- Owner.
- General manager.
- Marketing manager.
- Franchise operator.

Buyer goals:

- Publish consistently.
- Show an active, welcoming community.
- Reduce agency or photographer expense.
- Increase trials, retention, and event awareness.
- Maintain brand quality.
- Avoid privacy or posting mistakes.

### 4.3 Venue administrator

Responsibilities:

- Configure location and brand kit.
- Select retention and consent policy.
- Invite staff.
- Connect social accounts.
- Review audit and device health.
- Manage subscription and usage.

### 4.4 Content reviewer

Responsibilities:

- Review daily/weekly selections.
- Confirm consent state.
- Choose crops and collages.
- Edit captions.
- Approve, schedule, publish, or download.

### 4.5 Staff operator

Responsibilities:

- Return the phone to its dock.
- Begin a staff-led capture session.
- Confirm event/class context.
- Report device or consent issues.
- Optionally flag important captures.

### 4.6 Member or guest photographer

Capabilities:

- Start a self-serve session.
- Read and accept the capture notice.
- Take photographs.
- Review or retake before upload when policy permits.
- Receive a private claim link or QR code.
- Grant or decline venue marketing use.

The member must not gain access to prior members' images, administrative controls, social accounts, or the general venue gallery.

---

## 5. Service concept

### 5.1 Core service loop

```text
Capture at venue
      ↓
Local encrypted spool
      ↓
Verified resumable upload
      ↓
Session and moment grouping
      ↓
Aggressive quality-aware culling
      ↓
Brand-aware editing
      ↓
Content-pack generation
      ↓
Venue approval
      ↓
Download, schedule, or publish
      ↓
Retention and deletion
```

### 5.2 Daily venue outcome

At the end of a day, the dashboard might report:

- 286 photographs captured.
- 43 distinct moments.
- 31 selected edited photographs.
- 8 images awaiting consent clarification.
- 4 post packages ready for review.
- 1 carousel ready.
- 3 Story crops ready.
- 2 private member galleries created.

The venue should not be asked to review 286 files.

### 5.3 Subscription outcome

The subscription should promise an operational result rather than unlimited storage:

- A predictable number of processed captures.
- A predictable number of generated content packs.
- A review queue requiring minutes, not hours.
- Ongoing camera/device monitoring.
- Current social output templates.
- Brand consistency.
- Secure retention and deletion.

---

## 6. Capture station specification

### 6.1 Hardware

Initial reference kit:

- Supported Google Pixel phone with adequate local storage.
- Secure, aligned charging dock or wall/desk mount.
- Continuous power.
- Stable venue Wi-Fi.
- Optional compact light with fixed color temperature.
- Optional marked floor position or branded backdrop.
- Physical signage adjacent to the device.
- Optional security tether.

The quality and positioning of the light, background, and mount may improve content more than upgrading between adjacent phone models.

### 6.2 Wireless charging considerations

Wireless charging is convenient for pick-up/return behavior, but continuous charging, high display brightness, camera use, and background upload can create heat. The production station should:

- Verify alignment and charging state.
- Monitor battery temperature and charge state.
- Reduce background processing under thermal pressure.
- Dim or turn off the display when docked and idle.
- Prefer upload while charging and on unmetered Wi-Fi.
- Alert the administrator when charging is intermittent.
- Support a wired dock option for higher reliability.

Wireless charging should be supported, not required.

### 6.3 Android dedicated-device mode

Production devices should be enrolled as fully managed or otherwise administered dedicated devices. Android lock task mode can restrict a device to an allowlisted application or set of applications, hide system navigation, and prevent ordinary users from accessing unrelated device functions. See [Android lock task mode](https://developer.android.com/work/dpc/dedicated-devices/lock-task-mode) and [dedicated-device guidance](https://developer.android.com/work/dpc/dedicated-devices).

Minimum controls:

- Launch capture application after boot.
- Restrict access to settings, accounts, notifications, and other apps.
- Prevent account addition and factory reset by public users.
- Keep an administrator exit path.
- Remotely report app version, storage, charging, connectivity, last upload, and last heartbeat.
- Permit remote configuration updates.
- Avoid displaying customer OAuth credentials or venue account details.

### 6.4 Capture application modes

#### Self-serve

Member starts a private session, acknowledges the notice, captures photographs, optionally retakes, and receives a claim link.

#### Staff session

Staff selects a class, event, coach, or purpose and captures continuously. Consent status may come from an event/class roster or separate venue process, subject to customer policy and legal review.

#### Quick capture

Authorized staff bypasses member claim flow but still selects a content purpose and confirms that the venue's capture policy applies.

#### Booth mode

Phone remains mounted. A timer, remote trigger, or large shutter control captures individuals or groups against a known background.

### 6.5 Capture interface

The public interface should include only:

- Live camera preview.
- Clear venue branding.
- Large shutter button.
- Front/rear camera control if allowed.
- Timer.
- Optional short burst.
- Retake/delete-this-session.
- Consent/usage indicator.
- Finish session.

Exclude:

- General photo gallery.
- Device settings.
- Other users' sessions.
- Social credentials.
- Administrative dashboards.
- Unnecessary editing controls.

### 6.6 Session start

A self-serve session begins with a concise layered notice:

1. What is captured.
2. Where it is uploaded.
3. How long source images are retained.
4. Whether the user is requesting a private copy only or allowing venue marketing use.
5. How to request deletion.
6. Special handling for minors.

The user makes an affirmative selection before capture:

- **Private copy only**.
- **Venue may use approved photos for marketing**.

This distinction is stored per session and propagated to every derivative.

### 6.7 Session completion

On Finish:

- Stop capture.
- Display the number of photographs.
- Permit removal of individual images before upload if policy allows.
- Generate a short-lived, high-entropy claim QR/link for the session.
- Show marketing permission state.
- Clear previews and return to the attract screen after timeout.

The claim link must expose only the relevant session and must not reveal sequential identifiers.

### 6.8 Shared-subject warning

The person operating the camera may not have authority to grant marketing permission for every person visible in a group photograph. Group sessions require one or more of:

- Staff confirmation tied to an event release process.
- Individual subject release collection.
- A policy that keeps group photos private until a reviewer confirms authorization.
- Face blurring or exclusion for non-cleared subjects where appropriate.

The system must never infer consent from presence, a smile, gym membership, or use of the camera by another participant.

---

## 7. Device storage and upload design

### 7.1 Local spool

Every capture first enters an application-controlled local spool.

Asset states:

```text
CAPTURED
  → CHECKSUMMED
  → QUEUED
  → UPLOADING
  → UPLOADED
  → SERVER_VERIFIED
  → LOCAL_RETENTION
  → LOCAL_DELETED
```

The application must not delete the local source until the server confirms the expected checksum and durable-object state.

### 7.2 Upload behavior

Requirements:

- Resumable, chunked upload.
- Idempotency key per asset.
- Exponential backoff with jitter.
- Wi-Fi preference.
- Charging preference.
- Pause under thermal or storage-pressure conditions when capture safety requires it.
- Resume after reboot.
- Duplicate upload detection.
- Progress and failure visibility in administrator mode.
- No public object URLs during ingestion.

Android WorkManager supports constraints such as unmetered network, charging, battery-not-low, and storage-not-low, and supports retryable background work. See [Android WorkManager constraints](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work) and [background transfer guidance](https://developer.android.com/develop/background-work/background-tasks/data-transfer-options).

For continuous or large backlogs, design around Android's current background execution rules rather than assuming an indefinitely running service.

### 7.3 Storage thresholds

Illustrative defaults:

- Below 60% used: Normal operation.
- 60–75% used: Prioritize upload and local cleanup of verified assets.
- 75–85% used: Warn administrator and reduce optional local retention.
- Above 85% used: Preserve capture headroom, block nonessential downloads, and remove oldest server-verified local sources according to policy.
- Above 95% used: Enter capture-protection mode and clearly report the condition.

Actual thresholds should be configurable and validated across supported devices.

### 7.4 Google Drive option

Google Drive can be supported in two ways:

#### Drive as customer archive/export

Recommended. The service exports selected originals, finished galleries, or content packs into a customer-selected Drive folder.

Advantages:

- Customer retains familiar access.
- Clear separation between processing storage and customer archive.
- The service controls ingest reliability.
- Customers can use existing retention and collaboration workflows.

#### Drive as ingestion source

Supported for pilots or customers with existing workflows. A phone uploader places source files into an authorized Drive folder; the SaaS detects new files and imports them.

Disadvantages:

- Additional OAuth and account-support burden.
- Extra download path before processing.
- More complex idempotency and deletion semantics.
- Drive quota and folder-ownership complications.
- Harder device-fleet health visibility.

Google Drive supports resumable uploads that can continue after interruption. See [Google Drive resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads).

### 7.5 Google Photos option

Google Photos may be offered as a user-facing backup destination for app-created results, but should not be the system of record.

Reasons:

- Library API access is focused on app-created content.
- Full-library access requires user-mediated selection.
- Sharing APIs and scopes changed materially in 2025.
- Storage cleanup and service processing would have separate state machines.
- Business audit, consent, and derivative lineage are better controlled in the service.

---

## 8. Cloud platform architecture

### 8.1 High-level architecture

```text
Managed Android station
        ↓
Regional ingest API
        ↓
Tenant-isolated object storage
        ↓
Event and job queue
        ↓
Metadata + preview workers
        ↓
Session/moment grouping
        ↓
Culling and confidence engine
        ↓
Editing and brand rendering
        ↓
Content composition engine
        ↓
Review and approval dashboard
        ↓
Drive export / download / social publishing
```

### 8.2 Services

#### Identity and tenancy

- Organizations.
- Locations.
- Users and roles.
- Devices.
- Billing accounts.
- Feature entitlements.

#### Device control plane

- Enrollment.
- Configuration.
- Heartbeats.
- Application version.
- Storage and thermal status.
- Remote commands with audit logs.
- Revocation.

#### Ingest service

- Short-lived device credentials.
- Upload-session creation.
- Signed multipart/resumable upload.
- Checksums.
- Idempotency.
- Malware/format validation.
- Tenant routing.

#### Media catalog

- Source and derivative lineage.
- Capture sessions.
- Consent states.
- Retention deadlines.
- Processing status.
- Review and publish states.

#### Analysis workers

- Preview generation.
- Exact and near-duplicate detection.
- Technical-quality analysis.
- Face and subject analysis.
- Aesthetic and uniqueness features.
- Moment grouping.
- Culling.

#### Editing workers

- Brand look.
- Exposure and color.
- Noise and sharpening.
- Lens/fringe correction where relevant.
- Crop candidates.
- Export rendering.

#### Composition workers

- Platform formats.
- Collages.
- Carousels.
- Story sequences.
- Logo, text, and safe-area placement.
- Caption briefs.

#### Workflow orchestrator

- Idempotent stage transitions.
- Retry policy.
- Dead-letter queue.
- User approval gates.
- Publishing schedule.

#### Customer dashboard

- Review.
- Approval.
- Brand configuration.
- Device health.
- Consent/deletion requests.
- Billing and usage.

### 8.3 Multi-tenant isolation

Requirements:

- Tenant identifier on every resource and job.
- Separate object prefixes or buckets according to security design.
- No cross-tenant queries without audited support tooling.
- Per-tenant encryption context where feasible.
- Tenant-scoped signed URLs.
- Short URL expiration.
- Role-based access control.
- Environment and region separation.
- Automated isolation tests.

### 8.4 Processing regions

The initial service may use one supported region, but region must be represented explicitly in tenant configuration and data lineage. Enterprise and international expansion may require regional storage and processing commitments.

### 8.5 Worker strategy

Use a two-pass pipeline:

#### Fast pass

- Metadata.
- Preview.
- Checksums.
- Similarity embedding.
- Faces/subjects.
- Technical metrics.
- Moment grouping.
- Preliminary cull.

#### Finalist pass

- Higher-resolution subject focus.
- Detailed artifact checks.
- Edit recipe.
- Crop variants.
- Full-resolution render.

Only selected and review-candidate images require expensive full-resolution rendering.

---

## 9. Venue culling intelligence

### 9.1 Venue-specific objective

The venue service should not simply choose the most aesthetically pleasing photographs. It should create a useful marketing set that is attractive, representative, safe to use, and not repetitive.

Selection value includes:

```text
technical quality
+ expression and action quality
+ venue/brand relevance
+ participant and class coverage
+ visual diversity
+ content-format usefulness
+ consent readiness
- repetition
- privacy or safety risk
```

Consent readiness is a workflow property, not an aesthetic score. A beautiful image without adequate permission cannot enter a public content pack.

### 9.2 Capture-session boundaries

The station provides explicit session boundaries. The backend additionally detects:

- Separate bursts within a session.
- Class or activity transitions.
- Changes in room/background.
- Staff-led versus self-serve capture.
- Very long sessions that should be split.

### 9.3 Venue modes

#### Community day

- Favor energy, smiles, interactions, and variety.
- Represent multiple groups and activities.
- Avoid returning only the most camera-comfortable participants.

#### Class highlights

- Preserve warm-up, instruction, main activity, effort, and finish.
- Prefer clear action and safe-looking frames.
- Avoid claiming to evaluate exercise form or medical safety.
- Provide coach and class-wide coverage.

#### Coach content

- Prioritize clear subject isolation, demonstration stages, and brand context.
- Retain multiple compositions suitable for captions and overlays.

#### Member moment

- Prioritize the participant's private gallery first.
- Public-marketing candidates require explicit permission and review.
- Avoid appearance ranking as the primary criterion.

#### Facility and equipment

- Favor clean composition, space, lighting, and equipment visibility.
- Reduce face-analysis weight.
- Create website and announcement formats.

#### Event recap

- Emphasize story coverage across time.
- Retain arrivals, activities, groups, details, awards, and closing moments.

### 9.4 Technical analysis

- Motion blur relative to intended subject.
- Low-light noise.
- LED flicker and banding.
- Mirror reflections and accidental photographer inclusion.
- Harsh overhead lighting.
- Mixed color temperature.
- Backlit windows.
- Face and eye quality.
- Occlusion.
- Awkward body truncation.
- Screens or documents containing sensitive information.
- Visible bystanders without public-use permission.

### 9.5 Participant coverage without persistent identification

Within a capture session or short event window, ephemeral face clustering may help avoid selecting twenty images of one participant and none of others.

Default restrictions:

- Do not identify or name people.
- Do not match people across days or locations.
- Do not create attendance records.
- Do not infer membership, health, demographic attributes, or identity.
- Delete ephemeral face embeddings after selection or within a short documented interval.
- Permit customers to disable face clustering entirely.

Persistent recognition is outside the initial product and requires separate legal, privacy, security, and product justification.

### 9.6 Selection tiers

Every capture is classified into one of:

- `PRIVATE_SELECTED`: Good private-session result.
- `PUBLIC_CANDIDATE`: Quality and consent state permit marketing review.
- `REVIEW_REQUIRED`: Quality, consent, or content risk needs human judgment.
- `PRIVATE_ONLY`: Not eligible for public content under captured permission.
- `HIDDEN_REDUNDANT`: Duplicate or weaker alternative.
- `HIDDEN_TECHNICAL`: Severe technical failure.
- `QUARANTINED`: Policy, safety, or moderation concern.

Quality selection must never override consent classification.

### 9.7 Review confidence

Route to review when:

- Multiple faces have different best frames.
- Consent does not cover every visible subject.
- A minor may be present.
- A mirror introduces additional people.
- An image may reveal health, membership, schedule, access, or personal information.
- The culling models disagree.
- The image is strong but unusual.
- A logo or caption crop could create an awkward or misleading composition.

---

## 10. Editing and brand system

### 10.1 Editing goals

- Make mixed daily capture look coherent.
- Handle difficult gym lighting.
- Preserve natural skin tones.
- Produce consistent contrast and color.
- Prepare multiple aspect ratios safely.
- Avoid unrealistic body or face manipulation.

### 10.2 Base edit pipeline

- Orientation and color profile.
- Lens/fringe correction.
- Mixed-light white balance.
- Exposure normalization.
- Highlight and shadow control.
- LED banding detection and limited correction.
- Skin-tone protection.
- Noise reduction.
- Output-aware sharpening.
- Straightening.
- Crop candidates.
- Brand look.

### 10.3 Prohibited default edits

- Body reshaping.
- Muscle enhancement.
- Face reshaping.
- Skin-color alteration beyond neutral color correction.
- Removal of people to create a false event representation.
- Addition of nonexistent equipment, attendance, awards, or branding.
- Expression replacement.
- Generative reconstruction of missing body parts.

Generative object cleanup, if added later, must be labeled internally, reviewable, and disabled by default for documentary/event content.

### 10.4 Brand kit

Per tenant or location:

- Primary and secondary logo.
- Light and dark logo variants.
- Brand colors.
- Typography choices from licensed fonts.
- Photography look.
- Overlay styles.
- Approved calls to action.
- Hashtag sets.
- Location handles.
- Sponsor rules.
- Prohibited language.
- Safe-area templates.
- Accessibility preferences for text contrast.

### 10.5 Brand looks

Each look is a versioned parameter family rather than one fixed filter. The system should offer:

- Clean energetic.
- Warm community.
- High-contrast training.
- Soft wellness.
- Neutral documentary.
- Monochrome performance.

The customer's setup process selects one primary and one alternate look.

---

## 11. Content generation

### 11.1 Content packages

#### Daily highlights

- Five to fifteen edited images.
- Chronological or activity-based order.
- Download gallery.
- One recommended lead image.

#### Carousel package

- Three to ten compatible crops.
- Consistent aspect ratio.
- Recommended sequence.
- Cover image.
- Optional title card.
- Draft caption.

#### Story package

- Vertical crops.
- Safe areas for UI overlays.
- Optional branded intro/outro card.
- Text-free and text-overlay variants.

#### Single-post package

- Recommended lead image.
- Feed crop variants.
- Caption brief.
- Alt-text draft.
- Brand and consent checks.

#### Collage package

- Two-, three-, four-, and six-image layouts.
- Face-safe crop positioning.
- Consistent gutters and brand frame.
- Logo variant.
- Text-free variant.

#### Website/newsletter package

- Landscape hero.
- Card thumbnail.
- Square thumbnail.
- Descriptive filename.
- Alt-text draft.

### 11.2 Platform profiles

Output dimensions, aspect ratios, file constraints, safe zones, and carousel behavior must be stored in a versioned platform-profile service.

Initial aspect-ratio families:

- 1:1 square.
- 4:5 portrait feed.
- 3:4 portrait source-friendly feed.
- 9:16 Story/Reel cover.
- 16:9 landscape/web.
- Original aspect ratio.

Do not couple core rendering to one platform's current dimensions. Platform rules change.

### 11.3 Smart crop

For each target ratio:

- Preserve important faces, bodies, equipment, logos, and action direction.
- Avoid cutting joints where possible.
- Avoid obscuring faces with text safe zones.
- Keep horizon level.
- Score alternate crops.
- Route low-confidence crops to review.

### 11.4 Collage selection

Collages should maximize complementary content:

- Different moments.
- Different shot scales.
- Compatible color and exposure.
- Balanced face placement.
- Narrative flow.
- No redundant frames.

Avoid grids containing several nearly identical burst frames unless the template intentionally illustrates motion.

### 11.5 Caption assistance

Caption generation is an appropriate optional use of an LLM. It is separate from culling.

Inputs may include:

- Venue-provided event title.
- Date and class type.
- Approved coach or campaign names.
- Brand voice.
- Selected content reason codes.
- Approved calls to action.
- Hashtag sets.

Restrictions:

- Do not identify unnamed people.
- Do not infer health conditions, weight loss, ability, or personal attributes.
- Do not invent attendance numbers, achievements, quotes, or testimonials.
- Do not make medical or guaranteed fitness claims.
- Do not publish generated captions without the configured approval gate.
- Store prompt, model, output, editor changes, and approval record.

Template-based captions should remain available when LLM assistance is disabled.

### 11.6 Accessibility

Generate alt-text drafts describing visible content without guessing identity, sensitive traits, or intent. Human approval is required before publication if the draft contains uncertain subject descriptions.

---

## 12. Review, approval, and publishing experience

### 12.1 Dashboard home

Primary information:

- Content ready for review.
- Today's capture and selected counts.
- Consent-blocked assets.
- Scheduled posts.
- Device status.
- Storage/retention alerts.

Avoid vanity AI metrics on the primary dashboard.

### 12.2 Review queue

Review units are content packages, not raw photographs.

For each package:

- Preview all formats.
- Show source lineage.
- Show consent eligibility.
- Swap an alternate image.
- Adjust crop.
- Change template.
- Edit caption and alt text.
- Approve for download.
- Approve for scheduling.
- Reject with reason.

### 12.3 Approval states

```text
DRAFT
  → NEEDS_CONTENT_REVIEW
  → NEEDS_CONSENT_REVIEW
  → APPROVED_FOR_DOWNLOAD
  → APPROVED_FOR_PUBLISHING
  → SCHEDULED
  → PUBLISHED
```

Failure states:

- `PUBLISH_FAILED_RETRYABLE`
- `PUBLISH_FAILED_AUTH`
- `PUBLISH_FAILED_POLICY`
- `WITHDRAWN`
- `TAKEDOWN_REQUESTED`
- `REMOVED`

### 12.4 Publishing integration

Initial support should target Instagram professional accounts through the official API.

Requirements:

- Venue-admin OAuth connection.
- Least-privilege content-publishing permission.
- Encrypted token storage.
- Token-health monitoring.
- Explicit account destination display.
- Versioned API adapter.
- Preflight validation.
- Time-limited media URL accessible to Meta only during publication workflow.
- Container-status polling.
- Idempotent publish request.
- Audit event for approval and publication.
- Clear handling of expired authorization.

Meta documentation states that Instagram publishing is for professional accounts and requires content-publishing permissions. Media is fetched from a reachable URL during container creation. See [Meta Instagram API documentation](https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api).

### 12.5 Human approval policy

Initial product rule:

> Every public post requires approval by an authorized venue user.

Future limited auto-publishing may be enabled only when:

- The venue opts in.
- The template is preapproved.
- All included assets have verified marketing permission.
- No minors or ambiguous subjects are detected unless the venue's verified policy permits them.
- Moderation checks pass.
- Caption uses an approved template or has been preapproved.
- Destination account and schedule are explicit.
- A kill switch is available.

---

## 13. Consent, privacy, and content rights

### 13.1 Important scope note

This section defines product requirements, not legal advice. Applicable rights of publicity, privacy, biometric, employment, consumer-protection, child-privacy, surveillance, and recording laws vary by jurisdiction and customer use. Qualified counsel should review the launch jurisdiction, customer agreement, station notice, release language, data-processing terms, and deletion workflow before production use.

### 13.2 Consent layers

Track separate permissions:

1. **Capture consent:** Permission to take the photograph.
2. **Processing consent:** Permission to upload, analyze, edit, and create derivatives.
3. **Private delivery:** Permission to provide a private session gallery.
4. **Venue internal use:** Permission for internal review or private team channels.
5. **Public marketing use:** Permission for website, email, organic social, and specified venue marketing.
6. **Paid advertising use:** Separate permission if required by the venue's policy or jurisdiction.
7. **Model training use:** Off by default and never implied by marketing consent.

Each derivative inherits the most restrictive relevant source permission.

### 13.3 Station notice

Notice should be visible before capture and outside a buried privacy policy. It should identify:

- Venue.
- Service provider role.
- What is collected.
- Why it is collected.
- Retention period.
- Public-use options.
- Deletion request path.
- Contact information.
- Minor policy.

FTC facial-recognition guidance emphasizes privacy by design, clear notice, meaningful choice, security, and sound retention/disposal practices. It also recommends affirmative consent for materially different uses and cautions against identifying anonymous people without consent. See [FTC facial-recognition guidance](https://www.ftc.gov/news-events/news/press-releases/2012/10/ftc-recommends-best-practices-companies-use-facial-recognition-technologies).

### 13.4 No identity recognition by default

The service may detect faces and create ephemeral within-session clusters for culling. It must not identify a person or match that person against other sessions by default.

California describes biometric information processed to identify a consumer as sensitive personal information under the CCPA. Other jurisdictions may impose additional or stricter biometric obligations. See [California Attorney General CCPA overview](https://oag.ca.gov/privacy/ccpa).

### 13.5 Minors

Initial recommended policy:

- Self-serve public-marketing flow is unavailable to unverified minors.
- A parent/guardian or documented venue process must authorize public use involving minors.
- If age is uncertain, route to review and treat as not public-ready.
- Do not attempt automatic age determination as the sole compliance mechanism.
- Provide tenant-level “no minors in public content” mode.

FTC guidance notes that photographs, videos, and audio containing a child's image or voice can constitute personal information under COPPA when the service is covered by that rule. See [FTC COPPA FAQ](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions). Applicability to a particular gym and workflow requires counsel.

### 13.6 Data minimization

- Strip unnecessary GPS from public derivatives by default.
- Do not collect personal email/phone data merely to operate a public shutter.
- Use claim tokens rather than requiring an account for private delivery where practical.
- Retain source files only as long as needed for the contracted workflow.
- Do not use photos or embeddings for advertising profiles.
- Do not sell or share member data for unrelated purposes.
- Do not use customer content to train global models by default.

### 13.7 Retention defaults

Illustrative policy:

- Device source after server verification: 24–72 hours.
- Unselected cloud source: 30 days.
- Selected source: 90 days.
- Final private gallery: 30 days unless claimed or extended.
- Approved marketing derivative: Customer-configured duration.
- Ephemeral face embeddings: Delete after culling or within 24 hours.
- Audit events: Contractual duration without image pixels.
- Revoked/takedown content: Immediate access restriction followed by verified deletion workflow.

Customers may choose shorter periods. Longer periods require a documented purpose.

### 13.8 Deletion and takedown

Provide:

- Public deletion request form.
- Claim-token deletion control.
- Venue-admin removal.
- Support-admin audited removal.
- Derivative lineage lookup.
- Social-post link tracking.
- Removal status and completion record.
- Backup-expiration disclosure.

A source deletion request must locate generated crops, collages, previews, private galleries, and unpublished packages derived from that source.

### 13.9 Content ownership and license

Customer agreements must define:

- Who owns source captures.
- What license the venue receives from participating subjects.
- What limited processing license the service receives.
- Whether staff or member photographers retain rights.
- What happens after subscription termination.
- Whether model-training rights are excluded.
- Customer responsibility for permissions and accuracy.

Meta advises users to post only content they created or have the right to share. See [Instagram copyright guidance](https://www.facebook.com/help/354736791367645/).

---

## 14. Security specification

### 14.1 Authentication

- Organization users authenticate with secure modern identity flows.
- Require MFA for administrators and publishing roles.
- Device credentials are distinct from human user credentials.
- Device credentials are revocable and rotated.
- Claim links use high-entropy, expiring tokens.
- Support access is just-in-time, scoped, and audited.

### 14.2 Authorization roles

- Organization owner.
- Location administrator.
- Content reviewer.
- Publisher.
- Staff operator.
- Billing administrator.
- Read-only auditor.
- Support operator.

Publishing and deletion permissions should be separable.

### 14.3 Encryption

- TLS for transport.
- Managed encryption at rest.
- Encrypted secrets and OAuth tokens.
- No long-lived cloud credentials on the phone.
- Optional per-tenant encryption keys for higher tiers.

### 14.4 Signed media access

- Private by default.
- Short expiration.
- Tenant and asset scoped.
- Single-purpose where feasible.
- Revocable through lineage and object state.
- Never expose raw object-store paths in predictable URLs.

### 14.5 Audit events

Record:

- Login and role changes.
- Device enrollment/revocation.
- Consent configuration changes.
- Asset view/download.
- Manual consent override.
- Approval.
- Scheduling and publication.
- Social-account changes.
- Retention-policy changes.
- Deletion and takedown.
- Support access.

### 14.6 Incident response

Maintain procedures for:

- Lost or stolen capture phone.
- Credential compromise.
- Cross-tenant access defect.
- Accidental public publication.
- Consent dispute.
- Social token compromise.
- Data deletion failure.
- Ingest or processing outage.

Remote device revocation must prevent new uploads and administrative access without requiring physical possession.

---

## 15. Functional requirements

### 15.1 Device and capture

**FR-DEV-001:** The service shall enroll a device to one organization and location.  
**FR-DEV-002:** The device shall run a restricted capture experience suitable for shared use.  
**FR-DEV-003:** Public users shall not access prior sessions or administrative data.  
**FR-DEV-004:** The application shall create an explicit capture session.  
**FR-DEV-005:** Every asset shall inherit the session's consent state.  
**FR-DEV-006:** The application shall support retake and session cancellation.  
**FR-DEV-007:** The device shall report charging, storage, network, application version, and last-upload health.  
**FR-DEV-008:** Capture shall continue temporarily during network loss when local storage is safe.  
**FR-DEV-009:** The application shall visibly report when capture cannot safely continue.  
**FR-DEV-010:** Administrative exit shall require authentication.

### 15.2 Upload and storage

**FR-UP-001:** Upload shall be resumable and idempotent.  
**FR-UP-002:** Device and server shall verify content checksums.  
**FR-UP-003:** A local source shall not be deleted before server verification.  
**FR-UP-004:** Upload shall resume after application or device restart.  
**FR-UP-005:** The service shall enforce tenant-scoped storage.  
**FR-UP-006:** Assets shall have explicit retention deadlines.  
**FR-UP-007:** The service shall support Google Drive export.  
**FR-UP-008:** Google Drive ingestion may be supported as an optional connector.  
**FR-UP-009:** Object and derivative lineage shall remain queryable until applicable deletion completes.

### 15.3 Culling

**FR-CULL-001:** The system shall identify exact duplicates, derived duplicates, bursts, moments, and broader sessions separately.  
**FR-CULL-002:** The system shall select a variable number of keepers per moment.  
**FR-CULL-003:** The system shall optimize for quality and content diversity.  
**FR-CULL-004:** Venue modes shall alter ranking and coverage objectives.  
**FR-CULL-005:** Low-confidence decisions shall enter review.  
**FR-CULL-006:** Public candidates shall satisfy consent eligibility before package generation.  
**FR-CULL-007:** The system shall not identify people by default.  
**FR-CULL-008:** Within-session face clusters shall expire according to policy.  
**FR-CULL-009:** The system shall store structured decision reasons.  
**FR-CULL-010:** Reviewers shall be able to restore alternates and lock selections.

### 15.4 Editing and composition

**FR-MEDIA-001:** Source files shall remain immutable.  
**FR-MEDIA-002:** The system shall apply a tenant-approved look.  
**FR-MEDIA-003:** The system shall generate multiple versioned platform formats.  
**FR-MEDIA-004:** Smart crop shall protect detected important subjects and safe areas.  
**FR-MEDIA-005:** Low-confidence crops shall require review.  
**FR-MEDIA-006:** The system shall generate consistent-aspect carousel assets.  
**FR-MEDIA-007:** The system shall generate configurable collage layouts.  
**FR-MEDIA-008:** All derivatives shall retain source lineage and consent state.  
**FR-MEDIA-009:** The system shall not perform body or face reshaping by default.  
**FR-MEDIA-010:** The service shall generate alt-text drafts without identity inference.

### 15.5 Review and publishing

**FR-PUB-001:** Public content shall require authorized approval by default.  
**FR-PUB-002:** The reviewer shall see the destination account before approval.  
**FR-PUB-003:** The service shall validate media against the current platform profile.  
**FR-PUB-004:** Publication shall be idempotent.  
**FR-PUB-005:** Publication status and external identifier shall be recorded.  
**FR-PUB-006:** OAuth tokens shall be encrypted and revocable.  
**FR-PUB-007:** Failed authorization shall not discard approved work.  
**FR-PUB-008:** The service shall support download without social connection.  
**FR-PUB-009:** Scheduled publication shall be cancellable before execution.  
**FR-PUB-010:** Takedown requests shall identify associated external posts when known.

### 15.6 Consent and privacy

**FR-PRIV-001:** Capture, processing, private-delivery, and marketing permissions shall be distinct states.  
**FR-PRIV-002:** Public content generation shall exclude private-only assets.  
**FR-PRIV-003:** Every derivative shall inherit source restrictions.  
**FR-PRIV-004:** The service shall provide a deletion-request workflow.  
**FR-PRIV-005:** Deletion shall traverse derivative lineage.  
**FR-PRIV-006:** GPS shall be removed from public derivatives by default.  
**FR-PRIV-007:** Customer content shall not train general models by default.  
**FR-PRIV-008:** Minor-related content shall enter a restricted workflow.  
**FR-PRIV-009:** Consent overrides shall require an authorized role and audit event.  
**FR-PRIV-010:** Expired claim links shall not expose session content.

### 15.7 Subscription and administration

**FR-ADM-001:** Plans shall limit or meter locations, devices, captures, storage, or content packs.  
**FR-ADM-002:** Usage shall be visible before overage.  
**FR-ADM-003:** A subscription lapse shall not immediately delete customer data.  
**FR-ADM-004:** The service shall support export before account closure.  
**FR-ADM-005:** Organization owners shall manage users and roles.  
**FR-ADM-006:** Multi-location plans shall support shared and location-specific brand configuration.

---

## 16. Data model

### 16.1 Organization and operations

#### Organization

- `id`
- `name`
- `billing_account_id`
- `plan_id`
- `data_region`
- `status`
- `default_retention_policy_id`

#### Location

- `id`
- `organization_id`
- `name`
- `timezone`
- `address_reference`
- `brand_kit_id`
- `consent_policy_id`
- `retention_policy_id`

#### UserMembership

- `user_id`
- `organization_id`
- `location_scope`
- `roles`
- `status`

#### Device

- `id`
- `organization_id`
- `location_id`
- `hardware_model`
- `os_version`
- `app_version`
- `enrollment_state`
- `last_heartbeat_at`
- `storage_state`
- `charging_state`
- `thermal_state`
- `last_upload_at`
- `revoked_at`

### 16.2 Capture and consent

#### CaptureSession

- `id`
- `organization_id`
- `location_id`
- `device_id`
- `mode`
- `operator_type`
- `started_at`
- `ended_at`
- `claim_token_hash`
- `claim_expiration`
- `status`

#### ConsentRecord

- `id`
- `capture_session_id`
- `policy_version`
- `capture_allowed`
- `processing_allowed`
- `private_delivery_allowed`
- `internal_use_allowed`
- `public_marketing_allowed`
- `paid_advertising_allowed`
- `model_training_allowed`
- `minor_state`
- `group_subject_state`
- `captured_at`
- `revoked_at`
- `evidence_reference`

#### Asset

- `id`
- `capture_session_id`
- `source_object_id`
- `sha256`
- `byte_size`
- `mime_type`
- `width`
- `height`
- `capture_time`
- `metadata`
- `upload_state`
- `moderation_state`
- `retention_deadline`
- `deleted_at`

### 16.3 Intelligence and output

#### Moment

- `id`
- `capture_session_id`
- `moment_type`
- `start_time`
- `end_time`
- `group_confidence`

#### AssetAnalysis

- `asset_id`
- `feature_version`
- `technical_metrics`
- `semantic_metrics`
- `face_metrics`
- `aesthetic_metrics`
- `policy_flags`
- `expires_at`

#### CullDecision

- `asset_id`
- `moment_id`
- `selection_state`
- `rank`
- `confidence`
- `reason_codes`
- `model_versions`
- `manual_override`
- `locked`

#### EditRecipe

- `id`
- `asset_id`
- `look_version`
- `parameters`
- `crop_candidates`
- `approved_crop`
- `pipeline_version`

#### Derivative

- `id`
- `source_asset_ids`
- `recipe_id`
- `content_package_id`
- `format_profile_version`
- `object_id`
- `consent_ceiling`
- `retention_deadline`

#### ContentPackage

- `id`
- `organization_id`
- `location_id`
- `package_type`
- `title`
- `status`
- `caption_draft`
- `alt_text_draft`
- `consent_state`
- `created_at`
- `approved_by`
- `approved_at`

#### PublishJob

- `id`
- `content_package_id`
- `platform_account_id`
- `scheduled_at`
- `approved_by`
- `status`
- `idempotency_key`
- `external_media_id`
- `failure_code`

#### DeletionRequest

- `id`
- `organization_id`
- `claim_session_id`
- `requester_reference`
- `scope`
- `status`
- `received_at`
- `completed_at`
- `evidence_log`

---

## 17. Subscription packaging and pricing hypotheses

Pricing below is a customer-discovery hypothesis, not a final recommendation.

### 17.1 Starter — approximately $149 per location/month

- One capture station.
- Up to 2,000 source photos per month.
- Automatic culling and editing.
- One brand look.
- Daily highlight galleries.
- Feed, Story, and web crops.
- Basic collages.
- Download and Google Drive export.
- 30-day source retention.
- One administrator and two reviewers.
- Email support.

### 17.2 Growth — approximately $299 per location/month

- Up to three stations.
- Up to 10,000 source photos per month.
- Multiple venue modes.
- Two brand looks.
- Carousel and campaign packages.
- Caption and alt-text assistance.
- Instagram professional-account connection.
- Scheduling with approval.
- Longer configurable retention.
- Five users.
- Priority support.

### 17.3 Multi-location — approximately $699/month plus location usage, or custom

- Shared organization brand system.
- Location-specific overrides.
- Central approval queue.
- Role and location scoping.
- SSO/MFA policy options.
- Regional storage options.
- Advanced audit export.
- API/webhooks.
- Custom retention and support agreement.

### 17.4 Hardware options

#### Bring your own device

- Customer supplies a supported Pixel or Android phone, mount, and power.
- Service provides enrollment and validation.

#### Managed station kit

- Phone sold or leased separately.
- Secure dock/mount.
- Power supply.
- Setup signage.
- Optional light/backdrop kit.
- Remote enrollment.
- Replacement and support policy.

Avoid hiding expensive hardware support inside a low software price. Treat hardware, replacement, theft, and on-site installation as separate economics.

### 17.5 Overage and caps

Possible metering units:

- Source captures.
- Full-resolution retained storage.
- Generated content packages.
- Active devices.
- Locations.
- Published posts.

The simplest early model is per-location subscription with a generous capture allowance and explicit storage limits. Do not meter every individual crop; that makes value difficult to understand.

---

## 18. Unit economics

### 18.1 Cost categories

- Object storage.
- Preview and egress bandwidth.
- CPU/GPU inference.
- Full-resolution rendering.
- Database and queue infrastructure.
- Caption-model usage if enabled.
- Social API maintenance.
- Customer onboarding.
- Device support and replacement.
- Privacy and deletion operations.
- Human support.

### 18.2 Cost controls

- Analyze downscaled previews first.
- Render full resolution only for selected/review assets.
- Delete unselected source according to short default retention.
- Cache features, not unnecessary full derivatives.
- Generate platform variants on demand or according to package selection.
- Use CPU/accelerator-appropriate models rather than large general models.
- Batch inference by location/day when latency permits.
- Bound caption generation.
- Pass customer archive storage to Drive when selected.

### 18.3 Target economics

Initial target:

- Software gross margin above 75% excluding managed hardware.
- Infrastructure cost below 10–15% of subscription revenue at ordinary usage.
- Support and onboarding decline materially after the first month.
- Hardware margin and replacement reserve priced separately.

The largest early costs may be customer success, device reliability, and privacy operations rather than image inference.

---

## 19. Reliability and service operations

### 19.1 Offline operation

- Capture remains available during temporary network loss.
- Device shows a subtle offline indicator.
- Local spool is encrypted and bounded.
- Upload resumes automatically.
- Admin alert occurs before storage exhaustion.
- No duplicate processing after reconnect.

### 19.2 Service-level objectives

Illustrative pilot objectives:

- 99.5% monthly control-plane availability.
- 99.9% durable source-object availability during contracted retention.
- 95% of ordinary photos uploaded within 15 minutes when device has stable Wi-Fi and power.
- 95% of daily content packages ready within 30 minutes after the configured daily cutoff.
- Device offline alert within 30 minutes of missed heartbeat during operating hours.
- Deletion requests acknowledged immediately and completed within the documented policy window.

### 19.3 Failure handling

- Upload failure: Retry resumably.
- Checksum mismatch: Preserve local source and reupload.
- Processing failure: Retry idempotently, then dead-letter.
- Model failure: Use conservative fallback and route to review.
- Render failure: Preserve recipe and retry without rerunning culling.
- Social auth failure: Preserve approved package and request reconnection.
- Social publish uncertainty: Reconcile external state before retrying to avoid duplicate posts.
- Consent revocation: Immediately block new access and publication while deletion workflow proceeds.

### 19.4 Device fleet dashboard

Show:

- Online/offline.
- Battery and charging.
- Storage pressure.
- Temperature warning.
- Wi-Fi quality.
- Pending uploads.
- Camera error.
- Application/OS version.
- Last capture and upload.
- Enrollment and certificate expiration.

---

## 20. Analytics and success metrics

### 20.1 Customer outcome metrics

- Content packages approved per location per month.
- Median staff review minutes per package.
- Days with usable content.
- Percentage of packages approved without image substitution.
- Percentage of customers publishing at least weekly.
- Time from capture to approved content.
- Customer-reported reduction in content labor.

### 20.2 Culling metrics

- Source-to-selected reduction ratio.
- Moment coverage recall.
- Top-frame acceptance.
- Hidden-image restore rate.
- Redundancy in final packages.
- Low-confidence review precision.
- Consent-blocked selection rate.

### 20.3 Capture-station metrics

- Sessions per day.
- Photos per session.
- Completed versus abandoned sessions.
- Claim rate.
- Marketing opt-in rate.
- Upload latency.
- Device return-to-dock/charging health.
- Storage-pressure incidents.

### 20.4 Subscription metrics

- Trial-to-paid conversion.
- Activation: first approved package within seven days.
- 30/90/180-day retention.
- Location expansion.
- Active stations.
- Support tickets per location.
- Hardware incidents.
- Gross margin.

### 20.5 Privacy metrics

- Consent-ambiguous assets prevented from publication.
- Deletion request volume and completion time.
- Public-use override frequency.
- Minor-related review count.
- Unauthorized access events.
- Social takedown requests.

Privacy metrics are operational safeguards, not marketing data.

---

## 21. Pilot specification

### 21.1 Pilot customer

Choose one gym with:

- Engaged owner or manager.
- Existing Instagram professional account.
- One photogenic capture area.
- Frequent classes.
- Staff willing to promote use.
- Adult-only or easily controlled initial sessions.
- Clear consent process.

Avoid beginning with a youth-focused gym, school, medical/rehabilitation facility, locker-room-adjacent placement, or highly regulated franchise environment.

### 21.2 Pilot setup

- One managed Pixel.
- Secure wired or wireless charging dock.
- One fixed light or favorable ambient-light location.
- Capture app in managed mode.
- One venue mode: Community day/Class highlights.
- One brand look.
- Direct upload to service storage.
- Web dashboard.
- Download plus Drive export.
- No automatic social publication.
- Adult participants with explicit pilot release.
- 30-day source retention.

### 21.3 Pilot workflow

1. Staff introduces station during selected classes/events.
2. Participants use self-serve or staff capture.
3. Photos upload automatically.
4. Service creates daily highlights and one post package.
5. Manager reviews in under ten minutes.
6. Manager downloads or manually posts.
7. Team interviews manager weekly.

### 21.4 Pilot success gates

Over four weeks:

- At least three active capture days per week.
- At least one approved content package per week.
- Median review time under ten minutes per package.
- At least 70% reduction from source captures to reviewed candidates.
- At least 70% of suggested lead images accepted.
- No unconsented public publication.
- No source loss before verified upload.
- Fewer than one device-support intervention per week after onboarding.
- Customer indicates willingness to pay at the target tier.

### 21.5 Questions to validate

- Will members actually use a shared station?
- Is staff-led capture more common than self-serve capture?
- Does a claim link increase participation?
- Does public-marketing opt-in create unacceptable friction?
- Are daily or weekly packages more valuable?
- Does the manager want downloads, Drive, scheduling, or direct publishing?
- Which formats are repeatedly used?
- Is the editing quality visibly better than Pixel output alone?
- Is culling or composition the dominant time saving?
- Who owns the approval task?
- What price feels inexpensive relative to saved effort?

---

## 22. Delivery roadmap

### Phase 0: Customer and legal discovery

- Interview 10–15 gym owners/managers.
- Map current content workflow and spend.
- Validate camera placement and usage behavior.
- Draft consent and data-flow model with counsel.
- Select one adult-only pilot context.
- Define success metrics and paid-pilot terms.

Exit criterion:

- At least three credible design partners and one signed pilot.

### Phase 1: Managed capture and ingest

- Android capture sessions.
- Basic notice and permission state.
- Device enrollment.
- Encrypted spool.
- Resumable verified upload.
- Direct object storage.
- Device health.
- Manual gallery dashboard.

Exit criterion:

- One station operates for two weeks without source loss or daily technical intervention.

### Phase 2: Automated culling and editing

- Moment grouping.
- Duplicate/burst reduction.
- Technical and face-quality analysis.
- Venue-aware selection.
- Confidence routing.
- One brand look.
- Daily highlight package.

Exit criterion:

- Manager review is below ten minutes and selection acceptance meets pilot gate.

### Phase 3: Content packages

- Feed, Story, web, and carousel crops.
- Collage engine.
- Brand kit.
- Caption and alt-text drafts.
- Consent-aware package eligibility.
- Drive export.

Exit criterion:

- Customer regularly uses generated assets without external resizing/design work.

### Phase 4: Subscription product

- Billing.
- Plan limits.
- Organization/location roles.
- Onboarding.
- Device fleet controls.
- Retention settings.
- Deletion request workflow.
- Audit exports.

Exit criterion:

- Multiple paying locations can self-serve ordinary operations.

### Phase 5: Social integration

- Instagram professional account connection.
- Approval and scheduling.
- Publishing adapter.
- Token-health and reconciliation.
- Post analytics where permitted.

Exit criterion:

- Approved posts publish reliably without duplicates and with complete audit lineage.

### Phase 6: Expansion

- Multi-location dashboard.
- Additional venue verticals.
- Customer APIs/webhooks.
- More Android devices.
- Optional local/edge processing appliance.
- Advanced campaigns and template marketplace.

---

## 23. Go-to-market positioning

### 23.1 Category

Avoid positioning as generic AI photo editing. Suggested category:

- “Always-on content capture for physical businesses.”
- “Your venue's automated content desk.”
- “From daily activity to ready-to-post content.”

### 23.2 Core message

```text
Capture naturally throughout the day.
We select, edit, resize, and package the best moments.
Your team approves in minutes.
```

### 23.3 Initial sales motion

- Founder-led local sales.
- Paid four-week pilot.
- Physical demo at one location.
- Before/after workflow comparison.
- Weekly content output report.
- Convert to per-location subscription.

### 23.4 Expansion verticals

After gyms:

- Climbing gyms.
- Dance and yoga studios.
- Martial arts studios.
- Community clubs.
- Restaurants and cafés.
- Makerspaces.
- Coworking spaces.
- Hotels and experience operators.
- Adult recreational sports.
- Conferences and brand activations.

Youth sports, schools, childcare, healthcare, rehabilitation, and sensitive/private venues require additional policy and should not be early expansion targets.

---

## 24. Risks and mitigations

### 24.1 The station is not used

**Risk:** A phone on a charger does not create behavior by itself.  
**Mitigation:** Visible placement, staff scripts, private claim value, event-specific prompts, fixed lighting, and weekly activation reporting.

### 24.2 The product feels like surveillance

**Risk:** Members misunderstand the station or venue practice.  
**Mitigation:** User-initiated capture, clear physical/digital notice, no passive recording, visible capture state, no default identity recognition, and private-only option.

### 24.3 Consent does not cover group subjects

**Risk:** The operator consents but other people in frame do not.  
**Mitigation:** Separate group policy, staff verification, public-use blocking, release collection, reviewer gate, and deletion/takedown process.

### 24.4 Members dislike appearance-based selection

**Risk:** Culling is perceived as judging bodies or attractiveness.  
**Mitigation:** Rank technical quality, expression usability, action timing, and content diversity; prohibit body scoring and reshaping; explain selection conservatively.

### 24.5 Shared phone abuse or theft

**Risk:** Device exposes data or disappears.  
**Mitigation:** Dedicated-device mode, no prior-session gallery, short-lived credentials, remote revocation, security mount/tether, and minimal local retention.

### 24.6 Wireless charging unreliability

**Risk:** Misalignment or heat causes downtime.  
**Mitigation:** Charging telemetry, dock design, thermal policy, staff alert, and wired option.

### 24.7 Network interruption fills device storage

**Risk:** Upload backlog prevents capture.  
**Mitigation:** Bounded spool, storage thresholds, offline indication, admin alert, resumable upload, and verified local cleanup.

### 24.8 Google API dependency

**Risk:** Photos or Drive API policies change.  
**Mitigation:** Service-controlled ingest/storage, connector abstraction, versioned adapters, and Drive as optional integration.

### 24.9 Social API dependency

**Risk:** Publishing permissions or formats change.  
**Mitigation:** Download always available, versioned platform profiles, adapter isolation, token monitoring, and human approval.

### 24.10 Cloud cost grows with capture volume

**Risk:** Heavy users generate unprofitable storage and inference.  
**Mitigation:** Preview-first culling, selected-only rendering, short source retention, explicit plan allowances, and usage alerts.

### 24.11 Poor content despite good automation

**Risk:** Bad light, clutter, or camera placement limits results.  
**Mitigation:** Station-design kit, framing guide, fixed capture zone, optional light, setup scoring, and customer education.

### 24.12 Public posting error

**Risk:** Wrong account, caption, subject, or consent state reaches the public.  
**Mitigation:** Destination preview, role-based approval, consent hard gate, audit trail, scheduled cancellation, and takedown workflow.

---

## 25. Recommended MVP

### 25.1 Included

- One managed Pixel per location.
- Custom Android capture app.
- Self-serve and staff session modes.
- Explicit private-only or venue-marketing permission.
- Local encrypted spool.
- Direct resumable upload to service storage.
- Device health monitoring.
- Session and moment grouping.
- Aggressive duplicate/burst culling.
- Technical, expression, aesthetic, and diversity ranking.
- One venue mode and one brand look.
- Daily highlight gallery.
- 4:5, 1:1, 9:16, and original-ratio output families.
- Simple two- to four-image collages.
- Browser review and download.
- Google Drive export.
- 30-day source retention.
- Manual social posting by customer.
- Complete source-to-derivative lineage.
- Deletion request workflow.

### 25.2 Excluded

- Automatic Instagram publishing.
- Persistent face recognition.
- Named member profiles.
- Minors in self-serve marketing workflow.
- Video and Reels generation.
- Generative body/face editing.
- Arbitrary Google Photos library ingestion.
- Multi-location enterprise features.
- Paid-ad campaign management.
- Performance claims about exercise technique.

### 25.3 MVP proof point

One adult-focused gym captures at least 200 photographs per week and receives at least one genuinely useful, approved content package while spending fewer than ten minutes reviewing each package.

---

## 26. Decisions recommended now

1. Maintain Local Photo Curator as the consumer/local product.
2. Treat Venue Content Loop as a separate B2B product using the same intelligence core.
3. Start with gyms as a design-partner vertical, not as a permanent platform limitation.
4. Build a custom managed capture application.
5. Use service-controlled object storage for ingest.
6. Offer Google Drive as export first and ingest second.
7. Do not use Google Photos as the primary source of truth.
8. Make culling the largest product-investment area.
9. Render only selected and ambiguous images at full resolution.
10. Track consent separately from quality.
11. Avoid persistent face recognition.
12. Require human approval for public posts in the initial product.
13. Begin with still JPEG images and static social assets.
14. Validate customer behavior and willingness to pay before building Instagram publishing.
15. Run the first pilot in an adult-only, non-sensitive capture environment.

---

## 27. Open questions

### Customer and behavior

1. Who actually takes the photographs: staff, members, or both?
2. What motivates a member to use the station?
3. Is receiving a private gallery necessary for participation?
4. Do customers want daily content, weekly content, or event recaps?
5. Who is responsible for approval?
6. How many minutes of review is acceptable?

### Capture

7. Handheld shared phone, fixed booth, or both?
8. Is wireless charging important enough to accept additional thermal risk?
9. Is one camera location sufficient?
10. Should staff have a quick-capture mode separate from public sessions?
11. Is still photography enough for the first paid product?

### Privacy

12. What permission model does the pilot gym currently use?
13. How are group subjects cleared?
14. Are minors present?
15. What deletion turnaround will be promised?
16. Can the initial pilot prohibit public use unless every subject is explicitly cleared?

### Output

17. Are Instagram carousels, Stories, or single posts most valuable?
18. Do customers want caption drafts?
19. Do they want download, Drive export, scheduling, or direct publishing?
20. How much brand customization is needed?
21. Would a weekly email containing ready-to-download packages outperform a complex dashboard?

### Business

22. Is $149–$299 per location per month plausible?
23. Will customers supply the phone?
24. Who supports hardware and connectivity?
25. Is installation a one-time paid service?
26. Which usage unit is easiest for customers to understand?

---

## 28. Final product statement

Venue Content Loop should not be sold as a camera, photo backup service, or AI filter. It is an automated content operation for physical businesses.

The winning workflow is:

> People capture real moments during the normal day. The service safely moves the files, discards repetition, selects the strongest usable moments, makes them visually coherent, turns them into brand-ready formats, and asks an authorized human for a few final approvals.

If the product can consistently turn a shared phone and a day's activity into a week's worth of usable content—with clear permission, minimal review, and no storage babysitting—it has a credible subscription value proposition.
