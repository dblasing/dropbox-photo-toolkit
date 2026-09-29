# dropbox-photo-toolkit

Command-line tools for untangling a photo library that has been copied between
machines, backup drives and cloud services for twenty years: exact duplicates,
near duplicates, wrong dates, and no reliable way to tell what is already
somewhere else.

Two halves. The `bin/` scripts work on a Dropbox account. The `windows/` scripts
crawl a local Windows machine for the photos that never made it to any cloud,
which is where the genuinely lost material tends to be.

Built to solve one specific mess and kept because the pieces are reusable. See
[CASE-STUDY.md](CASE-STUDY.md) for what it was actually used on and what broke
along the way.

## What it does

Duplicates first, then dates, then the move.

| Script | What it does |
| --- | --- |
| `bin/dropbox-auth.sh` | Dropbox OAuth with a refresh token, so long runs survive the 4-hour access token expiry. Prints the scopes actually granted. |
| `bin/dedupe-exact.py` | Finds byte-identical files using Dropbox's own `content_hash`. Nothing is downloaded. Stages extras into a review folder; fully reversible. |
| `bin/find-near-dupes.py` | Finds the same photo at different resolutions or encodes, where the hash differs. |
| `bin/apply-near-dupes.py` | Stages near-duplicate extras for review, refusing to act on any group without exactly one keeper. |
| `bin/contact-sheet.py` | Builds a local HTML contact sheet from Dropbox thumbnails so you can eyeball a set of proposed duplicates before deleting anything. |
| `bin/read-capture-dates.sh` | Reads real EXIF capture dates over HTTP and sorts files into `YYYY/YYYY-MM`. Downloads 64 KB per file, not the whole file. |
| `bin/apply-sort.py` | Applies a sort plan in resumable batches, checkpointing so a token expiry mid-run costs nothing. |
| `bin/pull-year.py` | Downloads one year folder locally, resumable, setting each file's mtime from Dropbox's `client_modified`. |
| `bin/pull-all.sh` | Runs `pull-year.py` across many years unattended, with disk-space guards and a log. |
| `bin/stamp-dates.py` | Writes `DateTimeOriginal` into images that have none, so the destination files them by date rather than by upload day. |
| `bin/restamp-and-gather.sh` | Repairs photos that were uploaded before they were stamped. |
| `bin/apple-photos-inventory.sh` | Inventories a macOS Photos library to CSV by reading a copy of its index. Photos.app can stay open. |

## Windows: the photos that never left the machine

An old PC that has been restored from USB backup drives two or three times over
fifteen years accumulates photos nothing else has a copy of. They were never in
Dropbox, never on a phone, never uploaded anywhere. Two PowerShell scripts find
them and get them out.

| Script | What it does |
| --- | --- |
| `windows/Collect-Photos.ps1` | Crawls the machine for photos and video, hash-dedupes as it copies them into one folder, and writes a manifest mapping every file back to where it came from. Four modes: `Report` (read-only, the default), `Copy`, `Move`, and `Dates` (how many images lack an EXIF capture date). |
| `windows/Split-ForUpload.ps1` | Breaks that folder into upload-sized batches, grouped by year, by original source folder, or by plain count. A browser drag of several thousand files stalls; 800 is reliable. |

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Collect-Photos.ps1                                     # read-only report
.\Collect-Photos.ps1 -Mode Copy -Dest C:\photos-for-google
.\Collect-Photos.ps1 -Mode Dates -Dest C:\photos-for-google
.\Split-ForUpload.ps1 -Source C:\photos-for-google -By Source
```

Run `Dates` **before** splitting; it only looks at the top level of the folder.

Things they do on purpose:

- **Copy, never move, by default.** A whole-drive crawl finds program assets,
  game textures and browser cache. Moving those breaks software. `Move` exists
  but demands a typed confirmation, and it refuses to delete an original whose
  only copy it cannot verify.
- **Skip the destination and reparse points**, so a re-run cannot ingest its own
  output and a junction loop cannot send it in circles.
- **Preserve modified times.** When an image has no EXIF date, that timestamp is
  what the destination falls back on. Losing it means losing the date.
- **Record every failure with its path**, in `failed.txt`. A file that could not
  be read is useless as a number; you need to know which one.
- **Refuse to write into a cloud-synced folder by accident.** The default
  destination is the Desktop, and on a machine with a redirected Desktop that is
  inside OneDrive. Pass `-Dest` somewhere local or you will upload the whole
  collection to Microsoft as a side effect.

## Why the dates matter

This is the part people discover too late.

Most photo services fall back to the file's timestamp when an image has no EXIF
`DateTimeOriginal`, and if that fails, to the day you uploaded it. A folder
copied between machines has timestamps from the copy, not the photo. Upload it
and twenty years of pictures land under a single day in the destination.

So the order is: read the real dates, write dates into the files that lack them,
*then* upload. `stamp-dates.py` before the drag, never after. `pull-year.py`
exists partly to set the local mtime from Dropbox's `client_modified`, because
that is the only date signal left for a file with no EXIF at all.

Two dates are unrecoverable and worth knowing about:

- **Film scans carry the lab's scan date.** A roll shot in December and
  developed in February is stamped February, by the scanner, and there is no
  trace of the shutter date anywhere in the file. `PICT####.JPG` filenames are
  the Kodak Picture CD tell.
- **A timestamp from the current year means the file was copied, not captured.**
  `stamp-dates.py` refuses to guess in that case rather than writing a date it
  invented.

## Setup

```bash
git clone https://github.com/<you>/dropbox-photo-toolkit
cd dropbox-photo-toolkit
python3 -m venv ~/.cache/dropbox-cleanup/venv
~/.cache/dropbox-cleanup/venv/bin/pip install dropbox requests
brew install exiftool          # only needed for stamp-dates.py
./bin/dropbox-auth.sh
```

Create a Dropbox app at https://www.dropbox.com/developers/apps with these
scopes on the Permissions tab, then click Submit:

- `files.metadata.read`
- `files.content.read` — **required**, even though nothing is fully downloaded.
  Reading EXIF is a ranged read against the download endpoint. Without this
  scope the EXIF scan silently falls back to file timestamps and produces a
  plausible, confidently wrong result.
- `files.content.write` — only for the scripts that move files

Scopes are baked into a token when it is minted, so re-run `dropbox-auth.sh`
after changing them. It prints what Dropbox actually granted and refuses to
finish if `files.content.read` is missing.

## Usage

It runs as a pipeline. Each stage is read-only and writes a CSV; a separate apply
step reads that CSV and moves files, after asking. Nothing is ever deleted, only
moved into a review folder, and every apply has an `--undo`.

```bash
export DROPBOX_PHOTO_ROOT="/Photos/camera imports"

# 1. exact duplicates
python3 bin/dedupe-exact.py                    # read-only, writes dupes.csv
python3 bin/dedupe-exact.py --apply            # asks, then stages extras
python3 bin/dedupe-exact.py --undo dupes.csv   # puts them all back

# 2. near duplicates
./bin/read-capture-dates.sh scan "$DROPBOX_PHOTO_ROOT"   # writes photo-dates.csv
python3 bin/find-near-dupes.py                 # reads it, writes near-dupes.csv
python3 bin/contact-sheet.py 24                # 24 groups as contact-sheet.html
python3 bin/apply-near-dupes.py                # asks, then stages
python3 bin/apply-near-dupes.py --undo

# 3. sort by real capture date
./bin/read-capture-dates.sh apply "$DROPBOX_PHOTO_ROOT"
python3 bin/apply-sort.py                      # resumable, --undo available

# 4. down, dated, and out
DROPBOX_PHOTO_ROOT="$DROPBOX_PHOTO_ROOT" BIG_YEARS="2011 2012" TAIL_YEARS="2013 2014" \
  nohup caffeinate -i ./bin/pull-all.sh >/dev/null 2>&1 &
python3 bin/stamp-dates.py photos-2011         # dry run, writes dates-to-stamp.csv
python3 bin/stamp-dates.py photos-2011 --apply
```

Then upload, verify, and only then delete. Not the other way around.

The stages pass data through fixed filenames (`photo-dates.csv`,
`near-dupes.csv`) so the sequence needs no plumbing. Override them with
`DATES_CSV`, `NEAR_CSV` and `OUT_HTML` if you are running more than one library
through it. Add `--yes` to an apply step to skip its confirmation prompt, which
is what you want inside a script and nowhere else.

## Verification is manual, by necessity

Google removed the read scopes from the Photos Library API in March 2025. There
is no way to inventory a Google Photos library programmatically any more, which
means there is no automated check that an upload landed.

The workaround that actually works: count images per month locally, then check
those months in the destination by hand. Expect the destination to show *more*
than your local count, since other sources feed into it. What matters is that it
never shows fewer.

Storage used is a poor check on its own. Accounts that compress on upload, and
that dedupe against files already present, can absorb 40 GB and report 9 GB.

## Design notes

Every script here follows the same three rules, learned the hard way:

1. **Separate finding from doing, and write the plan to a CSV.** Every stage that
   inspects is read-only; every stage that moves reads a plan you have already
   had the chance to read. It is the only defence against a confidently wrong
   batch operation.
2. **Stage, do not delete.** Moving into a review folder is reversible. The
   `--undo` path is written at the same time as the `--apply` path.
3. **Fail loudly on a missing precondition.** A silent fallback that produces
   plausible output is worse than a crash. `read-capture-dates.sh` preflights
   its scopes and refuses to apply a sort when EXIF coverage is under 50%.

## Requirements

For `bin/`: macOS or Linux, Python 3.9+, the `dropbox` and `requests` packages,
and `exiftool` for date writing. Tested on macOS 26 with bash 3.2, which is why
the shell scripts avoid anything newer.

For `windows/`: Windows PowerShell 5.1 or PowerShell 7, no modules. The `Dates`
mode uses `System.Drawing` and wants Windows PowerShell 5.1 specifically
(`powershell.exe`, not `pwsh`).

## What it cost to build

These scripts were written alongside the job they were doing, over two sessions
with Claude. Posting the meter because people ask what this kind of work
actually costs, and the answer is rarely published.

```
Total cost:            $215.76
Total duration (API):  2h 17m 34s
Total duration (wall): 9h 10m 43s
Total code changes:    2666 lines added, 168 lines removed

Usage by model:
       claude-opus-5:  19.7k input, 550.7k output, 242.6m cache read, 8.1m cache write ($215.73)
    claude-haiku-4-5:  24.1k input, 723 output, 0 cache read, 0 cache write ($0.0277)

Prompt cache (main):   19 requests · 100% of input tokens from cache · no misses
```

Nine hours of wall clock against two and a bit hours of actual API time, because
most of the elapsed time was waiting on file transfers, uploads and an overnight
batch job. The 2,666 lines include the scripts, their tests and the documentation
in this repo.

Worth reading next to [CASE-STUDY.md](CASE-STUDY.md), which lists the nineteen
bugs that got shipped and fixed along the way. The cost bought working scripts
and a cleaned-up library; it did not buy code that was right the first time.

## License

MIT. See [LICENSE](LICENSE).
