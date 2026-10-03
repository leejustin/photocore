/// The browser half of "repeats and blurry ones are fine": before uploading,
/// the page reads each photo's capture time from its EXIF, a 64-bit
/// difference hash and a sharpness score (variance of the Laplacian at 256
/// pixels), all on the person's own phone. It keeps the sharpest frame of each
/// burst (alike within 5 bits and 15 seconds), and skips frames that are
/// clearly blurry against the rest or nearly black, and files that aren't
/// photos. Anything it can't read (HEIC on Android) goes up for the server to
/// judge. The real curation still happens on the server; this only spares
/// uploads, so its thresholds are deliberately cautious, and the page offers
/// to add the skipped ones anyway.
enum Prefilter {
    static let script = """
    (function(){
      function isPhoto(f){
        var t = (f.type || '').toLowerCase(), n = (f.name || '').toLowerCase();
        if (t === 'image/jpeg' || t === 'image/heic' || t === 'image/heif') return true;
        return ['.jpg', '.jpeg', '.heic', '.heif'].some(function(e){ return n.slice(-e.length) === e; });
      }
      function exifDate(buf){
        var v = new DataView(buf);
        if (v.byteLength < 4 || v.getUint16(0) !== 0xFFD8) return null;
        var off = 2;
        while (off + 4 <= v.byteLength) {
          if (v.getUint8(off) !== 0xFF) return null;
          var marker = v.getUint8(off + 1), len = v.getUint16(off + 2);
          if (marker === 0xE1 && off + 10 <= v.byteLength && v.getUint32(off + 4) === 0x45786966) return tiffDate(v, off + 10);
          if (marker === 0xDA) return null;
          off += 2 + len;
        }
        return null;
      }
      function tiffDate(v, t){
        if (t + 8 > v.byteLength) return null;
        var little = v.getUint16(t) === 0x4949;
        function u16(o){ return v.getUint16(t + o, little); }
        function u32(o){ return v.getUint32(t + o, little); }
        function find(ifd, tag){
          if (t + ifd + 2 > v.byteLength) return -1;
          var n = u16(ifd);
          for (var i = 0; i < n; i++) {
            var e = ifd + 2 + i * 12;
            if (t + e + 12 > v.byteLength) return -1;
            if (u16(e) === tag) return e;
          }
          return -1;
        }
        function ascii(e){
          var count = u32(e + 4), o = count > 4 ? u32(e + 8) : e + 8, s = '';
          for (var i = 0; i < count - 1 && t + o + i < v.byteLength; i++) s += String.fromCharCode(v.getUint8(t + o + i));
          return s;
        }
        var ifd0 = u32(4), pointer = find(ifd0, 0x8769), s = null;
        if (pointer >= 0) {
          var exif = u32(pointer + 8), e = find(exif, 0x9003);
          if (e < 0) e = find(exif, 0x9004);
          if (e >= 0) s = ascii(e);
        }
        if (!s) { var d = find(ifd0, 0x0132); if (d >= 0) s = ascii(d); }
        if (!s || s.length < 19) return null;
        var ms = Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10), +s.slice(11, 13), +s.slice(14, 16), +s.slice(17, 19));
        return isNaN(ms) ? null : ms / 1000;
      }
      var canvas = document.createElement('canvas'), ctx = canvas.getContext('2d', { willReadFrequently: true });
      var tiny = document.createElement('canvas'); tiny.width = 9; tiny.height = 8;
      var tctx = tiny.getContext('2d', { willReadFrequently: true });
      function load(file){
        return new Promise(function(resolve){
          var url = URL.createObjectURL(file), img = new Image();
          img.onload = function(){ resolve({ img: img, url: url }); };
          img.onerror = function(){ URL.revokeObjectURL(url); resolve(null); };
          img.src = url;
        });
      }
      function analyze(img){
        var w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
        if (!w || !h) return null;
        var scale = Math.min(1, 256 / Math.max(w, h)), cw = Math.max(3, Math.round(w * scale)), ch = Math.max(3, Math.round(h * scale));
        canvas.width = cw; canvas.height = ch;
        ctx.imageSmoothingQuality = 'high';
        ctx.drawImage(img, 0, 0, cw, ch);
        var px = ctx.getImageData(0, 0, cw, ch).data, gray = new Float32Array(cw * ch), sum = 0;
        for (var i = 0, j = 0; i < px.length; i += 4, j++) { var g = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]; gray[j] = g; sum += g; }
        var n = 0, mean = 0, m2 = 0;
        for (var y = 1; y < ch - 1; y++) for (var x = 1; x < cw - 1; x++) {
          var k = y * cw + x, l = gray[k - cw] + gray[k + cw] + gray[k - 1] + gray[k + 1] - 4 * gray[k];
          n++; var d = l - mean; mean += d / n; m2 += d * (l - mean);
        }
        tctx.imageSmoothingQuality = 'high';
        tctx.drawImage(canvas, 0, 0, 9, 8);
        var t = tctx.getImageData(0, 0, 9, 8).data, bits = [];
        for (var yy = 0; yy < 8; yy++) for (var xx = 0; xx < 8; xx++) {
          var a = (yy * 9 + xx) * 4, b = a + 4;
          bits.push(t[a] * 0.299 + t[a + 1] * 0.587 + t[a + 2] * 0.114 > t[b] * 0.299 + t[b + 1] * 0.587 + t[b + 2] * 0.114 ? 1 : 0);
        }
        return { brightness: sum / gray.length, sharpness: n > 1 ? m2 / (n - 1) : 0, hash: bits };
      }
      function hamming(a, b){ var d = 0; for (var i = 0; i < 64; i++) if (a[i] !== b[i]) d++; return d; }
      function decide(items){
        var skipped = [], read = items.filter(function(x){ return x.info; });
        var sharp = read.map(function(x){ return x.info.sharpness; }).sort(function(a, b){ return a - b; });
        var median = sharp.length ? sharp[Math.floor(sharp.length / 2)] : 0, keep = [];
        items.forEach(function(x){
          if (!x.info) { keep.push(x); return; }
          if (x.info.brightness < 14) { skipped.push({ file: x.file, reason: 'dark' }); return; }
          if (read.length >= 6 && x.info.sharpness < Math.min(median * 0.1, 20)) { skipped.push({ file: x.file, reason: 'blurry' }); return; }
          keep.push(x);
        });
        keep.sort(function(a, b){ return (a.date || 0) - (b.date || 0) || a.index - b.index; });
        var result = [];
        keep.forEach(function(x){
          if (!x.info) { result.push(x); return; }
          var match = -1;
          for (var i = result.length - 1; i >= 0 && i >= result.length - 6; i--) {
            var y = result[i];
            if (!y.info) continue;
            var close = (x.date != null && y.date != null) ? Math.abs(x.date - y.date) <= 15 : (x.date == null && y.date == null && Math.abs(x.index - y.index) <= 3);
            if (close && hamming(x.info.hash, y.info.hash) <= 5) { match = i; break; }
          }
          if (match < 0) { result.push(x); return; }
          var other = result[match];
          if (x.info.sharpness > other.info.sharpness) { result[match] = x; skipped.push({ file: other.file, reason: 'repeat' }); }
          else skipped.push({ file: x.file, reason: 'repeat' });
        });
        result.sort(function(a, b){ return a.index - b.index; });
        return { keep: result.map(function(x){ return x.file; }), skipped: skipped };
      }
      function run(files, progress){
        var items = [], skipped = [];
        return files.reduce(function(chain, file, i){
          return chain.then(function(){
            if (progress) progress(i, files.length);
            if (!isPhoto(file)) { skipped.push({ file: file, reason: 'other' }); return; }
            return file.slice(0, 131072).arrayBuffer().then(function(buf){
              var date = null;
              try { date = exifDate(buf); } catch (e) {}
              return load(file).then(function(loaded){
                var info = null;
                if (loaded) { try { info = analyze(loaded.img); } catch (e) {} URL.revokeObjectURL(loaded.url); }
                items.push({ file: file, date: date, info: info, index: i });
              });
            });
          });
        }, Promise.resolve()).then(function(){
          var result = decide(items);
          result.skipped = skipped.concat(result.skipped);
          return result;
        });
      }
      function summary(result){
        var counts = { repeat: 0, blurry: 0, dark: 0, other: 0 };
        result.skipped.forEach(function(s){ counts[s.reason]++; });
        var parts = [];
        if (counts.repeat) parts.push(counts.repeat + (counts.repeat === 1 ? ' repeat' : ' repeats'));
        if (counts.blurry) parts.push(counts.blurry + ' blurry');
        if (counts.dark) parts.push(counts.dark + ' too dark');
        if (counts.other) parts.push(counts.other + (counts.other === 1 ? ' file that isn\\u2019t a photo' : ' files that aren\\u2019t photos'));
        return parts.length ? 'Skipped ' + parts.join(', ').replace(/, ([^,]*)$/, ' and $1') + '.' : '';
      }
      window.BoundPrefilter = { run: run, decide: decide, exifDate: exifDate, analyze: analyze, hamming: hamming, summary: summary };
    })();
    """
}
