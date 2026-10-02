import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// Renders a trip book as one self-contained HTML page. Images are siblings in
/// `photos/`. With an edit endpoint, the owner can fix any line in place.
public enum BookRenderer {
    public struct Options: Sendable {
        /// Where owner edits are POSTed (`{"key", "value"}`), or nil for a read-only page.
        public var editEndpoint: String?
        /// Where guest notes and reactions are POSTed, or nil to hide them.
        public var guestEndpoint: String?
        /// The trip's invite page, where people who were there add their photos;
        /// nil when the owner has closed it.
        public var invitePath: String?
        /// Where "I'd love a printed copy" taps are counted, or nil to hide it.
        public var printInterestEndpoint: String?
        /// Empty for no footer. Free books carry a Photocore footer.
        public var footer: String
        public var footerLink: String?

        public init(editEndpoint: String? = nil, guestEndpoint: String? = nil, invitePath: String? = nil, printInterestEndpoint: String? = nil, footer: String = "Made with Photocore", footerLink: String? = nil) {
            self.editEndpoint = editEndpoint
            self.guestEndpoint = guestEndpoint
            self.invitePath = invitePath
            self.printInterestEndpoint = printInterestEndpoint
            self.footer = footer
            self.footerLink = footerLink
        }

        /// The footer free books carry: the growth loop's last page.
        public static let freeFooter = "Made free with Photocore. Make a book of your own trip."
    }

    public static func photoPath(_ photo: BookPhoto) -> String {
        "photos/" + (photo.fileName as NSString).deletingPathExtension + ".jpg"
    }

    /// Rows for a chapter: the first photo alone as the chapter's hero, then
    /// portraits in pairs, landscapes alternating between a full-width single and
    /// a pair, so a page reads like a laid-out book rather than a grid.
    public static func rows(for photos: [BookPhoto]) -> [[BookPhoto]] {
        guard let first = photos.first else { return [] }
        var rows: [[BookPhoto]] = [[first]]
        var rest = Array(photos.dropFirst())
        var wideNext = false
        while let photo = rest.first {
            rest.removeFirst()
            if photo.isPortrait {
                if let partner = rest.firstIndex(where: \.isPortrait) {
                    rows.append([photo, rest.remove(at: partner)])
                } else if let other = rest.first {
                    rest.removeFirst()
                    rows.append([photo, other])
                } else {
                    rows.append([photo])
                }
            } else if wideNext || rest.isEmpty || rest.first?.isPortrait == true {
                rows.append([photo])
                wideNext = false
            } else {
                rows.append([photo, rest.removeFirst()])
                wideNext = true
            }
        }
        return rows
    }

    public static func html(_ book: TripBook, options: Options = Options()) -> String {
        let cover = book.allPhotos.first { $0.id == book.coverPhotoID } ?? book.allPhotos.first
        var body = ""
        if book.theme == .snapshot {
            body += "<header class=\"pcover\">"
            if let cover {
                body += "<figure class=\"print big\"><img src=\"\(attr(photoPath(cover)))\" alt=\"\(attr(cover.altText))\"><figcaption>\(text(book.dateRange))</figcaption></figure>"
            }
            body += "<h1 \(editable("title"))>\(text(book.title))</h1>"
            if let line = book.creditLine { body += "<p class=\"byline\">\(text(line))</p>" }
            body += "</header>"
        } else {
            body += "<header class=\"cover\">"
            if let cover {
                body += "<img class=\"cover-img\" src=\"\(attr(photoPath(cover)))\" alt=\"\(attr(cover.altText))\">"
            }
            body += "<div class=\"cover-shade\"></div><div class=\"cover-text\">"
            body += "<p class=\"kicker\">\(text(book.dateRange))</p>"
            body += "<h1 \(editable("title"))>\(text(book.title))</h1>"
            if let line = book.creditLine { body += "<p class=\"byline\">\(text(line))</p>" }
            body += "</div></header>"
        }
        body += "<main>"
        body += "<p class=\"intro\" \(editable("intro"))>\(text(book.intro))</p>"
        if book.sections.count > 1 {
            body += "<nav class=\"chapters\" aria-label=\"Chapters\">"
            for (index, section) in book.sections.enumerated() {
                body += "<a href=\"#\(attr(section.id))\"><span>\(String(format: "%02d", index + 1))</span> \(text(section.heading))</a>"
            }
            body += "</nav>"
        }
        for (index, section) in book.sections.enumerated() {
            var photos = section.photos
            if photos.count > 1, let cover, photos.first?.id == cover.id { photos.removeFirst() }
            body += "<section class=\"chapter\" id=\"\(attr(section.id))\">"
            body += "<div class=\"chapter-head\"><p class=\"number\">\(String(format: "%02d", index + 1))</p>"
            body += "<div><p class=\"kicker\">\(text(section.dateLine))\(section.place.map { " · " + text($0) } ?? "")</p>"
            body += "<h2 \(editable("section.\(section.id).heading"))>\(text(section.heading))</h2></div></div>"
            if !section.diary.isEmpty {
                body += "<blockquote class=\"diary\" \(editable("section.\(section.id).diary"))>\(text(section.diary))</blockquote>"
            }
            if book.theme == .snapshot {
                body += "<div class=\"board\">"
                for photo in photos {
                    body += "<figure class=\"print\">"
                    body += "<img loading=\"lazy\" decoding=\"async\" src=\"\(attr(photoPath(photo)))\" alt=\"\(attr(photo.altText))\">"
                    body += "<figcaption \(editable("photo.\(photo.id.description).caption"))>\(text(photo.caption))</figcaption>"
                    if book.contributors != nil, let credit = photo.credit { body += "<p class=\"credit\">\(text(credit))</p>" }
                    if options.guestEndpoint != nil {
                        body += "<button class=\"heart\" data-photo=\"\(attr(photo.id.description))\" aria-label=\"Love this photo\">\u{2661}<span></span></button>"
                    }
                    body += "</figure>"
                }
                body += "</div></section>"
                continue
            }
            for (rowIndex, row) in rows(for: photos).enumerated() {
                let kind = row.count == 1 ? (rowIndex == 0 ? "hero" : "single") : "pair"
                let shape = row.count == 2 ? (row.allSatisfy(\.isPortrait) ? " tall" : " wide") : (row[0].isPortrait ? " tall" : "")
                body += "<div class=\"row \(kind)\(shape)\">"
                for photo in row {
                    body += "<figure>"
                    body += "<img loading=\"lazy\" decoding=\"async\" src=\"\(attr(photoPath(photo)))\" alt=\"\(attr(photo.altText))\">"
                    body += "<figcaption \(editable("photo.\(photo.id.description).caption"))>\(text(photo.caption))</figcaption>"
                    if book.contributors != nil, let credit = photo.credit { body += "<p class=\"credit\">\(text(credit))</p>" }
                    if options.guestEndpoint != nil {
                        body += "<button class=\"heart\" data-photo=\"\(attr(photo.id.description))\" aria-label=\"Love this photo\">\u{2661}<span></span></button>"
                    }
                    body += "</figure>"
                }
                body += "</div>"
            }
            body += "</section>"
        }
        if options.guestEndpoint != nil {
            body += """
            <section class="guestbook"><h2>Notes from everyone</h2>
            <p class="hint">Were you there? Add a memory, or tap \u{2661} on your favorites.</p><ul id="notes"></ul>
            <form id="note-form"><input id="note-name" maxlength="40" placeholder="Your name" required>
            <textarea id="note-text" maxlength="500" rows="3" placeholder="A memory from the trip" required></textarea>
            <button type="submit">Add note</button></form>
            """
            if let invite = options.invitePath {
                body += """
                <div class="addphotos"><h3>Were you there too?</h3>
                <p class="hint">Add your photos from the trip. The next update picks the best shot of each moment from everyone's photos.</p>
                <a class="upload" href="\(attr(invite))">Add your photos</a></div>
                """
            }
            body += "</section>"
        }
        if options.printInterestEndpoint != nil {
            body += """
            <section class="printcopy"><h2>Want it on paper?</h2>
            <p class="hint">Printed copies are coming. Tap if you'd want one, so the book's owner knows.</p>
            <button type="button" id="print-interest">I'd love a printed copy</button>
            <p id="print-thanks" class="hint" hidden>Thanks! Noted.</p></section>
            """
        }
        body += "</main>"
        if !options.footer.isEmpty {
            let words = text(options.footer)
            body += "<footer><p>" + (options.footerLink.map { "<a href=\"\(attr($0))\">\(words)</a>" } ?? words) + "</p></footer>"
        }

        let config = """
        window.PHOTOCORE = { edit: \(jsString(options.editEndpoint)), guest: \(jsString(options.guestEndpoint)), print: \(jsString(options.printInterestEndpoint)) };
        """
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <title>\(text(book.title))</title>
        <meta name="description" content="\(attr(book.intro))">
        <meta property="og:type" content="article">
        <meta property="og:title" content="\(attr(book.title))">
        <meta property="og:description" content="\(attr(book.intro))">
        \(cover.map { "<meta property=\"og:image\" content=\"\(attr(photoPath($0)))\">" } ?? "")
        <meta name="twitter:card" content="summary_large_image">
        \(book.theme == .snapshot ? "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Caveat:wght@500;700&display=swap\">" : "")
        <style>\(css)</style></head>
        <body class="theme-\(book.theme.rawValue)">\(body)
        <script>\(config)\(script)</script></body></html>
        """
    }

    private static func editable(_ key: String) -> String {
        "data-key=\"\(attr(key))\""
    }

    static func text(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func attr(_ value: String) -> String {
        text(value).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func jsString(_ value: String?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return String(json.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }

    static let css = """
    :root { --paper:#f7f3ec; --ink:#1d1a17; --muted:#6f675e; --faint:#a49b90; --accent:#b8532f; --line:#e4ddd1; --card:#fffdf9; --serif:"New York","Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; --sans:-apple-system,BlinkMacSystemFont,"Helvetica Neue","Segoe UI",sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --paper:#141210; --ink:#efeae2; --muted:#a69e94; --faint:#6d665e; --accent:#e58a63; --line:#2a2622; --card:#1c1916; } }
    * { box-sizing:border-box; }
    html { scroll-behavior:smooth; -webkit-text-size-adjust:100%; }
    body { margin:0; background:var(--paper); color:var(--ink); font:17px/1.65 var(--sans); }
    h1, h2 { font-family:var(--serif); font-weight:600; letter-spacing:-0.015em; margin:0; }
    .kicker { text-transform:uppercase; letter-spacing:.14em; font-size:11.5px; font-weight:600; color:var(--muted); margin:0 0 10px; }
    .cover { position:relative; height:min(92vh, 860px); min-height:460px; overflow:hidden; background:#000; }
    .cover-img { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
    .cover-shade { position:absolute; inset:0; background:linear-gradient(to bottom, rgba(0,0,0,.05) 35%, rgba(0,0,0,.62)); }
    .cover-text { position:absolute; left:0; right:0; bottom:0; padding:0 max(24px, calc((100vw - 1040px) / 2)) 56px; color:#fff; }
    .cover-text .kicker { color:rgba(255,255,255,.82); }
    .cover h1 { font-size:clamp(42px, 8vw, 92px); line-height:1.02; max-width:14ch; text-shadow:0 2px 24px rgba(0,0,0,.25); }
    main { max-width:1040px; margin:0 auto; padding:0 20px 40px; }
    .intro { font-family:var(--serif); font-size:clamp(21px, 2.6vw, 26px); line-height:1.45; max-width:30em; margin:48px 0 8px; }
    .chapters { display:flex; gap:8px; overflow-x:auto; padding:18px 0 4px; scrollbar-width:none; }
    .chapters::-webkit-scrollbar { display:none; }
    .chapters a { flex:none; text-decoration:none; color:var(--ink); font-size:14px; padding:7px 14px; border:1px solid var(--line); border-radius:999px; background:var(--card); white-space:nowrap; }
    .chapters a span { color:var(--accent); font-weight:600; margin-right:4px; font-variant-numeric:tabular-nums; }
    .chapter { padding-top:72px; }
    .chapter-head { display:flex; gap:20px; align-items:flex-start; margin-bottom:18px; }
    .number { font-family:var(--serif); font-size:44px; line-height:.9; color:var(--accent); margin:0; font-variant-numeric:tabular-nums; }
    .chapter h2 { font-size:clamp(28px, 4.2vw, 40px); line-height:1.1; }
    .diary { font-family:var(--serif); font-style:italic; font-size:clamp(19px, 2.2vw, 22px); line-height:1.5; max-width:34em; margin:0 0 30px 64px; padding-left:18px; border-left:2px solid var(--accent); }
    .row { display:grid; gap:14px; margin:0 0 22px; }
    .row.pair { grid-template-columns:1fr 1fr; }
    .row.hero { margin-left:calc(-1 * max(20px, (100vw - 1040px) / 2 + 20px) / 4); margin-right:calc(-1 * max(20px, (100vw - 1040px) / 2 + 20px) / 4); }
    figure { margin:0; position:relative; }
    figure img { width:100%; display:block; border-radius:6px; cursor:zoom-in; background:var(--line); }
    .row.hero img, .row.single img { aspect-ratio:3 / 2; object-fit:cover; }
    .row.single.tall { max-width:640px; margin-left:auto; margin-right:auto; }
    .row.single.tall img, .row.hero.tall img { aspect-ratio:4 / 5; }
    .row.pair.wide img { aspect-ratio:3 / 2; object-fit:cover; }
    .row.pair.tall img { aspect-ratio:4 / 5; object-fit:cover; }
    .row.pair:not(.wide):not(.tall) img { aspect-ratio:1 / 1; object-fit:cover; }
    figcaption { font-size:14px; color:var(--muted); padding:8px 2px 0; }
    figcaption:empty { display:none; }
    .credit { font-size:12px; color:var(--muted); margin:2px 2px 0; letter-spacing:.02em; }
    .credit::before { content:"by "; }
    .byline { margin:14px 0 0; font-size:15px; opacity:.88; }
    [data-key][contenteditable="true"] { outline:1px dashed var(--accent); outline-offset:6px; border-radius:4px; cursor:text; }
    .heart { position:absolute; top:12px; right:12px; border:0; border-radius:999px; padding:6px 11px; background:rgba(20,18,16,.42); backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px); color:#fff; font-size:15px; cursor:pointer; }
    .heart.on { background:var(--accent); }
    .heart span:not(:empty) { margin-left:5px; font-size:13px; }
    .guestbook { margin-top:88px; padding:32px; border-radius:18px; background:var(--card); border:1px solid var(--line); }
    .guestbook h2 { font-size:28px; }
    .hint { color:var(--muted); margin:6px 0 16px; }
    .guestbook ul { list-style:none; padding:0; margin:0 0 20px; }
    .guestbook li { padding:12px 0; border-bottom:1px solid var(--line); }
    .guestbook li:last-child { border-bottom:0; }
    .guestbook form { display:grid; gap:10px; max-width:560px; }
    .guestbook input, .guestbook textarea { font:inherit; padding:11px 13px; border-radius:10px; border:1px solid var(--line); background:var(--paper); color:var(--ink); }
    .addphotos { margin-top:28px; padding-top:22px; border-top:1px solid var(--line); }
    .addphotos h3 { font-family:var(--serif); font-size:22px; margin:0; }
    .upload { display:inline-block; font-weight:600; padding:10px 20px; border-radius:999px; border:1.5px solid var(--accent); color:var(--accent); cursor:pointer; }
    .upload { text-decoration:none; }
    .guestbook button { justify-self:start; font:inherit; font-weight:600; padding:10px 20px; border:0; border-radius:999px; background:var(--accent); color:#fff; cursor:pointer; }
    footer a { color:inherit; }
    .printcopy { margin-top:72px; text-align:center; }
    .printcopy h2 { font-size:26px; }
    .printcopy button { font:inherit; font-weight:600; padding:11px 22px; border-radius:999px; border:1.5px solid var(--accent); background:none; color:var(--accent); cursor:pointer; }
    .printcopy button:disabled { opacity:.55; cursor:default; }
    footer { text-align:center; color:var(--faint); font-size:13px; letter-spacing:.04em; padding:56px 20px 64px; }
    .lightbox { position:fixed; inset:0; background:rgba(0,0,0,.94); display:flex; align-items:center; justify-content:center; z-index:10; cursor:zoom-out; }
    .lightbox img { max-width:96vw; max-height:92vh; border-radius:4px; }
    @media (max-width: 640px) {
      body { font-size:16px; }
      .cover { height:78vh; min-height:420px; }
      .cover-text { padding:0 22px 36px; }
      main { padding:0 16px 32px; }
      .intro { margin-top:32px; }
      .chapter { padding-top:52px; }
      .chapter-head { gap:14px; }
      .number { font-size:34px; }
      .diary { margin-left:0; }
      .row { gap:8px; margin-bottom:14px; }
      .row.hero { margin-left:-16px; margin-right:-16px; }
      .row.hero img { border-radius:0; }
      .row.hero figcaption { padding-left:16px; padding-right:16px; }
      .row.hero .credit { padding-left:16px; }
      .row.pair.wide { grid-template-columns:1fr; }
      .guestbook { padding:22px; margin-top:64px; }
    }
    @media print {
      .chapters, .heart, .guestbook, .printcopy, footer { display:none; }
      body { background:#fff; color:#000; }
      .cover { height:100vh; page-break-after:always; }
      .chapter { page-break-before:always; padding-top:0; }
      .row { break-inside:avoid; }
    }
    /* Snapshots theme: instant prints pinned to a board. Apple devices use their
       built-in handwriting fonts; others load Caveat. */
    body.theme-snapshot { --paper:#efe8dc; --hand:"Bradley Hand","Noteworthy","Caveat","Segoe Print",cursive; background:var(--paper) radial-gradient(rgba(0,0,0,.035) 1px, transparent 1px) 0 0 / 14px 14px; }
    @media (prefers-color-scheme: dark) { body.theme-snapshot { --paper:#23201c; } }
    .pcover { max-width:1040px; margin:0 auto; padding:56px 20px 8px; display:grid; justify-items:center; gap:22px; text-align:center; }
    .pcover h1 { font-family:var(--hand); font-weight:700; font-size:clamp(40px, 7vw, 76px); line-height:1.05; color:var(--ink); max-width:16ch; }
    .theme-snapshot .print { background:#fdfcf8; padding:14px 14px 0; box-shadow:0 1px 2px rgba(0,0,0,.12), 0 10px 26px rgba(0,0,0,.16); border-radius:2px; position:relative; }
    .theme-snapshot .print img { aspect-ratio:1 / 1; object-fit:cover; border-radius:0; filter:saturate(.9) contrast(.97) sepia(.07) brightness(1.02); }
    .theme-snapshot .print figcaption { font-family:var(--hand); font-size:22px; line-height:1.2; color:#34302b; text-align:center; min-height:62px; padding:12px 6px 14px; display:block; }
    .theme-snapshot .print figcaption:empty { display:block; }
    .theme-snapshot .print.big { width:min(520px, 86vw); transform:rotate(-2deg); }
    .theme-snapshot .print.big figcaption { font-size:26px; }
    .board { display:grid; grid-template-columns:repeat(3, 1fr); gap:34px 26px; padding:10px 6px 20px; }
    .board .print:nth-child(4n+1) { transform:rotate(-2.2deg); }
    .board .print:nth-child(4n+2) { transform:rotate(1.6deg) translateY(10px); }
    .board .print:nth-child(4n+3) { transform:rotate(-0.8deg) translateY(-6px); }
    .board .print:nth-child(4n) { transform:rotate(2.4deg); }
    .board .print:nth-child(3n+1)::before { content:""; position:absolute; top:-12px; left:50%; width:84px; height:26px; transform:translateX(-50%) rotate(-3deg); background:rgba(244,232,196,.78); box-shadow:0 1px 2px rgba(0,0,0,.08); }
    .theme-snapshot .chapter h2, .theme-snapshot .number { font-family:var(--hand); }
    .theme-snapshot .diary { font-family:var(--hand); font-style:normal; font-size:clamp(22px, 2.6vw, 27px); }
    .theme-snapshot .intro { font-family:var(--hand); font-size:clamp(24px, 3vw, 30px); text-align:center; margin-left:auto; margin-right:auto; }
    .theme-snapshot .heart { top:22px; right:22px; }
    .theme-snapshot .print .credit { text-align:right; margin:0; padding:0 8px 10px; font-family:var(--hand); font-size:15px; color:#6b645b; }
    .theme-snapshot .print figcaption:has(+ .credit) { min-height:48px; padding-bottom:2px; }
    .pcover .byline { font-family:var(--hand); font-size:22px; color:var(--muted); margin:0; }
    @media (max-width: 640px) {
      .board { grid-template-columns:repeat(2, 1fr); gap:24px 16px; }
      .theme-snapshot .print { padding:9px 9px 0; }
      .theme-snapshot .print figcaption { font-size:18px; min-height:46px; padding:8px 4px 10px; }
    }
    @media print { .board .print { break-inside:avoid; } }
    """

    static let script = """
    (function(){
      var cfg = window.PHOTOCORE || {};
      document.querySelectorAll('figure img').forEach(function(img){
        img.addEventListener('click', function(){
          var box = document.createElement('div'); box.className = 'lightbox';
          var big = document.createElement('img'); big.src = img.src; big.alt = img.alt;
          box.appendChild(big); box.addEventListener('click', function(){ box.remove(); });
          document.body.appendChild(box);
        });
      });
      var token = (location.hash.match(/edit=([A-Za-z0-9_-]+)/) || [])[1];
      if (cfg.edit && token) {
        document.querySelectorAll('[data-key]').forEach(function(el){
          el.contentEditable = 'true';
          el.addEventListener('blur', function(){
            fetch(cfg.edit, { method:'POST', headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer ' + token },
              body: JSON.stringify({ key: el.dataset.key, value: el.innerText.trim() }) });
          });
        });
      }
      if (cfg.guest) {
        var notes = document.getElementById('notes');
        function render(data){
          notes.innerHTML = '';
          (data.notes || []).forEach(function(n){
            var li = document.createElement('li'); var b = document.createElement('strong');
            b.textContent = n.name; li.appendChild(b); li.appendChild(document.createTextNode(' \\u2014 ' + n.text)); notes.appendChild(li);
          });
          document.querySelectorAll('.heart').forEach(function(btn){
            var n = (data.hearts || {})[btn.dataset.photo] || 0; btn.querySelector('span').textContent = n ? n : '';
          });
        }
        fetch(cfg.guest).then(function(r){ return r.json(); }).then(render).catch(function(){});
        document.querySelectorAll('.heart').forEach(function(btn){
          btn.addEventListener('click', function(){
            btn.classList.add('on');
            fetch(cfg.guest + '/hearts', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ photo: btn.dataset.photo }) })
              .then(function(r){ return r.json(); }).then(render).catch(function(){});
          });
        });
        document.getElementById('note-form').addEventListener('submit', function(e){
          e.preventDefault();
          fetch(cfg.guest + '/notes', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ name: document.getElementById('note-name').value, text: document.getElementById('note-text').value }) })
            .then(function(r){ return r.json(); }).then(function(d){ document.getElementById('note-text').value=''; render(d); }).catch(function(){});
        });
      }
      var want = document.getElementById('print-interest');
      if (want && cfg.print) {
        var key = 'photocore-print-' + location.pathname, done = false;
        try { done = localStorage.getItem(key) === '1'; } catch (e) {}
        function thanks(){ want.disabled = true; document.getElementById('print-thanks').hidden = false; }
        if (done) thanks();
        want.addEventListener('click', function(){
          fetch(cfg.print, { method:'POST' }).catch(function(){});
          try { localStorage.setItem(key, '1'); } catch (e) {}
          thanks();
        });
      }
    })();
    """
}

/// Finished photos, the book page and the Instagram pack for one trip.
public enum BookPublisher {
    public struct Report: Sendable {
        public var folder: URL
        public var indexURL: URL
        public var photoCount: Int
        public var carouselCount: Int
        public var storyCount: Int
    }

    /// - Parameter source: where each keeper's pixels are (an uploaded original
    ///   on the server, the culling copy in tests).
    public static func publish(
        book: TripBook,
        edits: BookEdits = BookEdits(),
        facts: TripFacts,
        source: (PhotoFacts) -> URL?,
        to folder: URL,
        options: BookRenderer.Options = BookRenderer.Options(),
        maxPixel: Int = 2048,
        settings: SubjectEditSettings = .natural,
        instagram includeInstagram: Bool = true
    ) throws -> Report {
        let fm = FileManager.default
        let photos = folder.appendingPathComponent("photos", isDirectory: true)
        let instagram = folder.appendingPathComponent("instagram", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try? fm.removeItem(at: instagram)
        try fm.createDirectory(at: instagram, withIntermediateDirectories: true)

        let finalBook = edits.applied(to: book)
        let factsByID = Dictionary(facts.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rendered = 0
        for photo in finalBook.allPhotos {
            guard let photoFacts = factsByID[photo.id], let url = source(photoFacts) else { continue }
            let output = folder.appendingPathComponent(BookRenderer.photoPath(photo))
            if !fm.fileExists(atPath: output.path) {
                try FinishRenderer.render(url: url, maxPixel: maxPixel, settings: settings).jpeg.write(to: output, options: .atomic)
            }
            rendered += 1
        }
        try book.save(to: folder)
        try edits.save(to: folder)
        let index = folder.appendingPathComponent("index.html")
        try Data(BookRenderer.html(finalBook, options: options).utf8).write(to: index, options: .atomic)
        guard includeInstagram else {
            try? fm.removeItem(at: instagram)
            return Report(folder: folder, indexURL: index, photoCount: rendered, carouselCount: 0, storyCount: 0)
        }
        let pack = try InstagramPack.build(book: finalBook, facts: facts, source: source, to: instagram, settings: settings)
        return Report(folder: folder, indexURL: index, photoCount: rendered, carouselCount: pack.carousel, storyCount: pack.stories)
    }
}

/// Instagram-ready crops and captions: a 4:5 carousel of up to ten photos that
/// walks through the trip, 9:16 stories, and a caption file to paste.
public enum InstagramPack {
    public static let carouselLimit = 10
    public static let storyLimit = 5

    /// Up to `limit` photos spread across chapters: the cover first, then one
    /// per chapter in order, then seconds from each chapter.
    public static func pick(book: TripBook, limit: Int = carouselLimit) -> [BookPhoto] {
        var chosen: [BookPhoto] = []
        var seen = Set<PhotoID>()
        func take(_ photo: BookPhoto) {
            guard chosen.count < limit, seen.insert(photo.id).inserted else { return }
            chosen.append(photo)
        }
        if let cover = book.allPhotos.first(where: { $0.id == book.coverPhotoID }) { take(cover) }
        var round = 0
        while chosen.count < limit {
            var added = false
            for section in book.sections where round < section.photos.count {
                take(section.photos[round])
                added = true
            }
            if !added { break }
            round += 1
        }
        return chosen
    }

    public static func caption(for book: TripBook, photos: [BookPhoto]) -> String {
        var tags: [String] = []
        for photo in photos {
            for word in photo.instagramCaption.split(separator: " ") where word.hasPrefix("#") && !tags.contains(String(word)) {
                tags.append(String(word))
            }
        }
        let lines = [book.title, book.intro, "", tags.prefix(8).joined(separator: " ")]
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func build(book: TripBook, facts: TripFacts, source: (PhotoFacts) -> URL?, to folder: URL, settings: SubjectEditSettings) throws -> (carousel: Int, stories: Int) {
        let factsByID = Dictionary(facts.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let carousel = pick(book: book)
        var written = 0
        for photo in carousel {
            guard let f = factsByID[photo.id], let url = source(f) else { continue }
            written += 1
            let crop = f.crops[CropAspect.portrait.rawValue]
            let out = try FinishRenderer.render(url: url, maxPixel: 4096, settings: settings, crop: crop, outputSize: CGSize(width: 1080, height: 1350))
            try out.jpeg.write(to: folder.appendingPathComponent(String(format: "carousel-%02d.jpg", written)))
        }
        var stories = 0
        for photo in pick(book: book, limit: storyLimit) {
            guard let f = factsByID[photo.id], let url = source(f) else { continue }
            stories += 1
            let out = try FinishRenderer.render(url: url, maxPixel: 4096, settings: settings, crop: f.crops[CropAspect.story.rawValue], outputSize: CGSize(width: 1080, height: 1920))
            try out.jpeg.write(to: folder.appendingPathComponent(String(format: "story-%02d.jpg", stories)))
        }
        try caption(for: book, photos: carousel).write(to: folder.appendingPathComponent("caption.txt"), atomically: true, encoding: .utf8)
        return (written, stories)
    }
}
