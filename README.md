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
access, permissions, on-device speech model) and tells you exactly what to fix
if anything's missing. Re-run `uv run fk doctor` any time.

### Granola access

Granola **≥ 7.427 encrypts all its local data** with a key only Granola itself
can read, so filler-killer uses the **official Granola API**:

1. In the Granola desktop app, generate an API key (Settings → API keys).
   On non-Business plans a workspace admin may need to enable personal API
   keys first.
2. Add to your shell profile: `export GRANOLA_API_KEY=grn_...`
3. `uv run fk doctor` to confirm, then `uv run fk dashboard`.

On older Granola installs with a readable local cache (`cache-v3.json` /
`cache-v6.json`), no key is needed — the cache is read directly.

### Whose words get counted (`FK_MY_NAME`, `FK_MY_EMAIL`)

In a Granola transcript, **"Me" is whoever captured the note** — their
microphone. For meetings someone *else* recorded and shared with you, your
words appear under your display name instead, and counting "Me" would pin the
note-taker's fillers on you. Set the names Granola labels you with, and your
Granola account email:

```bash
export FK_MY_NAME="Dave Suzuki,Dave"
export FK_MY_EMAIL="dave.suzuki@hiya.com"
```

Per meeting:
- a named speaker matching you (full or first name, case-insensitive) is
  counted;
- otherwise "Me" is counted — **unless** the note's owner metadata says
  someone else captured it, in which case the meeting isn't counted at all
  (you weren't there, or never spoke; the transcript stays browsable).

The next `fk sync` also re-checks every already-synced meeting from its
stored transcript and owner metadata, so history heals without refetching.
Unset, behavior is unchanged: "Me" is always counted.

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
   `tests/fixtures/cache-v3.json`) — or your Granola encrypts locally and you
   need `GRANOLA_API_KEY` (see "Granola access" above; `fk doctor` will say).
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
- `granola/` — official-API source (GRANOLA_API_KEY), local-cache parser for
  older installs, legacy unofficial-API fallback
- `store/`, `sync.py` — incremental SQLite persistence
- `dashboard/` — FastAPI + Chart.js local web app
- `realtime/` — Apple Speech adapter, session counter, rumps menu bar

## Native macOS app (macapp/)

The Python tool above is now the **reference implementation and test oracle**
for Filler Killer.app — a native SwiftUI menu bar app being built for public
release (see the milestone plan in CLAUDE.md).

- `macapp/FillerKillerKit/` — pure Swift package, builds and tests on Linux:
  DetectorKit (provably identical to the Python detector via
  `fixtures/detector/golden.json`), SessionKit (live session counter, trend
  aggregation), SpeechEngine (SFSpeechRecognizer supervisor; compiled out off
  macOS).
- `macapp/FillerKillerMacKit/` — mac-only package: SessionStore (GRDB, same
  SQLite schema as the Python tool — fk.db imports as a file copy), retro
  queries, Granola official-API client + sync engine (grn_ key in Keychain).
- `macapp/FillerKiller/` — app shell: menu bar session controls with live mic
  level, floating HUD alerts (screen-share-hidden) with the clean-run
  mechanic, native Trends window (Swift Charts), Granola connect window.
  Project generated by XcodeGen from `macapp/project.yml`.
- CI (`.github/workflows/macapp.yml`) builds/tests on Linux + macOS and
  uploads an ad-hoc-signed `FillerKiller-b<run#>` artifact per run.

### On-Mac verification checklist (current milestones)

1. **Live counting (M2)** — Start Session, speak "um, so, you know…": bar
   glyph moves with your voice, count ticks; diagnostics lines visible in the
   menu while listening.
2. **Persistence (M3)** — End & Save, quit, reopen: session survives; first
   launch imported the Python tool's fk.db (meeting count in idle menu).
3. **HUD (M4)** — pill flashes on fillers without stealing typing focus
   (type in a doc while it fires); green clean-run variant at 50+ clean
   words; on a Zoom/Meet screen share the OTHER side must not see the pill;
   Mute Alerts silences flashes while counting continues.
4. **Trends (M5)** — Open Trends: numbers must match the Python dashboard on
   the same database; range picker; drill into a transcript and check
   highlighted fillers.
5. **Granola (M6)** — Connect Granola with a grn_ key: validation, first
   sync counts match `fk sync`, live-only mode (no key) still works.

## Development

```bash
uv pip install -e . --group dev
uv run pytest
```

Everything Mac-specific is a thin adapter; all logic is tested with fixtures
on any OS.
