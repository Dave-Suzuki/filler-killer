import pytest

from fillerkiller.granola.public_api_source import PublicApiError, PublicApiSource

DOCS = {
    "docs": [
        {"id": "d1", "title": "Sync", "created_at": "2026-07-30T10:00:00Z",
         "updated_at": "2026-07-30T11:00:00Z"},
        {"id": "d2", "title": "Empty one", "created_at": "2026-07-29T10:00:00Z"},
    ]
}
TRANSCRIPTS = {
    "d1": [
        {"text": "So basically we", "source": "microphone", "is_final": True},
        {"text": "should ship it, you know.", "source": "microphone", "is_final": True},
        {"text": "Agreed.", "source": "system"},
    ],
    "d2": [],
}


def _source(monkeypatch, transcripts=TRANSCRIPTS, docs=DOCS):
    src = PublicApiSource(api_key="grn_test")

    def fake_post(endpoint, payload):
        if endpoint == "get-documents":
            return docs
        if endpoint == "get-document-transcript":
            return transcripts[payload["document_id"]]
        raise AssertionError(endpoint)

    monkeypatch.setattr(src, "_post", fake_post)
    return src


def test_requires_api_key(monkeypatch):
    monkeypatch.delenv("GRANOLA_API_KEY", raising=False)
    with pytest.raises(PublicApiError, match="GRANOLA_API_KEY"):
        PublicApiSource()


def test_meetings_parsed_and_merged(monkeypatch):
    meetings = _source(monkeypatch).meetings()
    assert [m.id for m in meetings] == ["d1"]  # d2 has no transcript
    m = meetings[0]
    assert m.title == "Sync"
    assert m.updated_at == "2026-07-30T11:00:00Z"
    # Consecutive microphone segments merged, so cross-segment analysis works.
    assert m.utterances[0].speaker == "Me"
    assert m.utterances[0].text == "So basically we should ship it, you know."
    assert m.utterances[1].speaker == "Them"


def test_bare_list_response_shapes(monkeypatch):
    # Tolerate the API returning a bare list for docs and transcript.
    src = _source(
        monkeypatch,
        docs=DOCS["docs"],
        transcripts={"d1": TRANSCRIPTS["d1"], "d2": []},
    )
    assert [m.id for m in src.meetings()] == ["d1"]


def test_ping_counts_docs(monkeypatch):
    assert _source(monkeypatch).ping() == 2
