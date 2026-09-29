#!/usr/bin/env python3
"""Execute the moves already planned in photo-dates.csv.

No re-scan: the plan is already in the CSV. The Dropbox client is built with your
refresh token, so it renews itself mid-run instead of dying after four hours.
Progress is written back to the CSV after every batch, so an interruption costs
one batch, not the whole job.

  python3 apply-sort.py            move what's left
  python3 apply-sort.py --undo     put everything back
"""
import csv, os, re, sys, time
import dropbox
from dropbox.files import RelocationPath

CSV = "photo-dates.csv"
CONF = os.path.expanduser("~/.config/dropbox-cleanup")

def load_conf():
    key = secret = None
    p = os.path.join(CONF, "app")
    if os.path.exists(p):
        for line in open(p):
            if line.startswith("APP_KEY="): key = line.split("=",1)[1].strip()
            if line.startswith("APP_SECRET="): secret = line.split("=",1)[1].strip()
    rt = None
    p = os.path.join(CONF, "refresh")
    if os.path.exists(p): rt = open(p).read().strip()
    tok = open(os.path.join(CONF, "token")).read().strip()
    return tok, rt, key, secret

def human(n):
    for u in ("B","KB","MB","GB","TB"):
        if n < 1024 or u == "TB": return f"{n:,.1f} {u}"
        n /= 1024

def connect():
    tok, rt, key, secret = load_conf()
    if rt and key and secret:
        dbx = dropbox.Dropbox(oauth2_access_token=tok, oauth2_refresh_token=rt,
                              app_key=key, app_secret=secret, timeout=300)
        mode = "auto-refreshing"
    else:
        dbx = dropbox.Dropbox(tok, timeout=300)
        mode = "single token (will expire in under 4 hours)"
    try:
        who = dbx.users_get_current_account()
    except dropbox.exceptions.AuthError:
        sys.exit("Token rejected. Run: dropbox-auth.sh")
    print(f"Signed in as {who.name.display_name}  [{mode}]")
    return dbx

def api(fn, *a, **kw):
    for i in range(6):
        try: return fn(*a, **kw)
        except dropbox.exceptions.RateLimitError as e:
            w = getattr(e.error, "retry_after", None) or 2**i
            print(f"\n  rate limited, waiting {w}s", flush=True); time.sleep(w)
    sys.exit("Rate limited repeatedly. Try again later.")

def save(rows):
    fields = ["path","size_bytes","year","month","date_source","target","moved"]
    with open(CSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows([{k: r.get(k,"") for k in fields} for r in rows])

def run(dbx, rows, pairs, label, mark):
    done, failed = 0, []
    batches = (len(pairs) + 999)//1000
    t_all = time.time()
    by_src = {r["path"]: r for r in rows}
    for n, s in enumerate(range(0, len(pairs), 1000), 1):
        chunk = pairs[s:s+1000]
        print(f"  batch {n}/{batches} ({len(chunk):,} files): submitting", flush=True)
        t0 = time.time()
        launch = api(dbx.files_move_batch_v2,
                     [RelocationPath(from_path=a, to_path=b) for a,b in chunk], autorename=True)
        if launch.is_async_job_id():
            job = launch.get_async_job_id()
            while True:
                time.sleep(3)
                st = api(dbx.files_move_batch_check_v2, job)
                if st.is_complete(): results = st.get_complete().entries; break
                if not st.is_in_progress(): sys.exit(f"Unexpected state: {st}")
                print(f"\r  batch {n}/{batches}: waiting {int(time.time()-t0)}s", end="", flush=True)
            print(f"\r  batch {n}/{batches}: done in {int(time.time()-t0)}s" + " "*14, flush=True)
        else:
            results = launch.get_complete().entries
        for (src,dst), r in zip(chunk, results):
            if r.is_success():
                o = r.get_success(); md = getattr(o, "metadata", o)
                landed = getattr(md, "path_display", None) or dst
                row = by_src.get(src if mark == "yes" else dst)
                if row is not None:
                    if mark == "yes": row["target"] = landed; row["moved"] = "yes"
                    else: row["moved"] = ""
            else:
                failed.append((src, str(r.get_failure())))
            done += 1
        save(rows)                      # checkpoint after every batch
        el = int(time.time()-t_all)
        print(f"  {label}: {done:,}/{len(pairs):,} ({100*done//len(pairs)}%), "
              f"{el//60}m{el%60:02d}s elapsed, progress saved", flush=True)
    if failed:
        with open("sort_failures.csv","w",newline="") as fh:
            csv.writer(fh).writerows([("path","error"), *failed])
        print(f"{len(failed):,} moves failed. See sort_failures.csv")
    return done - len(failed)

rows = list(csv.DictReader(open(CSV)))
for r in rows: r.setdefault("moved", "")
dbx = connect()

if "--undo" in sys.argv:
    pairs = [(r["target"], r["path"]) for r in rows if r.get("moved")=="yes" and r.get("target")]
    if not pairs: sys.exit("Nothing recorded as moved.")
    print(f"Restoring {len(pairs):,} files")
    run(dbx, rows, pairs, "restoring", "")
    sys.exit(0)

todo = [r for r in rows if r.get("target") and r.get("moved") != "yes"
        and r["target"] != r["path"]]
already = sum(1 for r in rows if r.get("moved") == "yes")
if not todo:
    sys.exit(f"Nothing left to move. {already:,} already done.")
size = sum(int(r["size_bytes"] or 0) for r in todo)
print(f"\n{len(todo):,} files to move, {human(size)}"
      + (f"  ({already:,} already done in an earlier run)" if already else ""))
if "--yes" not in sys.argv:
    if input("Type yes to go: ").strip().lower() != "yes":
        sys.exit("Stopped.")
n = run(dbx, rows, [(r["path"], r["target"]) for r in todo], "moving", "yes")
print(f"\nMoved {n:,} files. Undo with: python3 {os.path.basename(sys.argv[0])} --undo")
