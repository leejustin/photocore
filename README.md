# Bound, made with Photocore

**Finish the trip.** Everyone's photos. One book.

**Bound** is the consumer app: it picks your best photos from each trip on your iPhone, brings in everyone who was there from one link, and turns the pile into one book with a short diary of where you went. **Photocore** is the engine underneath, the CLI, the server binary and the Mac pro studio. See [the brand](./outputs/brand.md), [the business model](./outputs/business-model.md), [direction and platforms](./outputs/direction-and-platforms.md) and [the strategy](./outputs/product-strategy.md).

- **Free, on the iPhone.** Pick a trip and Bound picks your best on the phone, asks about a few close calls, and saves your picks to Photos. Nothing is uploaded or copied.
- **Every book is free to make.** Up to 15 friends with 150 photos each, online for 90 days. Anyone in the book can keep it for good for $4.99 (a Trip Pass), from the app or the book page. The Event Pass ($39) is for weddings and big parties. Yearly is offered only to people who keep a few books a year.
- **Friends add theirs from a link.** In any browser, the invite page skips repeats and blurry ones on the person's phone before anything goes up. On iPhone, the App Clip picks their best on the phone, sends feature prints first, and uploads only the originals the book needs.
- **The book.** The best shot of each moment across everyone, shared out fairly, credited, with a diary written only from facts. Friends' photos that weren't picked are deleted. Each friend can tap their face to find every photo they're in and save them, free.
- **During the trip,** the book is made again each night while friends add photos, and everyone hears "Day 2 is in".
- **Keep, print, download.** Kept books stay up for good with everyone's full-size photos to download. Anyone can order a printed copy, made by Lulu and shipped.
- **No app needed to make one.** `/new` starts a book on the web, for organizers on Android.
- **The Mac studio** stays the owner's pro tool, and the same engine runs the server.

## Current status

| Part | State |
|---|---|
| Engine on iOS and macOS | Culls on both; 69 Swift tests and 48 engine checks pass |
| Bound for iPhone (`Apps/PhotocoreiOS`) | Trips from capture dates, streamed cull, swipe review, picks to Photos, set aside and restore, snapshots, highlight reel, finish card, plans, invite panel, nightly toggle, push token |
| Bound App Clip (`Apps/PhotocoreiOS/BoundClip`) | Opens from an invite, picks on the phone, offers feature prints, uploads only what's wanted; verified in the simulator |
| Invite page | Designed as the book's cover; browser pre-filter; optional email; photos of you |
| Trip book | Book and Snapshots styles, chapters by local day and place, grounded diary, credits, owner edits, notes and hearts, Instagram pack, keep and print on the page |
| Server (`photocore-server`) | Trips, invites, offers, finish, 90-day lifecycle with reminders, email, Stripe, Lulu, downloads, photos of you, nightly refinish, APNs, web owners; 8 groups of server checks pass against stand-in Stripe, Lulu and APNs |
| Not built | A live Stripe, Lulu, APNs or Resend account run (all need credentials); App Store Server Notifications for refunds and renewals; publishing books to object storage; a Snapshots print pack (needs a second printer); a native Android app (on evidence only, see the direction doc) |

The original specifications are still useful background:

- [Engine implementation plan](./outputs/photo-engine-implementation-plan.md)
- [Local Photo Curator specification](./outputs/local-photo-curator-spec.md)
- [Hybrid processing platform specification](./outputs/hybrid-photo-processing-platform-spec.md)

## The iPhone app and App Clip

```bash
xcrun simctl addmedia booted /path/to/some/*.JPG
Scripts/ios-app.sh -PhotocoreAutoOpen YES
Scripts/clip.sh http://localhost:8799/j/<invite code>
```

`Scripts/ios-app.sh` builds Bound (`Apps/PhotocoreiOS`), installs it on the booted simulator, grants Photos access and launches it. `Scripts/clip.sh` installs the App Clip and opens it on an invite, the way tapping the link would. To run on a phone, open `Apps/PhotocoreiOS/PhotocoreiOS.xcodeproj`, set your team, and set `BOUND_DOMAIN` to the domain that serves invite links (it goes into the associated-domains entitlements of the app and the clip). The bundle ID stays `com.photocore.trip` and the clip is `com.photocore.trip.Clip`; App Store product IDs never change.

How it stays safe on a real camera roll:

- **One trip at a time, capped.** Trips are found by 20-hour gaps, need 20 photos, and split above 21 days or 1,500 photos. Trips queue and cull one after another.
- **Streamed, not copied.** Thumbnails are read from Photos in batches, analyzed in memory and dropped. Only about 5 KB of analysis per photo is stored, and a killed app resumes from the last batch.
- **Guards.** It refuses to start under 200 MB free, pauses when the phone is hot, and slows down in Low Power Mode.
- **Nothing is deleted by picking.** "Set aside" gathers the other photos in "Bound · Set aside" in Photos to look over; nothing else changes and one tap undoes it. Bound never hides photos: iOS keeps hidden photos away from apps, so an app could hide them but never unhide them. Favorites, edited, shared and already-sorted photos are never set aside. Deleting is a separate step, at most 500 at a time, through the iOS confirmation into Recently Deleted (30 days). Every step is logged, with a pending entry written before any change. Albums titled "Photocore · Set aside" from before the rename are still found and renamed.

## The trip book

```bash
swift run photo-engine book /path/to/trip --tone warm --note "Sam's birthday weekend" --output ./exports/trip-book
```

This culls the folder, reads scene labels, smart crops and place names for the keepers, writes the diary, renders finished photos, and writes `index.html` plus `instagram/` (1080 x 1350 carousel, 1080 x 1920 stories, `caption.txt`).

The diary writer is chosen in this order: `PHOTOCORE_WRITER` if set (`gemini`, `deepseek`, `apple` or `offline`); Gemini (`gemini-3.1-flash-lite`) when `GEMINI_API_KEY` is set; DeepSeek (`deepseek-flash`) when `DEEPSEEK_API_KEY` is set; Apple's model (Private Cloud Compute on iOS 27 and macOS 27, otherwise the on-device model); then the offline writer. `PHOTOCORE_WRITER_MODEL` overrides the hosted model name. Both hosted providers use their OpenAI-compatible chat API, read 512-pixel thumbnails, and cost about a cent per book at current prices. Measured on a real trip, Apple's small on-device model writes plain, label-like captions, so a hosted key is the better choice for paid books.

The writer never invents the trip. It gets a list of facts, each with a source: place names from GPS, landmarks within about 150 m from MapKit (written as "near", never "visited"), sunrise and sunset computed from date and place, short signs read from the photos, scene labels, how many people appear, and anything the owner adds (`--note`, or calendar events in the app). A checker then reads every generated line. Names, numbers, things and event verbs ("arrived", "ate", "flew") must trace back to a fact. Lines that don't are replaced with plain text built from the facts, and the count is recorded in `book.json`. Owner edits are stored apart from generated text, so regenerating never overwrites them.

Local time in the book follows a GPS place's time zone first, then the camera's recorded UTC offset. Cameras often stay on home time while traveling.

## The server

```bash
Scripts/dev-server.sh            # http://127.0.0.1:8799, token dev-token, test checkout and printer
PHOTO_ENGINE_TOKEN=dev-token GEMINI_API_KEY=... swift run photocore-server
Scripts/ios-app.sh -PhotocoreServerURL http://localhost:8799 -PhotocoreServerToken dev-token
```

`Scripts/dev-server.sh` keeps everything in `.build/dev-server-data`, uses the no-charge test checkout and a printer that prints nothing, and writes emails to `worker-runs/trips/outbox`. The full route list is in `Sources/PhotoEngineServer/openapi.yaml`. The main ones:

| Route | Auth | Purpose |
|---|---|---|
| `POST /v2/trips` | Server token | Start a trip; returns the owner token once and the invite path |
| `POST /v2/trips/{id}/settings` | Server token | Title, note, style, owner name and email, time zone, nightly on or off |
| `PUT /v2/trips/{id}/photos/{name}` | Server token | Upload a pick (JPEG or HEIC, 60 MB, 400 per trip) |
| `POST /v2/trips/{id}/finish` | Server token | Queue the finish |
| `POST /v2/trips/{id}/plan` | Server token | Apply an App Store purchase, checked against Apple's root certificate |
| `POST /v2/trips/{id}/device` | Server token | The owner's iPhone, for "Day 2 is in" |
| `GET /b/{slug}/` | Public link | The book; an offline page once a free book's 90 days are up |
| `POST /b/{slug}/keep`, `/print` | Public link | Checkout to keep the book or order a printed copy |
| `GET /b/{slug}/photos.zip` | Public link | Everyone's full-size photos, once kept |
| `GET /b/{slug}/make` | Public link | "Make one for your trip", counted by platform |
| `GET /j/{code}` | Invite link | The invite page |
| `POST /j/{code}/join`, `/email` | Invite link | Join with a first name and an optional email |
| `PUT /j/{code}/photos/{name}` | Person's token | Add a photo (150 per person on a free book) |
| `POST /j/{code}/offers`, `GET /wanted` | Person's token | The App Clip's offers and the originals wanted |
| `GET`/`POST /j/{code}/you` | Person's token | Photos of you: tap your face, see and save your photos |
| `GET /new`, `/w/...` | Owner token | Make a book on the web |
| `POST /stripe/webhook` | Stripe signature | Paid checkouts |
| `GET /u/{token}` | Link in an email | One-click unsubscribe |

What it needs to talk to the outside world, all optional; without each, that part is off or goes to a local stand-in:

| Setting | For |
|---|---|
| `PHOTOCORE_PUBLIC_URL` | The public address, for links in emails, checkout returns and print files |
| `PHOTOCORE_DATA_DIR` | One folder for everything the server writes |
| `RESEND_API_KEY`, `PHOTOCORE_MAIL_FROM` | Sending email; otherwise emails go to the outbox folder |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | Web purchases; `PHOTOCORE_DEV_CHECKOUT=1` gives a no-charge test checkout instead |
| `LULU_CLIENT_KEY`, `LULU_CLIENT_SECRET`, `LULU_API_BASE` | Printed copies; use `https://api.sandbox.lulu.com` first. `LULU_POD_SOFTCOVER`, `LULU_POD_HARDCOVER` and `LULU_SHIPPING_LEVEL` override the defaults, which should be checked against Lulu's pricing calculator |
| `PHOTOCORE_PRINT_CONTACT` | The address Lulu writes to |
| `PHOTOCORE_APPLE_TEAM_ID` | The App Clip and universal links file, and APNs |
| `APNS_KEY_FILE`, `APNS_KEY_ID`, `APNS_SANDBOX` | "Day 2 is in" pushes to the owner's iPhone |
| `PHOTOCORE_APP_STORE_ID`, `PHOTOCORE_APP_STORE_URL` | The invite page's App Clip banner, and where iPhone visitors go from "Make one" |
| `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET` | Cloudflare Turnstile on `/new` |
| `PHOTOCORE_FACE_MODEL`, `PHOTOCORE_FACE_THRESHOLD` | A Core ML face-embedding model for photos of you; Vision feature prints by default |

Book pages, invites and print files are public to anyone with their unguessable link, and Stripe and Lulu must reach the server, so production means a public address. Publishing books to object storage behind a CDN is still the planned path; until then, put the server behind a proxy you trust and keep `PHOTO_ENGINE_ALLOWED_ROOTS` narrow.

## Technical direction

- Swift 6 with strict concurrency.
- Swift Package Manager for the engine, CLI, and tests.
- SwiftUI for the macOS interface.
- Image I/O for metadata and downsampled previews.
- Vision for similarity, faces, capture quality, and aesthetics.
- Core ML for optional replaceable scoring models.
- Core Image and Accelerate for editing and image statistics.
- A narrow persistence adapter backed by SQLite for durable sessions/artifacts plus a compact binary property-list analysis cache that can be evicted.
- Versioned JSON manifests for portable pipeline inputs and outputs.

## Engine commands

Build the command-line engine:

```bash
swift build
swift run photo-engine smoke-test
swift run photo-engine-checks
swift run photo-engine catalog /path/to/photos
swift run photo-engine run /path/to/photos --profile trip --cull balanced --target 60 --style natural --size compact --base raw --output ./exports/trip
swift run photo-engine calibrate /path/to/photos --sheet /tmp/photocore-calibrate.jpg
swift run photo-engine compare-render /path/to/manifest.json --count 6 --sheet /tmp/photocore-compare.jpg
swift run photo-engine eval /path/to/photos --profile trip --target 40
swift test
Scripts/ios-engine-test.sh
```

`--base raw` decodes a RAW master with Core Image. `--base camera` starts from the camera JPEG beside that RAW, when one exists. `calibrate` prints Vision feature-print distances and can write a contact sheet. `compare-render` writes the current recipe beside the camera JPEG so a shoot can be judged on real frames.

## The Mac studio and worker

Launch the Mac studio:

```bash
swift run photo-engine-mac
# or a real .app with icon (opens after build):
./Scripts/package-app.sh
```

After a run, Photocore opens **Confirm**: a short queue of moments where two frames are close or a keeper looks soft or blinky. Return keeps the suggestion. **Look** previews built-in looks, imported `.cube` LUTs or Lightroom `.xmp` presets, optional **Match my style** from your graded JPEGs, album exposure balance, and a quiet portrait **Retouch** pass. **Deliver** exports finished JPEGs under `~/Pictures/Photocore` with rename patterns, an optional local proof gallery (face filter + sneak peek), and a cull report; stars and color labels are embedded for Lightroom. It can optionally write `.xmp` sidecars beside RAW/HEIC originals, and never replaces an existing sidecar. **Album** (⌘4) browses every photo with spray-can Pick/Hide; double-click or Space opens a large view with burst survey and eye zoom. **Adjust** (⌘D) offers basic sliders for one photo. Culling learns from your P/X/stars (**taste memory**), syncs second-shooter cameras, and boosts key faces. Technical misses are hidden as *Unusable*. ⌘/ lists every shortcut.

Run the same pipeline as a loopback worker. It reads a folder that already exists on this Mac; it does not upload photographs. `photo-engine serve` binds to `127.0.0.1` only. Every route requires `Authorization: Bearer`. `PHOTO_ENGINE_TOKEN` is the shared secret (a session token is printed when it is unset). `PHOTO_ENGINE_ALLOWED_ROOTS` is a colon-separated list of directories a source folder may live under, defaulting to `~/Pictures`. `PHOTO_ENGINE_ALLOWED_ORIGINS` is a comma-separated list of browser `Origin` values; the default is none, and the server does not send a wildcard CORS header. Clients cannot choose an output path. Jobs write under `~/Library/Application Support/Photocore/worker-runs`.

```bash
swift run photo-engine serve --port 8787
curl -H "Authorization: Bearer $PHOTO_ENGINE_TOKEN" http://127.0.0.1:8787/v1/health
curl -X POST http://127.0.0.1:8787/v1/jobs \
  -H "Authorization: Bearer $PHOTO_ENGINE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sourcePath":"/path/to/photos","profile":"groupEvent","cull":"balanced","target":40}'
```

A hosted service can be this same binary on an Apple Silicon worker, with upload and accounts added in front. Vision stays on the Mac either way.

The v2 API is `photocore-server`, bound to `127.0.0.1:8787`. Install it as a LaunchAgent so Vision and Core Image run in the logged-in user session (`outputs/deploy/com.photocore.server.plist`). `ProcessType` is `Interactive` so those frameworks stay at full priority. Do not install it as a LaunchDaemon.

```bash
cp .build/release/photocore-server /usr/local/bin/
cp outputs/deploy/com.photocore.server.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.photocore.server.plist
```

`PHOTO_ENGINE_TOKEN_FILE` points at a mode-600 file. If that file is missing, the server generates a token and creates it. The token is not printed when it comes from the file. `PHOTO_ENGINE_ALLOWED_ROOTS` is a colon-separated list of directories a `sourcePath` may live under.

Expose the API on a tailnet, and only there:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Put the frontend origin (the Tailscale MagicDNS name, or a dev server) in `PHOTO_ENGINE_ALLOWED_ORIGINS`. Do not bind the server to `0.0.0.0` or forward a router port.

Each run is written beneath `<output>/runs/<timestamp>-<id>/`, so rerunning with a smaller target cannot leave stale JPEGs in the current shortlist. Analysis and export never modify source files. Camera, lens, exposure, and capture metadata are retained in exports while GPS and XMP location metadata are removed by default. The optional cleanup action is separate and only proposes verified byte-identical copies.

`photo-engine-checks` is a fixture-driven regression executable that exercises grouping, bounded burst duration, deterministic selection, culling/style controls, Vision descriptor round-trips, durable catalog records, stable IDs, corrupt-file reporting, isolated outputs, metadata sanitization, warm-cache metrics, and unsafe output paths. It is deliberately runnable with the standalone Swift Command Line Tools installed on this machine; it can be migrated to XCTest/Swift Testing without changing the fixture coverage when the app moves into an Xcode project.

Vision feature-print revision 2, measured on 512–1024 px thumbnails:

| Shoot | Same moment, ≤ 3 s apart | Unrelated, > 5 min apart |
|---|---|---|
| Night event (Pycon) | p50 **0.45** (p10 0.34, p90 0.60) | p1 **0.58**, p50 1.05 |
| Daytime travel (Italy, RAW) | p50 **0.29** (p10 0.18, p90 0.56) | p1 **0.58**, p50 1.06 |

Pairs at 0.30–0.47 were the same shot repeated. 0.52–0.57 were the same scene with a different composition. A same-shot threshold of about **0.50**, and a same-moment threshold of about **0.62** only when frames are within 3 seconds, is what the profiles use. Older Hamming-scale cutoffs of 7–10 were 15–20× too large for this distance.

Vision face signals are not fully deterministic on borderline faces (see the evaluation log); a single shared face-detection pass is the planned fix. Person identity, a learned ranker, and lens-profile chromatic aberration beyond `CIRAWFilter` stay out of scope. Automatic culling never modifies source photographs; cleanup is limited to an explicit, verified exact-duplicate Trash action. Occasion profiles change which technical rejects are hard-hidden (creative keeps unusual frames; group events protect faces). Record a release-build owner run in `outputs/evaluation-log.md` when the Pycon and Italy slices are measured again.

## Repository policy

Source photographs, generated exports, private test fixtures, downloaded models, credentials, and application databases must not be committed.
