#!/usr/bin/env bash
#
# pull_all.sh - download the remaining Dropbox year folders, unattended.
#
#   nohup caffeinate -i ./pull_all.sh >/dev/null 2>&1 &
#
# For each year: downloads it, lists any non-photo files, and runs stamp-dates.py as a
# DRY RUN so you can see tomorrow what needs dating. Nothing is modified,
# nothing is uploaded, nothing is deleted. Safe to re-run: finished downloads
# are skipped, so if it dies halfway just start it again.
#
# Writes everything to pull-<timestamp>.log.

set -uo pipefail          # deliberately not -e: one bad year shouldn't stop the rest

PY="$HOME/.cache/dropbox-cleanup/venv/bin/python"
CONF="$HOME/.config/dropbox-cleanup"
# Years to pull into their own folder each, and years to pool into one folder
# because they are small. Override either from the environment:
#   BIG_YEARS="2004 2005" TAIL_YEARS="2006 2007" ./pull-all.sh
BIG_YEARS="${BIG_YEARS:-}"
TAIL_YEARS="${TAIL_YEARS:-}"
TAIL_DIR="${TAIL_DIR:-photos-late}"
LOG="pull-$(date +%Y%m%d-%H%M).log"
NEED_GB="${NEED_GB:-45}"      # refuse to start with less than this free
FLOOR_GB="${FLOOR_GB:-10}"    # stop mid-run rather than fill the disk

exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s)

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# free GB on the disk holding this folder. -P forces one line per filesystem,
# -k forces 1024-blocks, both of which BSD and GNU df agree on.
free_gb() { df -Pk . | awk 'NR==2 {print int($4/1048576)}'; }

[ -n "${DROPBOX_PHOTO_ROOT:-}" ] || {
  echo "Set DROPBOX_PHOTO_ROOT to the Dropbox folder holding the YYYY/ subfolders:"
  echo '  export DROPBOX_PHOTO_ROOT="/Photos/camera imports"'
  exit 1
}
[ -n "$BIG_YEARS$TAIL_YEARS" ] || {
  echo "Set BIG_YEARS and/or TAIL_YEARS to the years you want:"
  echo '  BIG_YEARS="2011 2012" TAIL_YEARS="2013 2014" ./pull-all.sh'
  exit 1
}
[ -x "$PY" ]        || { echo "Missing $PY  (run dropbox-auth.sh setup first)"; exit 1; }
[ -f pull-year.py ] || { echo "Run this from the folder holding pull-year.py"; exit 1; }
[ -f stamp-dates.py ]     || { echo "Run this from the folder holding stamp-dates.py"; exit 1; }

# An unattended run outlives the 4-hour access token, so it needs the refresh token.
[ -s "$CONF/refresh" ] || {
  echo "No refresh token at $CONF/refresh."
  echo "Without it the run dies after about 4 hours. Run ./dropbox-auth.sh first."
  exit 1
}

avail=$(free_gb)
say "Starting. ${avail}GB free, need roughly ${NEED_GB}GB."
if [ "${avail:-0}" -lt "$NEED_GB" ]; then
  echo "Not enough free space. Upload and delete some finished folders first."
  exit 1
fi

PHOTO_EXTS=(jpg jpeg png gif tif tiff heic heif bmp mov mp4 avi m4v 3gp)
not_photo() {                       # build the find predicate once
  local a=() e
  for e in "${PHOTO_EXTS[@]}"; do a+=( \! -iname "*.$e" ); done
  find "$1" -type f "${a[@]}" 2>/dev/null
}

junk_report() {
  local n
  n=$(not_photo "$1" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    echo "  $n non-photo files (Google Photos will reject these):"
    not_photo "$1" | sed 's/.*\.//' | tr 'A-Z' 'a-z' \
      | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'
  else
    echo "  no non-photo files"
  fi
}

# stamp-dates.py writes its plan into the current folder, so each year would clobber
# the last. Keep them per-year instead.
dry_stamp() {
  local dir="$1" tag="$2"
  echo "  --- stamp dry run ($dir) ---"
  "$PY" stamp-dates.py "$dir" 2>&1 | sed 's/^/  /'
  [ -f dates-to-stamp.csv ] && mv -f dates-to-stamp.csv "plan-$tag.csv"
  [ -f undated.txt ]        && mv -f undated.txt "undated-$tag.txt"
  return 0
}

done_dirs=""

for y in $BIG_YEARS; do
  say "=== $y ==="
  if [ "$(free_gb)" -lt "$FLOOR_GB" ]; then
    echo "  under ${FLOOR_GB}GB free, stopping here rather than filling the disk."
    break
  fi
  if "$PY" pull-year.py "$y"; then
    junk_report "photos-$y"
    dry_stamp "photos-$y" "$y"
    done_dirs="$done_dirs photos-$y"
  else
    echo "  $y did not download (no such folder, or an error above). Continuing."
  fi
done

say "=== $TAIL_YEARS into $TAIL_DIR ==="
for y in $TAIL_YEARS; do
  if [ "$(free_gb)" -lt "$FLOOR_GB" ]; then
    echo "  under ${FLOOR_GB}GB free, stopping here rather than filling the disk."
    break
  fi
  "$PY" pull-year.py "$y" "$TAIL_DIR" || echo "  $y did not download. Continuing."
done
if [ -d "$TAIL_DIR" ]; then
  junk_report "$TAIL_DIR"
  dry_stamp "$TAIL_DIR" "late"
  done_dirs="$done_dirs $TAIL_DIR"
fi

say "Finished in $(( ($(date +%s) - T0) / 60 )) minutes. Downloaded:"
if [ -n "$done_dirs" ]; then
  for d in $done_dirs; do
    printf '  %-16s %7s files  %8s\n' "$d" \
      "$(find "$d" -type f | wc -l | tr -d ' ')" "$(du -sh "$d" | cut -f1)"
  done
else
  echo "  nothing. Check the errors above."
fi
echo "  ${avail}GB free before, $(free_gb)GB free now"

cat <<'NEXT'

Tomorrow, one folder at a time:
  1. look at the non-photo list above; delete that junk if it is junk
  2. python3 stamp-dates.py <folder> --apply
  3. drag <folder> into photos.google.com
  4. rm -rf <folder>          (only once Google says the upload finished)

The per-year plan-YYYY.csv files show exactly what stamp-dates.py would write.
NEXT
echo "Log: $LOG"
