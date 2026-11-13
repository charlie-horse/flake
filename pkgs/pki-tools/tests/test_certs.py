from dataclasses import replace
from datetime import timedelta

import pytest
from conftest import NODES, key_pem, leaf_specs, pem

from pki.certs import chain_errors, expiring, key_matches, load_chain, ownership_errors, summarize


def spec(stem: str, node: str = "r440"):
    return next(s for s in leaf_specs(node) if s.stem == stem)


def others(pki, expected: str) -> dict:
    cas = {"root": pki.root} | pki.cas
    return {n: ca.cert for n, ca in cas.items() if n != expected}


def test_summarize_leaf(pki):
    cert, _ = pki.leaf(pki.cas["k8s"], spec("kubelet-r440"))
    s = summarize(cert)
    assert s.cn == "system:node:r440"
    assert s.subject == {("CN", "system:node:r440"), ("O", "system:nodes")}
    assert "r440.example.ts.net" in s.dns and "127.0.0.1" in s.ips
    assert s.key_usage == {"Digital Signature", "Key Encipherment"}
    assert s.ext_key_usage == {"TLS Web Server Authentication", "TLS Web Client Authentication"}
    assert not s.is_ca and s.key == "RSA-2048"
    assert s.issuer == pki.cas["k8s"].cert.subject.rfc4514_string()
    assert s.not_after - s.not_before == timedelta(days=365)
    assert len(s.sha256) == 64


def test_summarize_ca(pki):
    s = summarize(pki.cas["etcd"].cert)
    assert s.is_ca and s.key == "EC-P384" and s.cn == "neurosis etcd CA"


def test_load_chain_leaf_first(pki):
    cert, _ = pki.leaf(pki.cas["k8s"], spec("apiserver-r440"))
    assert load_chain(pem(cert, pki.cas["k8s"].cert)) == [cert, pki.cas["k8s"].cert]


@pytest.mark.parametrize("stem", ["apiserver-r440", "scheduler-r440", "kubelet-r440"])
def test_chain_expected_only(pki, stem):
    cert, _ = pki.leaf(pki.cas["k8s"], spec(stem))
    assert chain_errors([cert], pki.cas["k8s"].cert, others(pki, "k8s")) == []
    assert chain_errors([cert, pki.cas["k8s"].cert], pki.cas["k8s"].cert, others(pki, "k8s")) == []


@pytest.mark.parametrize("stem", ["etcd-peer-r440", "apiserver-r440"])
def test_chain_wrong_ca(pki, stem):
    cert, _ = pki.leaf(pki.cas["etcd"], spec(stem))
    assert chain_errors([cert], pki.cas["k8s"].cert, others(pki, "k8s")) == [
        "does not verify against CN=neurosis k8s CA,O=neurosis",
        "also verifies against etcd",
    ]


def test_chain_root_signed(pki):
    cert, _ = pki.leaf(pki.root, spec("scheduler-r440"))
    errors = chain_errors([cert], pki.cas["k8s"].cert, others(pki, "k8s"))
    assert errors[0].startswith("does not verify against ") and errors[1:] == ["also verifies against root"]


def test_chain_also_workload(pki):
    k8s = pki.cas["k8s"]
    twin = pki.ca("", pki.root, key=k8s.key, subject=k8s.cert.subject)
    cert, _ = pki.leaf(k8s, spec("admin-r440"))
    assert chain_errors([cert], k8s.cert, others(pki, "k8s") | {"workload": twin.cert}) == [
        "also verifies against workload"
    ]


def test_chain_extra_cert_not_expected(pki):
    cert, _ = pki.leaf(pki.cas["k8s"], spec("apiserver-r440"))
    errors = chain_errors([cert, pki.root.cert], pki.cas["k8s"].cert, others(pki, "k8s"))
    assert len(errors) == 1 and errors[0].startswith("chain cert 1 is not ")


def test_ownership_ok(pki):
    for s in leaf_specs("m2mini"):
        cert, _ = pki.leaf(pki.cas[s.ca], s)
        assert ownership_errors(s.stem, "m2mini", summarize(cert), NODES) == [], s.stem


def test_ownership_errors(pki):
    k8s, etcd = pki.cas["k8s"], pki.cas["etcd"]
    s = summarize(pki.leaf(k8s, spec("kubelet-r440"))[0])
    assert ownership_errors("kubelet-c4130x", "c4130", s, NODES) == ["name must be <component>-c4130"]
    assert ownership_errors("kubelet-c4130", "c4130", s, NODES) == [
        "CN 'system:node:r440', want 'system:node:c4130'",
        "names another node (r440)",
    ]
    peer = summarize(pki.leaf(etcd, replace(spec("etcd-peer-r440"), cn="m2mini"))[0])
    assert ownership_errors("etcd-peer-r440", "r440", peer, NODES) == [
        "CN 'm2mini', want 'r440'",
        "names another node (m2mini)",
    ]
    dns = summarize(pki.leaf(k8s, spec("apiserver-r440"), dns=("c4130.example.ts.net",))[0])
    assert ownership_errors("apiserver-r440", "r440", dns, NODES) == ["names another node (c4130)"]


def test_key_matches(pki):
    cert, key = pki.leaf(pki.cas["k8s"], spec("scheduler-r440"))
    _, other = pki.leaf(pki.cas["k8s"], spec("scheduler-r440"))
    assert key_matches(cert, key_pem(key))
    assert not key_matches(cert, key_pem(other))
    assert not key_matches(cert, b"not a key")


def test_expiring(pki):
    s = summarize(pki.leaf(pki.cas["k8s"], spec("scheduler-r440"), days=10)[0])
    assert expiring(s, pki.now, timedelta(days=14))
    assert not expiring(s, pki.now, timedelta(days=7))
