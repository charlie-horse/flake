import sys
from collections.abc import Callable
from dataclasses import dataclass

from pki.ceremony import CeremonyError


class Deferred(Exception):
    """The user answered 'later' at a card swap."""


@dataclass
class Prompter:
    yes: bool = False
    ask: Callable[[str], str] = lambda p: input(p)
    out: Callable[[str], None] = lambda s: print(s, file=sys.stderr, flush=True)

    def say(self, text: str) -> None:
        self.out(f"\n== {text}")

    def note(self, text: str) -> None:
        self.out(text)

    def touch(self, what: str) -> None:
        self.say(f"{what}: enter nothing, touch the key when it blinks")

    def confirm(self, text: str) -> None:
        if self.yes:
            self.out(f"{text} [yes: --yes]")
            return
        if self.ask(f"{text} [type yes] ").strip() != "yes":
            raise CeremonyError("aborted")

    def insert(self, serial: int) -> None:
        self.out(f"No YubiKey found. Insert card {serial}.")
        if not self.yes:
            self.ask("Press Enter when it is in. ")

    def swap(self, from_serial: int | None, to_serial: int, label: str) -> None:
        gone = f"Remove card {from_serial}. " if from_serial else "Remove any other card. "
        self.say(f"{gone}Insert {label} (serial {to_serial}).")
        if self.yes:
            return
        if self.ask("Press Enter when it is in, or type later: ").strip() == "later":
            raise Deferred()
