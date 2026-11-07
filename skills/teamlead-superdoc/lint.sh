#!/usr/bin/env bash
# superdoc lint: what a script can decide about a superdoc tree, reliably.
#
#   lint.sh [--doc DIR]                  whole tree, all checks (audit use)
#   lint.sh [--doc DIR] --files F...     all checks, report only findings in those files
#   lint.sh [--doc DIR] --staged         leak checks on lines ADDED in the index
#   lint.sh [--doc DIR] --range A..B     leak checks on lines added by EACH commit in A..B
#   lint.sh [--doc DIR] --push REF REMOTE  same, for the commits of REF no remote-tracking ref of
#                                        REMOTE has (a push of a new branch: old debt is not scanned)
#   lint.sh [--doc DIR] --force-load     the force-load report (SKILL.md Step 1)
#
# Findings print as `path:line: error|warn: <kind>`. A leaked value is NEVER printed, in any
# mode: no source line, no match text, only file, line and kind. Exit 0 = no errors
# (warnings allowed), 1 = at least one error, 2 = usage error. No doc root and no superdoc
# marker: exit 0 silently (hooks call this in every repo).
#
# The scanned set is the doc tree plus CLAUDE.md, text files only. A line containing
# `superdoc-lint: allow` is skipped (for true false positives only, never for a real value).
set -u

# ---- ALLOWLIST: never a finding. Edit here, nowhere else. ---------------------------------
# (Loopback 127.0.0.0/8, 0.0.0.0, localhost and ::1 are never reported: the IP scan skips
#  0.x and 127.x, and it has no hostname or IPv6 rule. Names below compare lowercased.)
ALLOW_HOME_NAMES="user you username name yourname your-name your_name youruser your-user your_username myuser me foo bar example alice bob someone runner node vscode ubuntu builder circleci shared public guest default all"
ALLOW_HOME_FIRST_CHAR='<$%{[~*'      # a name starting with one of these is a placeholder
ALLOW_EMAIL_DOMAINS="example.com example.org example.net"   # and every subdomain of them
ALLOW_EMAIL_TLDS="example invalid test localhost"            # *.example *.invalid *.test *.localhost
ALLOW_EMAIL_LOCAL_HAS="noreply no-reply no_reply donotreply do-not-reply"   # noreply addresses
ALLOW_EMAIL_SSH_USER="git"           # git@host:path and git@host/path SSH remotes
ALLOW_IPS="1.2.3.4 1.1.1.1 8.8.8.8 8.8.4.4 9.9.9.9"          # textbook placeholders, public resolvers
ALLOW_IP_PREFIXES="192.0.2. 198.51.100. 203.0.113."          # documentation ranges
ALLOW_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"   # the ranges themselves
ALLOW_HOST_PATH_NAMES="homebrew local c d"                    # /opt/homebrew, /opt/local, WSL /mnt/c
# Not an email when the "TLD" is a file extension (icon@2x.png, pkg@next.js):
DENY_EMAIL_TLDS="png jpg jpeg gif svg webp avif ico bmp tiff pdf zip tar gz tgz bz2 xz 7z txt log lock map bin exe dll so dylib wasm woff woff2 ttf otf eot mp3 mp4 mov webm csv xml ini cfg conf env js jsx ts tsx mjs cjs json md css scss html htm py rs go sh rb php java kt c h cc cpp hpp cs yml yaml toml sql vue"
# Extensions that make `file.ext:123` a line reference:
LINEREF_EXTS="c h cc cpp hpp hh cs go rs py js jsx ts tsx mjs cjs java kt swift rb php sh bash lua sql vue svelte md json toml yaml yml css scss html m mm zig ex exs erl hs ml scala dart pl jl clj nim"
# ---- end of allowlist -----------------------------------------------------------------------

# ---- Step 1's force-load logic. It lives here and nowhere else (SKILL.md calls --force-load). ----
# A match cannot follow a backtick, so an `@superdoc/...` written inside a code span (prose, not
# a force-load) is ignored; the sed drops the one character the pattern captures in front of the @.
# REF is set once the doc folder is known (refs/refs_nl/forceload read it).
# A glossary is judged by entry length, not file size: sum each "- **" entry (its wrapped
# lines too) up to the next entry or heading and print entries over ~300 characters.
LONG='function flush(){if(n>300)print s": "n" chars"} /^- \*\*/{flush();n=0;s=FILENAME":"FNR;on=1} /^#/{flush();n=0;on=0} on{n+=length($0)} END{flush()}'
refs_nl() { grep -noE "$REF" CLAUDE.md 2>/dev/null | sed "s/^\([0-9]*\):[^@]*@/\1$(printf '\t')/"; }   # line TAB path
refs() { refs_nl | cut -f2; }

# forceload report   -> Step 1's report, line for line
# forceload records  -> only the warnings, as findings records (sev, path, line, kind, commit)
forceload() {
  local fmode=$1 f ln b ents longn total vtotal flagged gloss
  # A dangling @-ref loads NOTHING and says nothing about it: the docs look wired
  # while the agent silently gets none of them.
  if [ "$fmode" = report ]; then
    refs | while read -r f; do
      test -f "$f" || echo "⚠ CLAUDE.md force-loads $f — that file does not exist"
    done
  else
    refs_nl | while IFS=$'\t' read -r ln f; do
      test -f "$f" || printf 'warn\tCLAUDE.md\t%s\tdangling @-ref (the target file does not exist)\t\n' "$ln"
    done
  fi
  # Force-load budget: CLAUDE.md plus every @-ref target sits in context for the whole
  # session, goes out with every request, and every worker carries its own copy.
  # Counted toward the 20 KB total: CLAUDE.md, the glossary, project-owned files. Verbatim
  # installs are listed but not counted (nobody may trim them). The glossary has no 8 KB
  # flag; its entries are checked instead.
  total=0; vtotal=0; flagged=0; longn=0; gloss=0
  for f in CLAUDE.md $(refs | sort -u); do
    test -f "$f" || continue
    b=$(wc -c < "$f")
    case "$f" in
      */claude-instructions/documentation.md|*/claude-instructions/documentation-version-policy.md)
        vtotal=$((vtotal + b))
        [ "$fmode" = report ] && echo "force-loaded: $f ${b}B (verbatim install: listed, not counted, never trimmed)" ;;
      */meta/TERMINOLOGY.md)
        total=$((total + b)); gloss=1
        [ "$fmode" = report ] && echo "force-loaded: $f ${b}B (glossary: judged by entry length, not file size)"
        ents=$(awk "$LONG" "$f"); longn=$(printf '%s' "$ents" | grep -c .)
        if [ "$longn" -gt 0 ] && [ "$fmode" = report ]; then
          echo "⚠ $f has $longn entries over ~300 characters (an entry is what the term is plus a link):"
          printf '%s\n' "$ents" | head -10 | sed 's/^/    /'
        fi ;;
      *)
        total=$((total + b))
        [ "$fmode" = report ] && echo "force-loaded: $f ${b}B"
        if [ "$b" -gt 8192 ]; then
          flagged=$((flagged + 1))
          if [ "$fmode" = report ]; then echo "⚠ $f is ${b}B (over 8 KB): force-loaded files are paid for all session"
          else printf 'warn\t%s\t1\tforce-loaded file is %sB (over 8 KB): force-loaded files are paid for all session\t\n' "$f" "$b"; fi
        fi ;;
    esac
  done
  if [ "$fmode" = report ]; then
    echo "force-loaded total: ${total}B"
    if [ "$vtotal" -gt 0 ]; then echo "verbatim installs: ${vtotal}B (listed above, not in the total)"; fi
  fi
  if [ "$total" -gt 20480 ]; then
    if [ "$gloss" = 1 ] && [ "$longn" = 0 ] && [ "$flagged" = 0 ]; then
      [ "$fmode" = report ] && echo "note: force-loaded total is ${total}B (over 20 KB) with every glossary entry short: ask whether every term must be known on every task (playbook Part 9)"
    elif [ "$fmode" = report ]; then echo "⚠ force-loaded total is ${total}B (over 20 KB)"
    else printf 'warn\t<total>\t1\tforce-loaded total is %sB (over 20 KB)\t\n' "$total"; fi
  fi
  return 0
}
# ---- end of the Step 1 logic -----------------------------------------------------------------

usage() {
  cat <<'EOF'
usage: lint.sh [--doc DIR] [--files F... | --staged | --range A..B | --push REF REMOTE | --force-load]
  (no mode)      whole tree, all checks
  --files F...   all checks, report only findings in the given files
  --staged       leak checks on lines added in the index
  --range A..B   leak checks on lines added by each commit in A..B
  --push REF REMOTE  the same for commits of REF that REMOTE's tracking refs lack (new-branch push)
  --force-load   the force-load size report
exit: 0 no errors, 1 errors found, 2 usage error
EOF
}
usage_err() { printf 'superdoc-lint: %s\n' "$1" >&2; usage >&2; exit 2; }

# ---- arguments ------------------------------------------------------------------------------------
MODE=all; DOC=""; DOC_GIVEN=0; RANGE=""; FILES_IN=""; PUSH_REF=""; PUSH_REMOTE=""
setmode() { [ "$MODE" = all ] || usage_err "only one of --files, --staged, --range, --push, --force-load"; MODE=$1; }
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --doc) [ $# -ge 2 ] || usage_err "--doc needs a folder"; DOC=$2; DOC_GIVEN=1; shift 2 ;;
    --doc=*) DOC=${1#--doc=}; DOC_GIVEN=1; shift ;;
    --staged) setmode staged; shift ;;
    --force-load) setmode force-load; shift ;;
    --range) [ $# -ge 2 ] || usage_err "--range needs A..B"; setmode range; RANGE=$2; shift 2 ;;
    --range=*) setmode range; RANGE=${1#--range=}; shift ;;
    --push) [ $# -ge 3 ] || usage_err "--push needs REF and REMOTE"; setmode push; PUSH_REF=$2; PUSH_REMOTE=$3; shift 3 ;;
    --files)
      setmode files; shift
      while [ $# -gt 0 ]; do
        case $1 in
          --) shift; while [ $# -gt 0 ]; do FILES_IN="$FILES_IN$1"$'\n'; shift; done ;;
          --*) break ;;
          *) FILES_IN="$FILES_IN$1"$'\n'; shift ;;
        esac
      done ;;
    *) usage_err "unknown argument" ;;
  esac
done
[ "$DOC_GIVEN" = 1 ] && [ -z "$DOC" ] && usage_err "--doc needs a folder"

# ---- repo root: work from any subdirectory and from a linked worktree --------------------------------
# Under a git hook GIT_DIR / GIT_INDEX_FILE are set and may be relative to the hook's cwd, so do
# not cd there: git already treats that cwd as the work tree. Elsewhere, cd to the toplevel.
PREFIX=""
if [ -n "${GIT_DIR:-}${GIT_INDEX_FILE:-}${GIT_WORK_TREE:-}" ]; then
  :
else
  _out=$(git rev-parse --show-toplevel --show-prefix 2>/dev/null) || _out=""
  if [ -n "$_out" ]; then
    case $_out in *$'\n'*) PREFIX=${_out#*$'\n'} ;; esac
    cd "${_out%%$'\n'*}" 2>/dev/null || exit 0
  else
    # not a git repo: walk up to the nearest dir that has superdoc/ or CLAUDE.md
    _d=$PWD; _o=$PWD
    while [ -n "$_d" ] && [ "$_d" != / ]; do
      if [ -d "$_d/superdoc" ] || [ -f "$_d/CLAUDE.md" ]; then
        cd "$_d" 2>/dev/null
        PREFIX=${_o#"$_d"}; PREFIX=${PREFIX#/}; [ -z "$PREFIX" ] || PREFIX="$PREFIX/"
        break
      fi
      _d=${_d%/*}
    done
  fi
fi
ROOT=$(pwd -P)

# ---- doc root ----------------------------------------------------------------------------------------
if [ -z "$DOC" ]; then
  if [ -d superdoc ]; then DOC=superdoc
  elif [ -f CLAUDE.md ]; then
    # the folder of the first @.../meta/TERMINOLOGY.md or @.../claude-instructions/... ref
    DOC=$(grep -oE '(^|[^`])@[^ )`]+/(meta/TERMINOLOGY\.md|claude-instructions/[^ )`]+)' CLAUDE.md 2>/dev/null | head -1 |
          sed 's/^[^@]*@//; s#/meta/TERMINOLOGY\.md$##; s#/claude-instructions/.*$##')
    case $DOC in /*|\~*|.*) DOC="" ;; esac
    if [ -z "$DOC" ] && grep -q 'superdoc:start' CLAUDE.md 2>/dev/null; then DOC=superdoc; fi
  fi
  [ -n "$DOC" ] || exit 0
else
  if [ ! -d "$DOC" ] && [ -n "$PREFIX" ] && [ -d "$PREFIX$DOC" ]; then DOC=$PREFIX$DOC; fi
  case $DOC in "$ROOT"/*) DOC=${DOC#"$ROOT"/} ;; esac
fi
while :; do case $DOC in ./*) DOC=${DOC#./} ;; */) DOC=${DOC%/} ;; *) break ;; esac; done
[ -n "$DOC" ] || usage_err "--doc needs a folder"
# One @-ref pattern for every use below, so they cannot drift.
REF='(^|[^`])@'"$DOC"'/[^ )`]+'

if [ "$MODE" = force-load ]; then forceload report; exit 0; fi

# ---- the leak scanner (one awk, reads files or tab-separated records) -----------------------------------
# Record input (--staged/--range): path TAB line TAB commit TAB text. File input: FILENAME/FNR.
# Output: sev TAB path TAB line TAB kind TAB commit. It prints kinds only, never text.
IFS= read -r -d '' LEAK_AWK <<'AWK'
function setof(str, arr,    n, t, i) { n = split(str, t, " "); for (i = 1; i <= n; i++) arr[tolower(t[i])] = 1 }
BEGIN {
  setof(ALLOW_HOME_NAMES, HOMEOK); setof(ALLOW_EMAIL_DOMAINS, EDOM); setof(ALLOW_EMAIL_TLDS, ETLD)
  setof(ALLOW_EMAIL_LOCAL_HAS, ELOC); setof(ALLOW_IPS, IPOK); setof(ALLOW_IP_PREFIXES, IPPFX)
  setof(ALLOW_CIDRS, CIDROK); setof(ALLOW_HOST_PATH_NAMES, OPTOK); setof(DENY_EMAIL_TLDS, EXTDENY)
  n = split(LINEREF_EXTS, t, " "); alt = ""
  for (i = 1; i <= n; i++) alt = alt (i > 1 ? "|" : "") t[i]
  LREGEX = "[A-Za-z0-9_./-]+\\.(" alt ")(:L?|#L)[0-9]+"
  ARCH = DOC "/architecture/"
  VERCTX = "([Vv]ersion|[Vv]er|[Rr]elease|[Bb]uild)[ :=]+$|(>=|<=|==|!=|[~^])[ ]*$"
}
function emit(sev, kind) {
  if (kind in S) return
  S[kind] = 1
  printf "%s\t%s\t%s\t%s\t%s\n", sev, P, L, kind, C
}
function placeholder_home(name,    l, f) {
  l = tolower(name)
  if (l in HOMEOK) return 1
  f = substr(name, 1, 1)
  if (f != "" && index(ALLOW_HOME_FIRST_CHAR, f)) return 1
  if (index(name, "...")) return 1
  return 0
}
# /home/<name>/ and /Users/<name>/ ; the char before the leading slash must not be a path char
# (so `example.com/home/x/` and `a/home/x/` are not host paths). A bare /home/<name> with no
# trailing slash (`cd /home/name`) counts too: same allowlist, same exclusions.
function unixhome(s, root,    rest, seg, nm, re) {
  rest = s
  re = "(^|[^A-Za-z0-9._~%+/-])/" root "/[A-Za-z0-9_-][A-Za-z0-9._-]*"
  while (match(rest, re)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/^[^\/]/, "", seg)
    nm = substr(seg, length(root) + 3)
    if (placeholder_home(nm)) continue
    sub(/\.+$/, "", nm)                         # "/home/name." at the end of a sentence
    if (nm != "" && !placeholder_home(nm)) { emit("error", "home path"); return }
  }
  rest = s
  re = "(^|[^A-Za-z0-9._~%+/-])/" root "/[^/ \t\"'`]+/"
  while (match(rest, re)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH - 1)
    sub(/^[^\/]/, "", seg)
    nm = substr(seg, length(root) + 3); nm = substr(nm, 1, length(nm) - 1)
    if (!placeholder_home(nm)) { emit("error", "home path"); return }
  }
}
function winhome(s,    rest, seg, nm, re) {
  rest = s
  re = "(^|[^A-Za-z0-9])[A-Za-z]:[\\\\/]+[Uu]sers[\\\\/]+[^\\\\/ \t\"'`]+[\\\\/]"
  while (match(rest, re)) {
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH - 1)
    nm = seg; sub(/^.*[Uu]sers[\\\/]+/, "", nm); sub(/[\\\/]$/, "", nm)
    if (!placeholder_home(nm)) { emit("error", "home path"); return }
  }
}
function emails(s,    rest, acc, seg, pre, post, tokpre, after, at, loc, dom, n, lab, tld, first, ld, ll, k, ok) {
  rest = s; acc = ""
  while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/)) {
    seg = substr(rest, RSTART, RLENGTH)
    pre = acc substr(rest, 1, RSTART - 1)
    post = substr(rest, RSTART + RLENGTH, 1)
    acc = acc substr(rest, 1, RSTART + RLENGTH - 1)
    rest = substr(rest, RSTART + RLENGTH)
    # user@host inside a URL (https://user:pw@host/...) is URL userinfo, not an email
    tokpre = pre; sub(/.*[[ \t"'(<`,;=]/, "", tokpre)
    if (index(tokpre, "://")) { after = substr(tokpre, index(tokpre, "://") + 3); if (index(after, "/") == 0) continue }
    at = index(seg, "@"); loc = substr(seg, 1, at - 1); dom = substr(seg, at + 1)
    if (tolower(loc) == ALLOW_EMAIL_SSH_USER && (post == ":" || post == "/")) continue
    n = split(dom, lab, "."); tld = tolower(lab[n]); first = lab[1]
    if (tld !~ /^[a-z][a-z]+$/) continue          # pkg@1.2.3, lodash@4.17.21: no alphabetic TLD
    if (first !~ /[A-Za-z]/) continue            # pkg@1.2.3-beta.rc, user@10.0.0.1: first label is all digits
    if (first ~ /^[0-9]x$/) continue             # icon@2x.png
    if (tld in EXTDENY) continue                 # file extension, not a TLD
    ld = tolower(dom); ll = tolower(loc); ok = 0
    if (ld in EDOM) ok = 1
    for (k in EDOM) if (length(ld) > length(k) && substr(ld, length(ld) - length(k)) == "." k) ok = 1
    if (tld in ETLD) ok = 1
    if (index(ld, "noreply")) ok = 1
    for (k in ELOC) if (index(ll, k)) ok = 1
    if (!ok) { emit("error", "email"); return }
  }
}
function ips(s,    rest, acc, tok, pre, post, post2, postrest, lb, n, p, i, bad, a, b, cand, k) {
  rest = s; acc = ""
  while (match(rest, /[0-9]+(\.[0-9]+)+/)) {
    tok = substr(rest, RSTART, RLENGTH)
    pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : substr(acc, length(acc), 1)
    lb = acc substr(rest, 1, RSTART - 1)
    post = substr(rest, RSTART + RLENGTH, 1); post2 = substr(rest, RSTART + RLENGTH + 1, 1)
    postrest = substr(rest, RSTART + RLENGTH)
    acc = acc substr(rest, 1, RSTART + RLENGTH - 1)
    rest = postrest
    if (pre ~ /[A-Za-z_.-]/) continue            # v10.0.0.1, host-10.0.0.1, a.10.0.0.1
    if (post ~ /[A-Za-z_]/) continue             # 10.0.0.1x
    if (post == "-" && post2 ~ /[A-Za-z]/) continue   # 10.0.0.1-beta
    if (lb ~ VERCTX) continue                    # "version 10.0.0.1", ">=10.0.0.1", "^1.2.3.4"
    # (a bare < or > is not a version operator: a "> 10.0.0.5" blockquote is still scanned)
    n = split(tok, p, "."); if (n != 4) continue # 1.10.0.1.2 and 1.2.3 are versions, not IPs
    bad = 0
    for (i = 1; i <= 4; i++) if (length(p[i]) > 3 || p[i] + 0 > 255 || (length(p[i]) > 1 && substr(p[i], 1, 1) == "0")) bad = 1
    if (bad) continue                            # 999.1.1.1
    if (post == "/" && match(postrest, /^\/[0-9]+/)) { cand = tok substr(postrest, 1, RLENGTH); if (cand in CIDROK) continue }
    if (tok in IPOK) continue
    a = p[1] + 0; b = p[2] + 0
    if (a == 0 || a == 127 || a >= 224) continue # 0.0.0.0, loopback, multicast/broadcast
    for (k in IPPFX) if (index(tok ".", k) == 1) bad = 1
    if (bad) continue                            # documentation ranges
    if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127)) emit("error", "private IP")
    else emit("warn", "public IP")
  }
}
function hostpaths(s,    rest, seg, nm, re) {
  rest = s
  re = "(^|[^A-Za-z0-9._~%+/-])/(mnt|media|srv|opt|Volumes|run/media)/[A-Za-z0-9._-]+"
  while (match(rest, re)) {
    seg = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    nm = seg; sub(/.*\//, "", nm)
    if (!(tolower(nm) in OPTOK)) { emit("warn", "host path"); return }
  }
}
{
  if (TSV) {
    i1 = index($0, "\t"); P = substr($0, 1, i1 - 1); r = substr($0, i1 + 1)
    i2 = index(r, "\t"); L = substr(r, 1, i2 - 1); r = substr(r, i2 + 1)
    i3 = index(r, "\t"); C = substr(r, 1, i3 - 1); T = substr(r, i3 + 1)
  } else { P = FILENAME; L = FNR; C = ""; T = $0 }
  sub(/\r$/, "", T)
  if (index(T, "superdoc-lint: allow")) next
  if (T !~ /[0-9@\/\\]/) next
  split("", S)
  U = T; gsub(/file:\/\//, " ", U)
  unixhome(U, "home"); unixhome(U, "Users"); winhome(T)
  emails(T); ips(T); hostpaths(U)
  if (LINEREF && index(P, ARCH) == 1 && match(T, LREGEX)) emit("warn", "line reference")
}
AWK

AWKV=(-v "DOC=$DOC"
  -v "ALLOW_HOME_NAMES=$ALLOW_HOME_NAMES" -v "ALLOW_HOME_FIRST_CHAR=$ALLOW_HOME_FIRST_CHAR"
  -v "ALLOW_EMAIL_DOMAINS=$ALLOW_EMAIL_DOMAINS" -v "ALLOW_EMAIL_TLDS=$ALLOW_EMAIL_TLDS"
  -v "ALLOW_EMAIL_LOCAL_HAS=$ALLOW_EMAIL_LOCAL_HAS" -v "ALLOW_EMAIL_SSH_USER=$ALLOW_EMAIL_SSH_USER"
  -v "ALLOW_IPS=$ALLOW_IPS" -v "ALLOW_IP_PREFIXES=$ALLOW_IP_PREFIXES" -v "ALLOW_CIDRS=$ALLOW_CIDRS"
  -v "ALLOW_HOST_PATH_NAMES=$ALLOW_HOST_PATH_NAMES" -v "DENY_EMAIL_TLDS=$DENY_EMAIL_TLDS"
  -v "LINEREF_EXTS=$LINEREF_EXTS")
scan_records() { LC_ALL=C awk -v TSV=1 -v LINEREF=0 "${AWKV[@]}" "$LEAK_AWK"; }   # records on stdin

# Added lines of a diff stream as records. Only the doc tree and CLAUDE.md. The commit marker is
# a line starting with \001 (git log --format=%x01%h); a diff header ends at the first @@.
diff_records() {
  awk -v D="$DOC/" '
    substr($0, 1, 1) == "\001" { C = substr($0, 2); inh = 0; P = ""; next }
    /^diff --git / { inh = 1; P = ""; next }
    inh && /^\+\+\+ / {
      s = substr($0, 5); sub(/\t.*$/, "", s)
      if (s == "/dev/null") P = ""; else { sub(/^b\//, "", s); P = s }
      if (P != "CLAUDE.md" && index(P, D) != 1) P = ""
      next }
    /^@@ / { inh = 0; if (P != "") { s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); L = s + 0 }; next }
    !inh && P != "" && substr($0, 1, 1) == "+" { printf "%s\t%d\t%s\t%s\n", P, L, C, substr($0, 2); L++ }'
}
GITDIFF_OPTS="-U0 -M --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/"

# ---- helpers for the file modes -------------------------------------------------------------------------
norm() {  # a file argument -> repo-root-relative path
  local p=$1
  case $p in
    /*) case $p in "$ROOT"/*) p=${p#"$ROOT"/} ;; esac ;;
    *) if [ -n "$PREFIX" ] && [ -e "$PREFIX$p" ]; then p=$PREFIX$p; fi ;;
  esac
  while case $p in ./*) true ;; *) false ;; esac; do p=${p#./}; done
  printf '%s' "$p"
}
in_scope() { [ "$1" = CLAUDE.md ] || case $1 in "$DOC"/*) return 0 ;; *) return 1 ;; esac; }
text_filter() { LC_ALL=C xargs -0 -r grep -Il . 2>/dev/null; }   # NUL names in, text files out
candidates_all() {
  [ -f CLAUDE.md ] && printf 'CLAUDE.md\0'
  [ -d "$DOC" ] && find "$DOC" -name .git -prune -o -type f -print0
  return 0
}

RECORDS=""
FILTER=0; FILES_SET=""
case $MODE in
  staged)
    git rev-parse --git-dir >/dev/null 2>&1 || usage_err "not a git repository"
    RECORDS=$(git -c core.quotepath=false diff --cached $GITDIFF_OPTS -- "$DOC" CLAUDE.md 2>/dev/null | diff_records | scan_records) ;;
  push)
    git rev-parse --git-dir >/dev/null 2>&1 || usage_err "not a git repository"
    git rev-parse -q --verify "$PUSH_REF^{commit}" >/dev/null 2>&1 || usage_err "bad revision"
    # commits of REF that no remote-tracking ref of REMOTE has. REMOTE is the remote's name (what
    # git hands pre-push as $1); a URL or an unknown name falls back to all remote-tracking refs.
    if git config --get "remote.$PUSH_REMOTE.url" >/dev/null 2>&1; then rglob="--remotes=$PUSH_REMOTE"; else rglob="--remotes"; fi
    RECORDS=$(git -c core.quotepath=false log --reverse --no-merges -p $GITDIFF_OPTS --format=%x01%h "$PUSH_REF" --not "$rglob" -- "$DOC" CLAUDE.md 2>/dev/null | diff_records | scan_records) ;;
  range)
    git rev-parse --git-dir >/dev/null 2>&1 || usage_err "not a git repository"
    case $RANGE in *...*) usage_err "--range takes A..B (two dots)" ;; *..*) ;; *) usage_err "--range takes A..B" ;; esac
    ra=${RANGE%%..*}; rb=${RANGE#*..}; [ -n "$rb" ] || rb=HEAD
    git rev-parse -q --verify "$rb^{commit}" >/dev/null 2>&1 || usage_err "bad revision range"
    # An empty/zero/empty-tree start means "everything reachable from B" (new branch, root commit).
    empty_tree=$(git hash-object -t tree /dev/null 2>/dev/null)
    case $ra in
      ""|0|00000000*|"$empty_tree"|4b825dc642cb6eb9a060e54bf8d69288fbb4904|6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321) spec=$rb ;;
      *) git rev-parse -q --verify "$ra^{commit}" >/dev/null 2>&1 || usage_err "bad revision range"
         spec="$ra..$rb" ;;
    esac
    RECORDS=$(git -c core.quotepath=false log --reverse --no-merges -p $GITDIFF_OPTS --format=%x01%h "$spec" -- "$DOC" CLAUDE.md 2>/dev/null | diff_records | scan_records) ;;
  all|files)
    if [ "$MODE" = files ]; then
      FILTER=1; cand=""
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        p=$(norm "$a"); in_scope "$p" || continue
        FILES_SET="$FILES_SET$p"$'\n'
        [ -f "$p" ] && cand="$cand$p"$'\n'
      done <<EOF
$FILES_IN
EOF
      [ -n "$FILES_SET" ] || exit 0
      LIST=$(printf '%s' "$cand" | tr '\n' '\0' | text_filter)
    else
      LIST=$(candidates_all | text_filter)
    fi
    if [ -n "$LIST" ]; then
      RECORDS=$(printf '%s\n' "$LIST" | tr '\n' '\0' | LC_ALL=C xargs -0 -r awk -v TSV=0 -v LINEREF=1 "${AWKV[@]}" "$LEAK_AWK")
    fi
    # force-load findings, glossary entry length, pages missing from the README
    RECORDS="$RECORDS"$'\n'$(forceload records)
    if [ -f "$DOC/meta/TERMINOLOGY.md" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        n=${l##*: }; n=${n% chars}; loc=${l%: *}
        RECORDS="$RECORDS"$'\n'"$(printf 'warn\t%s\t%s\tTERMINOLOGY entry over ~300 characters (%s chars)\t' "${loc%:*}" "${loc##*:}" "$n")"
      done <<EOF
$(awk "$LONG" "$DOC/meta/TERMINOLOGY.md")
EOF
    fi
    if [ -f "$DOC/README.md" ] && [ -n "$LIST" ]; then
      RECORDS="$RECORDS"$'\n'$(printf '%s\n' "$LIST" | awk -v doc="$DOC/" -v readme="$DOC/README.md" '
        BEGIN { while ((getline l < readme) > 0) txt = txt "\n" l; close(readme); hasci = index(txt, "claude-instructions/") > 0 }
        index($0, doc) == 1 && /\.md$/ {
          rel = substr($0, length(doc) + 1)
          if (rel ~ /(^|\/)README\.md$/) next
          if (index(rel, "brainstorm/") == 1) next
          if (index(rel, "claude-instructions/") == 1 && !hasci) next
          if (index(txt, rel) == 0) printf "warn\t%s\t1\tpage not listed in %sREADME.md\t\n", $0, doc
        }')
    fi ;;
esac

# ---- report ---------------------------------------------------------------------------------------------
FLSET=""
if [ "$FILTER" = 1 ]; then FLSET=$(printf 'CLAUDE.md\n'; refs | sort -u); fi
printf '%s\n' "$RECORDS" | awk -F'\t' -v FILTER="$FILTER" -v FILES="$FILES_SET" -v FLSET="$FLSET" -v DOC="$DOC" '
  BEGIN {
    if (FILTER) {
      n = split(FILES, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1
      n = split(FLSET, a, "\n"); for (i = 1; i <= n; i++) if (a[i] in want) anyfl = 1
    }
  }
  NF < 4 { next }
  {
    sev = $1; path = $2; ln = $3; kind = $4; com = $5
    if (path == "<total>") { if (FILTER && !anyfl) next; path = "CLAUDE.md"; ln = 1 }
    else if (FILTER && !(path in want)) next
    out = path ":" ln ": " sev ": " kind (com != "" ? " (commit " com ")" : "")
    if (out in dup) next
    dup[out] = 1
    if (sev == "error") { ne++; E[ne] = out; if (com != "") incommit = 1 }
    else {
      nw++; W[nw] = out
      if (index(kind, "line reference")) hl = 1
      else if (index(kind, "host path") || index(kind, "public IP")) hh = 1
      else if (index(kind, "dangling")) hd = 1
      else if (index(kind, "force-loaded")) hf = 1
      else if (index(kind, "TERMINOLOGY")) ht = 1
      else if (index(kind, "not listed")) hr = 1
    }
  }
  END {
    for (i = 1; i <= ne; i++) print E[i]
    for (i = 1; i <= nw; i++) print W[i]
    if (ne) {
      print "fix: replace each flagged value with a placeholder ($HOME, <host>, <user>, <ip>, ...) and move anything future agents need to .claude/local/ (untracked; never put a secret there or anywhere in the repo)."
      print "note: `superdoc-lint: allow` on a line skips it. It is for true false positives only (an example that is not a real value), never for a real value."
      if (incommit) print "fix: a flagged value in a commit is in a local commit: repairing the file does not remove it, and the commit has to be rewritten before pushing. Rewriting history is the user'"'"'s decision, so do not do it yourself: report it to the lead, who tells the user."
    }
    if (hh) print "hint: write repo-relative paths and placeholders; machine-specific details go to .claude/local/ (playbook Part 4a)."
    if (hl) print "hint: reference code by symbol (file:symbol), not by line number; line numbers go stale (playbook Part 8)."
    if (hd) print "hint: a dangling @-ref loads nothing: fix the path or remove the reference."
    if (hf) print "hint: force-load budget: move detail to a linked page first, never delete information (playbook Part 9 and Part 10)."
    if (ht) print "hint: trim the entry to what the term is plus a link to the page that holds the detail (playbook Part 9 and Part 10)."
    if (hr) print "hint: add a one-line bullet for the page to " DOC "/README.md."
    if (ne || nw) printf "superdoc-lint: %d error(s), %d warning(s)\n", ne, nw
    exit (ne > 0)
  }'
exit $?
