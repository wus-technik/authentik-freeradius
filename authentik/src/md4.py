# MD4 (RFC 1320). authentik's Python links OpenSSL 3, which no longer offers
# MD4, and the NT hash MSCHAPv2 needs is MD4 over the UTF-16LE password.
import struct


def md4(data):
    def rol(v, s):
        v &= 0xFFFFFFFF
        return ((v << s) | (v >> (32 - s))) & 0xFFFFFFFF

    F = lambda x, y, z: (x & y) | (~x & z)  # noqa: E731
    G = lambda x, y, z: (x & y) | (x & z) | (y & z)  # noqa: E731
    H = lambda x, y, z: x ^ y ^ z  # noqa: E731
    msg = bytearray(data)
    bitlen = len(data) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    msg += struct.pack("<Q", bitlen)
    a, b, c, d = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
    for off in range(0, len(msg), 64):
        X = struct.unpack("<16I", bytes(msg[off:off + 64]))
        A, B, C, D = a, b, c, d
        for i in (0, 4, 8, 12):
            A = rol(A + F(B, C, D) + X[i], 3)
            D = rol(D + F(A, B, C) + X[i + 1], 7)
            C = rol(C + F(D, A, B) + X[i + 2], 11)
            B = rol(B + F(C, D, A) + X[i + 3], 19)
        for i in (0, 1, 2, 3):
            A = rol(A + G(B, C, D) + X[i] + 0x5A827999, 3)
            D = rol(D + G(A, B, C) + X[i + 4] + 0x5A827999, 5)
            C = rol(C + G(D, A, B) + X[i + 8] + 0x5A827999, 9)
            B = rol(B + G(C, D, A) + X[i + 12] + 0x5A827999, 13)
        for i in (0, 2, 1, 3):
            A = rol(A + H(B, C, D) + X[i] + 0x6ED9EBA1, 3)
            D = rol(D + H(A, B, C) + X[i + 8] + 0x6ED9EBA1, 9)
            C = rol(C + H(D, A, B) + X[i + 4] + 0x6ED9EBA1, 11)
            B = rol(B + H(C, D, A) + X[i + 12] + 0x6ED9EBA1, 15)
        a, b, c, d = [(p + q) & 0xFFFFFFFF for p, q in ((a, A), (b, B), (c, C), (d, D))]
    return struct.pack("<4I", a, b, c, d)
