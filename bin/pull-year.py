#!/usr/bin/env python3
"""Download one year folder from Dropbox to a plain local folder.

  export DROPBOX_PHOTO_ROOT="/Photos/camera imports"
  python3 pull-year.py 2003              -> ./photos-2003/
  python3 pull-year.py 2003 ~/somewhere  -> ~/somewhere/

Sets each file's modification time from Dropbox's client_modified, which is what
stamp-dates.py falls back on for photos with no EXIF date. Skips files already present
at the right size, so re-running resumes instead of starting over.
"""
import os, sys, time, threading
from concurrent.futures import ThreadPoolExecutor
import dropbox
from dropbox.files import FileMetadata

ROOT = os.environ.get("DROPBOX_PHOTO_ROOT", "").rstrip("/")
CONF = os.path.expanduser("~/.config/dropbox-cleanup")
if not ROOT:
    sys.exit('Set DROPBOX_PHOTO_ROOT to the Dropbox folder holding the YYYY/ subfolders:\n'
             '  export DROPBOX_PHOTO_ROOT="/Photos/camera imports"')
year = next((a for a in sys.argv[1:] if not a.startswith("-")), None)
if not year: sys.exit("Which year? e.g.  python3 pull-year.py 2003")
rest = [a for a in sys.argv[1:] if not a.startswith("-")][1:]
dest = os.path.expanduser(rest[0]) if rest else f"photos-{year}"

def human(n):
    for u in ("B","KB","MB","GB","TB"):
        if n < 1024 or u == "TB": return f"{n:,.1f} {u}"
        n /= 1024

def connect():
    k = s = None
    p = os.path.join(CONF,"app")
    if os.path.exists(p):
        for line in open(p):
            if line.startswith("APP_KEY="): k = line.split("=",1)[1].strip()
            if line.startswith("APP_SECRET="): s = line.split("=",1)[1].strip()
    rt = None
    p = os.path.join(CONF,"refresh")
    if os.path.exists(p): rt = open(p).read().strip()
    tok = open(os.path.join(CONF,"token")).read().strip()
    if rt and k and s:
        dbx = dropbox.Dropbox(oauth2_access_token=tok, oauth2_refresh_token=rt,
                              app_key=k, app_secret=s, timeout=300)
        mode = "auto-refreshing"
    else:
        dbx = dropbox.Dropbox(tok, timeout=300); mode = "single token"
    try: who = dbx.users_get_current_account()
    except dropbox.exceptions.AuthError: sys.exit("Token rejected. Run: dropbox-auth.sh")
    print(f"Signed in as {who.name.display_name}  [{mode}]")
    return dbx

def api(fn, *a, **kw):
    for i in range(6):
        try: return fn(*a, **kw)
        except dropbox.exceptions.RateLimitError as e:
            time.sleep(getattr(e.error,"retry_after",None) or 2**i)
    sys.exit("Rate limited repeatedly.")

dbx = connect()
src = f"{ROOT}/{year}"
print(f"Listing {src}")
files = []
res = api(dbx.files_list_folder, src, recursive=True, limit=2000)
while True:
    files += [e for e in res.entries if isinstance(e, FileMetadata)]
    if not res.has_more: break
    res = api(dbx.files_list_folder_continue, res.cursor)
if not files: sys.exit(f"Nothing in {src}")
total = sum(f.size for f in files)
print(f"{len(files):,} files, {human(total)}  ->  {dest}/")

todo = []
for f in files:
    rel = f.path_display[len(src)+1:]
    local = os.path.join(dest, rel)
    if os.path.exists(local) and os.path.getsize(local) == f.size:
        continue
    todo.append((f, local))
skipped = len(files) - len(todo)
if skipped: print(f"{skipped:,} already downloaded, {len(todo):,} to go")
if not todo: sys.exit("Everything is already here.")

lock = threading.Lock()
done = [0, 0]
t0 = time.time()
fails = []
def pull(item):
    f, local = item
    os.makedirs(os.path.dirname(local), exist_ok=True)
    try:
        api(dbx.files_download_to_file, local, f.id)
        ts = f.client_modified.timestamp()
        os.utime(local, (ts, ts))          # stamp-dates.py needs this
    except Exception as e:
        with lock: fails.append((f.path_display, str(e)[:120]))
        return
    with lock:
        done[0] += 1; done[1] += f.size
        if done[0] % 20 == 0 or done[0] == len(todo):
            el = max(time.time()-t0, 1)
            pct = 100*done[0]//len(todo)
            print(f"\r  {done[0]:,}/{len(todo):,} ({pct}%)  {human(done[1])}  "
                  f"{human(done[1]/el)}/s", end="", flush=True)
with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(pull, todo))
print()
if fails:
    print(f"\n{len(fails):,} failed:")
    for p, e in fails[:5]: print(f"  {os.path.basename(p)}: {e}")
    print("Re-run to retry just those.")
print(f"\nDone. {done[0]:,} files in {dest}/")
print(f"Next:  python3 stamp-dates.py {dest}")
