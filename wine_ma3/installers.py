"""grandMA3 installer discovery."""

from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class MaInstaller:
    path: Path
    version: str
    size_mb: float
    mtime: float
    kind: str = "exe"
    source_path: Path | None = None
    archive_member: str | None = None

    def __post_init__(self) -> None:
        if self.source_path is None:
            object.__setattr__(self, "source_path", self.path)

    @property
    def prefix_name(self) -> str:
        return f".wine-gma{self.version.replace('.', '')}"

    @property
    def install_dir_name(self) -> str:
        parts = self.version.split(".")
        return f"gma3_{'.'.join(parts[:3])}"

    @property
    def display_source(self) -> str:
        if self.kind == "zip" and self.archive_member:
            return f"{self.source_path.name}:{self.archive_member}"
        return self.path.name

    def resolve_exe(self, root: Path) -> Path:
        if self.kind != "zip":
            return self.path
        if self.source_path is None or self.archive_member is None:
            raise ValueError("ZIP installer candidate is missing source/member metadata")

        extract_dir = root / "ma3onpcinstaller" / ".extracted" / self.source_path.stem
        target = extract_dir / Path(self.archive_member).name
        with zipfile.ZipFile(self.source_path) as archive:
            info = archive.getinfo(self.archive_member)
            if target.exists() and target.stat().st_size == info.file_size:
                return target
            extract_dir.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as src, target.open("wb") as dst:
                dst.write(src.read())
        return target


def installer_from_path(path: Path) -> MaInstaller | None:
    """Create an MaInstaller from an arbitrary file path."""
    if not path.exists():
        return None
    stat = path.stat()
    if path.suffix.lower() == ".exe":
        return MaInstaller(
            path=path,
            version=infer_version(path.name),
            size_mb=stat.st_size / 1024 / 1024,
            mtime=stat.st_mtime,
        )
    if path.suffix.lower() == ".zip":
        candidates = _discover_zip(path)
        return candidates[0] if candidates else None
    return None


def discover(root: Path) -> list[MaInstaller]:
    directory = root / "ma3onpcinstaller"
    installers: list[MaInstaller] = []
    for path in sorted(directory.glob("*.exe")):
        stat = path.stat()
        installers.append(
            MaInstaller(
                path=path,
                version=infer_version(path.name),
                size_mb=stat.st_size / 1024 / 1024,
                mtime=stat.st_mtime,
            )
        )
    for path in sorted(directory.glob("*.zip")):
        installers.extend(_discover_zip(path))
    return installers


def infer_version(filename: str) -> str:
    match = re.search(r"v?(\d+\.\d+\.\d+(?:\.\d+)?)", filename)
    if match:
        version = match.group(1)
        if version.count(".") == 2:
            return f"{version}.0"
        return version
    return "2.3.2.0"


def _discover_zip(path: Path) -> list[MaInstaller]:
    candidates: list[MaInstaller] = []
    try:
        with zipfile.ZipFile(path) as archive:
            exe_infos = [
                info
                for info in archive.infolist()
                if not info.is_dir() and info.filename.lower().endswith(".exe")
            ]
    except zipfile.BadZipFile:
        return []

    exe_infos.sort(key=lambda info: _exe_rank(info.filename))
    for info in exe_infos:
        candidates.append(
            MaInstaller(
                path=path,
                version=infer_version(Path(info.filename).name) or infer_version(path.name),
                size_mb=info.file_size / 1024 / 1024,
                mtime=path.stat().st_mtime,
                kind="zip",
                source_path=path,
                archive_member=info.filename,
            )
        )
    return candidates


def _exe_rank(filename: str) -> tuple[int, str]:
    lower = filename.lower()
    if "grandma3_onpc_win" in lower:
        return (0, lower)
    if "grandma3" in lower and "onpc" in lower:
        return (1, lower)
    return (2, lower)
