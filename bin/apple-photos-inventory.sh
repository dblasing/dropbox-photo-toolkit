#!/usr/bin/env bash
#
# apple-photos-inventory.sh - list everything in your Mac Photos library as a CSV
#
#   ./apple-photos-inventory.sh                      use the default library
#   ./apple-photos-inventory.sh --list               show the libraries it can find
#   ./apple-photos-inventory.sh /path/to/My.photoslibrary
#
# Reads a COPY of the library's index, so Photos is never touched or locked.
# Photos.app can stay open. Nothing in your library is modified.
#
# Writes photos-library.csv: one row per photo or video, with original filename,
# capture date, file size, dimensions, albums, and favourite/hidden/trashed flags.
# Also prints a year-by-year count so it lines up with photo-dates.csv.
#
# Needs no Python packages. If it reports a permissions error, give Terminal
# Full Disk Access in System Settings > Privacy & Security > Full Disk Access.

set -euo pipefail

OUT="${PHOTOS_CSV:-photos-library.csv}"
die()  { printf '%s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help|help) awk 'NR<3 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 not found."

python3 - "$OUT" "${1:-}" <<'PYEOF'
import csv
import glob
import os
import re
import shutil
import signal
import sqlite3
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone

# Don't blow up when piped into head/less.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

APPLE_EPOCH = 978307200          # 2001-01-01 in unix time
out_csv = sys.argv[1]
arg = sys.argv[2] if len(sys.argv) > 2 else ""


def find_libraries():
    seen, libs = set(), []
    spots = [os.path.expanduser("~/Pictures"), os.path.expanduser("~"),
             "/Users/Shared", os.path.expanduser("~/Volumes")]
    for spot in spots:
        for pat in ("*.photoslibrary", "*/*.photoslibrary"):
            for hit in glob.glob(os.path.join(spot, pat)):
                real = os.path.realpath(hit)
                if real not in seen and os.path.isdir(real):
                    seen.add(real)
                    libs.append(real)
    for vol in glob.glob("/Volumes/*"):
        for hit in glob.glob(os.path.join(vol, "*.photoslibrary")):
            real = os.path.realpath(hit)
            if real not in seen:
                seen.add(real)
                libs.append(real)
    return libs


def db_path(lib):
    for rel in ("database/Photos.sqlite", "database/photos.db", "Database/photos.db"):
        p = os.path.join(lib, rel)
        if os.path.exists(p):
            return p
    return None


def open_copy(src):
    """Copy the db (plus -wal/-shm) somewhere safe and open it read-only."""
    tmp = tempfile.mkdtemp(prefix="photos-inv-")
    dst = os.path.join(tmp, "Photos.sqlite")
    try:
        shutil.copy2(src, dst)
        for ext in ("-wal", "-shm"):
            if os.path.exists(src + ext):
                shutil.copy2(src + ext, dst + ext)
    except PermissionError:
        sys.exit(
            "macOS blocked reading the Photos library.\n"
            "Give Terminal Full Disk Access:\n"
            "  System Settings > Privacy & Security > Full Disk Access > add Terminal\n"
            "Then quit Terminal completely (Cmd-Q) and reopen it."
        )
    con = sqlite3.connect(dst)
    con.row_factory = sqlite3.Row
    return con, tmp


def tables(con):
    return {r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}


def cols(con, table):
    try:
        return {r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
    except sqlite3.Error:
        return set()


def pick(available, *names):
    """First column name that exists, else None."""
    for n in names:
        if n in available:
            return n
    return None


def apple_date(v):
    if v is None:
        return None
    try:
        return datetime.fromtimestamp(float(v) + APPLE_EPOCH, tz=timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None


def album_map(con, tbls):
    """asset Z_PK -> [album titles]. Best effort; schema varies by macOS version."""
    albums = defaultdict(list)
    alb_t = "ZGENERICALBUM" if "ZGENERICALBUM" in tbls else None
    if not alb_t:
        return albums
    joins = [t for t in tbls if re.fullmatch(r"Z_\d+ASSETS", t)]
    titles = {}
    for r in con.execute(f'SELECT Z_PK, ZTITLE FROM "{alb_t}"'):
        if r["ZTITLE"]:
            titles[r["Z_PK"]] = r["ZTITLE"]
    for j in joins:
        c = cols(con, j)
        acol = pick(c, *[x for x in c if x.endswith("ASSETS")])
        bcol = pick(c, *[x for x in c if x.endswith("ALBUMS")])
        if not acol or not bcol:
            continue
        try:
            for r in con.execute(f'SELECT "{acol}" a, "{bcol}" b FROM "{j}"'):
                t = titles.get(r["b"])
                if t:
                    albums[r["a"]].append(t)
        except sqlite3.Error:
            continue
    return albums


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:,.1f} {u}"
        n /= 1024


libs = find_libraries()
if arg == "--list":
    if not libs:
        sys.exit("No .photoslibrary found. Pass its path directly.")
    print("Photos libraries found:")
    for l in libs:
        d = db_path(l)
        size = 0
        try:
            size = sum(os.path.getsize(os.path.join(dp, f))
                       for dp, _, fs in os.walk(l) for f in fs
                       if os.path.exists(os.path.join(dp, f)))
        except OSError:
            pass
        print(f"  {l}\n      index: {'found' if d else 'NOT FOUND'}   size: {human(size)}")
    sys.exit(0)

if arg:
    lib = os.path.realpath(os.path.expanduser(arg))
    if not os.path.isdir(lib):
        sys.exit(f"No such library: {lib}")
elif libs:
    lib = libs[0]
    if len(libs) > 1:
        print(f"Found {len(libs)} libraries; using the first. "
              f"Run with --list to see them all.")
else:
    sys.exit("No Photos library found. Pass its path, or run with --list.")

src = db_path(lib)
if not src:
    sys.exit(f"No photos index inside {lib}")
print(f"Library: {lib}")

con, tmp = open_copy(src)
try:
    tbls = tables(con)
    asset_t = "ZASSET" if "ZASSET" in tbls else ("ZGENERICASSET" if "ZGENERICASSET" in tbls else None)
    if not asset_t:
        sys.exit("Could not find the asset table. This library layout isn't one I know.")
    ac = cols(con, asset_t)
    extra_t = "ZADDITIONALASSETATTRIBUTES" if "ZADDITIONALASSETATTRIBUTES" in tbls else None
    ec = cols(con, extra_t) if extra_t else set()

    c_pk   = "Z_PK"
    c_uuid = pick(ac, "ZUUID")
    c_name = pick(ac, "ZFILENAME")
    c_dir  = pick(ac, "ZDIRECTORY")
    c_date = pick(ac, "ZDATECREATED")
    c_add  = pick(ac, "ZADDEDDATE")
    c_w    = pick(ac, "ZWIDTH")
    c_h    = pick(ac, "ZHEIGHT")
    c_kind = pick(ac, "ZKIND")
    c_fav  = pick(ac, "ZFAVORITE")
    c_hid  = pick(ac, "ZHIDDEN")
    c_tra  = pick(ac, "ZTRASHEDSTATE")
    c_orig = pick(ec, "ZORIGINALFILENAME")
    c_size = pick(ec, "ZORIGINALFILESIZE")

    sel = [f'a."{c_pk}" pk']
    for alias, c in (("uuid", c_uuid), ("name", c_name), ("dir", c_dir),
                     ("date", c_date), ("added", c_add), ("w", c_w), ("h", c_h),
                     ("kind", c_kind), ("fav", c_fav), ("hid", c_hid), ("tra", c_tra)):
        sel.append(f'a."{c}" {alias}' if c else f'NULL {alias}')
    join = ""
    if extra_t and (c_orig or c_size):
        sel.append(f'b."{c_orig}" orig' if c_orig else "NULL orig")
        sel.append(f'b."{c_size}" osize' if c_size else "NULL osize")
        akey = "ZASSET" if "ZASSET" in cols(con, extra_t) else None
        if akey:
            join = f'LEFT JOIN "{extra_t}" b ON b."{akey}" = a."{c_pk}"'
        else:
            sel = [s for s in sel if not s.endswith((" orig", " osize"))]
            sel += ["NULL orig", "NULL osize"]
    else:
        sel += ["NULL orig", "NULL osize"]

    sql = f'SELECT {", ".join(sel)} FROM "{asset_t}" a {join}'
    rows = con.execute(sql).fetchall()
    albums = album_map(con, tbls)
finally:
    con.close()
    shutil.rmtree(tmp, ignore_errors=True)

by_year, kinds, flags = defaultdict(int), Counter(), Counter()
total_bytes = 0
out = []
for r in rows:
    dt = apple_date(r["date"])
    name = r["orig"] or r["name"] or ""
    size = r["osize"] or 0
    total_bytes += size or 0
    kind = "video" if (r["kind"] or 0) == 1 else "photo"
    kinds[kind] += 1
    trashed = bool(r["tra"])
    hidden = bool(r["hid"])
    if trashed: flags["in trash"] += 1
    if hidden:  flags["hidden"] += 1
    if r["fav"]: flags["favourite"] += 1
    y = f"{dt.year:04d}" if dt else "unknown"
    if not trashed:
        by_year[y] += 1
    out.append({
        "filename": name,
        "stored_as": r["name"] or "",
        "capture_date": dt.strftime("%Y-%m-%d %H:%M:%S") if dt else "",
        "year": dt.year if dt else "",
        "month": dt.month if dt else "",
        "size_bytes": size or "",
        "width": r["w"] or "", "height": r["h"] or "",
        "kind": kind,
        "favourite": int(bool(r["fav"])),
        "hidden": int(hidden),
        "trashed": int(trashed),
        "albums": "; ".join(sorted(set(albums.get(r["pk"], [])))),
        "uuid": r["uuid"] or "",
    })

with open(out_csv, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(out[0].keys()) if out else ["filename"])
    w.writeheader()
    w.writerows(out)

print(f"\n{len(out):,} items  ({kinds['photo']:,} photos, {kinds['video']:,} videos)")
if total_bytes:
    print(f"Originals total: {human(total_bytes)}")
print("\nBy year (excluding trash):")
if by_year:
    peak = max(by_year.values())
    for y in sorted(by_year):
        bar = "#" * min(40, by_year[y] * 40 // peak)
        print(f"  {y:>9}  {by_year[y]:>6,}  {bar}")
for label, n in flags.most_common():
    print(f"  {n:,} {label}")
print(f"\nWritten to {out_csv}")
PYEOF
