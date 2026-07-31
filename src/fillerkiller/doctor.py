"""fk doctor — check every setup prerequisite and say exactly what to fix."""

import sys

OK, WARN, FAIL = "✓", "!", "✗"


def _line(mark: str, label: str, detail: str = "") -> None:
    print(f" {mark} {label}" + (f" — {detail}" if detail else ""))


def run_doctor() -> int:
    from fillerkiller import config

    failures = 0
    print("filler-killer doctor\n")

    # --- Reflection path -----------------------------------------------------
    print("Reflection (Granola):")
    api_key = config.granola_api_key()
    if api_key:
        try:
            from fillerkiller.granola.public_api_source import PublicApiSource

            PublicApiSource(api_key).ping()
            _line(OK, "Granola official API", "key accepted — fk sync will use it")
        except Exception as e:
            failures += 1
            _line(FAIL, "Granola official API", str(e))
    else:
        cache = config.granola_cache_path()
        gdir = config.granola_dir()
        # Granola >= 7.427 fingerprint: encrypted cache present, no storage.dek.
        encrypted = (gdir / "cache-v6.json.enc").exists() and not (gdir / "storage.dek").exists()
        if encrypted:
            failures += 1
            _line(
                FAIL,
                "Granola encrypts its local data on this version (>= 7.427)",
                "the cache can't be read locally. Fix: generate an API key in the "
                "Granola desktop app (Settings → API keys; a workspace admin may "
                "need to enable personal API keys), then set GRANOLA_API_KEY=grn_... "
                "in your shell profile and re-run fk doctor",
            )
        elif cache.exists():
            try:
                from fillerkiller.granola.cache_source import CacheSource

                meetings = CacheSource(cache).meetings()
                with_words = sum(1 for m in meetings if m.utterances)
                _line(OK, "Granola cache", f"{with_words} meetings with transcripts found")
                if with_words == 0:
                    _line(
                        WARN,
                        "No transcripts in the cache",
                        "cache format may have drifted — set GRANOLA_API_KEY to use "
                        "the official API instead",
                    )
            except Exception as e:
                failures += 1
                _line(FAIL, "Granola cache unreadable", str(e))
        else:
            failures += 1
            _line(
                FAIL,
                "Granola cache not found",
                f"looked at {cache}. Is the Granola desktop app installed? "
                "(Override with FK_GRANOLA_CACHE, or set GRANOLA_API_KEY to use "
                "the official API.)",
            )

    try:
        from fillerkiller.store.db import connect

        conn = connect()
        n = conn.execute("SELECT COUNT(*) c FROM meetings").fetchone()["c"]
        conn.close()
        _line(OK, "Database", f"{config.db_path()} ({n} meetings synced so far)")
    except Exception as e:
        failures += 1
        _line(FAIL, "Database", str(e))

    # --- Real-time path ------------------------------------------------------
    print("\nReal-time listener:")
    if sys.platform != "darwin":
        _line(WARN, "Not macOS", "fk listen is Mac-only; reflection works here")
        print()
        return 1 if failures else 0

    try:
        import rumps  # noqa: F401

        _line(OK, "rumps (menu bar)")
    except ImportError:
        failures += 1
        _line(FAIL, "rumps missing", 'install with: uv pip install -e ".[realtime]"')

    try:
        from Foundation import NSLocale
        from Speech import SFSpeechRecognizer

        _line(OK, "Apple Speech framework (PyObjC)")
        status = SFSpeechRecognizer.authorizationStatus()
        names = {0: "not asked yet", 1: "denied", 2: "restricted", 3: "authorized"}
        if status == 3:
            _line(OK, "Speech Recognition permission", "authorized")
        elif status == 0:
            _line(WARN, "Speech Recognition permission", "first fk listen will prompt")
        else:
            failures += 1
            _line(
                FAIL,
                "Speech Recognition permission",
                f"{names.get(status, status)} — System Settings → Privacy & Security → "
                "Speech Recognition, or: tccutil reset SpeechRecognition",
            )
        rec = SFSpeechRecognizer.alloc().initWithLocale_(
            NSLocale.localeWithLocaleIdentifier_("en-US")
        )
        if rec is not None and rec.isAvailable():
            if rec.supportsOnDeviceRecognition():
                _line(OK, "On-device recognition", "free + private, no time limits")
            else:
                _line(
                    WARN,
                    "On-device model not downloaded",
                    "enable Dictation once (System Settings → Keyboard → Dictation); "
                    "until then Apple's server recognition is used",
                )
        else:
            failures += 1
            _line(FAIL, "Speech recognizer unavailable for en-US")
    except ImportError:
        failures += 1
        _line(FAIL, "PyObjC Speech missing", 'install with: uv pip install -e ".[realtime]"')

    print()
    if failures:
        print(f"{failures} problem(s) to fix — see above.")
        return 1
    print("All good. Try: uv run fk dashboard")
    return 0
