import json
from pathlib import Path

from cryptography import x509

from pki.ceremony import CeremonyError
from pki.ceremony.checks import (
    cross_chain_ok,
    fingerprint,
    fingerprints_txt,
    intermediates_next_to,
    issued_errors,
    load_cert,
    verify_attestation,
)
from pki.ceremony.context import Context, write_new
from pki.ceremony.flow_sign import check_slot82, gate_root_card
from pki.ceremony.prompts import Deferred
from pki.ceremony.profiles import BACKUP_PATHLEN, CROSS_PATHLEN, cross, ski_of
from pki.ceremony.secrets import pem
from pki.ceremony.signer import spki

LIMITATION = """\
Note: B' (backup root cross-signed by the root) lets clients that trust only the root accept
certificates the backup root signs DIRECTLY (leaf -> B' -> root fits the root's pathlen:1), so
the backup card can now issue leaves that every root-trusting client accepts: guard it like the
root card. B' does NOT carry intermediates issued under the backup root (leaf -> intB -> B' -> root
is two CAs under a pathlen:1 anchor; OpenSSL, Go and Python cryptography refuse it). To keep those
working after losing the root card, ship the backup root certs in every root-trusting bundle
(docs/pki.md, "Backup roots")."""


def files(out: Path, index: int) -> dict[str, Path]:
    return {
        "backup": out / f"backup-root-{index}.pem",
        "a_by_b": out / f"root-ca-by-backup-{index}.pem",
        "b_by_a": out / f"backup-root-{index}-by-root.pem",
    }


def cross_errors(crossed: x509.Certificate, subject: x509.Certificate, issuer: x509.Certificate) -> list[str]:
    errs = issued_errors(crossed, issuer, CROSS_PATHLEN)
    if crossed.subject != subject.subject or spki(crossed.public_key()) != spki(subject.public_key()):
        errs.append("subject name or key differs from the subject's certificate")
    if ski_of(crossed) != ski_of(subject):
        errs.append("SKI is not the subject's SKI")
    if crossed.not_valid_after_utc > min(subject.not_valid_after_utc, issuer.not_valid_after_utc):
        errs.append("valid beyond the subject or the issuer")
    return errs


def reload_step1(d: Path, state: dict, root: x509.Certificate, require_attest: bool) -> tuple[x509.Certificate, x509.Certificate]:
    f = files(d, state["index"])
    backup, a_by_b = load_cert(f["backup"]), load_cert(f["a_by_b"])
    errs = []
    if fingerprint(root) != state["root_sha256"]:
        errs.append("the root certificate is not the one step 1 cross-signed")
    if fingerprint(backup) != state["backup_sha256"]:
        errs.append(f"{f['backup'].name} changed since step 1")
    errs += [f"backup root: {e}" for e in issued_errors(backup, backup, BACKUP_PATHLEN)]
    errs += [f"{f['a_by_b'].name}: {e}" for e in cross_errors(a_by_b, root, backup)]
    if errs:
        raise CeremonyError(f"{d}: " + "; ".join(errs))
    if require_attest:
        attest, f9 = (load_cert(d / f"attest-{s}-{state['serial']}.pem") for s in ("9c", "f9"))
        verify_attestation(attest, f9, state["serial"], backup.public_key())
    return backup, a_by_b


def check_backup_card(ctx: Context, card, backup: x509.Certificate) -> None:
    """The backup card itself must hold B: key, certificate, policy and a fresh attestation."""
    gate_root_card(ctx, card, backup)
    if not card.attested:
        ctx.prompter.note("rehearsal: no PIV attestation (SoftHSM)")
        return
    attestation = card.attest_9c()
    if attestation is None:
        raise CeremonyError(f"card {card.serial}: no attestation for 9c; refusing")
    verify_attestation(*attestation, card.serial, backup.public_key())


def load_state(d: Path, serial: int | None) -> dict:
    try:
        state = json.loads((d / "state.json").read_text())
    except (OSError, ValueError) as e:
        raise CeremonyError(f"{d}: no readable state.json from step 1 ({e})") from None
    if serial != state["serial"]:
        raise CeremonyError(f"step 2 needs --serial {state['serial']} (the backup card of step 1), got {serial}")
    return state


def run_cross(ctx: Context, d: Path, root_serial: int, root_path: Path, serial: int | None = None, state: dict | None = None) -> int:
    """Step 2. `state` comes from step 1 in this process; without it, step 1's directory is re-checked against the backup card."""
    resumed = state is None
    state = load_state(d, serial) if resumed else state
    if state["root_serial"] != root_serial:
        raise CeremonyError(f"step 1 named root card {state['root_serial']}, not {root_serial}")
    f = files(d, state["index"])
    if f["b_by_a"].exists():
        raise CeremonyError(f"{f['b_by_a']} exists; step 2 already ran")
    root = load_cert(root_path)
    card_b, card = ctx.cards.card(state["serial"]), ctx.cards.card(root_serial)
    backup, a_by_b = reload_step1(d, state, root, card_b.attested)
    if resumed:
        try:
            ctx.swap_to(card_b, None, f"backup card {state['index']}")
            check_backup_card(ctx, card_b, backup)
            ctx.swap_to(card, card_b.serial, "the root card")
        except Deferred:
            ctx.prompter.say(f"Stopped. Resume with: pki-ceremony backup-root --cross-sign-with-root {d} --serial {serial} {ctx.resume_flags}")
            return 0
    before = gate_root_card(ctx, card, root)
    ctx.prompter.confirm(
        f"Root card {root_serial} signs {backup.subject.rfc4514_string()}, key on card {state['serial']},\n"
        f"  SHA-256 {fingerprint(backup)} (as printed after step 1). Sign it?"
    )
    pin = ctx.ask_pin(f"PIV PIN of root card {root_serial}")
    card.verify_pin(pin)
    with ctx.signing(card, pin, root.public_key()) as signer:
        ctx.prompter.touch("The root cross-signs the backup root")
        b_by_a = cross(backup, root, signer, at=ctx.now)
    errs = cross_errors(b_by_a, backup, root)
    if errs:
        raise CeremonyError("B cross-signed by the root: " + "; ".join(errs))
    targets = intermediates_next_to(root_path)
    cross_chain_ok(backup, a_by_b, targets)
    ctx.prompter.note(f"Chains to the backup root through {f['a_by_b'].name}: {', '.join(targets) or 'no intermediates found'}")
    check_slot82(card, before)
    write_new(f["b_by_a"], pem(b_by_a))
    names = {"root": root, f"backup-{state['index']}": backup, f"root-by-backup-{state['index']}": a_by_b, f"backup-{state['index']}-by-root": b_by_a}
    write_new(d / "fingerprints.txt", fingerprints_txt(names))
    (d / "state.json").write_text(json.dumps({**state, "step": 2}, indent=2) + "\n")
    ctx.prompter.say(LIMITATION)
    ctx.prompter.say(f"Done. Nothing in {ctx.repo} was changed. On a branch:")
    ctx.prompter.note(f"  cluster/pki/ <- {', '.join(p.name for p in f.values())}, attest-*-{state['serial']}.pem, fingerprints.txt")
    if state.get("puk_file"):
        ctx.prompter.note(f"  secrets/admin.yaml <- yubikey-{state['serial']}-piv-puk from puk-{state['serial']}.sops.yaml:")
        ctx.prompter.note(f"    sops decrypt --extract '[\"yubikey-{state['serial']}-piv-puk\"]' puk-{state['serial']}.sops.yaml | jq -Rs . \\")
        ctx.prompter.note(f"      | sops set --value-stdin secrets/admin.yaml '[\"yubikey-{state['serial']}-piv-puk\"]'")
        ctx.prompter.note('  docs/cluster.md "Secrets (all of them)": add a row for that PUK.')
    ctx.prompter.note("Unplug the YubiKey.")
    return 0
