import Foundation

/// The page behind a trip's invite link, and for most people the first thing
/// they see of Bound. It's designed like the cover of the book with their
/// friend's name on it, not like an upload form. Anyone who was there gives a
/// first name and adds photos; no app or account needed. The page keeps the
/// person's token in the browser so they can come back to add more or take
/// theirs out.
enum InvitePage {
    /// - Parameter cover: the finished book's cover photo, once there is one.
    static func html(code: String, title: String?, ownerName: String?, cover: String? = nil) -> String {
        let trip = title.flatMap { $0.isEmpty ? nil : $0 }
        let who = ownerName.flatMap { $0.isEmpty ? nil : $0 }
        let headline = "\(who ?? "Someone from the trip") is making a book of \(trip ?? "the trip")."
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex">
        <title>\(escape(trip ?? "Add your photos")) · Bound</title>
        <meta property="og:title" content="\(escape(headline))">
        <meta property="og:description" content="Add your photos. The best shot of each moment goes in, with your name on it.">
        <style>\(css)</style></head>
        <body><main>
        <div class="cover\(cover == nil ? "" : " has-photo")">
          \(cover.map { "<img src=\"\(escape($0))\" alt=\"\">" } ?? "")
          <div class="cover-words">
            <p class="cover-kicker">A book by everyone who was there</p>
            <p class="cover-title">\(escape(trip ?? "Our trip"))</p>
          </div>
          <span class="ribbon" aria-hidden="true"></span>
        </div>
        <h1>\(escape(headline)) <span>Add your photos.</span></h1>
        <p class="lede">The best shot of each moment goes in, with your name under it. Add as many as you like: repeats and blurry ones are fine.</p>

        <section id="closed" hidden><p>This book isn't taking photos any more.</p></section>

        <form id="join" hidden>
          <label for="name">Your first name</label>
          <input id="name" maxlength="40" autocomplete="given-name" required>
          <label for="email">Email <span class="optional">(optional)</span></label>
          <input id="email" type="email" maxlength="254" autocomplete="email" placeholder="To hear when the book is ready">
          <button type="submit">Continue</button>
        </form>

        <section id="add" hidden>
          <p class="who">Adding as <strong id="me"></strong> · <button type="button" class="link" id="not-me">Not you?</button></p>
          <label class="pick">Choose photos<input id="files" type="file" accept="image/*" multiple></label>
          <p class="hint">Bound looks through them on your phone first and skips repeats and blurry ones, so less goes up.</p>
          <div id="progress" hidden><div class="bar"><span id="bar"></span></div><p id="status" aria-live="polite"></p>
            <p id="skipped" class="hint" hidden></p>
            <button type="button" class="link" id="add-skipped" hidden></button></div>
          <p id="mine" class="hint"></p>
          <form id="mail" class="inline" hidden>
            <input id="later-email" type="email" maxlength="254" autocomplete="email" placeholder="Email me when the book is ready">
            <button type="submit" class="small">Save</button>
          </form>
          <button type="button" class="link danger" id="remove" hidden>Remove my photos</button>
        </section>

        <section id="ready" hidden><a id="read" class="pick" href="#">Read the book</a></section>

        <section id="you" hidden>
          <h2>Photos of you</h2>
          <p class="hint" id="you-hint">Tap your face. Bound finds your other photos in the book. Only you see this, and nobody is recognized: it only compares faces in this book.</p>
          <div id="faces" class="faces"></div>
          <button type="button" class="link" id="more-faces" hidden>More faces</button>
          <div id="yours" hidden>
            <h3 id="yours-title"></h3>
            <div id="your-photos" class="mine"></div>
            <button type="button" class="pick" id="save-yours">Save your photos</button>
          </div>
        </section>
        <p class="fine">Only people with this link can add photos. Photos stay private until they're picked for the book, and the ones that aren't picked are deleted.</p>
        <p class="brand">Bound · Finish the trip.</p>
        </main>
        <script>\(Prefilter.script)</script>
        <script>window.BOUND_INVITE = \(json(code));\(script)</script></body></html>
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
    :root { --paper:#f7f2ea; --ink:#1e1b18; --cover:#1e1b18; --muted:#6f675e; --accent:#b3322b; --line:#e4ddd1; --card:#fffdf9; --serif:"New York","Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif; --sans:-apple-system,BlinkMacSystemFont,"Helvetica Neue","Segoe UI",sans-serif; }
    @media (prefers-color-scheme: dark) { :root { --paper:#141210; --ink:#efeae2; --cover:#2a2622; --muted:#a69e94; --accent:#e06b61; --line:#2a2622; --card:#1c1916; } }
    * { box-sizing:border-box; }
    body { margin:0; background:var(--paper); color:var(--ink); font:17px/1.6 var(--sans); }
    main { max-width:560px; margin:0 auto; padding:40px 16px 64px; }
    .cover { position:relative; width:min(300px, 72vw); aspect-ratio:5 / 6; margin:0 auto 34px; border-radius:10px 14px 14px 10px; background:var(--cover); color:#f4ede1; overflow:hidden; box-shadow:0 2px 3px rgba(0,0,0,.18), 0 18px 40px rgba(40,25,10,.22); }
    .cover::before { content:""; position:absolute; top:0; bottom:0; left:22px; width:3px; background:rgba(255,255,255,.08); z-index:2; }
    .cover img { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
    .cover.has-photo .cover-words { background:linear-gradient(to top, rgba(0,0,0,.7), rgba(0,0,0,0)); }
    .cover-words { position:absolute; left:0; right:0; bottom:0; padding:44px 22px 24px 40px; z-index:1; }
    .cover-kicker { margin:0 0 6px; font-size:11px; letter-spacing:.14em; text-transform:uppercase; opacity:.75; }
    .cover-title { margin:0; font-family:var(--serif); font-weight:600; font-size:30px; line-height:1.08; letter-spacing:-.01em; }
    .ribbon { position:absolute; right:38px; bottom:-1px; width:22px; height:46px; background:var(--accent); clip-path:polygon(0 0, 100% 0, 100% 100%, 50% 78%, 0 100%); z-index:3; }
    h1 { font-family:var(--serif); font-weight:600; font-size:clamp(26px, 6.4vw, 34px); line-height:1.18; letter-spacing:-.01em; margin:0 0 12px; text-align:center; }
    h1 span { color:var(--accent); white-space:nowrap; }
    .lede { color:var(--muted); margin:0 0 26px; text-align:center; }
    form, #add, #closed, #ready, #you { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:20px; display:grid; gap:12px; margin-bottom:16px; }
    label[for] { font-weight:600; font-size:15px; }
    input[type=text], input[type=email], input#name { font:inherit; padding:12px 14px; border-radius:12px; border:1px solid var(--line); background:var(--paper); color:var(--ink); width:100%; }
    button[type=submit], .pick { font:inherit; font-weight:600; text-align:center; text-decoration:none; padding:14px 22px; border:0; border-radius:999px; background:var(--accent); color:#fff; cursor:pointer; display:block; }
    .pick input { display:none; }
    .who { margin:0; font-size:15px; color:var(--muted); }
    .link { font:inherit; font-size:inherit; background:none; border:0; padding:0; color:var(--accent); cursor:pointer; text-decoration:underline; justify-self:start; }
    .danger { color:var(--muted); font-size:14px; }
    .hint, .fine { font-size:14px; color:var(--muted); margin:0; }
    .fine { margin-top:8px; text-align:center; }
    .optional { font-weight:400; color:var(--muted); }
    #you h2 { font-family:var(--serif); font-weight:600; font-size:24px; margin:0; }
    #you h3 { font-family:var(--serif); font-weight:600; font-size:19px; margin:10px 0 0; }
    .faces { display:grid; grid-template-columns:repeat(auto-fill, minmax(58px, 1fr)); gap:8px; }
    .face { padding:0; border:2px solid transparent; border-radius:50%; background:none; cursor:pointer; aspect-ratio:1; overflow:hidden; }
    .face img { width:100%; height:100%; object-fit:cover; border-radius:50%; display:block; }
    .face.on { border-color:var(--accent); box-shadow:0 0 0 2px var(--accent); }
    .mine { display:grid; grid-template-columns:repeat(3, 1fr); gap:6px; }
    .mine figure { margin:0; position:relative; }
    .mine img { width:100%; aspect-ratio:1; object-fit:cover; border-radius:6px; display:block; }
    .mine button { position:absolute; left:4px; bottom:4px; font:inherit; font-size:11px; padding:3px 8px; border:0; border-radius:99px; background:rgba(20,18,16,.6); color:#fff; cursor:pointer; }
    form.inline { display:flex; gap:8px; padding:0; border:0; background:none; margin:0; }
    form.inline input { flex:1; min-width:0; }
    button.small { font:inherit; font-weight:600; padding:10px 16px; border:0; border-radius:999px; background:var(--ink); color:var(--paper); cursor:pointer; }
    .brand { text-align:center; font-family:var(--serif); font-size:14px; color:var(--muted); margin:26px 0 0; letter-spacing:.02em; }
    .bar { height:8px; border-radius:99px; background:var(--line); overflow:hidden; }
    .bar span { display:block; height:100%; width:0; background:var(--accent); transition:width .2s; }
    #status { margin:8px 0 0; font-size:15px; }
    [hidden] { display:none !important; }
    """

    static let script = """
    (function(){
      var code = window.BOUND_INVITE, base = '/j/' + code, key = 'photocore-invite-' + code;
      function $(id){ return document.getElementById(id); }
      function load(){ try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch (e) { return null; } }
      function save(v){ try { if (v) localStorage.setItem(key, JSON.stringify(v)); else localStorage.removeItem(key); } catch (e) {} }
      var me = load();
      function headers(){ return me ? { 'X-Photocore-Contributor': me.token } : {}; }
      function plural(n, one){ return n + ' ' + one + (n === 1 ? '' : 's'); }
      function refresh(){
        fetch(base + '/status', { headers: headers() }).then(function(r){ return r.json(); }).then(function(s){
          if (s.bookPath) { $('ready').hidden = false; $('read').href = s.bookPath; if (me && s.me) loadYou(); }
          if (!s.open) { $('closed').hidden = false; $('join').hidden = true; $('add').hidden = true; return; }
          if (me && s.me) {
            $('join').hidden = true; $('add').hidden = false; $('me').textContent = s.me;
            $('mine').textContent = s.mine ? 'You\\u2019ve added ' + plural(s.mine, 'photo') + '.' : '';
            $('remove').hidden = !s.mine;
            $('mail').hidden = !!s.emailSet;
          } else {
            if (me && !s.me) { me = null; save(null); }
            $('join').hidden = false; $('add').hidden = true;
          }
        }).catch(function(){});
      }
      $('join').addEventListener('submit', function(e){
        e.preventDefault();
        var name = $('name').value.trim(); if (!name) return;
        var email = $('email').value.trim();
        fetch(base + '/join', { method:'POST', headers:{ 'Content-Type':'application/json' }, body: JSON.stringify({ name: name, email: email || null }) })
          .then(function(r){ return r.json().then(function(d){ if (!r.ok) throw d; return d; }); })
          .then(function(d){ me = { token: d.token, name: d.name }; save(me); refresh(); })
          .catch(function(e){ alert((e && e.error && e.error.message) || 'Couldn\\u2019t join. Check the link and try again.'); });
      });
      $('mail').addEventListener('submit', function(e){
        e.preventDefault();
        var email = $('later-email').value.trim(); if (!email || !me) return;
        fetch(base + '/email', { method:'POST', headers: Object.assign({ 'Content-Type':'application/json' }, headers()), body: JSON.stringify({ email: email }) })
          .then(function(r){ return r.json().then(function(d){ if (!r.ok) throw d; return d; }); })
          .then(function(){ $('mail').hidden = true; })
          .catch(function(e){ alert((e && e.error && e.error.message) || 'Couldn\\u2019t save that.'); });
      });
      $('not-me').addEventListener('click', function(){ me = null; save(null); refresh(); });
      var leftOut = [];
      function upload(files, note){
        var done = 0, failed = 0, full = false;
        $('progress').hidden = false;
        function show(){
          $('bar').style.width = Math.round(100 * (done + failed) / Math.max(files.length, 1)) + '%';
          $('status').textContent = 'Adding ' + (done + failed) + ' of ' + files.length + '\\u2026';
        }
        show();
        return files.reduce(function(chain, file, i){
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
            : (files.length ? 'Those photos couldn\\u2019t be added. JPEG and HEIC photos work.' : 'Nothing new to add.');
          refresh();
        });
      }
      $('files').addEventListener('change', function(){
        var files = Array.prototype.slice.call(this.files || []); this.value = '';
        if (!files.length || !me) return;
        $('progress').hidden = false; $('skipped').hidden = true; $('add-skipped').hidden = true;
        var looking = function(i, n){
          $('bar').style.width = Math.round(100 * i / n) + '%';
          $('status').textContent = 'Looking through your photos\\u2026 ' + i + ' of ' + n;
        };
        var filter = window.BoundPrefilter ? window.BoundPrefilter.run(files, looking) : Promise.resolve({ keep: files, skipped: [] });
        filter.catch(function(){ return { keep: files, skipped: [] }; }).then(function(result){
          leftOut = result.skipped.filter(function(s){ return s.reason !== 'other'; }).map(function(s){ return s.file; });
          var note = window.BoundPrefilter ? window.BoundPrefilter.summary(result) : '';
          upload(result.keep).then(function(){
            if (note) { $('skipped').textContent = note; $('skipped').hidden = false; }
            if (leftOut.length) { $('add-skipped').textContent = 'Add the ' + plural(leftOut.length, 'skipped photo') + ' anyway'; $('add-skipped').hidden = false; }
          });
        });
      });
      $('add-skipped').addEventListener('click', function(){
        var files = leftOut; leftOut = [];
        $('add-skipped').hidden = true; $('skipped').hidden = true;
        upload(files);
      });
      var allFaces = false, lastYou = null;
      function renderYou(y){
        lastYou = y;
        if (!y.available) { $('you').hidden = true; return; }
        $('you').hidden = false;
        var tapped = {}; y.tapped.forEach(function(id){ tapped[id] = true; });
        var shown = allFaces ? y.faces : y.faces.slice(0, 30);
        $('faces').innerHTML = '';
        shown.forEach(function(f){
          var b = document.createElement('button'); b.type = 'button'; b.className = 'face' + (tapped[f.id] ? ' on' : '');
          b.setAttribute('aria-label', tapped[f.id] ? 'Your face, tap to undo' : 'Tap if this is you');
          var img = document.createElement('img'); img.src = f.url; img.alt = ''; img.loading = 'lazy'; b.appendChild(img);
          b.addEventListener('click', function(){ youPost('', { face: f.id }); });
          $('faces').appendChild(b);
        });
        $('more-faces').hidden = allFaces || y.faces.length <= 30;
        $('yours').hidden = !y.photos.length;
        $('you-hint').textContent = y.photos.length
          ? 'Tap more of your faces if any photos are missing. Only you see this.'
          : 'Tap your face. Bound finds your other photos in the book. Only you see this, and nobody is recognized: it only compares faces in this book.';
        $('yours-title').textContent = y.photos.length === 1 ? 'You\\u2019re in 1 photo' : 'You\\u2019re in ' + y.photos.length + ' photos';
        $('your-photos').innerHTML = '';
        y.photos.forEach(function(p){
          var fig = document.createElement('figure');
          var img = document.createElement('img'); img.src = p.url; img.alt = p.credit ? 'By ' + p.credit : ''; img.loading = 'lazy';
          var no = document.createElement('button'); no.type = 'button'; no.textContent = 'Not me';
          no.addEventListener('click', function(){ youPost('/not', { file: p.file }); });
          fig.appendChild(img); fig.appendChild(no); $('your-photos').appendChild(fig);
        });
        if (location.hash === '#you' && !window.__boundScrolled) { window.__boundScrolled = true; $('you').scrollIntoView(); }
      }
      function loadYou(){
        fetch(base + '/you', { headers: headers() }).then(function(r){ return r.ok ? r.json() : null; }).then(function(y){ if (y) renderYou(y); }).catch(function(){});
      }
      function youPost(path, body){
        fetch(base + '/you' + path, { method:'POST', headers: Object.assign({ 'Content-Type':'application/json' }, headers()), body: JSON.stringify(body) })
          .then(function(r){ return r.ok ? r.json() : null; }).then(function(y){ if (y) renderYou(y); }).catch(function(){});
      }
      $('more-faces').addEventListener('click', function(){ allFaces = true; if (lastYou) renderYou(lastYou); });
      $('save-yours').addEventListener('click', function(){
        var button = $('save-yours'); button.disabled = true; button.textContent = 'Getting your photos\\u2026';
        fetch(base + '/you.zip', { headers: headers() }).then(function(r){ if (!r.ok) throw r; return r.blob(); }).then(function(blob){
          var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'Photos of ' + (me && me.name || 'you') + '.zip';
          document.body.appendChild(a); a.click(); a.remove();
          setTimeout(function(){ URL.revokeObjectURL(a.href); }, 10000);
        }).catch(function(){ alert('Couldn\\u2019t get your photos. Try again in a moment.'); }).then(function(){ button.disabled = false; button.textContent = 'Save your photos'; });
      });
      $('remove').addEventListener('click', function(){
        if (!confirm('Remove all the photos you added? They won\\u2019t be in the book.')) return;
        fetch(base + '/photos', { method:'DELETE', headers: headers() }).then(function(){ $('progress').hidden = true; refresh(); });
      });
      refresh();
    })();
    """
}
