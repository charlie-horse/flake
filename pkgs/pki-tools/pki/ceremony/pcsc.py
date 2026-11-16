import os
import shutil
import subprocess
import time
from collections.abc import Callable
from contextlib import contextmanager

from ykman.device import list_all_devices
from yubikit.core.smartcard import SmartCardConnection
from yubikit.piv import PivSession

from pki.ceremony import CeremonyError

_own: subprocess.Popen | None = None


def pcscd_running() -> bool:
    return subprocess.run(["pgrep", "-x", "pcscd"], capture_output=True).returncode == 0


def ensure_pcscd(serial: int, visible: Callable[[], bool], wait: float = 10.0) -> None:
    """Make the card reachable over PC/SC, starting ca-pcscd only if no pcscd serves it."""
    global _own
    if visible():
        return
    if _own is None and pcscd_running():
        raise CeremonyError(f"a pcscd is running but YubiKey {serial} is not visible over PC/SC (plugged in? polkit? try as root)")
    if not shutil.which("ca-pcscd"):
        raise CeremonyError("no pcscd reachable and ca-pcscd is not on PATH (nix shell <flake>#ca-ceremony-tools)")
    if os.geteuid() != 0:
        raise CeremonyError("no pcscd reachable: rerun as root (sudo -i) so ca-pcscd can be started")
    if _own is not None:
        _own.wait()
    _own = subprocess.Popen(["ca-pcscd"])
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if visible():
            return
        time.sleep(1)
    raise CeremonyError(f"YubiKey {serial} not visible over PC/SC after starting ca-pcscd")


class YkDevices:
    def serials(self) -> list[int | None]:
        return sorted((info.serial for _, info in list_all_devices()), key=lambda s: s or 0)

    def pcsc_serials(self) -> list[int | None]:
        return [info.serial for _, info in list_all_devices([SmartCardConnection])]

    @contextmanager
    def piv(self, serial: int):
        dev = next((d for d, info in list_all_devices([SmartCardConnection]) if info.serial == serial), None)
        if dev is None:
            raise CeremonyError(f"YubiKey {serial} is not reachable over PC/SC")
        with dev.open_connection(SmartCardConnection) as conn:
            yield PivSession(conn)
