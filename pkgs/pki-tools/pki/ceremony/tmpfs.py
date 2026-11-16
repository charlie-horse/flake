import getpass
import os
import sys
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from pki.ceremony import CeremonyError

WEAK_PINS = {"123456", "12345678", "000000", "00000000"}


def fs_type(path: str) -> str:
    real, best, kind = os.path.realpath(path), "", ""
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            mount, fstype = fields[4], fields[fields.index("-") + 1]
            if (real == mount or real.startswith(mount.rstrip("/") + "/")) and len(mount) >= len(best):
                best, kind = mount, fstype
    return kind


def tmpfs_base() -> str:
    for base in (os.environ.get("XDG_RUNTIME_DIR"), "/dev/shm"):
        if base and os.path.isdir(base) and fs_type(base) == "tmpfs":
            return base
    raise CeremonyError("no tmpfs for the PIN file ($XDG_RUNTIME_DIR and /dev/shm are not tmpfs)")


def shred(path: Path) -> None:
    size = path.stat().st_size
    with open(path, "r+b", buffering=0) as f:
        f.write(b"\0" * size)
        os.fsync(f.fileno())
    path.unlink()


@contextmanager
def workdir() -> Iterator[Path]:
    old = os.umask(0o077)
    work = Path(tempfile.mkdtemp(prefix="ceremony.", dir=tmpfs_base()))
    try:
        yield work
    finally:
        for p in sorted(work.rglob("*"), reverse=True):
            if p.is_file():
                shred(p)
            else:
                p.rmdir()
        work.rmdir()
        os.umask(old)


def pin_file(work: Path, pin: str, name: str = "pin") -> Path:
    path = work / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(pin)
    return path


def ask_pin(label: str, read=getpass.getpass) -> str:
    pin = read(f"{label} (not echoed): ")
    if not pin:
        raise CeremonyError("empty PIN")
    return pin


def ask_new_pin(label: str, read=getpass.getpass) -> str:
    for _ in range(5):
        pin = read(f"New {label}, 6-8 characters (not echoed): ")
        if not 6 <= len(pin) <= 8 or pin in WEAK_PINS:
            print(f"{label}: 6-8 characters and not a default; try again", file=sys.stderr)
            continue
        if read(f"New {label} again: ") == pin:
            return pin
        print(f"{label}: the two entries differ; try again", file=sys.stderr)
    raise CeremonyError(f"no valid {label} entered")
