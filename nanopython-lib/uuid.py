"""nanopython — uuid module (uuid4 only).

Pure Python; depends on `os.urandom` (C-side, feature-os). Ships the
`uuid4()` factory + `UUID` class covering `.bytes`, `.hex`, `int`,
`str()`, `__eq__`, `__hash__`.

Not shipped: uuid1/uuid3/uuid5 (MAC/name-based). Add if a caller
needs them.
"""
import os


class UUID:
    """RFC 4122 UUID. 128 bits, presented as five hex groups."""

    def __init__(self, hex=None, bytes=None, int=None):
        if bytes is not None:
            b = bytes
            if len(b) != 16:
                raise ValueError("bytes is not a 16-byte string")
            self._bytes = b
        elif int is not None:
            buf = bytearray(16)
            for i in range(15, -1, -1):
                buf[i] = int & 0xff
                int >>= 8
            self._bytes = builtins_bytes(buf)
        elif hex is not None:
            h = hex.replace("-", "").replace("{", "").replace("}", "").replace("urn:", "").replace("uuid:", "")
            if len(h) != 32:
                raise ValueError("badly formed hexadecimal UUID string")
            self._bytes = _hex_to_bytes(h)
        else:
            raise TypeError("UUID requires one of: bytes, int, hex")

    @property
    def bytes(self):
        return self._bytes

    @property
    def hex(self):
        return self._bytes.hex()

    @property
    def int(self):
        result = 0
        for b in self._bytes:
            result = (result << 8) | b
        return result

    def __str__(self):
        h = self._bytes.hex()
        return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]

    def __repr__(self):
        return "UUID('" + str(self) + "')"

    def __eq__(self, other):
        if isinstance(other, UUID):
            return self._bytes == other._bytes
        return NotImplemented

    def __hash__(self):
        return hash(self._bytes)


# Local alias so we can accept `bytes` as a kwarg name in UUID.__init__
# without shadowing the builtin.
builtins_bytes = bytes


def _hex_to_bytes(h):
    """Decode 32 hex chars → 16-byte bytes."""
    result = bytearray(16)
    for i in range(16):
        result[i] = int(h[i * 2 : i * 2 + 2], 16)
    return builtins_bytes(result)


def uuid4():
    """Generate a random UUID (RFC 4122 §4.4)."""
    raw = bytearray(os.urandom(16))
    # Set version 4 in high nibble of byte 6, variant 10 in bits 6-7 of byte 8.
    raw[6] = (raw[6] & 0x0f) | 0x40
    raw[8] = (raw[8] & 0x3f) | 0x80
    return UUID(bytes=builtins_bytes(raw))
