"""Configuration: env vars with sensible Mac defaults, overridable for tests/CI."""

import os
from pathlib import Path

APP_NAME = "filler-killer"


def granola_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Granola"


def granola_cache_path() -> Path:
    env = os.environ.get("FK_GRANOLA_CACHE")
    if env:
        return Path(env).expanduser()
    # Granola bumped its cache filename over time; prefer whichever exists.
    for name in ("cache-v3.json", "cache-v6.json"):
        candidate = granola_dir() / name
        if candidate.exists():
            return candidate
    return granola_dir() / "cache-v3.json"


def my_names() -> list[str]:
    """FK_MY_NAME: comma-separated names Granola may label the user with in
    meetings captured by someone else (e.g. "Dave Suzuki,Dave"). Empty means
    only microphone speech ("Me") is ever counted."""
    raw = os.environ.get("FK_MY_NAME", "")
    return [part.strip() for part in raw.split(",") if part.strip()]


def my_email() -> str | None:
    """FK_MY_EMAIL: the user's Granola account email; combined with note
    owner metadata to skip shared meetings the user didn't speak in."""
    raw = os.environ.get("FK_MY_EMAIL", "").strip()
    return raw or None


def granola_api_key() -> str | None:
    return os.environ.get("GRANOLA_API_KEY")


def granola_api_base() -> str:
    return os.environ.get("FK_GRANOLA_API_BASE", "https://public-api.granola.ai/v1")


def granola_supabase_path() -> Path:
    env = os.environ.get("FK_GRANOLA_SUPABASE")
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library" / "Application Support" / "Granola" / "supabase.json"


def db_path() -> Path:
    env = os.environ.get("FK_DB_PATH")
    if env:
        return Path(env).expanduser()
    base = Path.home() / "Library" / "Application Support" / APP_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base / "fk.db"


DASHBOARD_HOST = os.environ.get("FK_HOST", "127.0.0.1")
DASHBOARD_PORT = int(os.environ.get("FK_PORT", "8756"))
