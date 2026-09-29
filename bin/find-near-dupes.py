#!/usr/bin/env python3
"""Find near-duplicate photos: the same picture at a different resolution or encode,
where the content hash differs so dedupe-exact.py cannot see it.

  python3 find-near-dupes.py

Reads the CSV that read-capture-dates.sh produced (path, size_bytes, year, month) and
writes near-dupes.csv. Override either filename:

  DATES_CSV=my-dates.csv NEAR_CSV=my-groups.csv python3 find-near-dupes.py

Files are grouped on normalized filename stem + extension class + year + month. The
extension has to be in the key: without it, unrelated files that share a stem but not
a format collapse into one bogus group. Images only, and nothing under 10 KB, so
icons and stubs stay out. Nothing is moved; apply-near-dupes.py does that.
"""
import csv, os, re, collections
SUF = re.compile(r"(-\d{1,2}|_\d{1,2}|\s\(\d{1,2}\)|\scopy)$", re.IGNORECASE)
IMG = {".jpg",".jpeg",".jpe",".png",".tif",".tiff",".heic",".heif",".bmp",".gif",
       ".dng",".nef",".cr2",".arw",".orf",".raf",".rw2",".mov",".mp4",".avi",".m4v",".3gp"}
MIN_BYTES = 10_000
DATES_CSV = os.environ.get("DATES_CSV", "photo-dates.csv")
NEAR_CSV  = os.environ.get("NEAR_CSV", "near-dupes.csv")
def norm_ext(e):
    e = e.lower()
    return ".jpg" if e in (".jpeg",".jpe") else (".tif" if e == ".tiff" else e)
def stem(p):
    s, ext = os.path.splitext(os.path.basename(p))
    prev = None
    while prev != s:
        prev = s; s = SUF.sub("", s)
    return s.lower(), norm_ext(ext)
def size(r):
    try: return int(r["size_bytes"] or 0)
    except ValueError: return 0
def human(n):
    for u in ("B","KB","MB","GB","TB"):
        if n < 1024 or u == "TB": return f"{n:,.1f} {u}"
        n /= 1024
allrows = list(csv.DictReader(open(DATES_CSV)))
rows, skipped_type, skipped_small = [], 0, 0
for r in allrows:
    _, ext = stem(r["path"])
    if ext not in IMG: skipped_type += 1; continue
    if size(r) < MIN_BYTES: skipped_small += 1; continue
    rows.append(r)
g = collections.defaultdict(list)
for r in rows:
    s, ext = stem(r["path"])
    g[(s, ext, r["year"], r["month"])].append(r)     # extension now part of the key
dupes = {k: v for k, v in g.items() if len(v) > 1}
extras = sum(len(v) - 1 for v in dupes.values())
waste = sum(sum(sorted((size(x) for x in v), reverse=True)[1:]) for v in dupes.values())
print(f"{len(allrows):,} files in the folder")
print(f"  {skipped_type:,} not images (documents, templates, etc)")
print(f"  {skipped_small:,} under 10 KB (stubs, icons)")
print(f"  {len(rows):,} real images considered\n")
print(f"{len(dupes):,} near-duplicate groups")
print(f"{extras:,} extra copies, {human(waste)} keeping the largest in each\n")
sizes = collections.Counter(len(v) for v in dupes.values())
print("Group sizes:")
for n in sorted(sizes): print(f"  {sizes[n]:>6,} groups of {n}")
print("\nBiggest groups:")
for k, v in sorted(dupes.items(), key=lambda kv: -sum(sorted((size(x) for x in kv[1]), reverse=True)[1:]))[:8]:
    names = ", ".join(sorted(os.path.basename(x["path"]) for x in v))[:78]
    print(f"  {human(sum(sorted((size(x) for x in v), reverse=True)[1:])):>10}  {names}")
with open(NEAR_CSV,"w",newline="") as fh:
    w = csv.writer(fh); w.writerow(["group","action","size_bytes","year","month","path"])
    for i,(k,v) in enumerate(sorted(dupes.items(), key=lambda kv: -sum(sorted((size(x) for x in kv[1]),reverse=True)[1:])),1):
        for j,x in enumerate(sorted(v, key=size, reverse=True)):
            w.writerow([i,"keep" if j==0 else "candidate",x["size_bytes"],x["year"],x["month"],x["path"]])
print(f"\nWritten to {NEAR_CSV}")
