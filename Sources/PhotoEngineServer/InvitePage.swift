import Foundation

/// The page behind a trip's invite link. Anyone who was there opens it in a
/// browser, gives a first name and adds photos; no app or account needed. The
/// page keeps the person's token in the browser so they can come back to add
/// more or take theirs out.
enum InvitePage {
    static func html(code: String, title: String?, ownerName: String?) -> String {
        let trip = title.flatMap { $0.isEmpty ? nil : $0 } ?? "the trip"
        let who = ownerName.flatMap { $0.isEmpty ? nil : $0 } ?? "Someone from the trip"
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex">
        <title>Add your photos · \(escape(trip))</title>
        <meta property="og:title" content="Add your photos to \(escape(trip))">
        <meta property="og:description" content="\(escape(who)) is making a book of the trip with everyone's photos.">
        <style>\(css)</style></head>
        <body><main>
        <p class="kicker">Photocore</p>
        <h1>Add your photos to <span class="trip">\(escape(trip))</span></h1>
        <p class="lede">\(escape(who)) is making a book of the trip from everyone's photos. Add yours, and the best shot of each moment goes in, with your name on it.</p>

        <section id="closed" hidden><p>This trip isn't taking photos any more.</p></section>

        <form id="join" hidden>
          <label for="name">Your first name</label>
          <input id="name" maxlength="40" autocomplete="given-name" required>
          <button type="submit">Continue</button>
        </form>

        <section id="add" hidden>
          <p class="who">Adding as <strong id="me"></strong> · <button type="button" class="link" id="not-me">Not you?</button></p>
          <label class="pick">Choose photos<input id="files" type="file" accept="image/*" multiple></label>
          <p class="hint">Add as many as you like, up to 150. Repeats and blurry ones are fine: Photocore picks.</p>
          <div id="progress" hidden><div class="bar"><span id="bar"></span></div><p id="status" aria-live="polite"></p></div>
          <p id="mine" class="hint"></p>
          <button type="button" class="link danger" id="remove" hidden>Remove my photos</button>
        </section>

        <section id="ready" hidden><a id="read" class="pick" href="#">Read the book</a></section>
        <p class="fine">Only people with this link can add photos. Photos stay private until they're picked for the book.</p>
        </main>
        <script>window.PHOTOCORE_INVITE = \(json(code));\(script)</script></body></html>
        """
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func json(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static let css = """
    :root { --paper:#f7f3ec; --ink:#1d1a17; --muted:#6f675e; --accent:#b8532f; --line:#e4ddd1; --card:#fffdf9; --serif:"New York","Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; --sans:-apple-system,BlinkMacSystemFont,"Helvetica Neue","Segoe UI",sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --paper:#141210; --ink:#efeae2; --muted:#a69e94; --accent:#e58a63; --line:#2a2622; --card:#1c1916; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--paper); color:var(--ink); font:17px/1.6 var(--sans); }
    main { max-width:560px; margin:0 auto; padding:56px 20px 64px; }
    .kicker { text-transform:uppercase; letter-spacing:.14em; font-size:11.5px; font-weight:600; color:var(--accent); margin:0 0 12px; }
    h1 { font-family:var(--serif); font-weight:600; font-size:clamp(30px, 7vw, 40px); line-height:1.12; letter-spacing:-.015em; margin:0 0 14px; }
    .lede { color:var(--muted); margin:0 0 30px; }
    form, #add, #closed, #ready { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:22px; display:grid; gap:12px; margin-bottom:18px; }
    label[for] { font-weight:600; font-size:15px; }
    input#name { font:inherit; padding:12px 14px; border-radius:12px; border:1px solid var(--line); background:var(--paper); color:var(--ink); }
    button[type=submit], .pick { font:inherit; font-weight:600; text-align:center; text-decoration:none; padding:14px 22px; border:0; border-radius:999px; background:var(--accent); color:#fff; cursor:pointer; display:block; }
    .pick input { display:none; }
    .who { margin:0; font-size:15px; color:var(--muted); }
    .link { font:inherit; font-size:inherit; background:none; border:0; padding:0; color:var(--accent); cursor:pointer; text-decoration:underline; justify-self:start; }
    .danger { color:var(--muted); font-size:14px; }
    .hint, .fine { font-size:14px; color:var(--muted); margin:0; }
    .fine { margin-top:8px; text-align:center; }
    .bar { height:8px; border-radius:99px; background:var(--line); overflow:hidden; }
    .bar span { display:block; height:100%; width:0; background:var(--accent); transition:width .2s; }
    #status { margin:8px 0 0; font-size:15px; }
    [hidden] { display:none !important; }
    """

    static let script = """
    (function(){
      var code = window.PHOTOCORE_INVITE, base = '/j/' + code, key = 'photocore-invite-' + code;
      function $(id){ return document.getElementById(id); }
      function load(){ try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) { return null; } }
      function save(v){ try { if (v) localStorage.setItem(key, JSON.stringify(v)); else localStorage.removeItem(key); } catch (e) {} }
      var me = load();
      function headers(){ return me ? { 'X-Photocore-Contributor': me.token } : {}; }
      function plural(n, one){ return n + ' ' + one + (n === 1 ? '' : 's'); }
      function refresh(){
        fetch(base + '/status', { headers: headers() }).then(function(r){ return r.json(); }).then(function(s){
          if (s.bookPath) { $('ready').hidden = false; $('read').href = s.bookPath; }
          if (!s.open) { $('closed').hidden = false; $('join').hidden = true; $('add').hidden = true; return; }
          if (me && s.me) {
            $('join').hidden = true; $('add').hidden = false; $('me').textContent = s.me;
            $('mine').textContent = s.mine ? 'You\\u2019ve added ' + plural(s.mine, 'photo') + '.' : '';
            $('remove').hidden = !s.mine;
          } else {
            if (me && !s.me) { me = null; save(null); }
            $('join').hidden = false; $('add').hidden = true;
          }
        }).catch(function(){});
      }
      $('join').addEventListener('submit', function(e){
        e.preventDefault();
        var name = $('name').value.trim(); if (!name) return;
        fetch(base + '/join', { method:'POST', headers:{ 'Content-Type':'application/json' }, body: JSON.stringify({ name: name }) })
          .then(function(r){ if (!r.ok) throw r; return r.json(); })
          .then(function(d){ me = { token: d.token, name: d.name }; save(me); refresh(); })
          .catch(function(){ alert('Couldn\\u2019t join. Check the link and try again.'); });
      });
      $('not-me').addEventListener('click', function(){ me = null; save(null); refresh(); });
      $('files').addEventListener('change', function(){
        var files = Array.prototype.slice.call(this.files || []); this.value = '';
        if (!files.length || !me) return;
        var done = 0, failed = 0, full = false;
        $('progress').hidden = false;
        function show(){
          $('bar').style.width = Math.round(100 * (done + failed) / files.length) + '%';
          $('status').textContent = 'Adding ' + (done + failed) + ' of ' + files.length + '\\u2026';
        }
        show();
        files.reduce(function(chain, file, i){
          return chain.then(function(){
            if (full) { failed++; show(); return; }
            var name = Date.now().toString(36) + i;
            return fetch(base + '/photos/' + name, { method:'PUT', headers: Object.assign({ 'Content-Type': file.type || 'application/octet-stream' }, headers()), body:file })
              .then(function(r){ if (r.ok) done++; else { failed++; if (r.status === 409) full = true; } show(); })
              .catch(function(){ failed++; show(); });
          });
        }, Promise.resolve()).then(function(){
          $('bar').style.width = '100%';
          $('status').textContent = done
            ? 'Thanks, ' + me.name + '! ' + plural(done, 'photo') + ' added.' + (failed ? ' ' + plural(failed, 'photo') + ' couldn\\u2019t be added' + (full ? ': that\\u2019s the limit.' : ' (JPEG or HEIC only).') : '')
            : 'Those photos couldn\\u2019t be added. JPEG and HEIC photos work.';
          refresh();
        });
      });
      $('remove').addEventListener('click', function(){
        if (!confirm('Remove all the photos you added? They won\\u2019t be in the book.')) return;
        fetch(base + '/photos', { method:'DELETE', headers: headers() }).then(function(){ $('progress').hidden = true; refresh(); });
      });
      refresh();
    })();
    """
}
