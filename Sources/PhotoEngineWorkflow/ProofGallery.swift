import Foundation
import PhotoEngineCore

public struct ProofGalleryOptions: Sendable, Equatable {
    public var title: String
    public var includeFaceFind: Bool
    public var dualExport: Bool
    public var sneakPeekCount: Int

    public init(title: String, includeFaceFind: Bool = true, dualExport: Bool = true, sneakPeekCount: Int = 12) {
        self.title = title
        self.includeFaceFind = includeFaceFind
        self.dualExport = dualExport
        self.sneakPeekCount = sneakPeekCount
    }
}

public struct ProofGalleryReport: Sendable, Equatable {
    public var folder: URL
    public var indexURL: URL
    public var photoCount: Int
    public var sneakPeekCount: Int
    public var webCount: Int

    public init(folder: URL, indexURL: URL, photoCount: Int, sneakPeekCount: Int, webCount: Int) {
        self.folder = folder
        self.indexURL = indexURL
        self.photoCount = photoCount
        self.sneakPeekCount = sneakPeekCount
        self.webCount = webCount
    }
}

public enum ProofGalleryBuilder {
    /// Builds a self-contained local proof gallery next to delivered JPEGs.
    /// Face find is filename/face-count metadata based until identity lands.
    public static func build(
        deliveredJPEGs: [URL],
        analyzed: [AnalyzedPhoto],
        options: ProofGalleryOptions,
        into parent: URL
    ) throws -> ProofGalleryReport {
        let fm = FileManager.default
        let gallery = parent.appendingPathComponent("proof-gallery", isDirectory: true)
        let images = gallery.appendingPathComponent("images", isDirectory: true)
        let web = gallery.appendingPathComponent("web", isDirectory: true)
        let peek = gallery.appendingPathComponent("sneak-peek", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        if options.dualExport { try fm.createDirectory(at: web, withIntermediateDirectories: true) }
        try fm.createDirectory(at: peek, withIntermediateDirectories: true)

        let byName = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.asset.url.deletingPathExtension().lastPathComponent.lowercased(), $0) })
        var cards: [(file: String, faces: Int, score: Double)] = []
        for jpeg in deliveredJPEGs {
            let dest = images.appendingPathComponent(jpeg.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: jpeg, to: dest)
            let key = jpeg.deletingPathExtension().lastPathComponent.lowercased()
            // Try matching by trailing source stem in delivery names like 001-DSC0123.jpg
            let photo = byName[key] ?? analyzed.first { key.contains($0.asset.url.deletingPathExtension().lastPathComponent.lowercased()) }
            cards.append((jpeg.lastPathComponent, photo?.signals.faceCount ?? 0, photo.map { $0.signals.faceQuality + $0.signals.sharpness } ?? 0))
            if options.dualExport {
                // Web copy is the same file for now; renderer already supports compact elsewhere.
                let webDest = web.appendingPathComponent(jpeg.lastPathComponent)
                if fm.fileExists(atPath: webDest.path) { try fm.removeItem(at: webDest) }
                try fm.copyItem(at: jpeg, to: webDest)
            }
        }

        let sneak = cards.sorted { $0.score > $1.score }.prefix(options.sneakPeekCount)
        for item in sneak {
            let src = images.appendingPathComponent(item.file)
            let dest = peek.appendingPathComponent(item.file)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        }

        let index = gallery.appendingPathComponent("index.html")
        try html(title: options.title, cards: cards, faceFind: options.includeFaceFind).write(to: index, atomically: true, encoding: .utf8)
        return ProofGalleryReport(
            folder: gallery,
            indexURL: index,
            photoCount: cards.count,
            sneakPeekCount: sneak.count,
            webCount: options.dualExport ? cards.count : 0
        )
    }

    private static func html(title: String, cards: [(file: String, faces: Int, score: Double)], faceFind: Bool) -> String {
        let items = cards.map { card in
            """
            <figure class="card" data-faces="\(card.faces)" data-name="\(card.file.lowercased())">
              <img src="images/\(card.file)" loading="lazy" alt="\(card.file)" />
              <figcaption>\(card.file)\(card.faces > 0 ? " · \(card.faces) face\(card.faces == 1 ? "" : "s")" : "")</figcaption>
            </figure>
            """
        }.joined(separator: "\n")
        let faceUI = faceFind ? """
        <label class="find">Show frames with faces
          <input id="facesOnly" type="checkbox" />
        </label>
        <input id="q" type="search" placeholder="Filter by filename" />
        """ : ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(title) — Photocore Proof</title>
          <style>
            :root { color-scheme: dark; --bg:#0a0a0a; --text:#f0eeea; --muted:#9a9690; --line:#222; }
            * { box-sizing: border-box; }
            body { margin: 0; font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; background: var(--bg); color: var(--text); }
            header { position: sticky; top: 0; backdrop-filter: blur(10px); background: rgba(10,10,10,.9); border-bottom: 1px solid var(--line); padding: 16px 22px; display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }
            h1 { font-size: 20px; font-weight: 600; margin: 0; letter-spacing: -0.02em; }
            .meta { color: var(--muted); }
            input[type=search] { background: #141414; border: 1px solid var(--line); color: var(--text); padding: 8px 10px; min-width: 220px; }
            .find { color: var(--muted); display: flex; gap: 8px; align-items: center; }
            main { padding: 18px; display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; }
            .card { margin: 0; background: #000; border: 1px solid var(--line); }
            .card img { display: block; width: 100%; height: 200px; object-fit: cover; }
            figcaption { padding: 8px 10px; color: var(--muted); font-size: 12px; }
            .card.hide { display: none; }
          </style>
        </head>
        <body>
          <header>
            <h1>\(title)</h1>
            <span class="meta">\(cards.count) photos · local proof</span>
            \(faceUI)
          </header>
          <main id="grid">
        \(items)
          </main>
          <script>
            const q = document.getElementById('q');
            const facesOnly = document.getElementById('facesOnly');
            function apply() {
              const query = (q?.value || '').toLowerCase();
              const needFaces = !!facesOnly?.checked;
              document.querySelectorAll('.card').forEach(card => {
                const name = card.dataset.name || '';
                const faces = Number(card.dataset.faces || 0);
                const ok = (!query || name.includes(query)) && (!needFaces || faces > 0);
                card.classList.toggle('hide', !ok);
              });
            }
            q?.addEventListener('input', apply);
            facesOnly?.addEventListener('change', apply);
          </script>
        </body>
        </html>
        """
    }
}
