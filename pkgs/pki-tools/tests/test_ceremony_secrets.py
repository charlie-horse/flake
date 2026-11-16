import base64
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

import pytest
import yaml
from ceremony_helpers import BACKUP_SERIAL, SOPS_YAML, Hierarchy

from pki import sopsfile
from pki.ceremony import CeremonyError
from pki.ceremony import secrets as k8s_secrets
from pki.ceremony.secrets import ca_secret, key_pem, pem, puk_doc, tls_secret

ADMINS = ["age1yubikey1qwdgvy8jqgqjd2f380hf6d787x25eyhfwj5nxyv5gzhu6827medygv69f6q", "age1dcz2gzz3u4uw09jvgp74zv33eqhvwgd7rl76kg9ehwy3g00thsms8vpl08"]
FLUX = "age1ynj83hcd8zmscx4us80q6hqzxmr0d69hv3vr8extl5kvjqd92agqypgdux"
has_sops = pytest.mark.skipif(
    not (shutil.which("sops") and shutil.which("age-plugin-yubikey") and SOPS_YAML.exists()), reason="sops, age-plugin-yubikey or .sops.yaml missing"
)


@pytest.fixture(scope="module")
def h():
    return Hierarchy()


@pytest.fixture
def repo(tmp_path):
    if SOPS_YAML.exists():
        shutil.copy(SOPS_YAML, tmp_path / ".sops.yaml")
    return tmp_path


def b64(doc, k):
    return base64.b64decode(doc["data"][k])


def test_tls_secret_is_sorted_and_exact(h):
    text = tls_secret("n", "ns", b"ca\n", b"crt\n", b"key\n")
    assert list(yaml.safe_load(text)) == ["apiVersion", "data", "kind", "metadata", "type"]
    doc = yaml.safe_load(text)
    assert list(doc["data"]) == ["ca.crt", "tls.crt", "tls.key"] and b64(doc, "tls.key") == b"key\n"
    assert doc["type"] == "kubernetes.io/tls" and doc["metadata"] == {"name": "n", "namespace": "ns"}


def test_workload_and_bootstrap_secrets(h):
    path, fname, text = ca_secret("workload", h.int, h.a, h.int_key)
    doc = yaml.safe_load(text)
    assert (path, fname) == ("k8s/secrets/cert-manager/cluster-ca.sops.yaml", "cluster-ca.sops.yaml")
    assert doc["metadata"] == {"name": "cluster-ca", "namespace": "cert-manager"}
    assert b64(doc, "tls.crt") == pem(h.int) + pem(h.a) and b64(doc, "ca.crt") == pem(h.a)
    assert b64(doc, "tls.key") == key_pem(h.int_key)
    path, fname, text = ca_secret("etcd", h.int, h.a, h.int_key)
    doc = yaml.safe_load(text)
    assert (path, fname) == ("k8s/secrets/cluster-pki/etcd-ca.sops.yaml", "etcd-ca.sops.yaml")
    assert doc["metadata"] == {"name": "etcd-ca", "namespace": "cluster-pki"} and b64(doc, "tls.crt") == pem(h.int)


def test_puk_doc():
    assert yaml.safe_load(puk_doc(BACKUP_SERIAL, "01234567")) == {"yubikey-22616756-piv-puk": "01234567"}


def test_plaintext_goes_only_to_stdin(repo, monkeypatch):
    calls, before = [], set(repo.iterdir())

    def fake_run(argv, **kw):
        calls.append((argv, kw))
        return type("R", (), {"returncode": 0, "stdout": "x: ENC[...]\n", "stderr": ""})()

    monkeypatch.setattr(sopsfile.subprocess, "run", fake_run)
    sopsfile.encrypt_stdin(str(repo), "secrets/admin.yaml", "x: hunter22\n")
    argv, kw = calls[0]
    assert argv[-1] == "/dev/stdin" and kw["input"] == "x: hunter22\n" and "hunter22" not in " ".join(argv)
    assert set(repo.iterdir()) == before


@has_sops
@pytest.mark.parametrize("ca,want", [("workload", ADMINS + [FLUX]), ("k8s", ADMINS + [FLUX])])
def test_real_sops_k8s_secrets(h, repo, ca, want):
    path, _, text = ca_secret(ca, h.int, h.a, h.int_key)
    out = k8s_secrets.encrypt(str(repo), path, text)
    assert sorted(sopsfile.recipients(out)) == sorted(want)
    doc = yaml.safe_load(out)
    assert all(v.startswith("ENC[") for v in doc["data"].values())
    assert base64.b64encode(key_pem(h.int_key)).decode() not in out and doc["metadata"]["name"]


@has_sops
def test_real_sops_puk(repo):
    out = k8s_secrets.encrypt(str(repo), "secrets/admin.yaml", puk_doc(BACKUP_SERIAL, "01234567"))
    assert sorted(sopsfile.recipients(out)) == sorted(ADMINS) and "01234567" not in out


@has_sops
def test_wrong_rule_is_refused(h, repo):
    path, _, text = ca_secret("k8s", h.int, h.a, h.int_key)
    out = sopsfile.encrypt_stdin(str(repo), "secrets/admin.yaml", text)
    assert "recipients" in " ".join(k8s_secrets.encryption_errors(str(repo), path, out, ["ca.crt", "tls.crt", "tls.key"]))


def test_encryption_errors_catch_plaintext(repo):
    if not (repo / ".sops.yaml").exists():
        pytest.skip("no .sops.yaml")
    plain = "data:\n  tls.key: abc\nsops:\n  age: []\n"
    with pytest.raises(CeremonyError, match="not encrypted"):
        k8s_secrets.encrypt(str(repo), "secrets/admin.yaml", "data:\n  tls.key: abc\n", encrypt_stdin=lambda *a: plain)



SIGNAL_CHILD = """
import time
from pki.ceremony import cli, tmpfs
tmpfs.fs_type = lambda p: "tmpfs"
cli.exit_on_signals()
with tmpfs.workdir() as work:
    tmpfs.pin_file(work, "123456")
    print(work, flush=True)
    time.sleep(60)
"""


@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGQUIT, signal.SIGTERM])
def test_signals_shred_the_pin_file(tmp_path, sig):
    env = {**os.environ, "PYTHONPATH": os.pathsep.join(sys.path), "XDG_RUNTIME_DIR": str(tmp_path)}
    child = subprocess.Popen([sys.executable, "-c", SIGNAL_CHILD], stdout=subprocess.PIPE, env=env, text=True)
    work = Path(child.stdout.readline().strip())
    assert (work / "pin").exists()
    child.send_signal(sig)
    assert child.wait(timeout=20) == 128 + sig
    assert not work.exists()
