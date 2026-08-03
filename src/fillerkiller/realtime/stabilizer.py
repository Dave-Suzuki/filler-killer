"""Commit-on-stability for partial transcriptions.

Newer macOS on-device recognition can amend a partial forever without ever
delivering isFinal — and without the routine silence errors server mode
emits — so a pipeline that only counts finalized segments counts nothing
(field report: "audio flowing", "hearing you…", then silence). A partial
that stops changing for `commit_after` seconds is treated as final by the
caller.

Pure logic (no Apple dependency) so it tests anywhere. Mirrors
macapp/FillerKillerKit/Sources/SpeechEngine/PartialStabilizer.swift.
"""


class PartialStabilizer:
    def __init__(self, commit_after: float = 1.75):
        self.commit_after = commit_after
        self._text = ""
        self._changed_at: float | None = None

    def observe(self, partial: str, now: float) -> None:
        """Record the latest partial (each partial rewrites the whole
        utterance). The stability clock only restarts when the text changes."""
        if partial == self._text:
            return
        self._text = partial
        self._changed_at = now

    def take_stable(self, now: float) -> str | None:
        """The partial, if it's non-blank and unchanged for commit_after
        seconds. Consuming: state resets so the same text can't commit twice."""
        if (
            self._changed_at is None
            or now - self._changed_at < self.commit_after
            or not self._text.strip()
        ):
            return None
        stable = self._text
        self.reset()
        return stable

    def reset(self) -> None:
        self._text = ""
        self._changed_at = None
