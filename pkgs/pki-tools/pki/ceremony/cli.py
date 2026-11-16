import argparse
import shlex
import signal
import subprocess
import sys
from pathlib import Path

from pki.ceremony import CeremonyError
from pki.ceremony.context import Context
from pki.ceremony.flow_backup import run_backup
from pki.ceremony.flow_root import run_root
from pki.ceremony.flow_sign import run_sign
from pki.ceremony.profiles import ALL_CAS, BOOTSTRAP_CAS, ROOT_CN, parse_lifetime
from pki.ceremony.prompts import Deferred, Prompter
from pki.ceremony.tmpfs import ask_new_pin, ask_pin

ROOT_SERIAL = 19830800


def git_toplevel() -> str | None:
    res = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else None


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", help="flake checkout (default: git toplevel); read only")
    common.add_argument("--rehearsal", metavar="HSMDIR", help="SoftHSM tokens in HSMDIR stand in for the cards")
    common.add_argument("--yes", action="store_true", help="answer prompts automatically (only with --rehearsal)")
    p = argparse.ArgumentParser(prog="pki-ceremony", description="YubiKey root-CA ceremonies (docs/pki.md)")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("root", parents=[common], help="first-time root ceremony: new root in 9c plus intermediates")
    r.add_argument("--serial", type=int, default=ROOT_SERIAL)
    r.add_argument("--cn", default=ROOT_CN)
    r.add_argument("--csr-dir", help="k8s.csr, etcd.csr, front-proxy.csr signed as given")
    r.add_argument("--new", action="append", default=[], choices=BOOTSTRAP_CAS, help="generate this CA's key in memory")
    r.add_argument("--cn-date", help="date in generated CA names (default: today)")
    r.add_argument("--out", required=True)

    s = sub.add_parser("sign", parents=[common], help="sign intermediates under the existing root")
    s.add_argument("--serial", type=int, default=ROOT_SERIAL)
    s.add_argument("--root", help="root cert (default: <repo>/cluster/pki/root-ca.pem)")
    s.add_argument("--new", action="append", default=[], choices=ALL_CAS)
    s.add_argument("--csr", action="append", default=[], metavar="NAME=FILE")
    s.add_argument("--not-after", type=parse_lifetime, help="lifetime of every item, e.g. 43824h or 1826d")
    s.add_argument("--cn-date", help="date in generated CA names (default: today)")
    s.add_argument("--out", required=True)

    b = sub.add_parser("backup-root", parents=[common], help="backup root on a new card, cross-signed both ways")
    b.add_argument("--serial", type=int, help="the new card's serial")
    b.add_argument("--index", type=int)
    b.add_argument("--year", type=int, default=2026)
    b.add_argument("--root-serial", type=int, default=ROOT_SERIAL)
    b.add_argument("--root", help="root cert (default: <repo>/cluster/pki/root-ca.pem)")
    b.add_argument("--out")
    b.add_argument("--cross-sign-with-root", metavar="DIR", help="step 2 only, from step 1's directory")
    return p


def context(args) -> Context:
    if args.yes and not args.rehearsal:
        raise CeremonyError("--yes is only allowed with --rehearsal")
    repo = Path(args.repo or git_toplevel() or "")
    if not (repo / ".sops.yaml").is_file():
        raise CeremonyError("run from a checkout of the flake repo (or pass --repo): no .sops.yaml")
    prompter = Prompter(yes=args.yes)
    protected = frozenset({getattr(args, "root_serial", None) or ROOT_SERIAL})
    if args.rehearsal:
        from pki.ceremony.hsm import PIN, HsmCards

        cards, pin = HsmCards(Path(args.rehearsal).resolve(), prompter, protected), lambda _label: PIN
        flags = f"--rehearsal {shlex.quote(args.rehearsal)}" + (" --yes" if args.yes else "")
        return Context(repo, prompter, cards, pin, pin, resume_flags=flags + root_flags(args))
    from pki.ceremony.card import YubiKeyCards

    return Context(repo, prompter, YubiKeyCards(prompter, protected), ask_pin, ask_new_pin, resume_flags=root_flags(args))


def root_flags(args) -> str:
    flags = f" --repo {shlex.quote(str(args.repo))}" if args.repo else ""
    if getattr(args, "root", None):
        flags += f" --root {shlex.quote(str(args.root))}"
    if getattr(args, "root_serial", ROOT_SERIAL) != ROOT_SERIAL:
        flags += f" --root-serial {args.root_serial}"
    return flags


def run(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    ctx = context(args)
    if args.cmd in ("sign", "backup-root") and not args.root:
        args.root = str(ctx.repo / "cluster" / "pki" / "root-ca.pem")
    return {"root": run_root, "sign": run_sign, "backup-root": run_backup}[args.cmd](ctx, args)


def main(argv: list[str] | None = None) -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        return run(argv)
    except CeremonyError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except Deferred:
        print("Stopped before any card operation; nothing was signed.", file=sys.stderr)
        return 0
    except KeyboardInterrupt:
        print("ERROR: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
