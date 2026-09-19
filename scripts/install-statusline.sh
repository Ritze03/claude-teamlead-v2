#!/usr/bin/env bash
# Install teamlead's status line segment.
#
# A plugin cannot set a main status line — only your settings.json can — so this
# is the one thing teamlead has to ask you to do. It never changes settings
# without telling you what it is replacing, and always writes a backup first.
#
#   ./install-statusline.sh              ask
#   ./install-statusline.sh --combined   keep your current status line, add teamlead's
#   ./install-statusline.sh --only       teamlead's alone (replaces what is there)
#   ./install-statusline.sh --uninstall  restore what was there before
#   ./install-statusline.sh --show       print what is configured, change nothing
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(dirname "$HERE")
SEG="$PLUGIN/hooks/statusline.sh"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"
COMBINED="$CFG/statusline.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }
[ -f "$SEG" ] || die "can't find teamlead's segment at $SEG"
command -v python3 >/dev/null || die "python3 is required"

cur() { python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("statusLine") or {}).get("command", ""))
except Exception:
    print("")
PY
}

set_status() { python3 - "$SETTINGS" "$1" <<'PY'
import json, sys, os
p, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
if cmd:
    d["statusLine"] = {"type": "command", "command": cmd}
else:
    d.pop("statusLine", None)
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
}

backup() {
  [ -f "$SETTINGS" ] || return 0
  local b="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$b"; printf '  backup: %s\n' "$b"
  # Remember the pre-teamlead command so --uninstall can put it back.
  [ -f "$CFG/.teamlead-statusline-prev" ] || printf '%s\n' "$(cur)" > "$CFG/.teamlead-statusline-prev"
}

# A plugin-cache path with a pinned version breaks silently on the next update.
# Swap the version for a glob; the combiner version-sorts and takes the newest.
depin() {
  local c="$1"
  # Only worth doing for a pinned plugin-cache path.
  printf '%s' "$c" | grep -qE '/plugins/cache/[^/]+/[^/]+/[^/*"]+/' || { printf '%s' "$c"; return; }
  # A glob must be UNQUOTED to expand — bash "/x/*/y.sh" is a literal path and the
  # segment silently disappears. So only de-pin when the path has no spaces, where
  # dropping the quotes is safe.
  printf '%s' "$c" | grep -qE '"[^"]* [^"]*"' && { printf '%s' "$c"; return; }
  printf '%s' "$c" | sed -E 's#(/plugins/cache/[^/]+/[^/]+/)[^/*"]+/#\1*/#g; s/"//g'
}

write_combined() {
  local prev="$1" segs=""
  # Readable double-quoted lines, not %q escaping — the whole point is that a
  # human can add another line by eye.
  q() { local c=${1//\\/\\\\}; printf '  "%s"' "${c//\"/\\\"}"; }
  if [ -n "$prev" ]; then
    local dp; dp=$(depin "$prev")
    [ "$dp" != "$prev" ] && printf '  un-pinned the version in your existing segment so it survives plugin updates:\n    %s\n' "$dp"
    segs+="$(q "$dp")"$'\n'
  fi
  segs+="$(q "bash \"$SEG\"")"$'\n'
  segs+='  # "your-command-here"        <- add lines like this'
  if [ -f "$COMBINED" ] && ! grep -q "install-statusline.sh" "$COMBINED"; then
    printf '  %s already exists and was not written by this installer — leaving it alone.\n' "$COMBINED"
    printf '  Add this line to its SEGMENTS list yourself:\n    %s\n' "$(q "bash \"$SEG\"")"
    return 1
  fi
  python3 - "$HERE/statusline-combined.template.sh" "$COMBINED" "$segs" <<'PY'
import sys
tpl, out, segs = sys.argv[1], sys.argv[2], sys.argv[3]
open(out, "w").write(open(tpl).read().replace("__SEGMENTS__", segs.rstrip("\n")))
PY
  chmod +x "$COMBINED"
}

show() {
  printf 'settings: %s\n' "$SETTINGS"
  local c; c=$(cur)
  printf 'statusLine: %s\n' "${c:-<none>}"
  [ -n "$c" ] && { printf 'renders as: '; echo '{"workspace":{"current_dir":"'"$PWD"'"}}' | bash -c "$c" 2>/dev/null; echo; }
}

mode="${1:-ask}"
case "$mode" in
  --show) show; exit 0 ;;
  --uninstall)
    backup
    prev=$(cat "$CFG/.teamlead-statusline-prev" 2>/dev/null)
    set_status "$prev"
    rm -f "$CFG/.teamlead-statusline-prev"
    printf '  restored: %s\n' "${prev:-<none>}"; show; exit 0 ;;
esac

existing=$(cur)
if [ "$mode" = "ask" ]; then
  printf '\nTeamlead status line\n\n'
  if [ -n "$existing" ]; then
    printf '  You already have one:\n    %s\n\n' "$existing"
    printf '  1) Keep it and add teamlead alongside  (recommended)\n'
    printf '  2) Replace it with teamlead only\n'
    printf '  3) Cancel\n\n'
  else
    printf '  You have no status line configured.\n\n'
    printf '  1) Install teamlead, in a combiner you can add more segments to  (recommended)\n'
    printf '  2) Install teamlead alone\n'
    printf '  3) Cancel\n\n'
  fi
  read -rp '  Choice [1]: ' a </dev/tty || a=3
  case "${a:-1}" in 1) mode=--combined ;; 2) mode=--only ;; *) echo '  cancelled'; exit 0 ;; esac
fi

case "$mode" in
  --combined)
    backup
    if write_combined "$existing"; then
      set_status "bash \"$COMBINED\""
      printf '  combiner: %s\n' "$COMBINED"
    fi ;;
  --only)
    backup
    set_status "bash \"$SEG\"" ;;
  *) die "unknown option: $mode (try --combined, --only, --uninstall, --show)" ;;
esac

printf '\n'; show
printf '\nTakes effect in new sessions.\n'
