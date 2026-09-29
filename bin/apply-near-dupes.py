import csv, os, sys, time, collections
import dropbox
from dropbox.files import RelocationPath

TRASH = "/_near_dupes_review"
CSV = "near-dupes.csv"
TOKEN = open(os.path.expanduser("~/.config/dropbox-cleanup/token")).read().strip()

def human(n):
    for u in ("B","KB","MB","GB","TB"):
        if n < 1024 or u == "TB": return f"{n:,.1f} {u}"
        n /= 1024

def api(fn, *a, **kw):
    for i in range(6):
        try: return fn(*a, **kw)
        except dropbox.exceptions.RateLimitError as e:
            time.sleep(getattr(e.error, "retry_after", None) or 2**i)
    sys.exit("Rate limited repeatedly. Try again later.")

def run_moves(dbx, pairs, label):
    landed, failed, done = {}, [], 0
    batches = (len(pairs) + 999)//1000
    for n, s in enumerate(range(0, len(pairs), 1000), 1):
        chunk = pairs[s:s+1000]
        print(f"  batch {n}/{batches} ({len(chunk):,} files): submitting", flush=True)
        t0 = time.time()
        launch = api(dbx.files_move_batch_v2,
                     [RelocationPath(from_path=a, to_path=b) for a,b in chunk], autorename=True)
        if launch.is_async_job_id():
            job = launch.get_async_job_id()
            while True:
                time.sleep(2)
                st = api(dbx.files_move_batch_check_v2, job)
                if st.is_complete(): results = st.get_complete().entries; break
                if not st.is_in_progress(): sys.exit(f"Unexpected state: {st}")
                print(f"\r  batch {n}/{batches}: waiting {int(time.time()-t0)}s", end="", flush=True)
            print(f"\r  batch {n}/{batches}: done in {int(time.time()-t0)}s" + " "*12, flush=True)
        else:
            results = launch.get_complete().entries
        for (src,dst), r in zip(chunk, results):
            if r.is_success():
                o = r.get_success(); md = getattr(o, "metadata", o)
                landed[src] = getattr(md, "path_display", None) or dst
            else: failed.append((src, str(r.get_failure())))
            done += 1
        print(f"  {label}: {done:,} of {len(pairs):,}", flush=True)
    if failed:
        with open("near_move_failures.csv","w",newline="") as fh:
            csv.writer(fh).writerows([("path","error"), *failed])
        print(f"{len(failed):,} failed. See near_move_failures.csv")
    return landed

dbx = dropbox.Dropbox(TOKEN, timeout=300)
try: who = dbx.users_get_current_account()
except dropbox.exceptions.AuthError: sys.exit("Token rejected. Run: dropbox-auth.sh --refresh")
print(f"Signed in as {who.name.display_name}")

rows = list(csv.DictReader(open(CSV)))

if "--undo" in sys.argv:
    pairs = [(r["moved_to"], r["path"]) for r in rows if r.get("moved")=="yes" and r.get("moved_to")]
    if not pairs: sys.exit("Nothing recorded as moved.")
    print(f"Restoring {len(pairs):,} files")
    run_moves(dbx, pairs, "restoring")
    sys.exit(0)

# safety: every group must retain exactly one keeper
g = collections.defaultdict(list)
for r in rows: g[r["group"]].append(r)
bad = [k for k,v in g.items() if sum(1 for x in v if x["action"]=="keep") != 1]
if bad:
    sys.exit(f"{len(bad)} groups do not have exactly one 'keep' row. Refusing to move anything.")

cands = [r for r in rows if r["action"]=="candidate"]
total = sum(int(r["size_bytes"] or 0) for r in cands)
print(f"\n{len(g):,} groups, {len(cands):,} candidates, {human(total)}")
print(f"Keepers stay put. Candidates move to {TRASH}, mirroring their paths.")
if "--yes" not in sys.argv:
    if input(f"\nMove {len(cands):,} files? Type yes: ").strip().lower() != "yes":
        sys.exit("Stopped. Nothing moved.")
pairs = [(r["path"], TRASH + r["path"]) for r in cands]
landed = run_moves(dbx, pairs, "moving")
for r in rows:
    if r["action"]=="candidate" and r["path"] in landed:
        r["moved_to"] = landed[r["path"]]; r["moved"] = "yes"
    else:
        r.setdefault("moved_to",""); r.setdefault("moved","")
with open(CSV,"w",newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["group","action","size_bytes","year","month","path","moved_to","moved"])
    w.writeheader(); w.writerows(rows)
print(f"\nMoved {len(landed):,} files into {TRASH}")
print(f"Review it on dropbox.com. Undo with:  python3 {sys.argv[0]} --undo")
