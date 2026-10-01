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
        public var footer: String

        public init(editEndpoint: String? = nil, guestEndpoint: String? = nil, footer: String = "Made with Photocore") {
            self.editEndpoint = editEndpoint
            self.guestEndpoint = guestEndpoint
            self.footer = footer
        }
    }

    public static func photoPath(_ photo: BookPhoto) -> String {
        "photos/" + (photo.fileName as NSString).deletingPathExtension + ".jpg"
    }

    public static func html(_ book: TripBook, options: Options = Options()) -> String {
        let cover = book.allPhotos.first { $0.id == book.coverPhotoID } ?? book.allPhotos.first
        var body = ""
        body += "<header class=\"cover\">"
        if let cover {
            body += "<img class=\"cover-img\" src=\"\(attr(photoPath(cover)))\" alt=\"\(attr(cover.altText))\">"
        }
        body += "<div class=\"cover-text\"><p class=\"kicker\">\(text(book.dateRange))</p>"
        body += "<h1 \(editable("title"))>\(text(book.title))</h1>"
        body += "<p class=\"intro\" \(editable("intro"))>\(text(book.intro))</p></div></header>"
        body += "<main>"
        for section in book.sections {
            body += "<section id=\"\(attr(section.id))\">"
            body += "<p class=\"kicker\">\(text(section.dateLine))</p>"
            body += "<h2 \(editable("section.\(section.id).heading"))>\(text(section.heading))</h2>"
            if !section.diary.isEmpty {
                body += "<p class=\"diary\" \(editable("section.\(section.id).diary"))>\(text(section.diary))</p>"
            }
            body += "<div class=\"photos\">"
            for photo in section.photos {
                body += "<figure class=\"\(photo.isPortrait ? "portrait" : "landscape")\">"
                body += "<img loading=\"lazy\" src=\"\(attr(photoPath(photo)))\" alt=\"\(attr(photo.altText))\">"
                body += "<figcaption \(editable("photo.\(photo.id.description).caption"))>\(text(photo.caption))</figcaption>"
                if options.guestEndpoint != nil {
                    body += "<button class=\"heart\" data-photo=\"\(attr(photo.id.description))\" aria-label=\"Love this photo\">\u{2661}<span></span></button>"
                }
                body += "</figure>"
            }
            body += "</div></section>"
        }
        if options.guestEndpoint != nil {
            body += """
            <section class="guestbook"><h2>Notes from everyone</h2><ul id="notes"></ul>
            <form id="note-form"><input id="note-name" maxlength="40" placeholder="Your name" required>
            <textarea id="note-text" maxlength="500" placeholder="Add a memory from the trip" required></textarea>
            <button type="submit">Add note</button></form></section>
            """
        }
        body += "</main><footer>\(text(options.footer))</footer>"

        let config = """
        window.PHOTOCORE = { edit: \(jsString(options.editEndpoint)), guest: \(jsString(options.guestEndpoint)) };
        """
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(text(book.title))</title>
        <meta property="og:title" content="\(attr(book.title))">
        <meta property="og:description" content="\(attr(book.intro))">
        \(cover.map { "<meta property=\"og:image\" content=\"\(attr(photoPath($0)))\">" } ?? "")
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
    :root { --paper:#f9f6f1; --ink:#1e1c1a; --muted:#6b655e; --accent:#c65c36; --line:#e7e1d8; --card:#fff; }
    @media (prefers-color-scheme: dark) { :root { --paper:#161514; --ink:#f1eee8; --muted:#a49d94; --accent:#e6825d; --line:#2c2925; --card:#1f1d1b; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--paper); color:var(--ink); font:17px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    h1, h2 { font-family: "New York", "Iowan Old Style", Georgia, serif; font-weight:600; letter-spacing:-0.01em; margin:0; }
    h1 { font-size: clamp(36px, 7vw, 64px); line-height:1.05; }
    h2 { font-size: clamp(26px, 4vw, 34px); line-height:1.15; margin-bottom:12px; }
    .kicker { text-transform:uppercase; letter-spacing:.12em; font-size:12px; color:var(--muted); margin:0 0 8px; }
    .cover { max-width:1080px; margin:0 auto; padding:24px 16px 8px; }
    .cover-img { width:100%; aspect-ratio: 3 / 2; object-fit:cover; border-radius:20px; display:block; }
    .cover-text { padding:28px 4px 8px; max-width:720px; }
    .intro { font-size:20px; color:var(--muted); margin:14px 0 0; }
    main { max-width:1080px; margin:0 auto; padding:0 16px 48px; }
    section { padding:48px 0 8px; border-top:1px solid var(--line); margin-top:32px; }
    .diary { font-family: "New York", "Iowan Old Style", Georgia, serif; font-size:20px; max-width:680px; margin:0 0 24px; }
    .photos { display:grid; grid-template-columns: repeat(2, 1fr); gap:14px; }
    figure { margin:0; position:relative; }
    figure.landscape { grid-column: span 2; }
    figure img { width:100%; display:block; border-radius:14px; cursor:zoom-in; background:var(--line); }
    figcaption { font-size:15px; color:var(--muted); padding:8px 2px 0; min-height:1em; }
    footer { text-align:center; color:var(--muted); font-size:13px; padding:32px 16px 48px; }
    [data-key][contenteditable="true"] { outline:1px dashed var(--accent); outline-offset:4px; border-radius:4px; }
    .heart { position:absolute; top:10px; right:10px; border:0; border-radius:999px; padding:6px 10px; background:rgba(0,0,0,.45); color:#fff; font-size:16px; cursor:pointer; }
    .heart.on { background:var(--accent); }
    .heart span:not(:empty) { margin-left:4px; font-size:13px; }
    .guestbook ul { list-style:none; padding:0; }
    .guestbook li { padding:12px 0; border-bottom:1px solid var(--line); }
    .guestbook form { display:grid; gap:10px; max-width:560px; }
    .guestbook input, .guestbook textarea { font:inherit; padding:10px 12px; border-radius:10px; border:1px solid var(--line); background:var(--card); color:var(--ink); }
    .guestbook button { justify-self:start; font:inherit; padding:10px 18px; border:0; border-radius:10px; background:var(--accent); color:#fff; cursor:pointer; }
    .lightbox { position:fixed; inset:0; background:rgba(0,0,0,.92); display:flex; align-items:center; justify-content:center; z-index:10; cursor:zoom-out; }
    .lightbox img { max-width:96vw; max-height:92vh; border-radius:8px; }
    @media (max-width: 640px) { .photos { grid-template-columns: 1fr; } figure.landscape { grid-column: auto; } body { font-size:16px; } }
    body.theme-scrapbook { --paper:#efe7da; }
    .theme-scrapbook figure { background:#fff; padding:12px 12px 4px; box-shadow:0 6px 18px rgba(0,0,0,.12); border-radius:2px; }
    .theme-scrapbook figure:nth-child(odd) { transform: rotate(-1.2deg); }
    .theme-scrapbook figure:nth-child(even) { transform: rotate(1deg); }
    .theme-scrapbook figure img { border-radius:0; }
    .theme-scrapbook figcaption { font-family: "Bradley Hand", "Segoe Print", "Comic Sans MS", cursive; font-size:18px; color:#3a3530; text-align:center; padding:10px 4px 8px; }
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
        settings: SubjectEditSettings = .natural
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
