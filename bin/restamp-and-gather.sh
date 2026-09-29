#!/usr/bin/env bash
#
# restamp-and-gather.sh - write capture dates from a stamp plan, then gather those
# files into one flat folder for a small re-upload.
#
# Use this when photos were uploaded BEFORE stamp-dates.py ran, so they landed in
# the destination under the upload date instead of the date they were taken.
#
#   ./restamp-and-gather.sh plan-2011.csv            show what it would do
#   ./restamp-and-gather.sh plan-2011.csv --apply    write the dates, build the folder
#
#   OUT=somewhere ./restamp-and-gather.sh plan.csv --apply     choose the folder name
#
# The plan CSV is what stamp-dates.py writes: SourceFile,DateTimeOriginal,CreateDate
#
# Re-uploading changes the bytes, so the destination will NOT treat these as
# duplicates of the undated copies. You will have two of each until you delete the
# undated ones, which are the files sitting under the upload date.

set -uo pipefail

PLAN="${1:-}"
APPLY=""
[ "${2:-}" = "--apply" ] && APPLY=1
[ "${1:-}" = "--apply" ] && { echo "Usage: $0 <plan.csv> [--apply]"; exit 1; }

[ -n "$PLAN" ] || { echo "Usage: $0 <plan.csv> [--apply]"; exit 1; }
[ -f "$PLAN" ] || { echo "No such plan file: $PLAN"; exit 1; }
command -v exiftool >/dev/null || { echo "exiftool not found: brew install exiftool"; exit 1; }

OUT="${OUT:-reupload-$(basename "${PLAN%.csv}" | sed 's/^plan-//')}"

# Paths in the plan can contain commas, so the column is extracted with a real CSV
# parser. `cut -d, -f1` truncates such a path at the first comma and silently skips
# the file.
paths_file=$(mktemp)
trap 'rm -f "$paths_file"' EXIT
python3 - "$PLAN" "$paths_file" <<'PY'
import csv, sys
plan, out = sys.argv[1], sys.argv[2]
with open(plan, newline="") as fh, open(out, "w") as w:
    rows = list(csv.DictReader(fh))
    if not rows or "SourceFile" not in rows[0]:
        sys.exit("That does not look like a stamp plan: no SourceFile column.")
    for r in rows:
        w.write(r["SourceFile"] + "\n")
PY
[ $? -eq 0 ] || exit 1

n=$(wc -l < "$paths_file" | tr -d ' ')
echo "$PLAN lists $n files with no capture date."

if [ -z "$APPLY" ]; then
  echo
  echo "Dates that would be written:"
  python3 - "$PLAN" <<'PY'
import csv, collections, sys
c = collections.Counter(r["DateTimeOriginal"][:7].replace(":", "-")
                        for r in csv.DictReader(open(sys.argv[1], newline="")))
for k, v in sorted(c.items()):
    print(f"  {v:5}  {k}")
PY
  echo
  echo "Re-run with --apply to write them and build $OUT/."
  exit 0
fi

missing=0
while IFS= read -r f; do
  [ -f "$f" ] || { echo "  missing: $f"; missing=$((missing+1)); }
done < "$paths_file"
[ "$missing" -eq 0 ] || echo "$missing of $n files are not where the plan says; they will be skipped."

exiftool -@ "$paths_file" -csv="$PLAN" -overwrite_original

# Flatten into one folder so the re-upload is a single drag, not a hunt through
# month subfolders. Name collisions get a numeric suffix.
rm -rf "$OUT"; mkdir -p "$OUT"
copied=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  dest="$OUT/$base"
  i=2
  while [ -e "$dest" ]; do dest="$OUT/${base%.*}-$i.${base##*.}"; i=$((i+1)); done
  cp -p "$f" "$dest" && copied=$((copied+1))
done < "$paths_file"

left=$(exiftool -r -q -if 'not $DateTimeOriginal' -p '$FilePath' \
       -ext jpg -ext jpeg -ext jpe -ext png -ext tif -ext tiff -ext heic -ext bmp -ext gif \
       "$OUT" 2>/dev/null | wc -l | tr -d ' ')

echo
echo "$copied files in $OUT/, $left of them still without a capture date."
if [ "$left" -gt 0 ]; then
  echo "Formats with no EXIF container (BMP, some GIF) cannot carry a date. Those will"
  echo "always land under the upload date."
fi
cat <<NEXT

Then:
  1. upload $OUT/ to the destination
  2. delete the undated originals there (they are filed under the upload date)
  3. rm -rf $OUT
NEXT
