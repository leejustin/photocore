# Bound business model

**Free to make. Pay to keep. Print to own.**

Written 2026-10-02, updated 2026-10-03 when it was built and the consumer app was named Bound. Replaces the plan table in `product-strategy.md`. Prices are starting points to test, but the shape is the decision.

## The one-paragraph model

Picking is free, forever, on the phone, for everyone. Every book is free to make, free for every friend to join from a link, and free to view for 90 days. Then it goes away unless someone keeps it. Anyone in the book, not only the organizer, can keep it for good with one $4.99 Trip Pass, and anyone can order a printed copy. Weddings and large events pay a flat pass up front. A yearly plan exists only for people who keep buying passes, and we never lead with it. Revenue comes from kept books and prints. Growth comes from every free book reaching every person in it.

## Why this shape

- **Nobody pays to try, join or view.** Participation is the whole growth loop. Any price at the door kills it. The wedding market shows browser links with no account get 65 to 85% of guests to upload; an app requirement halves that.
- **The paid moment is emotional, not technical.** People pay to keep memories and to hold them. They don't pay to remove a footer or unlock a style. "This book goes away in 7 days" is a conversion moment every book gets, automatically.
- **Every person in the book is a buyer.** A trip with eight friends has eight people who could keep it or print it. The old plan asked only the organizer.
- **No subscription required, ever.** Photo apps keep about 23% of annual subscribers because use comes in bursts. Trips are bursts. A pass per trip matches how people actually use it. The yearly plan is a discount for heavy users, offered after they've proven they are one.
- **We are not a storage company.** Google Photos is free and infinite. Pay-to-keep says plainly: we don't hold your library, we keep your book.

## The products

| | Price | What you get | Who buys |
|---|---|---|---|
| **Pick** | Free, forever | Every trip picked on the phone. Picks saved to Photos, snapshot cards, highlight reel. Nothing uploaded. | Nobody. This is the habit. |
| **Book** | Free to make | Invite up to 15 friends by link, 150 photos each. Best shot of each moment across everyone, credits, grounded diary, Book style, "Made free with Bound" footer. Every friend can find and save the photos they're in. Online 90 days, with reminders at 7 days and 1 day. | Nobody. This is the growth loop. |
| **Keep (Trip Pass)** | $4.99 once | The book stays up for good. Both styles, editing, the Instagram set, no footer, room for 25 friends, and a download of everyone's full-size photos. | Anyone in the book, in the app or on the book page. |
| **Event Pass** | $39 once | A wedding or big party. Up to 100 friends, 300 photos each, kept for good from the start. | The couple, the planner, the host. |
| **Prints** | Per order | Softcover 8.5 x 8.5 from $29, hardcover from $49, standard shipping included, printed by Lulu. | Anyone in the book, and their parents. |
| **Yearly** | $24.99 a year | Every book you make is kept, up to 12 a year. Offered in the app only after two Trip Passes in 12 months. | The 5% who travel a lot. |

"Keep" is the verb on every page; the Trip Pass is what keeps a book. That joins this model with the brand's choice to keep the Trip Pass and Event Pass names. A Snapshots print pack (from $15) was in the first draft; it needs a printer that makes loose prints and is not built.

Friends never pay to add or view. Nobody needs an account to do either. Buying creates an account by email so the purchase survives a lost phone.

### What's removed from the current plan

- **Plus monthly at $2.99.** Monthly subscriptions for burst products churn, confuse the choice, and anchor the price low.
- **The 5-friend cap on free books.** A 10-person trip that can't make a free book is a lost growth loop and ten lost buyers. The paid moment is keep and print, not size. Weddings are the exception because 100 guests cost real money and have real budgets.
- **"First book free per phone."** Every book is free to make. The thing that's scarce is permanence.
- **Size as the main paywall.** Keeping a book adds room for 25 friends instead of 15, but the pitch is keeping and printing.
- **Features as the paywall.** Styles and the Instagram set come with Keep, but they're not the pitch.

## Who pays on which platform

The server is the source of truth for plans and limits, so both channels enforce the same rules and the same prices.

| Buyer is on | Cull runs on | Pays through | Cut | Our cost per book |
|---|---|---|---|---|
| iPhone | Their phone | StoreKit | 15% (Small Business Program) | Low: keepers only are uploaded |
| Android or web | Our Apple Silicon server | Stripe on the book page | ~3% | Higher: full upload, server cull, rejects deleted within 24 hours |

These roughly cancel. The Keep and Print buttons on the book page itself use Stripe, which means a friend on Android can buy without any app. Apple allows this because the book is consumed in a browser, not in the app; the app itself only ever offers StoreKit.

## Unit economics

Per group book, 8 people, 600 uploaded photos, 150 in the book. Assumptions, to be replaced with measurements from the first ten trips.

| Item | Cost |
|---|---|
| Cull and render on an Apple Silicon Mac | about $0.02 |
| Diary and captions (Gemini Flash Lite) | about $0.01 |
| Transient storage, originals, deleted after finish | about $0.05 |
| Hosting a kept book (150 finished photos, ~100 MB) | about $0.02 a year |
| 90 days of hosting for a free book | about $0.01 |
| **Total to make and host a free book** | **under $0.10** |

| Revenue line | Price | Cost | Gross margin |
|---|---|---|---|
| Keep via StoreKit | $4.99 | $0.75 cut + $0.10 | about $4.15 |
| Keep via Stripe | $4.99 | $0.45 fee + $0.10 | about $4.45 |
| Softcover book via a print API (Lulu, Gelato, Peecho) | $29 | $12 to $15 print and ship | about $14 |
| Hardcover | $49 | $20 to $25 | about $25 |
| Event | $39 | $1 to $2 all in | about $31 after cut |

Per 100 free books, with targets rather than hopes:

| Assumption | Target | Per 100 books |
|---|---|---|
| People in a book | 8 | 800 people reached |
| Books kept by someone | 25% | 25 x $4.15 = $104 |
| Books with at least one print order | 10% | 10 x $14 = $140 |
| New organizers from friends within 90 days | 1 per book | 100 new books next cycle |
| **Revenue per 100 free books** | | **about $245 on $10 of cost** |

The growth number is the one that matters. Above one new organizer per book the product grows without paid acquisition. Below it, revenue per book has to fund ads, and at $2.45 a book it can't. So the first ten trips exist to measure that number, not revenue.

## How each dollar is earned

**Keep** is earned by the 90-day clock. Every person in the book gets the 7-day and 1-day reminder, with the cover photo and "Ana, Sam and Priya's photos are in it." One in eight is enough.

**Prints** are earned three times: when a book is kept, in a holiday round ("your 2026 trips, printed"), and from the book page itself, where visitors can already tap "I'd want this printed." That tap becomes a buy button the day a print partner is wired up.

**Event** is earned before the event by the person with a budget. The pitch is the same as the QR-code wedding apps, at the low end of their $25 to $200 range, with the one thing none of them do: a finished book and each guest's photos of themselves.

**Yearly** is earned by the second Keep. It's a thank-you to heavy users, not the plan.

## The free tier is a marketing budget, and it's cheap

Culling costs nothing because it runs on the phone. A free book costs under a dime and reaches eight people. A $5 CPM on Instagram reaches a thousand strangers who weren't on the trip. There's no cheaper acquisition than a free book, so the free tier should stay generous: 15 friends, 150 photos each, every style of trip, no count limit on free books. The only free thing that expires is hosting, because that's the thing people pay for.

## Later, not now

- **Event Pass in bulk** for planners, venues and tour operators, 10 at a time at a discount. The venue spec in `venue-photo-content-subscription-spec.md` is this.
- **Gift a Keep.** Buy a Keep for someone else's book. Parents will.
- **Yearbook.** All of a person's kept books from a year as one printed volume.
- **Android app** only when web owners on Android convert and name upload size as the reason they churn.

## What has to be true

| Question | Target | If it fails |
|---|---|---|
| Do invited friends upload? | 60% of them | The group angle fails. The free cull is the product, and Keep applies to solo books. |
| Does someone keep the book? | 25% of books | The book isn't good enough yet. Fix the book before the price. |
| Does anyone print? | 10% of books, measured by the interest tap until a partner is live | Prints stay a feature, and Keep has to carry revenue. |
| Does it spread? | 1 new organizer per book | Below 0.5, this is a paid-acquisition business and the prices need to triple. |

## What's built

Built on 2026-10-03 (see `consumer-build-plan.md`, chunks 18 to 29):

- `Plan` and `PlanLimits`: free books take 15 friends with 150 photos each and stay up 90 days; any number of free books; the Trip Pass and Yearly add 25 friends, both styles, editing, the Instagram set and the download; the Event Pass takes 100 friends with 300 photos each; monthly is retired.
- The lifecycle: reminders at 7 days and 1 day to everyone who gave an email, an offline page that can still be kept for 30 days, then the photos are deleted.
- Stripe Checkout on `/b/{slug}/keep`, `/b/{slug}/print` and the web owner's Event Pass, with signed webhooks writing to the same ledger as StoreKit.
- The full-size download for kept books.
- Lulu behind printed copies, with the interior and cover made from the book.
- Yearly is offered only after two passes in 12 months, counted on the phone.

Not built: App Store Server Notifications (refunds and renewals), so a Yearly book's hosting is set when it's applied, not when the subscription renews.
