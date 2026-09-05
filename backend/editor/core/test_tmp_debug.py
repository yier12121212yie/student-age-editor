# -*- coding: utf-8 -*-
import dis, io
from editor.core import ref_rules


def test_debug_dis():
    buf = io.StringIO()
    dis.dis(ref_rules.check_refs, file=buf)
    out = buf.getvalue()
    print("\nLOAD_METHOD get:", out.count("LOAD_METHOD"), "| get calls:", out.count("'get'"))
    print("BINARY_SUBSCR:", out.count("BINARY_SUBSCR"))
    print("co_filename:", ref_rules.check_refs.__code__.co_filename)
    print("first lines of dis:")
    print("\n".join(out.splitlines()[:40]))
