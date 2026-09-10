# -*- coding: utf-8 -*-
"""W4-4: generate the [bundled] Catch2 fixtures (base64 zips built with
Python zipfile — same approach as test_plugins.cpp / p3b_zip_fixtures.h).

Prints a C++ header block to stdout. Expected extraction contents are also
printed for embedding. Deterministic: fixed dates + ZIP_DEFLATED.
"""
import base64
import hashlib
import io
import zipfile

def make_zip(entries, extra_bytes=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, date_time=(2026, 9, 10, 12, 0, 0))
            if name.endswith("/"):
                z.writestr(zi, b"")
            else:
                z.writestr(zi, data)
    b = buf.getvalue()
    if extra_bytes:
        b += extra_bytes  # trailing junk does not invalidate the zip
    return b

V1 = [
    ("plain.txt", "hello bundled\n".encode("utf-8")),
    ("media/", b""),
    ("media/song.dat", bytes(range(256)) * 3),          # binary with NULs
    ("sub/inner/nested.json", b'{"k": "\xe4\xb8\xad\xe6\x96\x87"}'),  # utf-8 bytes as content
    # hostile / skipped entries (mirrors __init__.py:56 filter):
    ("../escape.txt", b"must never exist"),
    ("/abs.txt", b"must never exist"),
    ("drive:c.txt", b"must never exist"),
    ("ok/../../bad.txt", b"must never exist"),
]
V2_EXTRA = ("sub/second.txt", b"v2 added file\n")

def emit(label, blob, entries_kept):
    b64 = base64.b64encode(blob).decode("ascii")
    digest = hashlib.md5(blob[: 1 << 20]).hexdigest()
    print("static const char k%sZipB64[] =\n%s;" % (label, "\n".join(
        '    "%s"' % b64[i:i + 96] for i in range(0, len(b64), 96))))
    print('static const char k%sMd5[] = "%s";' % (label, digest))
    print("// size=%d" % len(blob))

z1 = make_zip(V1)
z2 = make_zip(V1 + [V2_EXTRA])
broken = b"PK\x03\x04not a zip at all, just noise 0123456789"

emit("V1", z1, None)
emit("V2", z2, None)
b64b = base64.b64encode(broken).decode("ascii")
print('static const char kBrokenZipB64[] = "%s";' % b64b)
