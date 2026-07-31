"""Configuration: env vars with sensible Mac defaults, overridable for tests/CI."""

import os
from pathlib import Path

APP_NAME = "filler-killer"


def granola_cache_path() -> Path:
    env = os.environ.get("FK_GRANOLA_CACHE")
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library" / "Application Support" / "Granola" / "cache-v3.json"


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
