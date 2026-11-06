#!/usr/bin/env python3
"""Check publication hygiene. Reports locations, never matched secret values."""
import argparse
import ipaddress
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "API secret": re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}\b"),
    "personal home path": re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/"),
}
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
PRIVATE_NETWORKS = [ipaddress.ip_network(value) for value in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"
)]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def text_findings(data):
    if b"\0" in data:
        return []
    try:
        content = data.decode("utf-8")
    except UnicodeDecodeError:
        return []
    findings = []
    for number, line in enumerate(content.splitlines(), 1):
        for rule, pattern in PATTERNS.items():
            if pattern.search(line):
                findings.append((number, rule))
        for match in IPV4.finditer(line):
            # Network definitions are not individual machine addresses.
            if line[match.end():].startswith("/"):
                continue
            try:
                address = ipaddress.ip_address(match.group())
            except ValueError:
                continue
            if any(address in network for network in PRIVATE_NETWORKS):
                findings.append((number, "private or shared-network IPv4 address"))
                break
    return findings


def path_findings(name):
    path = Path(name)
    if (path.suffix.lower() in {".p12", ".pfx", ".pem", ".key", ".mobileprovision"}
            or path.name == "LocalSigning.xcconfig"
            or (path.name.startswith(".env") and path.name != ".env.example")):
        return [(0, "local configuration or signing material")]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="also inspect all reachable Git blobs and commit messages")
    args = parser.parse_args()
    findings = []
    paths = set(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\0")) - {""}
    for name in sorted(paths):
        path = ROOT / name
        if not path.exists():
            continue
        if path.is_symlink():
            findings.append((name, 0, "symlink requires manual review"))
            continue
        if not path.is_file():
            findings.append((name, 0, "non-file entry requires manual review"))
            continue
        findings.extend((name, line, rule) for line, rule in path_findings(name) + text_findings(path.read_bytes()))
    if args.history:
        objects = git("rev-list", "--objects", "--all").decode().splitlines()
        for entry in objects:
            oid, _, name = entry.partition(" ")
            kind = git("cat-file", "-t", oid).strip()
            if kind not in {b"blob", b"commit"}:
                continue
            data = git("cat-file", kind.decode(), oid)
            if kind == b"commit":
                data = data.partition(b"\n\n")[2]
            location = f"history:{oid[:10]}:{name or 'commit message'}"
            findings.extend((location, line, rule) for line, rule in path_findings(name) + text_findings(data))
        addresses = set(git("log", "--all", "--format=%ae%n%ce").decode().splitlines())
        print(f"Review {len(addresses)} distinct author/committer email address(es) locally with git log before publication.")
    for name, line, rule in findings:
        print(f"{name}:{line}: {rule}")
    print(f"{len(findings)} finding(s). Binary contents and unrecognized secret formats require manual review.")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
