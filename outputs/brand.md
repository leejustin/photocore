# Bound brand

**Finish the trip.** Everyone's photos. One book.

Written 2026-10-03. The consumer app is **Bound**. **Photocore** stays the name of the engine packages, the CLI, the server binary and the Mac studio, because the pro tool should sound like a pro tool.

## Why Bound

One syllable with three meanings, all on message:

- **A bound book.** The output.
- **Bound together.** The group.
- **Bound for somewhere.** The trip.

It reads well in a sentence ("add your photos to the Bound"), works for a solo trip and a group one, and gives a logo for free: a spine, a ribbon marker, a stitch.

## Before launch

- **Trademark search.** Several App Store apps are called Bound: an audiobook player, a driver app, a business messaging tool and a romance reader. None are in photos, so coexistence is plausible, but a real search comes before anything is printed. That's the Polaroid lesson.
- **Listing name.** "Bound: Trip Photo Books".
- **A short domain for invite links.** bound.app is likely taken. `PHOTOCORE_SITE_URL` and `PHOTOCORE_PUBLIC_URL` point at whatever is chosen.
- **Fallback name: Pressed.** Pressed flowers, pressed into a book, off the press. No photo-app conflicts, but less group-coded, and a juice brand owns the word culturally.

Rejected after checking: Keepsake (five or more photo apps), Rollcall (a Locket feature), Souvenir and Recap (direct group-album competitors), Oneroll and Keepers (camera and culling apps).

## Voice

Plain, warm, short. The diary's grounded style is the voice of the whole product: it only says what happened.

| Say | Never say |
|---|---|
| picks, your best | keepers (photographer jargon) |
| friends | guests, contributors |
| book, trip | memories (Apple and Google own it) |
| set aside | album, content, curate, AI, magic |

Kept as they are: **Set aside**, **Trip Pass**, **Event Pass**. "Keep" is the verb on every book page ("Keep it for $4.99"), and the Trip Pass is what keeps it. That joins the business model's pay-to-keep with the names above.

Fixed lines:

- The free footer is **"Made free with Bound"**.
- **"Make one for your trip"** is on every book page. It is the growth loop.
- The invite page headline is **"Sam is making a book of Lisbon. Add your photos."**

## Look

Paper, not glass. The app feels like the object it makes.

| Token | Light | Dark |
|---|---|---|
| Paper | `#f7f2ea` | `#141210` |
| Ink | `#1e1b18` | `#efeae2` |
| Ribbon (the one accent) | `#b3322b` | `#e06b61` |

- A serif for anything that's part of the book. The system sans for controls.
- The two book styles already fit: Book is the clean serif edition, Snapshots is the pinned-prints edition.
- No gradients, no glossy icon. The icon is an ink-black book on cream stock with a red ribbon marker below the pages.

## The invite page is the brand

Most people meet Bound through a friend's invite link, in a browser, before they ever see the app. That page is designed like a book cover with their friend's name on it, not like an upload form. Once the book exists, its cover photo is on that cover.

## What stays Photocore

Engine packages, `photo-engine`, `photocore-server`, the Mac studio, internal identifiers (bundle ID `com.photocore.trip`, App Store product IDs, request headers, storage keys). App Store product IDs can never change, and renaming the bundle ID is a decision for App Store Connect, not code.
