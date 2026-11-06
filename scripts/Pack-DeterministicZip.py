#!/usr/bin/env python3
"""Create a deterministic ZIP from a release staging directory."""

from __future__ import annotations

import argparse
import zipfile
from pathlib import Path

TEXT_EXTENSIONS = {
    ".ps1", ".psm1", ".psd1", ".py", ".json", ".md", ".yml", ".yaml",
    ".html", ".svg", ".toml", ".txt", ".cmd",
}
TEXT_NAMES = {"LICENSE", ".gitignore"}
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def canonical_bytes(path: Path) -> bytes:
    if path.suffix.lower() not in TEXT_EXTENSIONS and path.name not in TEXT_NAMES:
        return path.read_bytes()
    text = path.read_bytes().decode("utf-8-sig")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if path.suffix.lower() == ".cmd":
        text = text.replace("\n", "\r\n")
    return text.encode("utf-8")


def build(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(
        (path for path in source.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(source).as_posix(),
    )
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for path in files:
            relative = path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(relative, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.create_version = 20
            info.extract_version = 20
            info.external_attr = 0o100644 << 16
            info.internal_attr = 0
            info.extra = b""
            info.comment = b""
            archive.writestr(info, canonical_bytes(path))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.source.is_dir():
        parser.error(f"source directory does not exist: {args.source}")
    build(args.source, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
