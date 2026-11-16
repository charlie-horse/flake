import json
import secrets
import string
from pathlib import Path

from pki.ceremony import CeremonyError
from pki.ceremony.checks import fingerprint, load_cert, verify_attestation
from pki.ceremony.context import Context, write_new
from pki.ceremony.flow_cross import cross_errors, files, run_cross
from pki.ceremony.flow_root import MIN_FIRMWARE
from pki.ceremony.prompts import Deferred
from pki.ceremony.profiles import BACKUP_PATHLEN, ROOT_LIFE, backup_cn, cross, self_signed_root
from pki.ceremony.secrets import PUK_PATH, pem, puk_doc


def diagnose(st) -> str:
    parts = {"PIN": st.pin_default, "PUK": st.puk_default, "management key": st.mgm_default}
    default = [k for k, v in parts.items() if v]
    changed = [k for k, v in parts.items() if not v]
    slot = "9c holds a key or certificate" if not st.empty_9c else "9c is empty"
    return f"default: {default or 'none'}; changed: {changed or 'none'}; {slot}"


def open_access(ctx: Context, card, out: Path) -> tuple[str, bool]:
    """Initialise a factory-fresh card (or reuse an initialised one); returns (PIN, PUK written)."""
    st = card.state()
    if st.initialised:
        ctx.prompter.confirm(f"Card {card.serial} already has its own PIN, PUK and PIN-protected management key, 9c empty. Skip init and use its PIN?")
        return ctx.ask_pin(f"PIV PIN of card {card.serial}"), False
    if not st.fresh:
        raise CeremonyError(f"card {card.serial} is neither factory-fresh nor cleanly initialised ({diagnose(st)}); refusing")
    pin = ctx.ask_new_pin(f"PIV PIN for card {card.serial}")
    puk = "".join(secrets.choice(string.digits) for _ in range(8))
    write_new(out / f"puk-{card.serial}.sops.yaml", ctx.encrypt(str(ctx.repo), PUK_PATH, puk_doc(card.serial, puk)))
    card.init_access(pin, puk)
    return pin, True


def step1(ctx: Context, args, out: Path, root) -> dict:
    card = ctx.cards.card(args.serial)
    if card.firmware() < MIN_FIRMWARE:
        raise CeremonyError(f"card {card.serial}: firmware < 5.3")
    pin, puk_written = open_access(ctx, card, out)
    card.verify_pin(pin)
    pub = card.generate_9c(pin)
    attestation = card.attest_9c()
    if attestation:
        verify_attestation(*attestation, card.serial, pub)
        write_new(out / f"attest-9c-{card.serial}.pem", pem(attestation[0]))
        write_new(out / f"attest-f9-{card.serial}.pem", pem(attestation[1]))
    f = files(out, args.index)
    with ctx.signing(card, pin, pub) as signer:
        ctx.prompter.touch("Self-signing the backup root")
        backup = self_signed_root(backup_cn(args.index, args.year), signer, BACKUP_PATHLEN, ROOT_LIFE, ctx.now)
        write_new(f["backup"], pem(backup))
        card.import_cert_9c(pin, backup)
        ctx.prompter.touch(f"Backup root cross-signs {root.subject.rfc4514_string()}")
        a_by_b = cross(root, backup, signer, at=ctx.now)
    errs = cross_errors(a_by_b, root, backup)
    if errs:
        raise CeremonyError("A cross-signed by B: " + "; ".join(errs))
    write_new(f["a_by_b"], pem(a_by_b))
    state = dict(serial=card.serial, index=args.index, year=args.year, root_serial=args.root_serial,
                 root_sha256=fingerprint(root), backup_sha256=fingerprint(backup),
                 attested=attestation is not None, puk_file=puk_written, step=1)
    write_new(out / "state.json", json.dumps(state, indent=2) + "\n")
    return state


def run_backup(ctx: Context, args) -> int:
    root_path = Path(args.root)
    if args.cross_sign_with_root:
        return run_cross(ctx, Path(args.cross_sign_with_root), args.root_serial, root_path)
    if args.serial is None or args.index is None or not args.out:
        raise CeremonyError("backup-root needs --serial, --index and --out (or --cross-sign-with-root DIR)")
    if args.serial == args.root_serial:
        raise CeremonyError(f"--serial {args.serial} is the root card; a backup root goes on a different card")
    out = Path(args.out)
    if out.exists():
        raise CeremonyError(f"{out} exists; refusing to overwrite")
    root = load_cert(root_path)
    ctx.swap_to(ctx.cards.card(args.serial), None, "the new backup card")
    out.mkdir(parents=True, mode=0o700)
    step1(ctx, args, out, root)
    resume = f"pki-ceremony backup-root --cross-sign-with-root {out} {ctx.resume_flags}"
    ctx.prompter.say(f"Step 1 done: {out}. Keep card {args.serial} safe; it now holds backup root {args.index}.")
    try:
        ctx.swap_to(ctx.cards.card(args.root_serial), args.serial, "the root card")
    except Deferred:
        ctx.prompter.say(f"Stopped before the swap. Resume step 2 later with:\n  {resume}")
        return 0
    return run_cross(ctx, out, args.root_serial, root_path, swapped=True)
