import base64, csv, collections, html, json, os, random, sys, time
from concurrent.futures import ThreadPoolExecutor
import requests
TOK = open(os.path.expanduser("~/.config/dropbox-cleanup/token")).read().strip()
URL = "https://content.dropboxapi.com/2/files/get_thumbnail_v2"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20
SEED = int(sys.argv[2]) if len(sys.argv) > 2 else 1

NEAR_CSV = os.environ.get("NEAR_CSV", "near-dupes.csv")
OUT_HTML = os.environ.get("OUT_HTML", "contact-sheet.html")
rows = list(csv.DictReader(open(NEAR_CSV)))
g = collections.defaultdict(list)
for r in rows: g[r["group"]].append(r)
def waste(v): return sum(sorted((int(x["size_bytes"] or 0) for x in v), reverse=True)[1:])
keys = list(g)
top = sorted(keys, key=lambda k: waste(g[k]), reverse=True)[:max(4, N//4)]
random.seed(SEED)
rest = random.sample([k for k in keys if k not in top], min(N - len(top), max(0, len(keys)-len(top))))
picked = [g[k] for k in top + rest]

def live_path(r):
    """Where the file is now: candidates moved, keepers didn't."""
    return r["moved_to"] if r.get("moved") == "yes" and r.get("moved_to") else r["path"]

def thumb(path):
    arg = {"resource": {".tag": "path", "path": path}, "format": "jpeg",
           "size": "w640h480", "mode": "strict"}
    for attempt in range(4):
        try:
            r = requests.post(URL, headers={"Authorization": f"Bearer {TOK}",
                              "Dropbox-API-Arg": json.dumps(arg)}, timeout=60)
        except requests.RequestException:
            time.sleep(2 ** attempt); continue
        if r.status_code == 200: return r.content
        if r.status_code == 429: time.sleep(int(r.headers.get("Retry-After", 2))); continue
        if r.status_code >= 500: time.sleep(2 ** attempt); continue
        return None
    return None

todo = [r for v in picked for r in v]
print(f"Fetching {len(todo)} thumbnails across {len(picked)} groups "
      f"({len(top)} biggest, {len(rest)} random)...")
with ThreadPoolExecutor(max_workers=8) as pool:
    blobs = list(pool.map(lambda r: thumb(live_path(r)), todo))
got = {id(r): b for r, b in zip(todo, blobs)}
ok = sum(1 for b in blobs if b)
print(f"  got {ok}/{len(todo)}")
if not ok: sys.exit("No thumbnails. Run dropbox-auth.sh --refresh and retry.")

out = ["""<!doctype html><meta charset=utf-8><title>Near-duplicate review</title>
<style>
:root{--bg:#faf9f7;--fg:#1a1a1a;--muted:#6b6b6b;--keep:#0a7d3c;--cand:#b45309;--line:#e3e0da;--card:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#16150f;--fg:#f0eee8;--muted:#9a978e;--line:#33312b;--card:#1e1d16}}
body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1400px}
h1{font-size:20px;margin:0 0 4px} .sub{color:var(--muted);margin:0 0 24px;max-width:70ch}
.grp{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:16px}
.gh{color:var(--muted);font-size:13px;margin-bottom:12px}
.imgs{display:flex;gap:14px;flex-wrap:wrap}
figure{margin:0;width:260px}
img{width:260px;height:auto;border-radius:6px;display:block;background:#0002}
figcaption{font-size:12px;margin-top:6px;word-break:break-all;line-height:1.45}
.tag{display:inline-block;padding:1px 7px;border-radius:99px;font-size:11px;font-weight:600;letter-spacing:.02em}
.keep .tag{background:#0a7d3c1f;color:var(--keep)} .cand .tag{background:#b453091f;color:var(--cand)}
.loc{color:var(--muted);font-size:11px}
.miss{width:260px;height:180px;display:grid;place-items:center;border:1px dashed var(--line);border-radius:6px;color:var(--muted);font-size:13px}
</style>
<h1>Near-duplicate review</h1>
<p class=sub>Green stayed where it was. Amber has moved to /_near_dupes_review. If the amber
images match the green one in each row, the move did what it should and the review folder
is safe to delete.</p>"""]
for v in picked:
    v = sorted(v, key=lambda r: int(r["size_bytes"] or 0), reverse=True)
    out.append(f'<div class=grp><div class=gh>Group {html.escape(v[0]["group"])} &middot; '
               f'{len(v)} files &middot; {html.escape(v[0]["year"])}-{int(v[0]["month"] or 1):02d}</div><div class=imgs>')
    for j, r in enumerate(v):
        b = got.get(id(r))
        keep = r["action"] == "keep"
        cls, label = ("keep","KEPT") if keep else ("cand","MOVED")
        where = os.path.dirname(live_path(r))
        img = (f'<img src="data:image/jpeg;base64,{base64.b64encode(b).decode()}">'
               if b else '<div class=miss>no thumbnail</div>')
        out.append(f'<figure class={cls}>{img}<figcaption><span class="tag">{label}</span> '
                   f'{html.escape(os.path.basename(r["path"]))}<br>'
                   f'{int(r["size_bytes"] or 0)/1e6:.2f} MB<br>'
                   f'<span class=loc>{html.escape(where)}</span></figcaption></figure>')
    out.append('</div></div>')
open(OUT_HTML,"w").write("\n".join(out))
print(f"\nWritten to {OUT_HTML}")
