import Foundation
import HTTPTypes
import Hummingbird
import PhotoEngineWorkflow

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

    static func response(_ html: String, status: HTTPResponse.Status = .ok, allowTurnstile: Bool = false) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        let turnstile = allowTurnstile ? " https://challenges.cloudflare.com" : ""
        headers[HTTPField.Name("Content-Security-Policy")!] = "default-src 'self'; img-src 'self' data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'\(turnstile); frame-src\(turnstile.isEmpty ? " 'none'" : turnstile); connect-src 'self'; form-action 'self'; frame-ancestors 'none'"
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

    static func thanks(kind: CheckoutKind, title: String?, bookPath: String) -> String {
        let book = InvitePage.escape(title.flatMap { $0.isEmpty ? nil : $0 } ?? "the book")
        let words: String
        switch kind {
        case .keep: words = "<h1>Kept for good</h1><p class=\"muted\">\(book) stays online now, for everyone in it. Everyone's full-size photos can be downloaded from the book.</p>"
        case .event: words = "<h1>Event Pass added</h1><p class=\"muted\">\(book) has room for 100 friends and is kept for good.</p>"
        case .print: words = "<h1>It's being printed</h1><p class=\"muted\">Your copy of \(book) is on its way to the printer. Printing and shipping usually take one to two weeks, and we'll email you when it ships.</p>"
        }
        let body = "<span class=\"ribbon\" aria-hidden=\"true\"></span>\(words)<p class=\"fine\">It can take a minute to show on the book.</p><p><a class=\"button\" href=\"\(InvitePage.escape(bookPath))\">Back to the book</a></p>"
        return shell(title: "Thank you · Bound", body: body)
    }

    /// The no-charge checkout used in development and the checks.
    static func devCheckout(_ request: CheckoutRequest) -> String {
        let price = String(format: "$%.2f", Double(request.cents) / 100)
        var fields = "<label for=\"email\">Email</label><input id=\"email\" name=\"email\" type=\"email\" placeholder=\"Optional\">"
        fields += "<label for=\"name\">Name</label><input id=\"name\" name=\"name\" value=\"Test Buyer\">"
        if request.collectShipping {
            fields += """
            <label for="line1">Address</label><input id="line1" name="line1" value="1 Infinite Loop" required>
            <label for="city">City</label><input id="city" name="city" value="Cupertino" required>
            <label for="state">State</label><input id="state" name="state" value="CA">
            <label for="postal">Postal code</label><input id="postal" name="postal" value="95014" required>
            <label for="country">Country</label><input id="country" name="country" value="US" maxlength="2" required>
            <label for="phone">Phone</label><input id="phone" name="phone" value="4085551234">
            """
        }
        let body = """
        <span class="ribbon" aria-hidden="true"></span><h1>Test checkout</h1>
        <p class="muted">No card is charged. This page stands in for Stripe on a development server.</p>
        <form method="post" class="card"><p><strong>\(InvitePage.escape(request.itemName))</strong><br><span class="muted">\(InvitePage.escape(request.itemDescription))</span></p>
        \(fields)<p style="margin-top:18px"><button type="submit">Pay \(price) (test)</button></p></form>
        """
        return shell(title: "Test checkout · Bound", body: body)
    }
}

/// Fields from an `application/x-www-form-urlencoded` body.
struct FormFields {
    private var values: [String: String] = [:]

    init(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let decode: (String) -> String = { ($0.replacingOccurrences(of: "+", with: " ")).removingPercentEncoding ?? $0 }
            values[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
    }

    subscript(_ key: String) -> String? { values[key] }
}
