# Case study: 120 GB of Dropbox, twenty years deep

What these scripts were built for, in the order it happened, including the parts
that went wrong. Personal details are left out; the numbers are real.

Two phases: consolidating a Dropbox account and a macOS Photos library into
Google Photos, then crawling an old Windows PC for the photos that had never
reached any cloud at all.

## The starting state

A Dropbox account at roughly 120 GB, most of it one folder: an unsorted dump off
an old Windows machine, about 22,000 files and 85 GB, spanning 1994 to 2022. The
same photos also existed, partially, in a macOS Photos library on the desktop
(26,655 items, 123 GB) and, partially, in Google Photos, which had been fed by a
phone for years and by some manual uploads long ago.

Nobody knew what was where. The goal was one library, in Google Photos, with
correct dates, and the duplicates gone.

## Results

| Step | Files | Space freed |
| --- | --- | --- |
| Exact duplicates removed | 4,991 | 15.9 GB |
| Near duplicates removed | 3,281 | 5.0 GB |
| Source backup folder deleted after upload | ~22,000 | 85 GB |

Non-space results mattered more:

- **23,489** real capture dates recovered from EXIF
- **21,897** files re-sorted into `YYYY/YYYY-MM` by capture date
- **~6,800** of those rescued from a fake 2011 bucket that import timestamps had
  created
- **328** duplicate groups merged in the macOS Photos library
- **15,092** files (46 GB) identified as existing in the Dropbox dump and nowhere
  in the Photos library, which was the finding that justified the whole exercise
- **~10,000** photos uploaded to Google Photos with correct dates

Dropbox ended at about 18 GB.

## What the diff found

The point of inventorying both libraries was to answer one question: can the
Dropbox dump be deleted? Comparing 25,178 Dropbox files against a CSV inventory
of the Photos library showed 15,092 files with no match by filename or by date.

A single spot check settled it. One 2002 photo from the dump, pulled up next to
the same month in Google Photos: same camera, same settings, same era, and the
photo itself simply was not there. The dump was not redundant, and deleting it
before uploading would have lost about 46 GB of photos permanently.

## Ten bugs worth remembering

| What broke | Why | Fix |
| --- | --- | --- |
| Batch move crashed partway through a 4,991-file run | `files_move_batch_v2` success entries are a `FileMetadata` directly, not wrapped in `.metadata`. The code had been tested against mocks, not real SDK objects. | `md = getattr(s, "metadata", s)` |
| `status.is_failed()` raised AttributeError | The v2 job-status union has only `in_progress` and `complete`. There is no failed variant. | Treat anything that is neither as the error case |
| Pasting the access token into Terminal failed, audibly | macOS canonical terminal input caps a line near 1,024 bytes. The token was 1,352. | Read it from `pbpaste` rather than stdin |
| EXIF scan produced a confident, plausible, completely wrong year histogram | The `files.content.read` scope was missing, every ranged read failed, and the script silently fell back to file timestamps | A preflight that fails loudly, plus refusing to apply a sort under 50% EXIF coverage |
| 32 unrelated files landed in one duplicate group | The grouping key computed the file extension and then never used it, so a pile of 1990s clipart templates with different extensions collapsed together | Add normalized extension to the key and restrict to image extensions |
| 1,000 of 21,897 moves failed with `from_lookup` | An earlier run's async job completed *after* the scan had already listed those files at their old paths | Nothing. All 1,000 verified already at the target |
| Unattended runner refused to start | `df -g` is a BSD flag and invalid on GNU | Read the Avail column from `df -Pk`, which both agree on |
| Summary loop would crash on a run where nothing downloaded | macOS ships bash 3.2, which errors on an empty array expansion under `set -u` | Use a plain string instead of an array |
| Two files silently skipped when writing dates | `cut -d, -f1` truncates a quoted CSV path at the first comma, and two filenames contained commas | Extract the column with a real CSV parser |
| Snapshot cleanup loop silently did nothing | A `grep -o '[0-9-]\{19\}'` pattern looking for 19 characters; the timestamps are 17 | Strip the prefix and suffix with `sed` instead of counting characters |

The pattern across most of these: **the failure mode that costs you is not a
crash, it is plausible output.** A missing scope, an unused variable in a hash
key, a truncated path. Each produced a result that looked entirely reasonable.
Three of the ten were only caught because a number looked slightly off, not
because anything errored.

## Two things that were not bugs

**Deleting 41 GB of local files freed 1 GB.** APFS keeps Time Machine local
snapshots that pin deleted blocks until they age out, usually within 24 hours.
`tmutil listlocalsnapshots /` shows them. Either wait, or clear them:

```bash
tmutil listlocalsnapshots / | sed -n 's/^com\.apple\.TimeMachine\.\(.*\)\.local$/\1/p' \
  | while read -r s; do tmutil deletelocalsnapshots "$s"; done
```

**Uploading 41 GB moved Google Photos storage by 8.8 GB.** Compression on upload
plus dedupe against files already present. Storage delta is not a usable
verification signal.

## The mistake worth naming

Partway through, the destination showed a batch of Christmas photos filed under
February 2002. The obvious read was that the destination had bad dates.

It did not. The film was shot in December, dropped at a one-hour photo counter,
and developed in February, and the lab's scanner wrote February into the EXIF.
Both systems agreed, and they were both faithfully reporting what the file said.
The date was wrong at the scanner in 2002 and has been wrong ever since.

Worth remembering before you "fix" a date that looks wrong: for anything
pre-digital, the file is telling you when it was *scanned*, and that is the only
date that exists.

## Phase two: the island on the old Windows machine

With the cloud side finished, one question remained: was anything still only on
a local machine? The candidate was an old Windows PC that had been restored from
USB backup drives two or three times across fifteen years. Each restore carried
forward whatever the last one held, and nothing ever pushed any of it to a cloud
service. Photos on a machine like that are genuinely single-copy.

A read-only crawl of the whole drive found 2,889 photo and video files, 24.6 GB,
under a 40 KB floor to keep icons and web thumbnails out. Copying them into one
folder with SHA256 dedupe produced:

| | |
| --- | --- |
| Copied, unique | 2,785 |
| Exact duplicates, skipped | 100 |
| Unreadable | 4 (Windows account avatars) |

2,785 + 100 + 4 = 2,889, which is the only arithmetic that matters after a job
like this.

**Most of it was not new.** Eighteen of the twenty largest folders sat under a
synced Dropbox folder, so they were already safe and already deduped. The find
was one folder: 215 video files, 10.2 GB, in a `Videos\old videos` directory that
had never been anywhere but this machine and the USB drives before it.

Grouping the output by original source folder (read back from the manifest)
turned up 119 distinct source folders, and made clear how much of a whole-drive
crawl is not photographs: web-export thumbnails from a site builder, images
extracted from Keynote decks, scanned expense receipts, purchase orders, org
charts, game screenshots. 1,410 of the 2,785 files were that. What was left,
1,376 files in 15 folders, was the actual family archive.

On dates: 648 of 2,513 stills had no EXIF capture date. Rather than reach for
exiftool, a one-line histogram of file timestamps settled it — they spread
plausibly across 2008 to 2024, with three files in the current year. Timestamps
that plausible are a usable fallback, so no stamping was needed at all. Worth
checking before assuming the worst.

## Nine more bugs, from the Windows half

| What broke | Why | Fix |
| --- | --- | --- |
| Unreadable files printed a wall of red and were counted as nothing | `Get-FileHash` writes a **non-terminating** error that a plain `try/catch` does not catch, so the failure count stayed at zero while files silently went missing | `-ErrorAction Stop` plus a null check on the result, and write every failed path to a file |
| The job wedged and sat at the same file for minutes | `Get-FileHash` has no timeout. A file that never returns blocks the loop forever, and the progress line only prints every 25 files so it looks alive | Kill it and resume from the manifest. Sample the destination's size twice 30 seconds apart to tell wedged from merely slow |
| 1,068 files suddenly became unreadable mid-run | Pausing the cloud sync client, to stop it locking files, instead made every file it manages unreadable | Do not pause the sync engine. Let it finish and retry the locked files |
| An overnight run stopped at 57% | Windows went to sleep | `powercfg /change standby-timeout-ac 0` before any long job |
| `cd Desktop` landed in an almost empty folder | The Desktop was redirected into OneDrive, so the real one is `%USERPROFILE%\OneDrive\Desktop` and `%USERPROFILE%\Desktop` is a leftover | Locate the file rather than assuming the path |
| The default output folder would have uploaded 24 GB to Microsoft | The default destination was the Desktop, which was inside OneDrive | Always pass an explicit `-Dest` outside any synced folder |
| A usage hint printed as three separate arguments | `Write-Host 'text' + $var + 'more'` does not concatenate in PowerShell; it passes positional arguments | Use the format operator: `('...{0}...' -f $var)` |
| A one-folder batch reported the wrong count | A single-element PowerShell array slice comes back as a scalar | Wrap the slice in `@( )` |
| Scripts refused to run in a new window | `Set-ExecutionPolicy -Scope Process` dies with the window it was set in | Prepend it to the command, or set `-Scope CurrentUser` once |

The through-line from the first half held here too, and harder: **the expensive
failure is not a crash, it is plausible output.** The 1,068 silent failures were
caught only because failure logging had been added an hour earlier. Without it
the run would have reported success, the folder would have looked full, and a
thousand photos would have quietly not been there.

## Sequence that worked

1. Dedupe by content hash. Free, and it shrinks everything downstream.
2. Dedupe near-copies, with a visual check before committing.
3. Read real EXIF dates. Verify coverage before trusting them.
4. Sort by capture date.
5. Inventory the other libraries and diff, to find what is genuinely unique.
6. Download a year at a time.
7. Stamp missing dates. **Before** uploading.
8. Upload, verify specific months by hand, then delete.

And once the cloud side is done, the last question is whether anything survives
only on a local machine. Old PCs restored from USB backup drives are where that
material hides, because nothing about that lineage ever involved a network.

Step 7 before step 8 is the one that cannot be reordered. Doing it backwards
means re-uploading and then hunting down the undated copies, which is what
`restamp-and-gather.sh` exists to clean up after.
