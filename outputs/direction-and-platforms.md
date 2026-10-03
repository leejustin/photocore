# Bound direction: group picking, local-first, and Android

Written 2026-10-03; everything in section 6 except the real trips and the native Android app was built the same day (see `consumer-build-plan.md`, chunks 18 to 29). Companion to [`product-strategy.md`](./product-strategy.md) (the story and the market) and [`business-model.md`](./business-model.md) (who pays, for what, and why). This document records the product reasoning behind the group book, how group culling stays local, what makes it worth joining, how we position against Google Photos, and how Android users are served without an Android engine.

## 1. Culling is the engine, not the product

Photocore started as a culling app. It hasn't drifted; culling has moved from the headline to the engine. Nobody opens an app because they want to cull. They open it for what culling produces: the album, the reel, the book. The group book is the strongest version of that because a group trip is the one case where a person literally cannot finish the trip alone. The best photo of them is on someone else's phone.

Solo and group are one product, not two:

- **Solo is the habit.** After every trip, the phone picks the best photos for free. Album, snapshot cards, highlight reel. Costs us nothing to run because it's on-device.
- **Group is the event.** Same engine, same review UI, with friends added from a link. The output is the book.
- **One sentence:** your phone picks your best. Together, you get the book.

## 2. Group culling that stays local

### What exists

`GroupCuration` (in `PhotoEngineWorkflow`) already dedupes across people: each person's uploads are culled on their own, the owner's keepers are always kept, the best frame of each moment wins across everyone (visually close and within 45 minutes), and contributors share a budget round-robin. It takes a distance closure and is pure Swift.

The gap: it runs on uploaded photos. Friends send everything, the server picks. That breaks "nothing leaves your phone" the moment a second person joins, and it makes uploads large, which is the main thing that stops friends from finishing the join flow.

### The design: analysis first, originals second

A two-phase protocol. Each iPhone culls locally, then uploads only the analysis for its keepers:

1. **Offer.** For each local keeper: the Vision feature print, capture time, the cull score, and a 512 px thumbnail. This is roughly the 5 KB per photo the engine already stores in its analysis cache. `GroupCuration` runs on the server over everyone's offers. Feature prints from the same Vision revision compare across devices, so the measured same-shot threshold of about 0.50 and same-moment threshold of about 0.62 within 3 seconds carry over (see the README table and the evaluation log).
2. **Pull.** The server asks each phone only for the originals it chose. Losers never leave the phone.

What this buys:

- **Privacy survives the group.** The server never sees a photo that didn't make the book.
- **Uploads shrink by about an order of magnitude**, which protects the 65 to 85% browser participation the plan depends on.
- **Fairness gets real.** Round-robin runs over everyone's full keeper set, not whatever they got around to uploading.

iPhone friends get this through the App Clip already on the roadmap: open the link, the App Clip culls on their phone and offers analysis, no install. Android and browser friends use today's upload path with server-side culling (section 5). We do not try to cull in a mobile browser.

Owner edits to the book stay as they are: stored apart from generated text on the server, surviving every refinish.

## 3. Making it worth joining

### Reciprocity: make the invite an offer, not a favor

Today the invite asks friends to give photos. The strongest single change is to make joining selfish: **add your photos, get everyone's photos of you.** It's the reason a friend actually opens the link, and it's the thing Apple shared albums and Google collaborative Memories don't do across platforms.

Implementation, as built: after each finish the server keeps an aligned crop and an embedding of every clear face in the book. A friend taps their own face once or twice on the invite page; faces close to their taps, in the same book, are theirs. They can tap more, say "not me", and save all their photos as one zip, free. Nothing is matched against a name or anything outside the book, and it's deleted with the book.

The first plan was a selfie at join. Measured on a real event shoot, Vision feature prints of face crops group a person reliably only within a trip, where clothes, glasses and light match; a selfie taken elsewhere wouldn't match. Tapping a face in the book uses exactly that strength and collects nothing new. A licensed Core ML face-embedding model (`PHOTOCORE_FACE_MODEL`) would find more of each person.

### Live during the trip, not only after

Keep the link open during the trip, let friends add as they go, and refinish the book each night. "Day 2 is in" is a notification people want. Chapters by local day and the refinish-with-more-photos flow already exist, so this is mostly scheduling and a push.

### Smaller levers, later

- Close calls between two people's shots of the same moment offered as a one-tap "which one?" to both, in the browser. Social, cheap, and makes the book feel co-made.
- A Live Activity on the lock screen while the book is made (already in the native audit).

## 4. Positioning against Google Photos

Don't compete directly, and the way to avoid it is to refuse to be a library. Google Photos stores, organizes and searches. Photocore finishes and leaves.

**Never build:** a browsable library, search, backup, face albums, a timeline. The moment we have those we are a worse Google Photos.

**Positions Google structurally can't take:**

- **We don't keep your photos.** Their business is keeping them. On iPhone the cull runs on the phone; on the web the server deletes what it didn't keep within 24 hours.
- **Finished output.** A book, a diary, prints. Google ends at a grid.
- **Works for the whole group** across platforms, from a link, with no account.
- **A pro-grade engine** that also serves RAW shooters through the Mac studio.

The biggest risk stays Apple or Google adding curation to shared albums. The answer is speed on the book and prints, not depth on the protocol.

## 5. Android without an Android engine

The Swift dependency is already on the server, not only the phone. `photocore-server` runs Vision and Core Image on an Apple Silicon Mac, and Android friends already go through it. Android users don't need the engine on their device; they need our Macs. **The Apple Silicon fleet is the Android strategy**, and it's already built.

### Three levels, cheapest first

**Level 1: Android as contributor, in the browser.** Built. The one cheap improvement is a few hundred lines of JavaScript on the join page: read EXIF timestamps, compute a perceptual hash and a blur score, and drop exact bursts and obvious misses before upload. Cuts uploads two to three times. A weekend of work. Do not run a real embedding model in a mobile browser; tab lifecycle, memory and battery on Android Chrome make it unreliable.

**Level 2: Android as owner, on the web.** A web app where an Android organizer creates the trip, picks photos from their phone, and the server does the whole finish. No native app, no Play Store. The routes exist; this is a web front end plus Stripe Checkout. This is the real unlock, because an Android organizer who can't start a trip is a lost sale and a lost growth loop. Trigger: log the user agent on the book page's "Make one for your trip" tap. If a meaningful share is Android (expect 30 to 40% in US friend groups), build it.

**Level 3: a native Android app that culls on-device.** Only if Level 2 shows Android owners converting and then churning with upload size as the stated reason. The seam is cleaner than it looks:

- `PhotoEngineCore` has no Apple imports. Trip detection, taste memory, key faces and multi-camera sync are portable Swift.
- `GroupCuration` is pure Swift and takes a distance closure; it doesn't care where distance came from.
- Swift on Android is officially supported, so pipeline logic ships as-is. The work is a `PhotoEngineAndroid` signals module on ML Kit faces and LiteRT.

The hard part is not the port. Vision feature prints exist only on Apple platforms, so an Android phone cannot produce a distance comparable to an iPhone's. Cross-person dedupe would need one shared embedding model computed on both platforms (MobileCLIP or a small DINOv2, through Core ML on iOS and LiteRT on Android). iPhones would run Vision for quality and faces and the shared model for cross-device comparison, and every threshold would be re-measured. That's months. Don't start it on speculation.

### Platform and payment

| Buyer is on | Cull runs on | Pays through | Cut | Our cost per book |
|---|---|---|---|---|
| iPhone | Their phone | StoreKit | 15% | Low: only keepers are uploaded |
| Android or web | Our Apple Silicon server | Stripe on the book page | about 3% | Higher: full upload and server cull, rejects deleted within 24 hours |

These roughly cancel. The server is the source of truth for `Plan` and `PlanLimits`, so both channels enforce the same rules at the same prices. The promise differs by platform and we say so: on iPhone your phone picks and nothing leaves; on the web our server picks and deletes what it didn't keep within 24 hours. Ephemerality is the universal promise; local-first is the iPhone bonus.

## 6. Order of work

1. **Run the 5 to 10 real group trips** the strategy doc calls for. Still to do, and now the most important thing: everything below is built and needs real groups to judge it.
2. **Level 1 browser pre-filter** on the join page. Built.
3. **Analysis-first protocol with the App Clip.** Built; verified end to end in the simulator. Needs a domain, an Apple team and an App Store record to run from a real link.
4. **"Photos of you."** Built, by tapping your face rather than a selfie (see section 3). Measure whether it moves participation.
5. **Nightly refinish during the trip.** Built, with emails and APNs pushes.
6. **Level 2 web owner flow.** Built at `/new`, ahead of the user-agent evidence, because "Make one for your trip" needed somewhere to send Android visitors. The make-one taps are counted by platform (`/v2/metrics/growth`) so the decision below has data.
7. **Level 3 native Android**, only on evidence. Not built, by design.

Each of 3 through 5 adds server surface. Speed on the book and prints matters more than depth on the protocol.
