import Foundation
import HTTPTypes
import Hummingbird

/// Small server pages in the Bound look: a book that went offline, an
/// unsubscribe confirmation, a checkout result.
enum Pages {
    static func shell(title: String, body: String, script: String = "") -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex">
        <title>\(InvitePage.escape(title))</title>
        <style>\(css)</style></head>
        <body><main>\(body)<p class="brand">Bound · Finish the trip.</p></main>
        \(script.isEmpty ? "" : "<script>\(script)</script>")</body></html>
        """
    }

    static func response(_ html: String, status: HTTPResponse.Status = .ok) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'"
        return APIJSON.bytes(Data(html.utf8), status: status, headers: headers)
    }

    static let css = """
    :root { --paper:#f7f2ea; --ink:#1e1b18; --muted:#6f675e; --accent:#b3322b; --line:#e4ddd1; --card:#fffdf9; --serif:"New York","Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; --sans:-apple-system,BlinkMacSystemFont,"Helvetica Neue","Segoe UI",sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --paper:#141210; --ink:#efeae2; --muted:#a69e94; --accent:#e06b61; --line:#2a2622; --card:#1c1916; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--paper); color:var(--ink); font:17px/1.6 var(--sans); }
    main { max-width:560px; margin:0 auto; padding:64px 16px; text-align:center; }
    h1 { font-family:var(--serif); font-weight:600; font-size:clamp(28px, 6.4vw, 38px); line-height:1.15; letter-spacing:-.01em; margin:0 0 14px; }
    p { margin:0 0 16px; }
    .muted { color:var(--muted); }
    .fine { font-size:13px; color:var(--muted); }
    .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:22px; margin:22px 0; text-align:left; }
    button, .button { font:inherit; font-weight:600; display:inline-block; padding:13px 26px; border:0; border-radius:999px; background:var(--accent); color:#fff; cursor:pointer; text-decoration:none; }
    button:disabled { opacity:.6; cursor:default; }
    .quiet { background:none; color:var(--accent); border:1.5px solid var(--accent); }
    input { font:inherit; padding:12px 14px; border-radius:12px; border:1px solid var(--line); background:var(--paper); color:var(--ink); width:100%; }
    label { display:block; font-weight:600; font-size:15px; margin:12px 0 6px; }
    .brand { font-family:var(--serif); font-size:14px; color:var(--muted); margin-top:40px; }
    .ribbon { display:inline-block; width:18px; height:34px; background:var(--accent); clip-path:polygon(0 0, 100% 0, 100% 100%, 50% 76%, 0 100%); margin-bottom:18px; }
    [hidden] { display:none !important; }
    """

    /// A free book whose 90 days are up. While its photos are still kept, anyone
    /// in it can bring it back for good.
    static func offline(title: String, credit: String?, keepEndpoint: String?) -> String {
        var body = "<span class=\"ribbon\" aria-hidden=\"true\"></span><h1>\(InvitePage.escape(title)) is offline</h1>"
        if let credit { body += "<p class=\"muted\">\(InvitePage.escape(credit))</p>" }
        if keepEndpoint != nil {
            body += """
            <p>Free books stay up for 90 days. Anyone in the book can bring it back for good, with everyone's full-size photos to download.</p>
            <button type="button" id="keep">Keep it for $4.99</button>
            <p class="fine">The photos are kept for a few more weeks, then deleted.</p>
            """
        } else {
            body += "<p>This book is no longer online, and its photos have been deleted.</p>"
        }
        let script = keepEndpoint.map { endpoint in
            """
            (function(){ var b = document.getElementById('keep'); b.addEventListener('click', function(){ b.disabled = true;
              fetch(\(InvitePage.json(endpoint)), { method:'POST', headers:{ 'Content-Type':'application/json' }, body:'{}' })
                .then(function(r){ return r.json(); }).then(function(d){ if (d.url) location.href = d.url; else { b.disabled = false; alert((d.error && d.error.message) || 'Try again in a moment.'); } })
                .catch(function(){ b.disabled = false; }); }); })();
            """
        } ?? ""
        return shell(title: title, body: body, script: script)
    }

    static func unsubscribe(title: String?, done: Bool) -> String {
        let book = title.map { "the book of " + InvitePage.escape($0) } ?? "this book"
        let body = done
            ? "<span class=\"ribbon\" aria-hidden=\"true\"></span><h1>No more emails</h1><p class=\"muted\">You won't get more emails about \(book).</p>"
            : "<span class=\"ribbon\" aria-hidden=\"true\"></span><h1>Stop emails?</h1><p class=\"muted\">Stop emails about \(book). Nothing else changes.</p><form method=\"post\"><button type=\"submit\">Stop emails</button></form>"
        return shell(title: "Emails · Bound", body: body)
    }
}
