#!/usr/bin/env python3
"""Verify changed app contents retain the configured certificate-based identity."""
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from signing import selected_identity

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Build/Products/Release/local-wispr.app").resolve()

def execute(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout + result.stderr

def requirement(path):
    output = execute(["codesign", "-d", "-r-", str(path)])
    match = re.search(r'^designated => (.+)$', output, re.M)
    if not match or "cdhash" in match.group(1):
        raise RuntimeError("Expected a certificate-based designated requirement")
    return match.group(1)

def content_hash(path):
    return re.search(r'^CDHash=(.+)$', execute(["codesign", "-dvvv", str(path)]), re.M).group(1)

before = requirement(app)
with tempfile.TemporaryDirectory(prefix="localstt-identity-check-") as directory:
    changed = Path(directory) / "local-wispr.app"
    execute(["ditto", str(app), str(changed)])
    plist = changed / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    data["CFBundleVersion"] = "999999"
    plist.write_bytes(plistlib.dumps(data))
    execute(["codesign", "--force", "--sign", selected_identity(), "--timestamp=none", str(changed)])
    execute(["codesign", "--verify", "--strict", "-R", "=" + before, str(changed)])
    assert content_hash(app) != content_hash(changed), "Test app contents must differ"
    assert requirement(changed) == before, "Signing identity changed across versions"
print("PASS: changed app contents satisfy the original signing requirement.")
print(before)
