# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec: onedir bundle for GPT Image Panel (Windows)."""
from pathlib import Path

PROJECT = Path(SPECPATH).resolve().parent
BUNDLE_ROOT = PROJECT / "packaging"

datas = [
    (str(PROJECT / "VERSION"), "."),
    (str(PROJECT / "frontend" / "build"), "frontend/build"),
]

hiddenimports = [
    "uvicorn.logging",
    "uvicorn.loops.auto",
    "uvicorn.loops.asyncio",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan.auto",
    "uvicorn.lifespan.on",
    "aiohttp",
    "aiohttp_socks",
    "aiosignal",
    "multipart",
    "PIL",
    "yaml",
    "zipstream",
]

a = Analysis(
    [str(BUNDLE_ROOT / "packaged_main.py")],
    pathex=[str(PROJECT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["pytest", "playwright", "svelte-check"],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="gpt-image-panel",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="gpt-image-panel",
)
