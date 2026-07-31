# filler-killer

Say what you mean. filler-killer helps you eliminate filler words two ways:

1. **Reflection** — analyzes your [Granola](https://granola.ai) meeting transcripts
   after the fact: which fillers you lean on, how often, and whether you're
   improving week over week.
2. **Real-time** — listens to your mic during a call (Zoom or anything else),
   transcribes **on-device** with Apple's Speech framework (free, private — audio
   never leaves your Mac), and shows a live filler counter in your menu bar.

Only *your* words are analyzed: Granola labels the note-taker's speech as "Me",
and the live listener hears only your own mic.

## What gets counted

| Category | Examples | Post-hoc (Granola) | Live |
|---|---|---|---|
| Vocalized | um, uh, er | ✗ (Granola's ASR strips them) | ✓* |
| Phrases | you know, i mean, kind of, basically, literally, actually | ✓ | ✓ |
| Discourse | filler *like*, sentence-initial *so* | ✓ | ✓ |
| Stutter repeats | "I I", "the the", "we we're" | ✓ | ✓ |

Heuristics keep legitimate uses out: "I'd **like** to", "looks **like**",
"what **kind of** car", "**so** far", "very very" are not counted.

\* Apple's on-device recognition may also drop some um/uh's — it's tuned for
clean dictation. Everything else is caught reliably. The transcriber sits
behind a small interface, so a verbatim engine (e.g. Deepgram with
`filler_words=true`) can be plugged in later if um/uh counting matters to you.

## Setup (macOS)

```bash
git clone https://github.com/davesuzuki-hiya/filler-killer.git
cd filler-killer
./install.sh
```

That's it — the script installs [uv](https://docs.astral.sh/uv) if needed, sets
up everything, and runs `fk doctor`, which checks each prerequisite (Granola
cache, permissions, on-device speech model) and tells you exactly what to fix
if anything's missing. Re-run `uv run fk doctor` any time.

## Use

```bash
uv run fk dashboard        # sync Granola + open the dashboard
uv run fk sync             # just sync (cron-able)
uv run fk listen           # live menu bar counter (macOS)
uv run fk listen --no-menubar   # live counts in the terminal instead
```

`fk listen` sessions are saved when you end them (Ctrl-C in terminal, or
*End Session* in the menu bar) and appear alongside meetings on the dashboard.

### Permissions (first run of `fk listen`)

macOS will prompt for two permissions for your terminal app:
**Microphone** and **Speech Recognition**. Grant both
(System Settings → Privacy & Security). Zoom and filler-killer can read the
mic at the same time.

Notes:
- On-device recognition needs the English dictation model. If `fk listen`
  warns it's falling back to server recognition, enable Dictation once
  (System Settings → Keyboard → Dictation) to download the model.
- Denied a prompt by accident? `tccutil reset SpeechRecognition && tccutil
  reset Microphone`, then run again.

## Mac verification checklist

The test suite runs anywhere, but four things can only be verified on your Mac:

1. **Granola cache format** — run `uv run fk sync`. If it errors or reports 0
   meetings, Granola's undocumented cache format has drifted from the parser in
   `src/fillerkiller/granola/cache_source.py` (fixture:
   `tests/fixtures/cache-v3.json`). `fk sync --api` is the fallback path.
2. **Dashboard sanity** — open a meeting you remember and eyeball the
   highlighted transcript against reality.
3. **Live listener** — `uv run fk listen --no-menubar`, say "um, you know,
   kind of" and watch the counts. First run triggers the permission prompts.
4. **Menu bar during a real Zoom call** — `uv run fk listen`, confirm the
   counter ticks while you speak on the call.

## How it works

```
Granola cache-v3.json ─┐
                       ├─> detector engine ─> SQLite ─> FastAPI dashboard
mic ─> Apple Speech ───┘        (shared)                (localhost:8756)
        (on-device)
```

- `detector/` — pure-function filler engine shared by both paths
- `granola/` — local-cache parser (primary), unofficial-API fallback
- `store/`, `sync.py` — incremental SQLite persistence
- `dashboard/` — FastAPI + Chart.js local web app
- `realtime/` — Apple Speech adapter, session counter, rumps menu bar

## Development

```bash
uv pip install -e . --group dev
uv run pytest
```

Everything Mac-specific is a thin adapter; all logic is tested with fixtures
on any OS.
