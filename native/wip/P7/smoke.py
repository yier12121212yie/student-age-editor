# -*- coding: utf-8 -*-
"""P7 CLI black-box smoke: full command surface against an isolated temp data
root, mirroring the tools/golden_env.py recipe (EDITOR_DATA_ROOT / PLUGINS /
PACKS + EDITOR_DISABLE_STEAM_DETECT=1; nothing ever touches the real game
Mods or the user's editor_env.json).

Every subcommand is asserted on BOTH its exit code and its stdout JSON.
Flow: fixture mod import -> cfg set/get/patch roundtrip -> history ->
validate -> bugfix scan/fix -> story import/export idempotent roundtrip ->
env set/get -> oobe done -> mods list selection state -> cleanup.

Usage:
    python native/wip/P7/smoke.py [path\\to\\backend_cli.exe]

Exit 0 == all checks PASS.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.abspath(os.path.join(HERE, "..", ".."))

CHECKS = []  # (name, ok, detail)


def check(name, cond, detail=""):
    CHECKS.append((name, bool(cond), detail))
    print("%-52s %s%s" % (name, "PASS" if cond else "FAIL",
                          "" if cond else "  -> " + detail))
    return bool(cond)


def find_cli():
    if len(sys.argv) > 1:
        return sys.argv[1]
    cand = os.path.join(NATIVE, "build", "bin", "backend_cli.exe")
    if os.path.isfile(cand):
        return cand
    cand = os.path.join(NATIVE, "build", "bin", "backend_cli.exe")
    return cand


class Ctx:
    def __init__(self, cli, data_root, workspace):
        self.cli = cli
        self.data = data_root
        self.ws = workspace
        self.env = dict(os.environ)
        self.env["EDITOR_DATA_ROOT"] = data_root
        self.env["EDITOR_PLUGINS_ROOT"] = os.path.join(data_root, "plugins")
        self.env["EDITOR_PACKS_ROOT"] = os.path.join(data_root, "resource_packs")
        self.env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
        self.env.pop("EDITOR_OOBE", None)
        self.env.pop("EDITOR_NO_OOBE", None)

    def run(self, *args, expect_rc=0, json_out=True, url=None):
        cmd = [self.cli]
        if url:
            cmd += ["--url", url]
        else:
            cmd += ["--data-root", self.data, "--workspace", self.ws]
        if json_out:
            cmd += ["--json"]
        cmd += list(args)
        p = subprocess.run(cmd, env=self.env, capture_output=True, timeout=120)
        out = p.stdout.decode("utf-8", "replace")
        err = p.stderr.decode("utf-8", "replace")
        body = None
        if json_out and out.strip():
            try:
                body = json.loads(out)
            except ValueError:
                err += "\n[stdout not JSON: %r]" % out[:200]
        if expect_rc is not None and p.returncode != expect_rc:
            check("rc(%s)" % " ".join(args), False,
                  "got %d want %d err=%s" % (p.returncode, expect_rc, err[:400]))
        return p.returncode, body, out, err


def make_fixture_mod(root, name, with_cfg=True):
    """Minimal hand-built mod: Cfgs/zh-cn + manifest.json (same shape the
    Python selftest relies on via /api/mods/create)."""
    mod = os.path.join(root, name)
    os.makedirs(os.path.join(mod, "Cfgs", "zh-cn"), exist_ok=True)
    if with_cfg:
        with open(os.path.join(mod, "Cfgs", "zh-cn", "EvtCfg.json"), "w", encoding="utf-8") as f:
            json.dump({"101": {"id": 101, "title": "测试事件", "type": 1}},
                      f, ensure_ascii=False)
    with open(os.path.join(mod, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"title": name, "description": "smoke fixture", "version": "1.0.0"},
                  f, ensure_ascii=False, indent=2)
    return mod


def main():
    cli = find_cli()
    if not os.path.isfile(cli):
        print("ERROR: backend_cli.exe not found at %s" % cli)
        return 2

    root = tempfile.mkdtemp(prefix="p7_smoke_")
    try:
        data = os.path.join(root, "data")
        ws = os.path.join(root, "workspace")
        os.makedirs(data)
        os.makedirs(ws)
        # Clean-user preseed: workspace already chosen, OOBE NOT completed yet
        # (the flow below completes it).
        with open(os.path.join(data, "editor_env.json"), "w", encoding="utf-8") as f:
            json.dump({"workspace_root": ws}, f, ensure_ascii=False, indent=2)
        ctx = Ctx(cli, data, ws)

        # -- oobe status: first run --
        rc, body, _, err = ctx.run("oobe", "status")
        check("oobe status first_run", rc == 0 and body and body.get("first_run") is True,
              str(body) + err)

        # -- mods: import fixture directory (path form of "add") --
        src = make_fixture_mod(os.path.join(root, "srcmods"), "FixtureMod")
        rc, body, _, err = ctx.run("mods", "add", "--path", src, "--name", "Imported")
        mod = (body or {}).get("mod") or {}
        check("mods add --path selects", rc == 0 and mod.get("name") == "Imported",
              str(body) + err)

        # -- mods: create --
        rc, body, _, err = ctx.run("mods", "create", "CliMod", "--desc", "cli smoke")
        check("mods create", rc == 0 and ((body or {}).get("mod") or {}).get("name") == "CliMod",
              str(body) + err)

        # -- mods: zip import --
        zmod = make_fixture_mod(os.path.join(root, "srcmods"), "ZipMod")
        zpath = os.path.join(root, "zipmod.zip")
        with __import__("zipfile").ZipFile(zpath, "w") as z:
            for dirpath, _, names in os.walk(zmod):
                for n in names:
                    full = os.path.join(dirpath, n)
                    z.write(full, os.path.relpath(full, os.path.dirname(zmod)))
        rc, body, _, err = ctx.run("mods", "add", "--zip", zpath)
        check("mods add --zip", rc == 0 and ((body or {}).get("mod") or {}).get("name") == "ZipMod",
              str(body) + err)

        # -- cfg set/get roundtrip (PUT whole table) --
        table = {"9001": {"id": 9001, "content": "第一行", "showTxt": None},
                 "9002": {"id": 9002, "content": "第二行", "showTxt": None}}
        sfile = os.path.join(root, "table.json")
        with open(sfile, "w", encoding="utf-8") as f:
            json.dump(table, f, ensure_ascii=False)
        rc, body, _, err = ctx.run("cfg", "set", "TextCfg", "--file", sfile)
        check("cfg set ok", rc == 0 and body and body.get("ok") is True and body.get("cfg") == "TextCfg",
              str(body) + err)
        rc, g2, _, err = ctx.run("cfg", "get", "TextCfg")
        check("cfg get mirrors written table",
              rc == 0 and g2 and g2.get("exists") is True and g2.get("data") == table,
              json.dumps(g2, ensure_ascii=False)[:200] + err)

        # -- cfg patch (apply_patch semantics; no PATCH verb, body key) --
        rc, p1, _, err = ctx.run("cfg", "patch", "TextCfg", "--set",
                                 json.dumps({"9003": {"id": 9003, "content": "第三行"}},
                                            ensure_ascii=False),
                                 "--remove", "9001")
        check("cfg patch applied counts",
              rc == 0 and p1 and p1.get("ok") is True and p1.get("applied_set") == 1
              and p1.get("applied_remove") == 1, str(p1) + err)
        rc, g3, _, err = ctx.run("cfg", "get", "TextCfg")
        data3 = (g3 or {}).get("data") or {}
        check("cfg get after patch",
              rc == 0 and "9001" not in data3 and "9003" in data3, str(list(data3))[:200])

        # -- cfg history: patch wrote a snapshot --
        rc, h, _, err = ctx.run("cfg", "history", "TextCfg")
        check("cfg history lists snapshots",
              rc == 0 and h and h.get("cfg") == "TextCfg" and len(h.get("entries", [])) >= 1,
              str(h) + err)

        # -- validate --
        rc, v, _, err = ctx.run("validate", "TextCfg")
        check("validate shape",
              rc == 0 and v and v.get("cfg") == "TextCfg" and "issues" in v and "counts" in v,
              str(v)[:200] + err)
        rc, v, _, err = ctx.run("validate", "TextCfg", "--data", "{\"1\": {}}")
        check("validate --data explicit", rc == 0 and v and v.get("cfg") == "TextCfg", str(v)[:200])

        # -- bugfix scan (+ fix no-op path) --
        rc, s, _, err = ctx.run("bugfix", "scan")
        check("bugfix scan shape", rc == 0 and s and isinstance(s.get("bugs"), list)
              and s.get("count") == len(s.get("bugs", [])), str(s)[:200] + err)
        rc, fx, _, err = ctx.run("bugfix", "fix")
        check("bugfix fix runs", rc == 0 and fx and "fixed" in fx and "remaining_count" in fx,
              str(fx)[:200] + err)

        # -- story import/export roundtrip (idempotent) --
        script = "【甲】你好，同学！\n【甲】我们一起去操场吧。\n【选择】去操场 => evt:102\n【选择】回教室 => end:1\n"
        script_file = os.path.join(root, "story.txt")
        with open(script_file, "w", encoding="utf-8") as f:
            f.write(script)
        rc, imp, _, err = ctx.run("story", "import", "--start-id", "101",
                                  "--file", script_file, "--write")
        check("story import write", rc == 0 and imp and imp.get("ok") is True
              and imp.get("write") is True and imp.get("count", 0) >= 1, str(imp)[:200] + err)
        rc, ex1, _, err = ctx.run("story", "export", "--evt", "101")
        check("story export", rc == 0 and ex1 and isinstance(ex1.get("text"), str)
              and "你好，同学" in ex1.get("text", ""), str(ex1)[:200] + err)
        # Re-import the same script: replacement is idempotent.
        rc, imp2, _, err = ctx.run("story", "import", "--start-id", "101",
                                   "--file", script_file, "--write")
        rc, ex2, _, err = ctx.run("story", "export", "--evt", "101")
        check("story roundtrip idempotent",
              rc == 0 and ex1.get("text") == ex2.get("text"),
              "\n--- first ---\n%s\n--- second ---\n%s" % (str(ex1)[:300], str(ex2)[:300]))
        # --out file form
        ofile = os.path.join(root, "exported.txt")
        rc, _, out_txt, err = ctx.run("story", "export", "--evt", "101", "--out", ofile,
                                      json_out=False)
        ok_file = os.path.isfile(ofile)
        if ok_file:
            with open(ofile, encoding="utf-8") as f:
                ok_file = "你好，同学" in f.read()
        check("story export --out file", rc == 0 and ok_file, out_txt + err)

        # -- env get/set (local editor_env.json) --
        rc, _, out, err = ctx.run("env", "get", "workspace_root", json_out=False)
        check("env get workspace_root", rc == 0 and out.strip() == ws, repr(out) + err)
        rc, body, _, err = ctx.run("env", "set", "smoke_key", "smoke_value")
        check("env set string", rc == 0 and body and body.get("ok") is True
              and body.get("value") == "smoke_value", str(body) + err)
        rc, body, _, err = ctx.run("env", "get", "smoke_key")
        check("env get roundtrip", rc == 0 and body == "smoke_value", str(body) + err)
        rc, body, _, err = ctx.run("env", "set", "smoke_num", "42", "--json-value")
        rc, body, _, err = ctx.run("env", "get", "smoke_num")
        check("env json-value roundtrip", rc == 0 and body == 42, str(body) + err)
        with open(os.path.join(data, "editor_env.json"), encoding="utf-8-sig") as f:
            env_disk = json.load(f)
        check("editor_env.json on disk", env_disk.get("smoke_key") == "smoke_value"
              and env_disk.get("smoke_num") == 42, str(env_disk))
        rc, _, _, _ = ctx.run("env", "get", "definitely_absent_key", expect_rc=1)
        check("env get missing -> exit 1", rc == 1)

        # -- oobe done then status --
        rc, body, _, err = ctx.run("oobe", "done")
        check("oobe done", rc == 0 and body and body.get("ok") is True, str(body) + err)
        rc, body, _, err = ctx.run("oobe", "status")
        check("oobe status after done",
              rc == 0 and body and body.get("done") is True and body.get("first_run") is False,
              str(body) + err)

        # -- mods list selection state + select/remove --
        rc, m1, _, err = ctx.run("mods", "select", "Imported")
        check("mods select Imported", rc == 0 and ((m1 or {}).get("mod") or {}).get("name") == "Imported",
              str(m1) + err)
        rc, lst, _, err = ctx.run("mods", "list")
        names = [m.get("name") for m in (lst or {}).get("mods", [])]
        check("mods list selected + complete",
              rc == 0 and lst.get("selected") == "Imported"
              and set(names) >= {"Imported", "CliMod", "ZipMod"},
              str(lst)[:200] + err)
        rc, _, _, err = ctx.run("mods", "select", "NoSuchMod", expect_rc=1)
        check("mods select missing -> exit 1", rc == 1)
        rc, body, _, err = ctx.run("mods", "remove", "ZipMod")
        check("mods remove", rc == 0 and body and body.get("ok") is True, str(body) + err)
        rc, lst2, _, err = ctx.run("mods", "list")
        check("mods list after remove",
              rc == 0 and "ZipMod" not in [m.get("name") for m in lst2.get("mods", [])],
              str(lst2)[:200])

        # -- error envelopes ride stdout with --json, exit 1 --
        rc, body, out, err = ctx.run("cfg", "get", "a:b", expect_rc=1)
        check("sandbox error keeps envelope + exit 1",
              rc == 1 and isinstance(body, dict) and "escapes" in body.get("error", "")
              and body.get("cfg") == "a:b",
              out[:200] + err)

        # -- global --mod selects per command (Python --mod parity) --
        rc, body, _, err = ctx.run("--mod", "Imported", "cfg", "list")
        check("--mod override", rc == 0 and body and body.get("mod") == "Imported",
              str(body) + err)
        rc, _, _, err = ctx.run("--mod", "GhostMod", "cfg", "list", expect_rc=1)
        check("--mod missing -> exit 1", rc == 1)

        # -- transport failure exit 3 (nothing listens on 8789) --
        rc, _, _, err = ctx.run("mods", "list", expect_rc=3,
                                url="http://127.0.0.1:8789")
        check("dead --url -> exit 3", rc == 3, err[:200])

        # -- usage error exit 2 --
        rc, _, _, _ = ctx.run("cfg", "set", "TextCfg", expect_rc=2, json_out=False)
        check("cfg set without data -> exit 2", rc == 2)

        n_ok = sum(1 for _, ok, _ in CHECKS if ok)
        print("RESULT: %s (%d/%d)" % ("PASS" if n_ok == len(CHECKS) else "FAIL",
                                      n_ok, len(CHECKS)))
        return 0 if n_ok == len(CHECKS) else 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
