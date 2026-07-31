"""Granola cache-v6: same state shape as v3 but single-encoded (the "cache"
value is a plain object, not a JSON string)."""

import json

from fillerkiller.granola.cache_source import CacheSource


def test_v6_single_encoded_cache_parses(tmp_path):
    state = {
        "cache": {
            "version": 6,
            "state": {
                "documents": {
                    "doc-a": {
                        "id": "doc-a",
                        "title": "V6 Meeting",
                        "created_at": "2026-07-30T10:00:00Z",
                    }
                },
                "transcripts": {
                    "doc-a": [
                        {
                            "text": "I mean, the plan is fine.",
                            "source": "microphone",
                            "is_final": True,
                        }
                    ]
                },
            },
        }
    }
    path = tmp_path / "cache-v6.json"
    path.write_text(json.dumps(state))
    meetings = CacheSource(path).meetings()
    assert len(meetings) == 1
    assert meetings[0].title == "V6 Meeting"
    assert meetings[0].utterances[0].speaker == "Me"
