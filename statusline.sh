#!/usr/bin/env bash
# avenoxstatusline — a two-line Claude Code status line with an ASCII pet.
#
#   Line 1: <pet>  model · effort · thinking      5h% · 7d%
#   Line 2: <ctx bar> %   ⎇ branch*  ⑂worktree   ● badge  ⚑approvals  ●sync
#
# The pet is a gauge, not an ornament: its mood tracks context pressure,
# reasoning effort, and pending approvals, so you can read session state
# without reading any numbers.
#
# Performance: the status line re-runs constantly, so git + project reads are
# cached ~5s per session_id (never key the cache off $$ — each render is a new
# process and you would never get a hit).
# Robustness: every external call is guarded; the script always prints, exit 0.
#
# Env knobs:
#   SL_BADGE_CMD   command whose first stdout line becomes the project badge
#   SL_NO_SERAI=1  disable the built-in Serai (.serai/config.json) badge
#   SL_TICK        pin the animation clock (for tests/screenshots)
#
# License: MIT

# Prepend common package-manager bins only if they exist.
# Windows (Git Bash): Claude Code's PATH is captured at launch, so a jq installed
# with winget afterwards stays invisible until restart; look in winget's package
# folder directly. The glob stays literal and fails -d on macOS/Linux.
for d in /opt/homebrew/bin /usr/local/bin \
         "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac
done
export PATH

if ! command -v jq >/dev/null 2>&1; then
  printf 'avenoxstatusline: jq not found on PATH\n'
  exit 0
fi

input=$(cat)

# ---- colors (literal ESC so we can print with %s) ----
ESC=$'\033'; R="${ESC}[0m"; B="${ESC}[1m"; D="${ESC}[2m"
CY="${ESC}[36m"; GR="${ESC}[32m"; YE="${ESC}[33m"; RD="${ESC}[31m"; MG="${ESC}[35m"

# ---- parse stdin in one jq pass ----
# One field per LINE, not tab-separated: tab is IFS whitespace, so `read` with
# IFS=$'\t' silently collapses runs of tabs and every field after an empty one
# shifts left. git_worktree is empty whenever you are not in a worktree, which
# would push CWD into WT and the session id into CWD — killing every git lookup.
# `IFS= read -r` per line keeps empty fields empty and preserves spaces.
{
  IFS= read -r MODEL; IFS= read -r CTX;   IFS= read -r EFFORT
  IFS= read -r THINK; IFS= read -r COST;  IFS= read -r FIVE
  IFS= read -r SEVEN; IFS= read -r WT;    IFS= read -r CWD
  IFS= read -r SID
} < <(
  printf '%s' "$input" | jq -r '
    [ (.model.display_name // "?"),
      (.context_window.used_percentage // 0 | floor),
      (.effort.level // ""),
      (.thinking.enabled // false),
      (.cost.total_cost_usd // 0),
      (.rate_limits.five_hour.used_percentage // -1 | floor),
      (.rate_limits.seven_day.used_percentage // -1 | floor),
      (.workspace.git_worktree // ""),
      (.workspace.current_dir // .cwd // "."),
      (.session_id // "nosess")
    ] | .[] | tostring | gsub("[\r\n\t]"; " ")' 2>/dev/null | tr -d '\r'
  # ^ native jq.exe on Windows writes CRLF. Without this every field keeps a
  #   trailing \r: numbers fail int() and render as 0%, and empty fields
  #   (git_worktree) turn non-empty. The gsub above can't help — it runs
  #   before jq's own line ending is added.
)

# ---- sanitize numerics (never let arithmetic crash the bar) ----
int() { case "$1" in ''|*[!0-9-]*) echo "${2:-0}";; *) echo "$1";; esac; }
MODEL=${MODEL:-?}; CTX=$(int "$CTX" 0); FIVE=$(int "$FIVE" -1); SEVEN=$(int "$SEVEN" -1)
[ -z "$COST" ] && COST=0
CWD=${CWD:-.}; SID=${SID:-nosess}

# ---- git + project badge (cached ~5s by session_id) ----
CACHE="${TMPDIR:-/tmp}/cc-sl-${SID//[^A-Za-z0-9]/_}.cache"
now=$(date +%s 2>/dev/null || echo 0)
# stat -f is BSD/macOS, stat -c is GNU/Linux — try both before giving up.
mt=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
if [ -s "$CACHE" ] && [ $((now - mt)) -lt 5 ]; then
  IFS=$'\t' read -r BRANCH DIRTY BADGE SYNC APPROV < "$CACHE"
else
  BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null \
           || git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")
  DIRTY=""; [ -n "$(git -C "$CWD" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ] && DIRTY="*"
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")
  BADGE=""; SYNC=""; APPROV=0

  # Generic badge hook: any command, first line of stdout wins.
  if [ -n "$SL_BADGE_CMD" ]; then
    BADGE=$( (cd "$ROOT" 2>/dev/null && eval "$SL_BADGE_CMD") 2>/dev/null | head -1 | tr -d '\t\n' )
  fi

  # Built-in badge: Serai-governed repos (https://serai.run). Opt out with SL_NO_SERAI=1.
  if [ -z "$BADGE" ] && [ -z "$SL_NO_SERAI" ] && [ -f "$ROOT/.serai/config.json" ]; then
    BADGE="serai:$(basename "$ROOT")"
    SS="$ROOT/.serai/cache/sync.state.json"
    if [ -f "$SS" ]; then
      hb=$(jq -r '(.lastHeartbeatAt // .heartbeatAt // .lastPullAt // .updatedAt // empty)
                  | if type=="number" then . else (try (fromdateiso8601) catch empty) end' "$SS" 2>/dev/null)
      if [ -n "$hb" ]; then [ $((now - ${hb%.*})) -lt 180 ] && SYNC="live" || SYNC="stale"; fi
    fi
    SNAP="$ROOT/.serai/cache/snapshot.json"
    if [ -f "$SNAP" ]; then
      APPROV=$(jq -r '[ (.approvalRequests // .approvals // [])[]
                        | select(((.status // "")|ascii_downcase) | test("pending|requested|open")) ] | length' "$SNAP" 2>/dev/null)
    fi
  fi
  APPROV=$(int "$APPROV" 0)
  printf '%s\t%s\t%s\t%s\t%s' "$BRANCH" "$DIRTY" "$BADGE" "$SYNC" "$APPROV" > "$CACHE" 2>/dev/null
fi
APPROV=$(int "$APPROV" 0)
[ ${#BRANCH} -gt 24 ] && BRANCH="${BRANCH:0:23}…"

# ---- the pet: ALWAYS animating; idle blink/glance + a stunt every ~10s ----
# Each render is a fresh process, so "animation" = frames chosen by wall-clock
# time (T). The bar re-renders on every event + every refreshInterval seconds,
# so the pet steps through frames as time passes. (SL_TICK overrides T for tests.)
T=${SL_TICK:-$(date +%s 2>/dev/null || echo 0)}
frame() { local -a a=("${@:2}"); PET="${a[$(( $1 % ${#a[@]} ))]}"; }   # frame <tick> f0 f1 …

PETC="$CY"
if   [ "$CTX" -ge 90 ]; then PETC="$RD"; frame "$T" "ʕ⊙ᴥ⊙ʔ‼" "ʕ☉ᴥ☉ʔ‼" "ʕノ⊙ᴥ⊙ʔノ‼" "ʕ⊙▱⊙ʔ‼"     # panic
elif [ "$CTX" -ge 75 ]; then PETC="$YE"; frame "$T" "ʕ•﹏•ʔ💦" "ʕ°﹏°ʔ💦" "ʕ-﹏-ʔ💦" "ʕ•﹏•ʔ"        # sweating
elif [ "$APPROV" -gt 0 ]; then PETC="$YE"; frame "$T" "ʕ•ᴥ•ʔ❗" "ʕ◕ᴥ◕ʔ❗" "ʕ•ᴥ•ʔ‼" "ʕ◕ᴥ◕ʔ❗"     # alert
else
  p=$(( T % 10 ))
  if [ "$p" -lt 4 ]; then                         # ~4s stunt every 10s, animated frame-by-frame
    case $(( (T / 10) % 9 )) in
      0) frame "$p" "ʕ-ᴥ-ʔ z" "ʕ-ᴥ-ʔ zz" "ʕ-ᴥ-ʔ zzz" "ʕ-ᴥ-ʔ 💤";;          # nap
      1) frame "$p" "ヽʕ•ᴥ•ʔ" "ʕ•ᴥ•ʔﾉ" "ヽʕ•ᴥ•ʔﾉ" "ʕ•ᴥ•ʔ";;                    # dance
      2) frame "$p" "ʕ•ᴥ•ʔ" "ʕ•ᴥ•ʔﾉ" "ʕ•ᴥ•ʔノﾞ" "ʕ•ᴥ•ʔﾉ";;                     # wave
      3) frame "$p" "ʕ•ᴥ•ʔ┳━┳" "ʕ •ᴥ•ʔ┳━┳" "ʕノ•ᴥ•ʔノ ︵┻━┻" "┬─┬ノʕ•ᴥ•ʔ";;   # tableflip → restore
      4) frame "$p" "ʕ•ᴥ•ʔ" "ʕ•ᴥ•ʔ✿" "ʕ◕ᴥ◕ʔ✿" "ʕ•ᴥ•ʔ❀";;                      # flower
      5) frame "$p" "ʕ•ᴥ•ʔ☕" "ʕ-ᴥ-ʔ☕" "ʕ•ᴥ•ʔ♨" "ʕ◕ᴥ◕ʔ☕";;                    # coffee
      6) PETC="$MG"; frame "$p" "ʕ•ᴥ•ʔ✦" "ʕ•ᴥ•ʔ✧" "ʕ◕ᴥ◕ʔ✨" "ʕ•ᴥ•ʔ✦";;         # sparkle
      7) frame "$p" "ʕっ•ᴥ•ʔっ" "ʕっ◕ᴥ◕ʔっ" "ʕっ•ᴥ•ʔっ♡" "ʕ•ᴥ•ʔ";;               # hug
      8) frame "$p" "ʕ•ᴥ•ʔ" " ʕ•ᴥ•ʔ" "  ʕ•ᴥ• ʔ?" " ʕ◕ᴥ◕ʔ";;                    # wander / peek
    esac
  elif [ "$EFFORT" = xhigh ] || [ "$EFFORT" = max ]; then
    PETC="$YE"; frame "$T" "ʕ•ᴥ•ʔ⚡" "ʕ◣_◢ʔ⚡" "ʕ•ᴥ•ʔ⚡" "ʕ-ᴥ-ʔ⚡"               # locked in
  elif [ "$CTX" -ge 50 ]; then
    frame "$T" "ʕ◔ᴥ◔ʔ" "ʕ◔ᴥ◔ʔ" "ʕ-ᴥ-ʔ" "ʕ◑ᴥ◑ʔ" "ʕ◔ᴥ◔ʔ" "ʕ◔ᴥ◔ʔﾞ"               # focused
  else
    frame "$T" "ʕ•ᴥ•ʔ" "ʕ•ᴥ•ʔ" "ʕ-ᴥ-ʔ" "ʕ◕ᴥ◕ʔ" "ʕ•ᴥ•ʔ" "ʕ •ᴥ• ʔ" "ʕ•ᴥ•ʔ" "ʕᴥ•ʔ"  # idle: blink / glance / lean
  fi
fi

# ---- context bar (8 wide) + band color ----
if   [ "$CTX" -ge 80 ]; then CC="$RD"; elif [ "$CTX" -ge 50 ]; then CC="$YE"; else CC="$GR"; fi
bw=8; fill=$((CTX*bw/100)); [ $fill -gt $bw ] && fill=$bw; [ $fill -lt 0 ] && fill=0; empty=$((bw-fill))
bar=""; i=0; while [ $i -lt $fill ]; do bar="${bar}▓"; i=$((i+1)); done
i=0; while [ $i -lt $empty ]; do bar="${bar}░"; i=$((i+1)); done

# ---- assemble line 1 ----
L1="${PETC}${PET}${R}  ${B}${MODEL}${R}"
[ -n "$EFFORT" ]   && L1="${L1} ${D}·${R} ${EFFORT}"
[ "$THINK" = true ] && L1="${L1} ${D}·${R} ${MG}think${R}"
[ "$FIVE"  -ge 0 ] && L1="${L1}   ${D}5h${R} ${FIVE}%"
[ "$SEVEN" -ge 0 ] && L1="${L1} ${D}·${R} ${D}7d${R} ${SEVEN}%"

# ---- assemble line 2 ----
L2="${CC}${bar}${R} ${CC}${CTX}%${R}"
[ -n "$BRANCH" ] && L2="${L2}  ${D}⎇${R} ${BRANCH}${DIRTY:+${YE}*${R}}"
[ -n "$WT" ]     && L2="${L2} ${D}⑂${WT}${R}"
# badge: dim the "prefix:" part when present, so the value stays readable
if [ -n "$BADGE" ]; then
  case "$BADGE" in
    *:*) L2="${L2}  ${GR}●${R} ${D}${BADGE%%:*}:${R}${BADGE#*:}";;
    *)   L2="${L2}  ${GR}●${R} ${BADGE}";;
  esac
fi
[ "$APPROV" -gt 0 ] && L2="${L2}  ${RD}⚑${APPROV}${R}"
[ "$SYNC" = live ]  && L2="${L2}  ${GR}●sync${R}"
[ "$SYNC" = stale ] && L2="${L2}  ${D}○sync${R}"

printf '%s\n%s\n' "$L1" "$L2"
exit 0
