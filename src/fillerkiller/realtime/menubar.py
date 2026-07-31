"""macOS menu bar counter (rumps). Glanceable, invisible to others on the call.

rumps runs the NSApplication main run loop; SFSpeechRecognizer delivers
results on the main queue by default, so the recognition handler can update
the menu bar title directly — no cross-thread hops. The transcriber starts
from the first timer tick (not before app.run()) so the run loop is alive for
permission prompts and callbacks.
"""


def run_menubar(label: str | None = None) -> int:
    import rumps

    from fillerkiller.realtime.counter import SessionCounter
    from fillerkiller.realtime.listener import SpeechTranscriber, ensure_authorized
    from fillerkiller.store.db import connect

    class FillerKillerApp(rumps.App):
        def __init__(self):
            super().__init__("FK …", quit_button=None)
            self.menu = ["Pause", "End Session & Save", "Discard & Quit"]
            self.counter = SessionCounter()
            self.transcriber = None
            self.paused = False
            self.start_failed = False

        @rumps.timer(1)
        def tick(self, _timer):
            if self.transcriber is None and not self.start_failed:
                try:
                    ensure_authorized()
                    self.transcriber = SpeechTranscriber(self.on_final)
                    self.transcriber.start()
                except Exception as e:
                    self.start_failed = True
                    rumps.alert("filler-killer could not start", str(e))
                    rumps.quit_application()
                    return
            prefix = "⏸ " if self.paused else ""
            self.title = prefix + self.counter.status_line()

        def on_final(self, text: str) -> None:
            if not self.paused:
                self.counter.add_final(text)
                self.title = self.counter.status_line()

        @rumps.clicked("Pause")
        def toggle_pause(self, sender):
            self.paused = not self.paused
            sender.title = "Resume" if self.paused else "Pause"

        @rumps.clicked("End Session & Save")
        def end_and_save(self, _):
            if self.transcriber is not None:
                self.transcriber.stop()
            conn = connect()
            session_id = self.counter.persist(conn, label)
            conn.close()
            rumps.notification(
                "filler-killer",
                f"Session #{session_id} saved",
                f"{self.counter.filler_count} fillers in {self.counter.word_count} "
                f"words ({self.counter.per_100_words}/100w). See fk dashboard.",
            )
            rumps.quit_application()

        @rumps.clicked("Discard & Quit")
        def discard(self, _):
            if self.transcriber is not None:
                self.transcriber.stop()
            rumps.quit_application()

    FillerKillerApp().run()
    return 0
