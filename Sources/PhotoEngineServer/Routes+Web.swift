import Foundation
import HTTPTypes
import Hummingbird
import PhotoEnginePersistence
import PhotoEngineWorkflow

/// Making a book on the web, for people without the iPhone app (Android
/// owners, mostly). `/new` starts one; the private owner page adds photos,
/// shares the invite, makes the book and buys an Event Pass. Nothing was
/// culled on a phone, so the server culls the owner's photos too, and deletes
/// the ones it didn't pick.
struct WebCreateBody: Decodable, Sendable {
    var title: String?
    var ownerName: String?
    var email: String?
    var timeZone: String?
    /// Cloudflare Turnstile's token, when the server asks for one.
    var turnstile: String?
}

struct WebCreatedDTO: Encodable, Sendable {
    var id: String
    var ownerToken: String
    var ownerPath: String
}

struct WebJobDTO: Encodable, Sendable {
    var state: String
    var message: String?
    var error: String?
}

struct WebTripDTO: Encodable, Sendable {
    var id: String
    var title: String?
    var ownerName: String?
    var bookPath: String
    var inviteURL: String?
    var inviteOpen: Bool
    var ownerPhotos: Int
    var friends: [ContributorDTO]
    var newSinceFinish: Int
    var plan: Plan
    var limits: PlanLimits
    var finishedAt: Date?
    var hostedUntil: Date?
    var job: WebJobDTO?
    var canBuy: Bool
}

/// A few new books an hour from one address, and a ceiling for everyone, so
/// the free web door can't be used to fill the disk.
actor CreationLimiter {
    private var recent: [String: [Date]] = [:]
    private var all: [Date] = []
    let perAddress: Int
    let total: Int

    init(perAddress: Int = 10, total: Int = 300) {
        self.perAddress = perAddress
        self.total = total
    }

    func allow(_ address: String, now: Date = Date()) -> Bool {
        let hour = now.addingTimeInterval(-3_600)
        all.removeAll { $0 < hour }
        var mine = (recent[address] ?? []).filter { $0 >= hour }
        guard mine.count < perAddress, all.count < total else { recent[address] = mine; return false }
        mine.append(now)
        all.append(now)
        recent[address] = mine
        return true
    }
}

/// Cloudflare Turnstile, when `TURNSTILE_SECRET` and `TURNSTILE_SITE_KEY` are set.
enum Turnstile {
    static func verify(token: String?, secret: String, address: String?) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        var request = URLRequest(url: URL(string: "https://challenges.cloudflare.com/turnstile/v0/siteverify")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = [("secret", secret), ("response", token)]
        if let address { form.append(("remoteip", address)) }
        request.httpBody = Data(StripePayments.encode(form).utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["success"] as? Bool == true
    }
}

enum WebLimits {
    /// The owner's own photos on the web, before the server culls them.
    static let ownerPhotos = 600
}

func registerWebOwnerRoutes(
    _ router: Router<BasicRequestContext>,
    env: ServerEnvironment,
    trips: TripStore,
    lifecycle: BookLifecycle,
    address: PublicAddress,
    canBuy: Bool,
    startFinish: @escaping @Sendable (String) async throws -> JobRecord,
    checkout: @escaping @Sendable (CheckoutKind, TripRecord, String?) async throws -> Response
) {
    let limiter = CreationLimiter()
    let configuration = env.configuration

    @Sendable func clientAddress(_ request: Request) -> String {
        request.headers[HTTPField.Name("X-Forwarded-For")!]?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "local"
    }

    @Sendable func owner(_ request: Request, _ context: BasicRequestContext) async throws -> TripRecord {
        let id = try context.parameters.require("id")
        guard let record = await trips.record(id: id), record.webOwner == true else { throw APIError.notFound("No book.") }
        let bearer = request.headers[.authorization].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        guard await trips.isOwner(record, token: bearer) else { throw APIError.unauthorized("This link is for the person making the book.") }
        return record
    }

    router.get("new") { _, _ in
        Pages.response(WebPages.new(turnstileSiteKey: configuration.turnstileSiteKey), status: .ok, allowTurnstile: configuration.turnstileSiteKey != nil)
    }

    router.post("w/trips") { request, context in
        let body = try await request.decode(as: WebCreateBody.self, context: context)
        let from = clientAddress(request)
        guard await limiter.allow(from) else { throw APIError.busy("Too many new books from here just now. Try again in an hour.") }
        if let secret = configuration.turnstileSecret, !secret.isEmpty {
            guard await Turnstile.verify(token: body.turnstile, secret: secret, address: from == "local" ? nil : from) else {
                throw APIError.forbidden("Please try the check again.")
            }
        }
        let title = body.title.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
        let name = body.ownerName.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TripLimits.nameLength)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard name != nil else { throw APIError.invalid("Add your first name, for the photo credits.") }
        var email: String?
        if let raw = body.email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard Mailers.isAddress(raw) else { throw APIError.invalid("That email doesn't look right.") }
            email = raw
        }
        let (record, token) = try await trips.create(title: title, context: .empty, tone: .warm, theme: .book, ownerName: name)
        try await trips.update(record.id) { trip in
            trip.webOwner = true
            if let zone = body.timeZone, TimeZone(identifier: zone) != nil { trip.timeZone = zone }
        }
        let ownerPath = "/w/\(record.id)#owner=\(token)"
        if let email {
            try await trips.setOwnerEmail(record.id, email: email)
            try? await lifecycle.mailer.send(MailTemplates.ownerLink(
                to: email, title: title ?? "your trip", ownerURL: address.base + ownerPath,
                inviteURL: TripPaths.invite(record).map { address.base + $0 }
            ))
        }
        return try APIJSON.response(WebCreatedDTO(id: record.id, ownerToken: token, ownerPath: ownerPath), status: .created)
    }

    router.get("w/{id}") { _, context in
        let id = try context.parameters.require("id")
        guard let record = await trips.record(id: id), record.webOwner == true else { throw APIError.notFound("No book.") }
        return Pages.response(WebPages.owner(id: record.id, title: record.title))
    }

    router.get("w/trips/{id}") { request, context in
        let record = try await owner(request, context)
        var friends: [ContributorDTO] = []
        for person in await trips.contributors(record.id) {
            friends.append(ContributorDTO(name: person.name, photos: await trips.photoCount(await trips.contributorFolder(record.id, person.id))))
        }
        var job: WebJobDTO?
        if let id = record.lastJobID, let stored = try? await env.jobs.job(id: id) {
            job = WebJobDTO(state: stored.state, message: stored.message, error: stored.errorMessage)
        }
        return try APIJSON.response(WebTripDTO(
            id: record.id, title: record.title, ownerName: record.ownerName,
            bookPath: TripPaths.book(record.slug), inviteURL: TripPaths.invite(record).map { address.base + $0 },
            inviteOpen: record.inviteOpen, ownerPhotos: await trips.photoCount(await trips.ownerFolder(record.id)),
            friends: friends, newSinceFinish: await trips.newSinceFinish(record.id),
            plan: record.currentPlan, limits: record.limits, finishedAt: record.finishedAt, hostedUntil: record.hostedUntil,
            job: job, canBuy: canBuy
        ))
    }

    router.put("w/trips/{id}/photos/{name}") { request, context in
        let record = try await owner(request, context)
        let name = try context.parameters.require("name")
        guard await trips.photoCount(await trips.ownerFolder(record.id)) < WebLimits.ownerPhotos else {
            throw APIError.conflict("That's as many photos as one book takes from you (\(WebLimits.ownerPhotos)).")
        }
        let buffer = try await request.body.collect(upTo: TripLimits.uploadBytes)
        let url = try await trips.store(photo: Data(buffer: buffer), name: name, id: record.id, guest: false, limit: WebLimits.ownerPhotos)
        return try APIJSON.response(UploadDTO(stored: url.lastPathComponent, count: await trips.photoCount(await trips.ownerFolder(record.id))), status: .created)
    }

    router.post("w/trips/{id}/finish") { request, context in
        let record = try await owner(request, context)
        let stored = try await startFinish(record.id)
        return try APIJSON.response(WebJobDTO(state: stored.state, message: nil, error: nil), status: .accepted)
    }

    router.post("w/trips/{id}/invite") { request, context in
        let record = try await owner(request, context)
        let body = try await request.decode(as: InviteBody.self, context: context)
        try await trips.update(record.id) { $0.inviteClosed = !body.open }
        return try APIJSON.response(["open": body.open])
    }

    /// The Event Pass for a wedding or big party, bought on the web.
    router.post("w/trips/{id}/event") { request, context in
        let record = try await owner(request, context)
        guard record.currentPlan.rank < Plan.eventPass.rank else { throw APIError.conflict("This book already has the Event Pass.") }
        return try await checkout(.event, record, "/w/\(record.id)")
    }

    router.post("w/trips/{id}/keep") { request, context in
        let record = try await owner(request, context)
        guard record.currentPlan == .free else { throw APIError.conflict("This book is already kept.") }
        return try await checkout(.keep, record, "/w/\(record.id)")
    }
}

/// The two web pages for making a book.
enum WebPages {
    static func new(turnstileSiteKey: String?) -> String {
        let check = turnstileSiteKey.map { "<div class=\"cf-turnstile\" data-sitekey=\"\(InvitePage.escape($0))\"></div>" } ?? ""
        let body = """
        <span class="ribbon" aria-hidden="true"></span>
        <h1>Make a book of your trip</h1>
        <p class="muted">Add your photos, send friends a link to add theirs, and Bound makes one book: the best shot of each moment, a short diary of where you went, everyone credited. Free for 90 days.</p>
        <form id="start" class="card">
          <label for="title">Where did you go?</label><input id="title" maxlength="120" placeholder="Lisbon, Sam's birthday weekend" required>
          <label for="name">Your first name</label><input id="name" maxlength="40" autocomplete="given-name" required>
          <label for="email">Email <span class="muted">(optional)</span></label><input id="email" type="email" maxlength="254" autocomplete="email" placeholder="We'll send your private link here">
          \(check)
          <p style="margin-top:18px"><button type="submit" id="go">Start the book</button></p>
          <p class="fine" id="err" hidden></p>
        </form>
        <p class="fine">On iPhone? The Bound app picks your best photos on the phone first.</p>
        """
        let script = """
        (function(){
          var form = document.getElementById('start');
          form.addEventListener('submit', function(e){
            e.preventDefault();
            var go = document.getElementById('go'); go.disabled = true;
            var t = document.querySelector('[name="cf-turnstile-response"]');
            var body = { title: document.getElementById('title').value, ownerName: document.getElementById('name').value,
              email: document.getElementById('email').value, timeZone: (Intl.DateTimeFormat().resolvedOptions().timeZone || null), turnstile: t ? t.value : null };
            fetch('/w/trips', { method:'POST', headers:{ 'Content-Type':'application/json' }, body: JSON.stringify(body) })
              .then(function(r){ return r.json().then(function(d){ if (!r.ok) throw d; return d; }); })
              .then(function(d){ try { localStorage.setItem('bound-owner-' + d.id, d.ownerToken); } catch (x) {} location.href = d.ownerPath; })
              .catch(function(e){ go.disabled = false; var err = document.getElementById('err'); err.hidden = false; err.textContent = (e && e.error && e.error.message) || 'That didn\\u2019t work. Try again.'; });
          });
        })();
        """
        var page = Pages.shell(title: "Make a book · Bound", body: body, script: script)
        if turnstileSiteKey != nil {
            page = page.replacingOccurrences(of: "</head>", with: "<script src=\"https://challenges.cloudflare.com/turnstile/v0/api.js\" async defer></script></head>")
        }
        return page
    }

    static func owner(id: String, title: String?) -> String {
        let body = """
        <span class="ribbon" aria-hidden="true"></span>
        <h1 id="title">\(InvitePage.escape(title ?? "Your book"))</h1>
        <p class="muted" id="lede">Your private page for this book. Keep the link to come back.</p>
        <div class="card" id="nolink" hidden><p>Open this page from the link you were sent, or from the browser where you started the book.</p></div>
        <div id="panel" hidden>
          <div class="card">
            <h2 class="step">Your photos</h2>
            <p class="muted" id="mine">Add everything from the trip. Bound picks your best, and skips repeats and blurry ones before anything goes up.</p>
            <label class="button" style="display:inline-block">Add photos<input id="files" type="file" accept="image/*" multiple hidden></label>
            <div id="progress" hidden><div class="bar"><span id="bar"></span></div><p id="status" class="muted"></p></div>
          </div>
          <div class="card">
            <h2 class="step">Friends</h2>
            <p class="muted">Send this link to everyone who was there. No app or account needed.</p>
            <p><input id="invite" readonly></p>
            <p><button type="button" class="quiet" id="copy">Copy the link</button> <button type="button" class="quiet" id="share" hidden>Share</button></p>
            <ul id="friends" class="list"></ul>
          </div>
          <div class="card">
            <h2 class="step">The book</h2>
            <p class="muted" id="bookline">When everyone's added theirs, make the book. You can make it again as more photos come in.</p>
            <p><button type="button" id="finish">Make the book</button></p>
            <p id="job" class="muted" hidden></p>
            <p id="read" hidden><a class="button quiet" id="readlink" href="#">Read the book</a></p>
          </div>
          <div class="card" id="buy" hidden>
            <h2 class="step">Keep it</h2>
            <p class="muted" id="buyline"></p>
            <p><button type="button" id="keep">Keep it for $4.99</button> <button type="button" class="quiet" id="event">Event Pass, $39</button></p>
            <p class="fine">The Event Pass is for a wedding or big party: up to 100 friends, kept for good.</p>
          </div>
        </div>
        """
        let script = """
        \(Prefilter.script)
        (function(){
          var id = \(InvitePage.json(id)), key = 'bound-owner-' + id;
          var hash = (location.hash.match(/owner=([A-Za-z0-9]+)/) || [])[1];
          if (hash) { try { localStorage.setItem(key, hash); } catch (x) {} history.replaceState(null, '', location.pathname); }
          var token = hash; if (!token) { try { token = localStorage.getItem(key); } catch (x) {} }
          function $(i){ return document.getElementById(i); }
          if (!token) { $('nolink').hidden = false; return; }
          $('panel').hidden = false;
          var auth = { 'Authorization': 'Bearer ' + token }, polling = null;
          function plural(n, w){ return n + ' ' + w + (n === 1 ? '' : 's'); }
          function refresh(){
            return fetch('/w/trips/' + id, { headers: auth }).then(function(r){ if (!r.ok) throw r; return r.json(); }).then(function(t){
              $('mine').textContent = !t.ownerPhotos ? 'Add everything from the trip. Bound picks your best, and skips repeats and blurry ones before anything goes up.'
                : (t.finishedAt ? (t.ownerPhotos === 1 ? 'One of your photos is' : t.ownerPhotos + ' of your photos are') + ' in the book; the others were deleted. Add more any time.'
                : 'You\\u2019ve added ' + plural(t.ownerPhotos, 'photo') + '. Add more any time.');
              $('invite').value = t.inviteURL || '';
              var list = $('friends'); list.innerHTML = '';
              t.friends.forEach(function(f){ var li = document.createElement('li'); li.textContent = f.name + ' \\u00B7 ' + plural(f.photos, 'photo'); list.appendChild(li); });
              if (!t.friends.length) { var li = document.createElement('li'); li.className = 'muted'; li.textContent = 'No one has joined yet.'; list.appendChild(li); }
              var running = t.job && (t.job.state === 'queued' || t.job.state === 'running');
              $('finish').disabled = running || (!t.ownerPhotos && !t.friends.some(function(f){ return f.photos; }));
              $('finish').textContent = t.finishedAt ? (t.newSinceFinish ? 'Update the book with ' + plural(t.newSinceFinish, 'new photo') : 'Make the book again') : 'Make the book';
              $('job').hidden = !t.job || t.job.state === 'succeeded';
              if (t.job) $('job').textContent = running ? (t.job.message || 'Making the book') + '\\u2026' : (t.job.state === 'failed' ? (t.job.error || 'That didn\\u2019t finish. Try again.') : '');
              $('read').hidden = !t.finishedAt; $('readlink').href = t.bookPath;
              $('buy').hidden = !t.canBuy || !t.finishedAt || t.plan === 'eventPass' || t.plan === 'tripPass';
              $('keep').hidden = t.plan !== 'free';
              if (t.hostedUntil) $('buyline').textContent = 'Free books stay up for 90 days. Keep it for good, with everyone\\u2019s full-size photos to download.';
              if (running && !polling) polling = setInterval(refresh, 2500);
              if (!running && polling) { clearInterval(polling); polling = null; }
            }).catch(function(){ $('panel').hidden = true; $('nolink').hidden = false; });
          }
          function upload(files){
            var done = 0, failed = 0; $('progress').hidden = false;
            function show(){ $('bar').style.width = Math.round(100 * (done + failed) / Math.max(files.length, 1)) + '%'; $('status').textContent = 'Adding ' + (done + failed) + ' of ' + files.length + '\\u2026'; }
            show();
            return files.reduce(function(chain, file, i){
              return chain.then(function(){
                return fetch('/w/trips/' + id + '/photos/' + Date.now().toString(36) + i, { method:'PUT', headers: Object.assign({ 'Content-Type': file.type || 'application/octet-stream' }, auth), body: file })
                  .then(function(r){ if (r.ok) done++; else failed++; show(); }).catch(function(){ failed++; show(); });
              });
            }, Promise.resolve()).then(function(){ $('status').textContent = plural(done, 'photo') + ' added.' + (failed ? ' ' + plural(failed, 'photo') + ' couldn\\u2019t be added.' : ''); refresh(); });
          }
          $('files').addEventListener('change', function(){
            var files = Array.prototype.slice.call(this.files || []); this.value = '';
            if (!files.length) return;
            $('progress').hidden = false;
            window.BoundPrefilter.run(files, function(i, n){ $('bar').style.width = Math.round(100 * i / n) + '%'; $('status').textContent = 'Looking through your photos\\u2026 ' + i + ' of ' + n; })
              .catch(function(){ return { keep: files, skipped: [] }; })
              .then(function(result){ var note = window.BoundPrefilter.summary(result); return upload(result.keep).then(function(){ if (note) $('status').textContent += ' ' + note; }); });
          });
          $('copy').addEventListener('click', function(){ var v = $('invite').value; (navigator.clipboard ? navigator.clipboard.writeText(v) : Promise.reject()).then(function(){ $('copy').textContent = 'Copied'; }).catch(function(){ $('invite').select(); }); });
          if (navigator.share) { $('share').hidden = false; $('share').addEventListener('click', function(){ navigator.share({ title: document.title, text: 'Add your photos so we can make one book together.', url: $('invite').value }).catch(function(){}); }); }
          $('finish').addEventListener('click', function(){
            $('finish').disabled = true;
            fetch('/w/trips/' + id + '/finish', { method:'POST', headers: auth }).then(function(r){ return r.json().then(function(d){ if (!r.ok) throw d; return d; }); })
              .then(refresh).catch(function(e){ $('finish').disabled = false; alert((e && e.error && e.error.message) || 'That didn\\u2019t start. Try again.'); });
          });
          function buy(path){ fetch('/w/trips/' + id + '/' + path, { method:'POST', headers: Object.assign({ 'Content-Type':'application/json' }, auth), body:'{}' })
            .then(function(r){ return r.json().then(function(d){ if (!r.ok) throw d; return d; }); }).then(function(d){ if (d.url) location.href = d.url; })
            .catch(function(e){ alert((e && e.error && e.error.message) || 'Try again in a moment.'); }); }
          $('keep').addEventListener('click', function(){ buy('keep'); });
          $('event').addEventListener('click', function(){ buy('event'); });
          refresh();
        })();
        """
        var page = Pages.shell(title: (title ?? "Your book") + " · Bound", body: body, script: script)
        page = page.replacingOccurrences(of: "</style>", with: """
        main { text-align:left; } h1, .ribbon { display:block; } .ribbon { margin-left:0; }
        .step { font-family:var(--serif); font-weight:600; font-size:21px; margin:0 0 6px; }
        .list { list-style:none; padding:0; margin:12px 0 0; } .list li { padding:6px 0; border-bottom:1px solid var(--line); }
        .bar { height:8px; border-radius:99px; background:var(--line); overflow:hidden; margin-top:12px; } .bar span { display:block; height:100%; width:0; background:var(--accent); }
        </style>
        """)
        return page
    }
}
