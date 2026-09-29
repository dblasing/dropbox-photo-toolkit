#!/usr/bin/env python3
"""Give photos a capture date when they have none, so Google Photos files them by year
instead of dumping them all under the day you uploaded.

  python3 stamp-dates.py <folder>            dry run, writes a plan, changes nothing
  python3 stamp-dates.py <folder> --apply    writes the dates into the files

Only touches files with no DateTimeOriginal. Prefers a date in the filename, falls back
to the file's timestamp, and refuses to guess when the timestamp looks meaningless.
"""
import csv, os, re, subprocess, sys, datetime

ROOT = next((a for a in sys.argv[1:] if not a.startswith("-")), ".")
APPLY = "--apply" in sys.argv
THIS_YEAR = datetime.date.today().year
EXTS = ["jpg","jpeg","jpe","png","tif","tiff","heic","heif","bmp","gif"]
FNAME_DATE = re.compile(r"(?<!\d)(19[89]\d|20[0-3]\d)[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)")

if subprocess.run(["which","exiftool"],capture_output=True).returncode != 0:
    sys.exit("exiftool not found. Install it with:  brew install exiftool")

ext_args = [x for e in EXTS for x in ("-ext", e)]
scan = subprocess.run(["exiftool","-r","-q","-if","not $DateTimeOriginal",
                       "-p","$FilePath\t$FileModifyDate","-d","%Y:%m:%d %H:%M:%S",
                       *ext_args, ROOT], capture_output=True, text=True)
lines = [l for l in scan.stdout.splitlines() if "\t" in l]
if not lines:
    sys.exit("Every image already has a capture date. Nothing to do.")

rows, from_name, from_mtime, skipped = [], 0, 0, []
for line in lines:
    path, mtime = line.split("\t", 1)
    mtime = mtime.strip()
    m = FNAME_DATE.search(os.path.basename(path))
    if m:
        stamp = f"{m.group(1)}:{m.group(2)}:{m.group(3)} 12:00:00"; from_name += 1
    else:
        year = int(mtime[:4]) if mtime[:4].isdigit() else 0
        # a timestamp from this year means the file was copied, not captured: no signal
        if not (1990 <= year < THIS_YEAR):
            skipped.append((path, mtime)); continue
        stamp = mtime; from_mtime += 1
    rows.append({"SourceFile": path, "DateTimeOriginal": stamp, "CreateDate": stamp})

print(f"{len(lines):,} images have no capture date")
print(f"  {from_name:,} take one from the filename")
print(f"  {from_mtime:,} fall back to the file timestamp")
if skipped:
    print(f"  {len(skipped):,} left alone (timestamp is {THIS_YEAR}, so it tells us nothing)")
if rows:
    print("\nSample of what would be written:")
    for r in sorted(rows, key=lambda x: x["DateTimeOriginal"])[:8]:
        print(f"  {r['DateTimeOriginal']}  {os.path.basename(r['SourceFile'])}")
if skipped:
    print("\nLeft undated (these will land under the upload date in Google Photos):")
    for p, t in skipped[:8]:
        print(f"  {os.path.basename(p)}")
    if len(skipped) > 8: print(f"  ... and {len(skipped)-8:,} more, listed in undated.txt")
    with open("undated.txt","w") as fh:
        fh.write("\n".join(p for p,_ in skipped))

if not rows:
    sys.exit("\nNothing can be dated reliably. No changes made.")

with open("dates-to-stamp.csv","w",newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["SourceFile","DateTimeOriginal","CreateDate"])
    w.writeheader(); w.writerows(rows)
print(f"\nPlan written to dates-to-stamp.csv ({len(rows):,} files)")

if not APPLY:
    sys.exit("Dry run. Nothing written. Re-run with --apply when the dates look right.")

with open("stamp-filelist.txt","w") as fh:
    fh.write("\n".join(r["SourceFile"] for r in rows) + "\n")
r = subprocess.run(["exiftool","-@","stamp-filelist.txt","-csv=dates-to-stamp.csv",
                    "-overwrite_original"], capture_output=True, text=True)
for stream in (r.stdout, r.stderr):
    t = stream.strip()
    if t: print(t)
left = subprocess.run(["exiftool","-r","-q","-if","not $DateTimeOriginal","-p","$FilePath",
                       *ext_args, ROOT], capture_output=True, text=True)
n = len([l for l in left.stdout.splitlines() if l.strip()])
print(f"\nDone. {n:,} images still have no capture date"
      + (" (the ones listed in undated.txt)" if n else ""))
