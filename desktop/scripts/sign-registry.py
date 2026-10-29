#!/usr/bin/env python3
"""Sign desktop/crates/platform/resources/registry.json (dev helper).

Release rules (ADR-0026/ADR-0027): the built-in public key in manifest.rs is a
dev key; release builds must be re-signed by the release key owner. This script
is for local/staging only.

Usage:
  CGC_REGISTRY_PRIVATE_KEY=<base64 raw 32-byte seed> \
    python3 desktop/scripts/sign-registry.py

If the env var is absent a new dev key is generated and printed. Keep it outside
the repository; the script never writes the private key to disk.
"""
from __future__ import annotations

import base64
import os
import re
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "crates/platform/resources/registry.json"
SIGNATURE = ROOT / "crates/platform/resources/registry.sig"
MANIFEST_RS = ROOT / "crates/platform/src/registry/manifest.rs"
PUBLIC_KEY_RE = re.compile(r'(pub const BUILTIN_PUBLIC_KEY: &str = ")([^"]+)(";)')


def main() -> None:
    payload = MANIFEST.read_bytes()
    seed = os.environ.get("CGC_REGISTRY_PRIVATE_KEY")
    if seed:
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(seed))
    else:
        key = Ed25519PrivateKey.generate()
        raw = key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )
        print(f"generated dev private key (base64): {base64.b64encode(raw).decode()}")
        print("keep it outside the repository; release must rotate to the release key")
    public = key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    signature = key.sign(payload)
    SIGNATURE.write_text(base64.b64encode(signature).decode() + "\n")
    source = MANIFEST_RS.read_text()
    source, count = PUBLIC_KEY_RE.subn(
        lambda match: match.group(1) + base64.b64encode(public).decode() + match.group(3),
        source,
        count=1,
    )
    if count != 1:
        raise SystemExit("BUILTIN_PUBLIC_KEY constant not found")
    MANIFEST_RS.write_text(source)
    print("signed", MANIFEST.name, "->", SIGNATURE.name)


if __name__ == "__main__":
    main()
