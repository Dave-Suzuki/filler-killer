# Filler Killer

Say what you mean. Filler Killer counts the "um"s, "you know"s and "like"s
you lean on, so your next meeting has fewer of them. It works two ways:

1. **Reflection** — analyzes your [Granola](https://granola.ai) meeting
   transcripts after the fact: which fillers you favor, how often, and
   whether you're improving week over week.
2. **Real-time** — listens to your mic during a call (Zoom or anything
   else), transcribes **on-device** with Apple's speech engine, and nudges
   you with a discreet on-screen counter — invisible to screen shares.

**Private by design:** audio and transcripts never leave your Mac, and only
*your* words are analyzed — never your colleagues'.

## Get started (5 minutes)

### 1. Install the app

Download the latest `FillerKiller-b<number>` from this repo's
[Actions page](../../actions/workflows/macapp.yml) (pick the newest green
run, artifact at the bottom) — or ask Dave for the current build.

- If it contains **`FillerKiller-b<number>.dmg`**: open it, drag
  Filler Killer to Applications, launch it. Done.
- If it contains **`FillerKiller-app.zip`** (unsigned dev build): unzip,
  then clear macOS quarantine once before first launch — paste this in
  Terminal from the folder holding the app:

  ```bash
  xattr -dr com.apple.quarantine FillerKiller.app && open FillerKiller.app
  ```

Look for the waveform icon in your menu bar.

### 2. Grant two permissions

Click **Start Listening** once. macOS asks for **Microphone** and
**Speech Recognition** — allow both. Everything runs on-device; if the app
says the offline model is missing, enable Dictation once
(System Settings → Keyboard → Dictation) to download it.

### 3. Connect Granola (recommended)

In the app popover: **Connect Granola…**

1. In the Granola desktop app, create an API key (Settings → API keys —
   on some plans a workspace admin must enable personal API keys first).
2. Paste the `grn_…` key and hit **Validate & Connect**.
3. Fill in **who you are**: the name(s) Granola labels you with in
   transcripts (e.g. `Jane Doe,Jane`) and your Granola account email.

That last step matters: in a Granola transcript, "Me" is whoever *captured*
the note. Your name + email let Filler Killer count **your** lines in
meetings a colleague recorded, and skip meetings you didn't speak in at all.

Meetings then sync automatically — on launch, within ~15 minutes of a new
note appearing, on wake from sleep, and shortly after your own sessions end.
There's also a **Sync Granola** button front and center.

## Using it

- **Start Listening** before (or during) a call. A small pill flashes when
  a filler slips out, with a green "clean run" variant when you're on a
  streak. The pill never steals focus and is hidden from Zoom/Meet/Teams
  screen shares. The bell icon mutes it for a session.
- **End Session → Save** — then hit **View Session Report** to see your
  transcript with every filler highlighted.
- **Trends** shows your rate over time (Day / 3 Days / Week / Month /
  3 Months / All), your favorite filler words, and every meeting and
  session — click any of them for the highlighted transcript.

## What gets counted

| Category | Examples | Granola (post-hoc) | Live |
|---|---|---|---|
| Vocalized | um, uh, er | ✗ (Granola's ASR strips them) | ✓* |
| Phrases | you know, i mean, kind of, basically, literally, actually | ✓ | ✓ |
| Discourse | filler *like*, sentence-initial *so* | ✓ | ✓ |
| Stutter repeats | "I I", "the the", "we we're" | ✓ | ✓ |

Heuristics keep legitimate uses out: "I'd **like** to", "looks **like**",
"what **kind of** car", "**so** far", "very very" are not counted.

\* Apple's on-device recognition also drops some um/uh's — it's tuned for
clean dictation. Everything else is caught reliably. The transcriber sits
behind a small interface, so a verbatim engine (e.g. Deepgram with
`filler_words=true`) can be plugged in later if um/uh counting matters.

## Troubleshooting

- **Counts stay at zero while listening** — Settings → Advanced →
  **Copy Diagnostics** and read the last lines: "no audio from the mic"
  means check your input device; "the speech model may be missing" means
  enable Dictation once (System Settings → Keyboard).
- **A meeting shows fillers that aren't yours** (or one you didn't attend
  appears) — set your name(s) and email in Connect Granola, then Sync Now;
  history re-scores itself.
- **Denied a permission by accident** — `tccutil reset SpeechRecognition &&
  tccutil reset Microphone`, then start a session again.
- **Version for bug reports** — Settings → Advanced (or hover the popover's
  Quit button).

---

## Python CLI & web dashboard (optional)

The original Python tool remains fully usable — same detector, same
database schema — and is handy for cron jobs or a browser-based dashboard:

```bash
git clone https://github.com/davesuzuki-hiya/filler-killer.git
cd filler-killer
./install.sh                    # installs uv, sets up, runs `fk doctor`
```

```bash
export GRANOLA_API_KEY=grn_...          # see "Connect Granola" above
export FK_MY_NAME="Jane Doe,Jane"       # names Granola labels you with
export FK_MY_EMAIL="jane@company.com"   # your Granola account email

uv run fk dashboard        # sync Granola + open the web dashboard
uv run fk sync             # just sync (cron-able)
uv run fk listen           # live counter in the menu bar
uv run fk listen --no-menubar   # live counts in the terminal
uv run fk doctor           # checks every prerequisite and says what to fix
```

On pre-encryption Granola installs (< 7.427) with a readable local cache,
no API key is needed — the cache is read directly.

### Speaker attribution details

Per meeting: a named speaker matching `FK_MY_NAME` (full or first name,
case-insensitive) is counted; otherwise "Me" is — **unless** the note's
owner metadata says someone else captured it and you never speak, in which
case the meeting isn't counted at all (the transcript stays browsable).
Every sync re-checks stored meetings, so changing these settings heals
history without refetching. With nothing configured, "Me" is always counted.

## For developers

```
Granola API / cache ─┐
                     ├─> detector engine ─> SQLite ─> dashboards
mic ─> Apple Speech ─┘        (shared)               (web + native)
      (on-device)
```

The Python package (`src/fillerkiller/`) is the **reference implementation
and cross-language test oracle** for the native app:

- `detector/` — pure-function filler engine shared by both paths
- `granola/` — official-API source, local-cache parser, legacy fallback,
  speaker/owner attribution
- `store/`, `sync.py` — incremental SQLite persistence (re-attribution heals
  history on every sync)
- `dashboard/` — FastAPI + Chart.js local web app
- `realtime/` — Apple Speech adapter (stability-commit for recognizers that
  never finalize), session counter, rumps menu bar

The native app (`macapp/`):

- `FillerKillerKit/` — pure Swift, builds and tests on Linux: DetectorKit
  (provably identical to the Python detector via `fixtures/*/golden.json`),
  SessionKit (counters, trend aggregation), SpeechEngine (SFSpeechRecognizer
  supervisor + PartialStabilizer; compiled out off-macOS)
- `FillerKillerMacKit/` — mac-only: SessionStore (GRDB, same SQLite schema —
  the Python tool's fk.db imports as a file copy), Retro queries, Granola
  client + sync engine (key in Keychain)
- `FillerKiller/` — app shell (menu bar, HUD, Trends, onboarding), generated
  by XcodeGen from `macapp/project.yml`

```bash
uv pip install -e . --group dev && uv run pytest      # Python suite
swift test --package-path macapp/FillerKillerKit      # cross-platform kit
swift test --package-path macapp/FillerKillerMacKit   # mac-only kit
python3 tools/gen_golden.py                           # regenerate oracle fixtures (review the diff!)
```

CI (`.github/workflows/macapp.yml`) tests both packages on Linux + macOS and
uploads a `FillerKiller-b<run#>` artifact per run. With Developer ID secrets
configured the artifact is a **notarized DMG** (no-terminal install);
without them it's an ad-hoc zip. Secrets (repo Settings → Secrets and
variables → Actions): `MACOS_CERT_P12` (base64 .p12, needs an Apple
Developer Program membership), `MACOS_CERT_PASSWORD`, `APPLE_ID`,
`APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (app-specific password for
`notarytool`).

### On-Mac verification checklist

1. **Live counting** — Start Session, speak "so, you know, kind of…" and
   pause: count ticks ~2s after each pause.
2. **Persistence** — End & Save, quit, reopen: session survives; View
   Session Report opens the highlighted transcript.
3. **HUD** — pill flashes without stealing typing focus; green clean-run at
   50+ clean words; the far side of a screen share must not see it.
4. **Trends** — numbers match the Python dashboard on the same database;
   range picker; transcript drill-down highlights.
5. **Granola** — connect with a grn_ key: first sync matches `fk sync`;
   meetings captured by others attribute to your named lines; meetings you
   didn't speak in are not counted.
