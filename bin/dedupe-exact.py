#!/usr/bin/env python3
"""
dedupe-exact.py

Finds exact duplicate files in your Dropbox using Dropbox's own content hash
(nothing gets downloaded), picks one copy to keep in each group, and moves the
extras into /_dupes_to_delete/<original path> so you can review before deleting.

  Dry run (default):  writes dupes.csv and prints a summary. Moves nothing.
  --apply             moves the extras into /_dupes_to_delete
  --undo dupes.csv    moves everything in that CSV back where it came from

Setup:
  pip3 install dropbox
  export DROPBOX_TOKEN='sl.xxxxx'   # needs files.metadata.read + files.content.write

Shared folders are skipped unless you pass --include-shared, because deleting
inside a shared folder deletes for everyone in it.
"""
import argparse
import csv
import os
import re
import sys
import time
from collections import defaultdict

try:
    import dropbox
    from dropbox.files import FileMetadata, RelocationPath
except ImportError:
    sys.exit("Missing the Dropbox SDK. Run: pip3 install dropbox")

TRASH_ROOT = "/_dupes_to_delete"

# Copies that paths under these prefixes hold lose ties to copies elsewhere.
DEFAULT_DEPRIORITIZE = []

# Name endings that usually mean "this is a copy": -2, _3, (1), " copy", conflicted copy.
# Capped at 2 digits so camera names like DSC_3716 aren't mistaken for copies.
COPY_SUFFIX = re.compile(
    r"(-\d{1,2}|_\d{1,2}|\s\(\d{1,2}\)|\s-?\s?copy(\s\d+)?|\s\(.*conflicted copy.*\))$",
    re.IGNORECASE,
)


def api(fn, *a, **kw):
    """Call a Dropbox API method, waiting out rate limits."""
    for attempt in range(6):
        try:
            return fn(*a, **kw)
        except dropbox.exceptions.RateLimitError as e:
            wait = getattr(e.error, "retry_after", None) or 2 ** attempt
            print(f"\n  rate limited, waiting {wait}s", flush=True)
            time.sleep(wait)
    sys.exit("Still rate limited after several retries. Try again later.")


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:,.1f} {unit}"
        n /= 1024


def looks_like_copy(name):
    stem, _ = os.path.splitext(name)
    return bool(COPY_SUFFIX.search(stem))


def keeper_rank(f, deprioritize):
    """Lower sorts first. The first file in a sorted group is the one we keep."""
    p = f.path_lower
    in_backup = any(p.startswith(d.lower().rstrip("/") + "/") for d in deprioritize)
    return (
        1 if in_backup else 0,
        1 if looks_like_copy(f.name) else 0,
        f.client_modified,           # oldest original wins
        len(f.path_display),         # then the shorter path
        f.path_lower,                # deterministic tiebreak
    )


def list_all(dbx, root, include_shared):
    files = []
    res = api(dbx.files_list_folder, root, recursive=True,
              include_mounted_folders=include_shared, limit=2000)
    while True:
        for e in res.entries:
            if not isinstance(e, FileMetadata):
                continue
            if e.path_lower.startswith(TRASH_ROOT.lower() + "/"):
                continue
            if not e.content_hash or e.size == 0:
                continue  # all empty files share a hash; not worth "deduping"
            files.append(e)
        print(f"\r  listed {len(files):,} files", end="", file=sys.stderr, flush=True)
        if not res.has_more:
            break
        res = api(dbx.files_list_folder_continue, res.cursor)
    print(file=sys.stderr)
    return files


def find_dupes(files, deprioritize):
    groups = defaultdict(list)
    for f in files:
        groups[(f.content_hash, f.size)].append(f)
    out = []
    for i, (_, members) in enumerate(
        sorted(((k, v) for k, v in groups.items() if len(v) > 1),
               key=lambda kv: -kv[0][1] * (len(kv[1]) - 1)),
        start=1,
    ):
        members.sort(key=lambda f: keeper_rank(f, deprioritize))
        out.append((i, members[0], members[1:]))
    return out


def write_csv(path, dupes, landed=None):
    """landed maps original path -> where the file actually ended up, after a move.
    Before any move it is None and the column shows the planned destination."""
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["group", "action", "size_bytes", "client_modified", "path", "moved_to"])
        for gid, keep, extras in dupes:
            w.writerow([gid, "keep", keep.size, keep.client_modified.isoformat(), keep.path_display, ""])
            for e in extras:
                dest = TRASH_ROOT + e.path_display if landed is None else landed.get(e.path_display, "")
                w.writerow([gid, "move", e.size, e.client_modified.isoformat(), e.path_display, dest])


def summarize(dupes, total_files):
    extras = [e for _, _, ex in dupes for e in ex]
    reclaim = sum(e.size for e in extras)
    print(f"\nScanned files:        {total_files:,}")
    print(f"Duplicate groups:     {len(dupes):,}")
    print(f"Extra copies to move: {len(extras):,}")
    print(f"Space reclaimable:    {human(reclaim)}")

    by_folder = defaultdict(int)
    for e in extras:
        parts = e.path_display.strip("/").split("/")[:-1]   # drop the filename
        by_folder["/" + "/".join(parts[:2]) if parts else "/"] += e.size
    if by_folder:
        print("\nWhere the extra copies are (top 10):")
        for folder, size in sorted(by_folder.items(), key=lambda kv: -kv[1])[:10]:
            print(f"  {human(size):>12}  {folder}")


def run_moves(dbx, pairs, label):
    """pairs: list of (from_path, to_path). Moves in batches of 1000.

    Returns {from_path: actual_destination} for the moves that succeeded, so the
    caller can record where each file really landed (autorename can change it).
    """
    landed, failed = {}, []
    done = 0
    for start in range(0, len(pairs), 1000):
        chunk = pairs[start:start + 1000]
        entries = [RelocationPath(from_path=a, to_path=b) for a, b in chunk]
        launch = api(dbx.files_move_batch_v2, entries, autorename=True)
        if launch.is_async_job_id():
            job = launch.get_async_job_id()
            while True:
                time.sleep(2)
                status = api(dbx.files_move_batch_check_v2, job)
                if status.is_complete():
                    results = status.get_complete().entries
                    break
                if not status.is_in_progress():
                    sys.exit(f"Batch move stopped in an unexpected state: {status}")
        else:
            results = launch.get_complete().entries
        for (src, dst), r in zip(chunk, results):
            if r.is_success():
                md = r.get_success().metadata
                landed[src] = getattr(md, "path_display", dst)
            else:
                failed.append((src, str(r.get_failure())))
            done += 1
        print(f"\r  {label}: {done:,} of {len(pairs):,}", end="", flush=True)
    print()
    if failed:
        with open("move_failures.csv", "w", newline="") as fh:
            csv.writer(fh).writerows([("path", "error"), *failed])
        print(f"{len(failed):,} moves failed. Details in move_failures.csv")
    return landed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--path", default="", help="folder to scan (default: whole Dropbox)")
    ap.add_argument("--apply", action="store_true", help="actually move the extra copies")
    ap.add_argument("--undo", metavar="CSV", help="move files listed in this CSV back")
    ap.add_argument("--csv", default="dupes.csv", help="report file (default dupes.csv)")
    ap.add_argument("--include-shared", action="store_true", help="also scan shared folders")
    ap.add_argument("--deprioritize", action="append", default=None,
                    help="path prefix whose copies should lose ties (repeatable)")
    args = ap.parse_args()

    token = os.environ.get("DROPBOX_TOKEN")
    if not token:
        sys.exit("Set DROPBOX_TOKEN first. See the notes at the top of this file.")
    dbx = dropbox.Dropbox(token, timeout=300)
    print(f"Signed in as {dbx.users_get_current_account().name.display_name}")

    if args.undo:
        with open(args.undo, newline="") as fh:
            pairs = [(r["moved_to"], r["path"]) for r in csv.DictReader(fh)
                     if r["action"] == "move" and r["moved_to"]]
        if not pairs:
            sys.exit(f"No moved files listed in {args.undo}. Nothing to undo.")
        print(f"Restoring {len(pairs):,} files to their original paths")
        run_moves(dbx, pairs, "restoring")
        return

    deprioritize = args.deprioritize or DEFAULT_DEPRIORITIZE
    print(f"Scanning {args.path or '/'} (shared folders {'included' if args.include_shared else 'skipped'})")
    files = list_all(dbx, args.path, args.include_shared)
    dupes = find_dupes(files, deprioritize)
    write_csv(args.csv, dupes)
    summarize(dupes, len(files))
    print(f"\nFull list: {args.csv}")

    if not args.apply:
        print("Dry run. Nothing moved. Look over the CSV, then rerun with --apply.")
        return

    pairs = [(e.path_display, TRASH_ROOT + e.path_display) for _, _, ex in dupes for e in ex]
    if not pairs:
        return
    reply = input(f"\nMove {len(pairs):,} files into {TRASH_ROOT}? Type yes: ")
    if reply.strip().lower() != "yes":
        print("Stopped. Nothing moved.")
        return
    landed = run_moves(dbx, pairs, "moving")
    write_csv(args.csv, dupes, landed)   # record where each file really went
    print(f"\nDone. Review {TRASH_ROOT} on dropbox.com, then delete that folder when you're satisfied.")
    print(f"Changed your mind? python3 dedupe-exact.py --undo {args.csv}")


if __name__ == "__main__":
    main()
