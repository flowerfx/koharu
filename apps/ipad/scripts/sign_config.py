#!/usr/bin/env python3
"""Sign remote app-config.json for KoharuPad.

  python3 scripts/sign_config.py keygen private.key
      Writes a new Ed25519 private key (keep it out of the repository) and prints
      the base64 public key for the KOHARU_CONFIG_SIGNING_KEY build setting.

  python3 scripts/sign_config.py sign private.key app-config.json
      Writes app-config.json.sig next to the file. Upload both objects to the
      same S3 prefix; upload the .sig first so clients never see an unsigned body.

Requires: pip install cryptography
"""
import base64
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def public_text(key):
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def main(argv):
    if len(argv) == 3 and argv[1] == "keygen":
        path = Path(argv[2])
        if path.exists():
            sys.exit(f"{path} already exists")
        key = Ed25519PrivateKey.generate()
        path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        path.chmod(0o600)
        print("KOHARU_CONFIG_SIGNING_KEY =", public_text(key))
    elif len(argv) == 4 and argv[1] == "sign":
        key = serialization.load_pem_private_key(Path(argv[2]).read_bytes(), password=None)
        body = Path(argv[3]).read_bytes()
        signature = base64.b64encode(key.sign(body)).decode()
        Path(argv[3] + ".sig").write_text(signature + "\n")
        print("wrote", argv[3] + ".sig", "for public key", public_text(key))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
