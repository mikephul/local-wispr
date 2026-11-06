#!/usr/bin/env python3
"""Configure a stable signing identity; create-local changes the login Keychain."""
import secrets
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = "LocalSTT Development"
CONFIG = ROOT / "Config/LocalSigning.xcconfig"

def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result.stdout

def identities():
    output = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    return re.findall(r'\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"', output)

def resolve(value):
    matches = [fingerprint for fingerprint, name in identities() if value.upper() == fingerprint.upper() or value == name]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one valid signing identity for {value!r}; found {len(matches)}. Configure a certificate before building. No ad-hoc fallback will be used.")
    return matches[0].upper()

def configure(value):
    fingerprint = resolve(value)
    CONFIG.parent.mkdir(exist_ok=True)
    CONFIG.write_text(f"// Local Keychain identity; keep this certificate for future builds.\nCODE_SIGN_IDENTITY = {fingerprint}\n")
    print(f"Configured stable signing identity {fingerprint} in Config/LocalSigning.xcconfig")

def selected_identity():
    if CONFIG.exists():
        match = re.search(r'^CODE_SIGN_IDENTITY\s*=\s*([0-9A-Fa-f]{40})\s*$', CONFIG.read_text(), re.M)
        if not match:
            raise RuntimeError("Invalid LocalSigning.xcconfig. Use scripts/signing.py use <identity> to configure it.")
        return resolve(match.group(1))
    return resolve(NAME)

def create_local():
    existing = [fingerprint for fingerprint, name in identities() if name == NAME]
    if existing:
        configure(NAME)
        return
    keychain = str(Path.home() / "Library/Keychains/login.keychain-db")
    found = subprocess.run(["/usr/bin/security", "find-certificate", "-c", NAME, keychain], capture_output=True)
    if found.returncode == 0:
        raise RuntimeError("A LocalSTT certificate already exists but is not a valid signing identity. Repair it in Keychain Access rather than replacing the app identity.")
    with tempfile.TemporaryDirectory(prefix="localstt-signing-") as directory:
        temp = Path(directory)
        key, cert, bundle, config = [temp / name for name in ("private.pem", "certificate.pem", "identity.p12", "openssl.cnf")]
        config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = LocalSTT Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-config", str(config), "-keyout", str(key), "-out", str(cert)])
        key.chmod(0o600)
        password = secrets.token_urlsafe(32)
        password_file = temp / "password"
        password_file.write_text(password)
        password_file.chmod(0o600)
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert), "-name", NAME, "-out", str(bundle), "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-passout", "file:" + str(password_file)])
        bundle.chmod(0o600)
        run(["/usr/bin/security", "import", str(bundle), "-k", keychain, "-f", "pkcs12", "-P", password, "-x", "-T", "/usr/bin/codesign"])
        run(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, str(cert)])
    configure(NAME)

if __name__ == "__main__":
    try:
        command = sys.argv[1] if len(sys.argv) > 1 else "identity"
        if command == "identity": print(selected_identity())
        elif command == "use" and len(sys.argv) == 3: configure(sys.argv[2])
        elif command == "create-local": create_local()
        else: raise RuntimeError("Usage: signing.py identity | use <certificate name or SHA-1> | create-local")
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
