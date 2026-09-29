#!/usr/bin/env bash
#
# read-capture-dates.sh - sort photos into date folders using their EXIF capture date
#
#   ./read-capture-dates.sh scan "/Photos/camera imports"
#   ./read-capture-dates.sh apply "/Photos/camera imports"
#   ./read-capture-dates.sh undo
#
# Reads only the first 64KB of each file over an HTTP Range request, so a 73GB
# folder costs about 1.5GB of transfer instead of downloading everything.
#
# scan writes photo-dates.csv and prints a year-by-year count. It changes nothing.
# apply moves each file to <folder>/YYYY/YYYY-MM/<name> (--by-year for just YYYY).
# Files with no usable date go to <folder>/_undated/ and are listed separately.
#
# Uses the same token as dropbox-cleanup.sh (~/.config/dropbox-cleanup/token).

set -euo pipefail

CACHE="${HOME}/.cache/dropbox-cleanup"
CONF="${HOME}/.config/dropbox-cleanup"
VENV="${CACHE}/venv"
PYFILE="${CACHE}/photo_sort.py"
TOKEN_FILE="${CONF}/token"
CSV="${PHOTO_CSV:-photo-dates.csv}"

die()  { printf '%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
usage() { awk 'NR<3 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0; }

write_python() {
  mkdir -p "$CACHE"
  cat > "$PYFILE" <<'PYEOF'
#!/usr/bin/env python3
"""Sort Dropbox photos into date folders by EXIF capture date."""
import argparse
import csv
import io
import json
import os
import re
import sys
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

import dropbox
import exifread
import requests
from dropbox.files import FileMetadata, RelocationPath

HEAD_BYTES = 65536          # enough for EXIF even behind a large thumbnail
DOWNLOAD_URL = "https://content.dropboxapi.com/2/files/download"
UNDATED = "_undated"

IMAGE_EXT = {".jpg", ".jpeg", ".jpe", ".tif", ".tiff", ".heic", ".heif",
             ".png", ".dng", ".nef", ".cr2", ".arw", ".orf", ".raf", ".rw2"}
# Files we never move: not photos, or already-sorted destinations.
SKIP_EXT = {".ini", ".db", ".ds_store", ".url", ".lnk", ".thm"}

# Dates hiding in filenames: 20080614_1230, 2008-06-14, IMG_20080614, PXL_20080614
FNAME_DATE = re.compile(r"(?<!\d)(19[89]\d|20[0-3]\d)[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)")

_print_lock = threading.Lock()


def human(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:,.1f} {u}"
        n /= 1024


def api(fn, *a, **kw):
    for attempt in range(6):
        try:
            return fn(*a, **kw)
        except dropbox.exceptions.RateLimitError as e:
            wait = getattr(e.error, "retry_after", None) or 2 ** attempt
            time.sleep(wait)
    sys.exit("Dropbox kept rate limiting. Try again later.")


def list_files(dbx, root):
    out = []
    res = api(dbx.files_list_folder, root, recursive=True,
              include_mounted_folders=False, limit=2000)
    while True:
        for e in res.entries:
            if isinstance(e, FileMetadata) and e.size > 0:
                out.append(e)
        print(f"\r  listed {len(out):,} files", end="", file=sys.stderr, flush=True)
        if not res.has_more:
            break
        res = api(dbx.files_list_folder_continue, res.cursor)
    print(file=sys.stderr)
    return out


def fetch_head(session, token, file_id, nbytes=HEAD_BYTES, why=None):
    """First nbytes of a file, via a Range request.

    Returns bytes, or None. When None and `why` is a dict, it records the
    HTTP status and body so the caller can explain the failure instead of
    silently falling back to a worse date.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Dropbox-API-Arg": json.dumps({"path": file_id}),
        "Range": f"bytes=0-{nbytes - 1}",
    }
    for attempt in range(5):
        try:
            r = session.post(DOWNLOAD_URL, headers=headers, timeout=60)
        except requests.RequestException as e:
            if attempt == 4 and why is not None:
                why.update(status="network", body=str(e)[:300])
            time.sleep(2 ** attempt)
            continue
        if r.status_code in (200, 206):
            return r.content
        if r.status_code == 429:
            time.sleep(int(r.headers.get("Retry-After", 2 ** attempt)))
            continue
        if r.status_code >= 500:
            time.sleep(2 ** attempt)
            continue
        if why is not None:                      # 401/403/409: permanent
            why.update(status=r.status_code, body=r.text[:300])
        return None
    return None


def probe(session, token, files):
    """Read one image header before doing 25,000 of them.

    A missing files.content.read scope makes every fetch fail, and without
    this check the run would quietly date everything from file timestamps.
    """
    sample = next((f for f in files
                   if os.path.splitext(f.name)[1].lower() in IMAGE_EXT), None)
    if sample is None:
        return
    why = {}
    blob = fetch_head(session, token, f"id:{sample.id.split(':', 1)[1]}", why=why)
    if blob:
        return
    status, body = why.get("status"), why.get("body", "")
    if "missing_scope" in body or status in (401, 403):
        sys.exit(
            f"Cannot read file contents (HTTP {status}).\n\n"
            f"Dropbox said: {body.strip()[:200]}\n\n"
            "This token lacks the 'files.content.read' scope, which is needed to\n"
            "read EXIF. Without it every photo would be dated from its file\n"
            "timestamp, which for this folder is the 2011 import date, not when\n"
            "the photo was taken.\n\n"
            "Fix: app console > Permissions > tick files.content.read > Submit,\n"
            "then Settings > OAuth 2 > Generate a new token, and run:\n"
            "  dropbox-cleanup.sh token"
        )
    sys.exit(
        f"Could not read a file header (status {status}).\n"
        f"Dropbox said: {body.strip()[:300]}\n"
        "Stopping rather than dating everything from file timestamps."
    )


def exif_date(blob):
    """(YYYY, MM, tag) from EXIF, or None."""
    try:
        tags = exifread.process_file(io.BytesIO(blob), details=False)
    except Exception:
        return None
    for key in ("EXIF DateTimeOriginal", "EXIF DateTimeDigitized", "Image DateTime"):
        raw = tags.get(key)
        if not raw:
            continue
        m = re.match(r"\s*(\d{4})[:\-](\d{2})[:\-](\d{2})", str(raw))
        if not m:
            continue
        y, mo = int(m.group(1)), int(m.group(2))
        if 1990 <= y <= 2035 and 1 <= mo <= 12:
            return y, mo, key.replace("EXIF ", "exif:").replace("Image ", "exif:")
    return None


def filename_date(name):
    m = FNAME_DATE.search(name)
    if m:
        return int(m.group(1)), int(m.group(2)), "filename"
    return None


def resolve(meta, blob):
    """Best available capture date. Returns (year, month, source)."""
    ext = os.path.splitext(meta.name)[1].lower()
    if blob and ext in IMAGE_EXT:
        got = exif_date(blob)
        if got:
            return got
    got = filename_date(meta.name)
    if got:
        return got
    cm = meta.client_modified
    if cm and 1990 <= cm.year <= 2035:
        return cm.year, cm.month, "file-date"    # least trustworthy
    return None


def target_for(root, meta, dated, by_year):
    if not dated:
        return f"{root}/{UNDATED}/{meta.name}"
    y, mo, _ = dated
    sub = f"{y:04d}" if by_year else f"{y:04d}/{y:04d}-{mo:02d}"
    return f"{root}/{sub}/{meta.name}"


def already_sorted(root, path_lower):
    """True if the file already sits in a YYYY or YYYY/YYYY-MM folder we made."""
    rel = path_lower[len(root.lower()):].strip("/")
    first = rel.split("/")[0] if "/" in rel else ""
    return bool(re.fullmatch(r"(19[89]\d|20[0-3]\d)", first)) or first == UNDATED


def run_moves(dbx, pairs, label):
    landed, failed, done = {}, [], 0
    batches = (len(pairs) + 999) // 1000
    for n, start in enumerate(range(0, len(pairs), 1000), start=1):
        chunk = pairs[start:start + 1000]
        print(f"  batch {n}/{batches} ({len(chunk):,} files): submitting", flush=True)
        entries = [RelocationPath(from_path=a, to_path=b) for a, b in chunk]
        t0 = time.time()
        launch = api(dbx.files_move_batch_v2, entries, autorename=True)
        if launch.is_async_job_id():
            job = launch.get_async_job_id()
            while True:
                time.sleep(2)
                st = api(dbx.files_move_batch_check_v2, job)
                if st.is_complete():
                    results = st.get_complete().entries
                    break
                if not st.is_in_progress():
                    sys.exit(f"Move stopped unexpectedly: {st}")
                print(f"\r  batch {n}/{batches}: waiting {int(time.time()-t0)}s",
                      end="", flush=True)
            print(f"\r  batch {n}/{batches}: done in {int(time.time()-t0)}s" + " " * 10,
                  flush=True)
        else:
            results = launch.get_complete().entries
        for (src, dst), r in zip(chunk, results):
            if r.is_success():
                s = r.get_success()
                md = getattr(s, "metadata", s)
                landed[src] = getattr(md, "path_display", None) or dst
            else:
                failed.append((src, str(r.get_failure())))
            done += 1
        print(f"  {label}: {done:,} of {len(pairs):,}", flush=True)
    if failed:
        with open("photo_move_failures.csv", "w", newline="") as fh:
            csv.writer(fh).writerows([("path", "error"), *failed])
        print(f"{len(failed):,} moves failed. See photo_move_failures.csv")
    return landed


def connect(token):
    dbx = dropbox.Dropbox(token, timeout=300)
    try:
        who = dbx.users_get_current_account()
    except dropbox.exceptions.AuthError:
        sys.exit("Dropbox rejected the token. Run: dropbox-cleanup.sh token")
    print(f"Signed in as {who.name.display_name}")
    return dbx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--path", required=True)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--undo", metavar="CSV")
    ap.add_argument("--csv", default="photo-dates.csv")
    ap.add_argument("--by-year", action="store_true", help="YYYY/ instead of YYYY/YYYY-MM/")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="move even when most dates are guesses, not EXIF")
    args = ap.parse_args()

    token = os.environ["DROPBOX_TOKEN"]
    dbx = connect(token)
    root = args.path.rstrip("/")

    if args.undo:
        with open(args.undo, newline="") as fh:
            pairs = [(r["target"], r["path"]) for r in csv.DictReader(fh)
                     if r.get("moved") == "yes" and r["target"]]
        if not pairs:
            sys.exit("Nothing recorded as moved in that CSV.")
        print(f"Restoring {len(pairs):,} files")
        run_moves(dbx, pairs, "restoring")
        return

    print(f"Listing {root}")
    files = list_files(dbx, root)
    todo = [f for f in files
            if os.path.splitext(f.name)[1].lower() not in SKIP_EXT
            and not already_sorted(root, f.path_lower)]
    skipped = len(files) - len(todo)
    print(f"{len(todo):,} files to date"
          + (f" ({skipped:,} already sorted or not photos)" if skipped else ""))

    # Read EXIF headers in parallel.
    session = requests.Session()
    probe(session, token, todo)          # fail loudly now, not silently later
    results, counter = {}, Counter()
    done = [0]
    t0 = time.time()

    def work(meta):
        ext = os.path.splitext(meta.name)[1].lower()
        blob = fetch_head(session, token, f"id:{meta.id.split(':',1)[1]}") \
            if ext in IMAGE_EXT else None
        dated = resolve(meta, blob)
        results[meta.path_display] = (meta, dated)
        counter[dated[2] if dated else "none"] += 1
        with _print_lock:
            done[0] += 1
            if done[0] % 100 == 0 or done[0] == len(todo):
                rate = done[0] / max(time.time() - t0, 1)
                eta = (len(todo) - done[0]) / max(rate, 0.1)
                print(f"\r  read {done[0]:,}/{len(todo):,}  "
                      f"{rate:.0f}/s  eta {int(eta//60)}m{int(eta%60):02d}s",
                      end="", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        list(pool.map(work, todo))
    print()

    # Plan and report.
    rows, by_year = [], defaultdict(int)
    for path, (meta, dated) in sorted(results.items()):
        tgt = target_for(root, meta, dated, args.by_year)
        y = f"{dated[0]:04d}" if dated else UNDATED
        by_year[y] += 1
        rows.append({"path": path, "size_bytes": meta.size,
                     "year": dated[0] if dated else "", "month": dated[1] if dated else "",
                     "date_source": dated[2] if dated else "none",
                     "target": tgt if tgt != path else "", "moved": ""})

    with open(args.csv, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["path", "size_bytes", "year", "month",
                                           "date_source", "target", "moved"])
        w.writeheader()
        w.writerows(rows)

    print("\nPhotos by year:")
    for y in sorted(by_year):
        bar = "#" * min(40, by_year[y] * 40 // max(by_year.values()))
        print(f"  {y:>9}  {by_year[y]:>6,}  {bar}")
    print("\nWhere the dates came from:")
    for src, n in counter.most_common():
        label = {"none": "no date found", "file-date": "file timestamp (least reliable)",
                 "filename": "filename"}.get(src, src)
        print(f"  {n:>6,}  {label}")
    print(f"\nFull list: {args.csv}")

    # How many of the actual images got a real EXIF date? If that share is low,
    # most "dates" are file timestamps, which for an imported dump are import
    # dates rather than capture dates. Refuse to move on that basis.
    images = sum(1 for m, _ in results.values()
                 if os.path.splitext(m.name)[1].lower() in IMAGE_EXT)
    from_exif = sum(n for src, n in counter.items() if src.startswith("exif:"))
    share = from_exif / images if images else 1.0
    if images >= 50 and share < 0.5:
        print(f"\nWARNING: only {from_exif:,} of {images:,} images ({share:.0%}) "
              f"have a real EXIF date.")
        print("The rest fall back to the file timestamp, which on an imported")
        print("dump is the import date, not when the photo was taken. Sorting on")
        print("that would file old photos under the year they were copied.")

    moves = [(r["path"], r["target"]) for r in rows if r["target"]]
    if not args.apply:
        print(f"\nDry run. {len(moves):,} files would move. Nothing changed.")
        return
    if images >= 50 and share < 0.5 and not args.force:
        sys.exit("\nRefusing to move files on mostly-guessed dates. "
                 "Fix the EXIF reads first, or pass --force if you really mean it.")
    if not moves:
        print("\nNothing to move.")
        return
    if not args.yes:
        if input(f"\nMove {len(moves):,} files into date folders? Type yes: ").strip().lower() != "yes":
            print("Stopped.")
            return
    landed = run_moves(dbx, moves, "moving")
    for r in rows:
        if r["target"] and r["path"] in landed:
            r["target"] = landed[r["path"]]
            r["moved"] = "yes"
    with open(args.csv, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["path", "size_bytes", "year", "month",
                                           "date_source", "target", "moved"])
        w.writeheader()
        w.writerows(rows)
    print(f"\nMoved {len(landed):,} files.")


if __name__ == "__main__":
    main()
PYEOF
}

setup_venv() {
  if [ -x "${VENV}/bin/python" ] \
     && "${VENV}/bin/python" -c 'import dropbox, exifread, requests' 2>/dev/null; then
    return
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 not found."
  [ -x "${VENV}/bin/python" ] || python3 -m venv "$VENV" \
    || die "Could not create a venv."
  note "Installing EXIF support (one time)"
  "${VENV}/bin/pip" install --quiet dropbox exifread requests \
    || die "Could not install dependencies."
}

load_token() {
  [ -n "${DROPBOX_TOKEN:-}" ] && return
  [ -r "$TOKEN_FILE" ] || die "No token found. Run: ./dropbox-cleanup.sh token"
  DROPBOX_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  [ -n "$DROPBOX_TOKEN" ] || die "${TOKEN_FILE} is empty. Run: ./dropbox-cleanup.sh token"
  export DROPBOX_TOKEN
}

cmd="${1:-}"
[ $# -gt 0 ] && shift || true
case "$cmd" in
  -h|--help|help|"") usage ;;
  scan|apply|undo) ;;
  *) die "Unknown command: ${cmd}. Try: $0 help" ;;
esac

write_python
setup_venv
load_token

case "$cmd" in
  scan)
    [ $# -gt 0 ] || die "Which folder? e.g. $0 scan \"/Photos/camera imports\""
    "${VENV}/bin/python" "$PYFILE" --path "$1" --csv "$CSV" "${@:2}"
    note ""
    note "Look over ${CSV}, then:  $0 apply \"$1\""
    ;;
  apply)
    [ $# -gt 0 ] || die "Which folder? e.g. $0 apply \"/Photos/camera imports\""
    "${VENV}/bin/python" "$PYFILE" --path "$1" --csv "$CSV" --apply "${@:2}"
    note ""
    note "Changed your mind?  $0 undo"
    ;;
  undo)
    csv_in="${1:-$CSV}"
    [ -r "$csv_in" ] || die "Can't read ${csv_in}."
    "${VENV}/bin/python" "$PYFILE" --path / --undo "$csv_in"
    ;;
esac
