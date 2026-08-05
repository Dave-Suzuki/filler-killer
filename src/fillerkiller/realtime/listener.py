"""Apple Speech adapter: mic -> on-device recognition -> finalized segments.

macOS only (PyObjC). All Apple imports are deferred so the package imports
fine on other platforms (tests, CI).

Long-session strategy: on-device recognition has no 1-minute cap, but a single
recognition task won't survive a whole meeting — the recognizer finalizes
after pauses and emits routine errors on silence (kAFAssistantErrorDomain
203/1110). So a supervisor restarts the request on every final/error while the
AVAudioEngine tap keeps running; the only loss window is the attribute swap
between requests. Partial results rewrite the whole utterance each time, so
fillers are counted from finalized text only; on an error-restart the last
partial is committed as final so words aren't dropped.

Newer macOS builds add a third case: on-device recognition can amend the
partial forever without EVER finalizing or erroring, so a timer commits any
partial that has stopped changing for ~1.2s (see stabilizer.py) and
restarts the request.

Intentional divergence from the Mac app (M8): the app's SpeechTranscriber
additionally enables Apple voice processing (echo cancellation) and runs a
per-segment pitch gate ("only count my voice", PitchEstimator.swift). This
legacy CLI listener counts everything the mic hears — it has no speaker
filtering and no plans for it.
"""

import sys
import time

from fillerkiller.realtime.stabilizer import PartialStabilizer


def ensure_authorized(timeout: float = 120.0) -> None:
    """Request Speech Recognition permission, driving the run loop so the
    prompt can appear. The mic prompt fires later, at engine start."""
    import queue

    from Foundation import NSDate, NSRunLoop
    from Speech import SFSpeechRecognizer

    AUTHORIZED, DENIED, RESTRICTED = 3, 1, 2
    status = SFSpeechRecognizer.authorizationStatus()
    if status == 0:  # notDetermined -> prompt
        answers: queue.Queue = queue.Queue()
        SFSpeechRecognizer.requestAuthorization_(lambda s: answers.put(int(s)))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            NSRunLoop.currentRunLoop().runUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(0.1)
            )
            try:
                status = answers.get_nowait()
                break
            except queue.Empty:
                continue
    if status in (DENIED, RESTRICTED) or status != AUTHORIZED:
        raise RuntimeError(
            "Speech Recognition permission not granted. Enable it for your "
            "terminal app in System Settings → Privacy & Security → Speech "
            "Recognition. (To re-trigger the prompt: tccutil reset SpeechRecognition)"
        )


class SpeechTranscriber:
    """Wraps AVAudioEngine + SFSpeechRecognizer. Calls on_final(text) with
    each finalized utterance. All callbacks arrive on the main run loop."""

    # Bias recognition toward the tokens we count (helps, not verbatim).
    _CONTEXT = ["um", "uh", "you know", "kind of", "sort of", "i mean", "basically"]

    def __init__(self, on_final, locale: str = "en-US"):
        from AVFoundation import AVAudioEngine
        from Foundation import NSLocale
        from Speech import SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognizer

        self._Request = SFSpeechAudioBufferRecognitionRequest
        self.on_final = on_final
        self.recognizer = SFSpeechRecognizer.alloc().initWithLocale_(
            NSLocale.localeWithLocaleIdentifier_(locale)
        )
        if self.recognizer is None or not self.recognizer.isAvailable():
            raise RuntimeError(
                f"Speech recognizer unavailable for locale {locale!r}. "
                "Enable Dictation once (System Settings → Keyboard → Dictation) "
                "to download the on-device model."
            )
        self.on_device = bool(self.recognizer.supportsOnDeviceRecognition())

        self.engine = AVAudioEngine.alloc().init()
        self._node = self.engine.inputNode()
        fmt = self._node.outputFormatForBus_(0)  # never hardcode sample rate
        self.request = None
        self.task = None
        self._last_partial = ""
        self._stabilizer = PartialStabilizer()
        self._timer = None
        self._running = False

        # Tap runs on the realtime audio thread: append the buffer, nothing else.
        # Keep a Python reference or PyObjC GC silently kills the callback.
        def tap(buffer, when):
            req = self.request
            if req is not None:
                req.appendAudioPCMBuffer_(buffer)

        self._tap = tap
        self._node.installTapOnBus_bufferSize_format_block_(0, 1024, fmt, tap)

    def _start_request(self) -> None:
        req = self._Request.alloc().init()
        req.setShouldReportPartialResults_(True)
        if self.on_device:
            req.setRequiresOnDeviceRecognition_(True)
        req.setContextualStrings_(self._CONTEXT)
        self._last_partial = ""
        self._stabilizer.reset()

        def handler(result, error):
            # A cancelled request can still deliver late results/errors;
            # acting on them would double-commit or cancel the current task.
            if not self._running or self.request is not req:
                return
            if result is not None:
                text = str(result.bestTranscription().formattedString())
                if result.isFinal():
                    self._last_partial = ""
                    self._stabilizer.reset()
                    if text.strip():
                        self.on_final(text)
                    self._restart()
                    return
                self._last_partial = text
                self._stabilizer.observe(text, time.monotonic())
            if error is not None:
                # Routine on silence (203 retry / 1110 no speech): commit what
                # we heard, then start a fresh request.
                pending = self._last_partial.strip()
                self._last_partial = ""
                self._stabilizer.reset()
                if pending:
                    self.on_final(pending)
                self._restart()

        self._handler = handler  # keep a reference (GC)
        self.request = req
        self.task = self.recognizer.recognitionTaskWithRequest_resultHandler_(req, handler)

    def _restart(self) -> None:
        old_task, self.task = self.task, None
        self.request = None  # tap stops feeding the old request immediately
        if old_task is not None:
            old_task.cancel()
        if self._running:
            self._start_request()

    def _commit_stable(self) -> None:
        """Timer tick: a partial that has stopped changing IS the final —
        some on-device configurations never send isFinal or an error."""
        if not self._running:
            return
        stable = self._stabilizer.take_stable(time.monotonic())
        if stable is None:
            return
        self._last_partial = ""
        self.on_final(stable)
        self._restart()

    def start(self) -> None:
        from Foundation import NSTimer

        self._running = True
        self._start_request()
        self.engine.prepare()
        ok, err = self.engine.startAndReturnError_(None)  # PyObjC returns a tuple
        if not ok:
            self._running = False
            raise RuntimeError(
                f"Could not start the audio engine: {err}. Check the Microphone "
                "permission for your terminal app."
            )
        # Keep a reference or PyObjC GC silently kills the timer block.
        self._timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            0.25, True, lambda _timer: self._commit_stable()
        )

    def stop(self) -> None:
        self._running = False
        if self._timer is not None:
            self._timer.invalidate()
            self._timer = None
        if self._last_partial.strip():
            self.on_final(self._last_partial)
            self._last_partial = ""
        self._stabilizer.reset()
        try:
            self._node.removeTapOnBus_(0)
        except Exception:
            pass
        self.engine.stop()
        if self.request is not None:
            self.request.endAudio()
        if self.task is not None:
            self.task.cancel()
        self.request = None
        self.task = None


def run_terminal(label: str | None = None) -> int:
    """fk listen --no-menubar: live counts in the terminal (Mac checkpoint 3)."""
    from Foundation import NSDate, NSRunLoop

    from fillerkiller.realtime.counter import SessionCounter
    from fillerkiller.store.db import connect

    counter = SessionCounter()

    def on_final(text: str) -> None:
        new = counter.add_final(text)
        for hit in new:
            print(f"  ✗ {hit.term} ({hit.category})")
        print(f"[{counter.status_line()}] {text}")

    ensure_authorized()
    transcriber = SpeechTranscriber(on_final)
    transcriber.start()
    if not transcriber.on_device:
        print(
            "warning: on-device model unavailable — using Apple's server "
            "recognition (1-minute segments, usage caps)",
            file=sys.stderr,
        )
    print("listening — speak normally; Ctrl-C to end and save the session")
    try:
        while True:
            NSRunLoop.currentRunLoop().runUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(0.25)
            )
    except KeyboardInterrupt:
        pass
    transcriber.stop()
    conn = connect()
    session_id = counter.persist(conn, label)
    conn.close()
    print(
        f"\nsession #{session_id} saved: {counter.filler_count} fillers in "
        f"{counter.word_count} words ({counter.per_100_words}/100w) — see fk dashboard"
    )
    return 0
