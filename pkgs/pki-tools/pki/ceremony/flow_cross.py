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
Note: B' (backup root cross-signed by the root) does NOT let clients that trust only the root
verify intermediates issued under the backup root: the root is pathlen:1, and OpenSSL, Go and
Python cryptography enforce a trust anchor's pathlen (leaf -> intB -> B' -> root is 2 CAs).
The real protection against losing the root card is shipping the backup root certs in every
root-trusting bundle now (docs/pki.md, "Backup roots")."""


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


def reload_step1(d: Path, state: dict, root: x509.Certificate) -> tuple[x509.Certificate, x509.Certificate]:
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
    if state["attested"]:
        attest = load_cert(d / f"attest-9c-{state['serial']}.pem")
        verify_attestation(attest, load_cert(d / f"attest-f9-{state['serial']}.pem"), state["serial"], backup.public_key())
    return backup, a_by_b


def run_cross(ctx: Context, d: Path, root_serial: int, root_path: Path, swapped: bool = False) -> int:
    try:
        state = json.loads((d / "state.json").read_text())
    except (OSError, ValueError) as e:
        raise CeremonyError(f"{d}: no readable state.json from step 1 ({e})") from None
    if state["root_serial"] != root_serial:
        raise CeremonyError(f"step 1 named root card {state['root_serial']}, not {root_serial}")
    f = files(d, state["index"])
    if f["b_by_a"].exists():
        raise CeremonyError(f"{f['b_by_a']} exists; step 2 already ran")
    root = load_cert(root_path)
    backup, a_by_b = reload_step1(d, state, root)
    card = ctx.cards.card(root_serial)
    if not swapped:
        try:
            ctx.swap_to(card, None, "the root card")
        except Deferred:
            ctx.prompter.say(f"Stopped. Resume with: pki-ceremony backup-root --cross-sign-with-root {d} {ctx.resume_flags}")
            return 0
    before = gate_root_card(ctx, card, root)
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
