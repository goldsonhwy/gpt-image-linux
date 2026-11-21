"""PyInstaller entrypoint for GPT Image Panel.

Keeps persistent data (images/, data/) next to the executable and serves the
bundled frontend build. Environment variables still override every path.
"""
import os
import sys
from pathlib import Path


def bundle_dir() -> Path:
    """Where PyInstaller extracted/kept bundled data files."""
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        return Path(meipass)
    return Path(__file__).resolve().parent.parent


def app_dir() -> Path:
    """Directory holding the executable; persistent data lives here."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


BUNDLE = bundle_dir()
BASE = app_dir()

# APP_VERSION is read by backend settings at import time, so set it first.
version_file = BUNDLE / "VERSION"
version = version_file.read_text(encoding="utf-8").strip() if version_file.exists() else "v0.0.0"
os.environ.setdefault("APP_VERSION", version)

# Persistent paths -> next to the executable (overridable by real env vars).
os.environ.setdefault("IMAGES_DIR", str(BASE / "images"))
os.environ.setdefault("THUMBNAILS_DIR", str(BASE / "images" / "thumbs"))
os.environ.setdefault("DATA_DIR", str(BASE / "data"))
os.environ.setdefault("DATABASE_FILE", str(BASE / "data" / "app.sqlite3"))

# No external version check in the offline binary.
os.environ.setdefault("ENABLE_VERSION_CHECK", "false")

# settings reads auth env at import time, so decide before importing backend.
if not os.environ.get("ACCESS_KEY") and not os.environ.get("ALLOW_UNAUTHENTICATED"):
    os.environ["ALLOW_UNAUTHENTICATED"] = "true"

# Import only after environment is prepared.
from backend.app.main import app  # noqa: E402

frontend_build = BUNDLE / "frontend" / "build"
app.state.frontend_build_dir = frontend_build

if not frontend_build.exists():
    print(f"[warn] frontend build not found at {frontend_build}")


def main() -> None:
    import uvicorn

    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "9090"))
    print(f"[info] GPT Image Panel {version} -> http://127.0.0.1:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
