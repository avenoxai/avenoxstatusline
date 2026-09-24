# avenoxstatusline

A two-line status line for [Claude Code](https://claude.com/claude-code) with an ASCII pet.

**132 lines of bash. No npm, no node, no build step.**

```
ʕ•ᴥ•ʔ☕  Opus 5 · high · think   5h 41% · 7d 63%
▓▓▓▓░░░░ 62%  ⎇ main*  ● serai:vegrun
```

---

## Why another one

There are plenty of good Claude Code status lines. Two things make this one different.

### 1. It's a shell script, not a package

Your status line re-runs **every few seconds, forever**. Every render is a fresh
process. Spawning a Node runtime on that loop is a strange thing to do to your
laptop.

This is one `bash` file with two dependencies you already have (`git`, `jq`).
Install is a `curl` and one line of JSON. There is nothing to update, nothing to
audit, and nothing in `node_modules`.

### 2. The pet is a gauge, not an ornament

The bear's mood is **derived from session state**, so you can read how the
session is doing without reading any numbers:

| State | Pet | Meaning |
|---|---|---|
| context ≥ 90% | `ʕ⊙ᴥ⊙ʔ‼` red, flailing | you are about to compact |
| context ≥ 75% | `ʕ•﹏•ʔ💦` yellow, sweating | start wrapping up |
| pending approvals | `ʕ•ᴥ•ʔ❗` yellow, alert | something is waiting on you |
| effort `xhigh` / `max` | `ʕ◣_◢ʔ⚡` locked in | the expensive gear is engaged |
| context ≥ 50% | `ʕ◔ᴥ◔ʔ` focused | working |
| otherwise | `ʕ•ᴥ•ʔ` idle | blinks, glances, leans |

Peripheral vision does the monitoring. You only look directly at the line when
the bear changes.

And when nothing is wrong, it does things. Roughly every 10 seconds it pulls a
~4-second stunt — nap, dance, wave, table flip (and sets the table back),
flower, coffee, sparkle, hug, wander.

---

## The trick: animating a stateless script

Claude Code runs the status line command fresh on every render. There is no
process to hold a frame counter in, so conventional animation is impossible.

So the frames are indexed by **wall-clock time** instead of by state:

```bash
T=${SL_TICK:-$(date +%s)}
frame() { local -a a=("${@:2}"); PET="${a[$(( $1 % ${#a[@]} ))]}"; }

frame "$T" "ʕ•ᴥ•ʔ" "ʕ•ᴥ•ʔ" "ʕ-ᴥ-ʔ" "ʕ◕ᴥ◕ʔ"   # idle: blinks
```

Each render independently computes *which frame it is right now*. The script
stays completely stateless and the pet still walks through its frames as time
passes. Stunts use the same idea at two scales: `T % 10` picks the position
within a stunt, `(T / 10) % 9` picks which stunt.

`SL_TICK` pins the clock so you can screenshot or test a specific frame.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/avenoxai/avenoxstatusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 3
  }
}
```

Requirements: `bash` (3.2+, so stock macOS works), `git`, `jq`.
Tested on macOS and Linux. On Windows it runs under Git Bash (which Claude Code
already requires) with `jq` from `winget install jqlang.jq`.

---

## What's on the line

**Line 1** — pet, model, reasoning effort, extended thinking, and your 5-hour /
7-day rate-limit usage.

**Line 2** — context bar (green → yellow → red), context %, branch (`*` = dirty
tracked files), worktree, project badge, pending approvals, sync state.

Every segment hides itself when it has nothing to say. In a plain directory
with no git, line 2 is just the context bar.

---

## Configuration

| Env var | Effect |
|---|---|
| `SL_BADGE_CMD` | Run any command in the repo root; its first stdout line becomes the project badge. A `prefix:value` string renders the prefix dimmed. |
| `SL_NO_SERAI=1` | Disable the built-in Serai badge. |
| `SL_TICK=<int>` | Pin the animation clock. Useful for screenshots and tests. |

Custom badge example:

```bash
export SL_BADGE_CMD='cat .env 2>/dev/null | grep -m1 ^APP_ENV= | cut -d= -f2 | sed "s/^/env:/"'
```

### The Serai badge

Out of the box, if the repo contains `.serai/config.json`, the line shows
`● serai:<repo>` plus pending approval count (`⚑2`) and sync freshness
(`●sync` live / `○sync` stale). That's [Serai](https://serai.run), a control
plane for coding agents.

If you don't use it, nothing renders and nothing is read. `SL_BADGE_CMD` takes
priority over it, and `SL_NO_SERAI=1` turns it off entirely.

---

## Seeing it without installing it

```bash
./demo.sh          # every mood state, side by side
./demo.sh stunts   # all 9 idle stunts, frame by frame
```

`demo.sh` pins `SL_TICK`, so it is also the smoke test — every state, a
non-git directory, and malformed input all render or the script is broken.

---

## Notes on correctness

Two things this script is deliberate about, because both are easy to get wrong:

**Caching.** Git calls are cached ~5s, keyed by `session_id`. Keying a cache off
`$$` looks reasonable and never hits — every render is a new PID.

**Field parsing.** The JSON payload is read **one field per line**, not
tab-separated. Tab is IFS whitespace, so `IFS=$'\t' read -r a b c` silently
collapses runs of tabs and every field after an empty one shifts left. Since
`git_worktree` is empty whenever you are *not* in a worktree — the normal case —
the working directory would land in the worktree slot and the session id in the
working directory slot, quietly killing every git lookup on line 2. `IFS= read -r`
per line keeps empty fields empty.

---

## License

MIT © Avenox
