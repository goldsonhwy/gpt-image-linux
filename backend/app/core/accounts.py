"""Admin account storage backed by the app's SQLite settings_kv table.

First visitor registers a single admin account (username + password). Passwords
are stored as PBKDF2-HMAC-SHA256 hashes with a per-account random salt.
"""
import hashlib
import hmac
import json
import os
from typing import Optional

from ..repositories import storage as db

_ACCOUNT_KEY = "admin_account_v1"
_PBKDF2_ROUNDS = 480_000


def _load() -> Optional[dict]:
    try:
        with db._connect() as conn:
            raw = db._get_setting_value(conn, _ACCOUNT_KEY)
    except Exception:
        return None
    if not raw:
        return None
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            return None
        return data
    except (ValueError, TypeError):
        return None


def _save(data: dict) -> None:
    raw = json.dumps(data, separators=(",", ":"))
    with db._connect() as conn:
        db._set_setting_value(conn, _ACCOUNT_KEY, raw)


def is_registered() -> bool:
    data = _load()
    return bool(data and data.get("username") and data.get("password_hash"))


def get_username() -> str:
    data = _load()
    return str(data.get("username", "")) if data else ""


def _hash_password(password: str, salt: bytes) -> str:
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, _PBKDF2_ROUNDS
    )
    return digest.hex()


def register(username: str, password: str) -> bool:
    """Create the admin account. Returns False if already registered."""
    if is_registered():
        return False
    username = username.strip()
    if not username or not password:
        return False
    salt = os.urandom(16)
    _save(
        {
            "username": username,
            "salt": salt.hex(),
            "password_hash": _hash_password(password, salt),
        }
    )
    return True


def verify(username: str, password: str) -> bool:
    data = _load()
    if not data or not data.get("password_hash"):
        return False
    if not hmac.compare_digest(username.strip(), str(data.get("username", ""))):
        return False
    try:
        salt = bytes.fromhex(str(data.get("salt", "")))
    except ValueError:
        return False
    expected = str(data.get("password_hash", ""))
    actual = _hash_password(password, salt)
    return hmac.compare_digest(actual, expected)
