#!/usr/bin/env bash
#
# dropbox-auth.sh - get a Dropbox token through OAuth, with the app's real scopes
#
#   ./dropbox-auth.sh             authorize in the browser, save a token
#   ./dropbox-auth.sh --refresh   mint a new access token, no browser needed
#
# Prints the scopes Dropbox actually granted, so you can see whether
# files.content.read made it in.
#
# Saves to ~/.config/dropbox-cleanup/ : token, refresh, app (key+secret, 0600)

set -euo pipefail
CONF="$HOME/.config/dropbox-cleanup"
PY="$HOME/.cache/dropbox-cleanup/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)" || { echo "python3 not found" >&2; exit 1; }
mkdir -p "$CONF"

[ -r "$CONF/app" ] && . "$CONF/app"
if [ -z "${APP_KEY:-}" ] || [ -z "${APP_SECRET:-}" ]; then
  echo "From the app console Settings tab (both are short, safe to paste):"
  printf '  App key: '; read -r APP_KEY
  printf '  App secret: '; read -r APP_SECRET
  ( umask 077; printf 'APP_KEY=%s\nAPP_SECRET=%s\n' "$APP_KEY" "$APP_SECRET" > "$CONF/app" )
  chmod 600 "$CONF/app"
fi

if [ "${1:-}" = "--refresh" ]; then
  [ -r "$CONF/refresh" ] || { echo "No refresh token saved. Run with no arguments first." >&2; exit 1; }
  "$PY" - "$APP_KEY" "$APP_SECRET" "$(cat "$CONF/refresh")" "$CONF" <<'PY'
import os, sys, requests
key, secret, rt, conf = sys.argv[1:5]
r = requests.post("https://api.dropboxapi.com/oauth2/token",
                  data={"grant_type": "refresh_token", "refresh_token": rt},
                  auth=(key, secret), timeout=30)
if r.status_code != 200:
    sys.exit(f"Refresh failed ({r.status_code}): {r.text[:300]}")
j = r.json()
p = os.path.join(conf, "token")
open(p, "w").write(j["access_token"]); os.chmod(p, 0o600)
print("New access token saved.")
print("Scopes:", j.get("scope", "(not reported)"))
PY
  exit 0
fi

URL="https://www.dropbox.com/oauth2/authorize?client_id=${APP_KEY}&response_type=code&token_access_type=offline"
echo
echo "Opening Dropbox to authorize. Click Allow, then copy the code it shows."
open "$URL" 2>/dev/null || echo "Open this in your browser:\n  $URL"
echo
printf 'Paste the code here (it is short): '
read -r CODE
[ -n "$CODE" ] || { echo "Nothing entered." >&2; exit 1; }

"$PY" - "$APP_KEY" "$APP_SECRET" "$CODE" "$CONF" <<'PY'
import os, sys, requests
key, secret, code, conf = sys.argv[1:5]
r = requests.post("https://api.dropboxapi.com/oauth2/token",
                  data={"code": code.strip(), "grant_type": "authorization_code"},
                  auth=(key, secret), timeout=30)
if r.status_code != 200:
    sys.exit(f"Dropbox rejected that ({r.status_code}): {r.text[:300]}")
j = r.json()
p = os.path.join(conf, "token")
open(p, "w").write(j["access_token"]); os.chmod(p, 0o600)
if j.get("refresh_token"):
    rp = os.path.join(conf, "refresh")
    open(rp, "w").write(j["refresh_token"]); os.chmod(rp, 0o600)
    print("Refresh token saved: from now on, './dropbox-auth.sh --refresh' "
          "gets a new token without the browser.")
scopes = j.get("scope", "")
print("\nAccess token saved.")
print("Scopes granted:")
for s in sorted(scopes.split()):
    mark = "  <-- needed for EXIF" if s == "files.content.read" else ""
    print(f"  {s}{mark}")
if "files.content.read" not in scopes.split():
    sys.exit("\nfiles.content.read is NOT in that list. The app itself does not have "
             "it yet:\ntick it on the Permissions tab, click Submit, then run this again.")
PY
