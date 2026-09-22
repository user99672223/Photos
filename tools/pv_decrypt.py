#!/usr/bin/env python3
"""Decrypt a PhotoVault blob.

Usage: pv_decrypt.py RECOVERY_STRING BLOB_UUID INPUT.enc OUTPUT
Requires: pip install cryptography
"""
import base64
import struct
import sys
import uuid

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    recovery, blob_id, src, dst = sys.argv[1:5]
    b32 = recovery.replace(" ", "").replace("-", "").upper()
    master = base64.b32decode(b32 + "=" * (-len(b32) % 8))
    if len(master) != 32:
        sys.exit("recovery string does not decode to 32 bytes")
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=uuid.UUID(blob_id).bytes,
        info=b"photovault-blob-v1",
    ).derive(master)
    aes = AESGCM(key)
    with open(src, "rb") as f, open(dst, "wb") as out:
        header = f.read(24)
        if header[:4] != b"PVLT" or header[4] != 1:
            sys.exit("not a PhotoVault blob")
        chunk_size, length = struct.unpack("<IQ", header[8:20])
        nonce_base = header[20:24]
        index = 0
        remaining = length
        while remaining > 0:
            want = min(chunk_size, remaining)
            sealed = f.read(want + 16)
            if len(sealed) != want + 16:
                sys.exit("truncated blob")
            # Nonce = nonceBase(4) || chunk index u64 LE; AAD = header || chunk index u64 LE.
            counter = struct.pack("<Q", index)
            out.write(aes.decrypt(nonce_base + counter, sealed, header + counter))
            index += 1
            remaining -= want


if __name__ == "__main__":
    main()
