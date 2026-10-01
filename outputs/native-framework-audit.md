# Native framework audit

Where Photocore uses Apple's frameworks, where it still builds its own, and what to move next. Checked against the code on 2026-10-01.

## Already native

| Job | Framework |
|---|---|
| Sharpness, faces, scenes, saliency, subject masks, sign text | Vision |
| Edits, subject-aware finish, reel frames and crossfades | Core Image |
| Reading the library, albums, Live Photo motion, saving | PhotoKit |
| Diary on the phone, or Private Cloud Compute with photos on OS 27 | Foundation Models |
| Checking the diary for invented names and events | NaturalLanguage |
| Nearby landmarks | MapKit |
| Calendar suggestions | EventKit |
| Reading the book in the app | SafariServices |
| Polaroid cards | SwiftUI ImageRenderer |
| Highlight reel encode and playback | AVFoundation, AVKit |
| Sharing | ShareLink |

## Move next, in order

1. **StoreKit 2 for the paid finish.** The book is a digital good, so App Store rules require in-app purchase for it. Printed books are physical and may use Apple Pay with any processor. The server should check the signed transaction before it starts a finish job.
2. **Keychain for owner links.** The edit link holds the owner token and is saved in UserDefaults today. Keychain with iCloud sync keeps it safe and survives a reinstall or a new phone. This also removes the need for accounts at launch. Sign in with Apple can come later, when people want their books on the web without the phone.
3. **Background upload session.** Keeper uploads use a normal URLSession and stop when the app is closed. A background URLSession lets the system finish them.
4. **BGContinuedProcessingTask for long culls (iOS 26).** Culls already resume from checkpoints. This task keeps a cull running after the person leaves the app, with system progress.
5. **MapKit reverse geocoding.** Place names still use CLGeocoder, which iOS 26 deprecates in favor of MapKit's geocoding requests. The engine already has an availability branch for the newer MapKit API.
6. **WeatherKit as a diary fact.** Sun times are computed by hand today. WeatherKit gives sunrise and sunset plus the day's past weather, which is a grounded fact the diary can use ("a rainy morning"). It needs a developer membership and has a free monthly allowance.
7. **Translation for sign text.** Text read from photos in another language can be translated on the device before it becomes a fact, so captions on foreign trips make sense.
8. **Live Activity for the finish.** A paid finish takes minutes on the server. A Live Activity with push updates shows progress on the lock screen and opens the book when ready.
9. **App Intents.** "Finish my last trip" in Shortcuts and Siri, and a widget for "Book ready". Low effort once the above is done.

## Keep our own

- **Guest photos on the book page.** Third-party apps cannot create or post to iCloud Shared Albums, and guests may not use iPhones. The web upload stays.
- **Hosting books.** CloudKit cannot serve a public web page to anyone with a link. The server stays.
- **Reel music.** Apple Music tracks cannot be put into an exported video. Ship a few royalty-free tracks, or none.
- **Memories.** PhotoKit cannot create Photos Memories, so the reel is saved as a video instead.
