# -*- coding: utf-8 -*-
"""网页版计划 M1 黑盒冒烟（一次性驱动脚本，不属于 golden 契约库）。

覆盖三块新面（全部走真 socket，不 import editor.* / 不依赖测试二进制）：
  A) 默认档 + --web-root 静态托管：/ -> index.html（no-cache）、资源缓存头、
     /api 优先、未命中 404 信封；桌面默认响应头逐字节不变。
  B) --trusted-origin server 档：白名单 Origin 200 + ACAO 回显 +
     Allow-Headers 含 Authorization；非白名单 403 forbidden origin 且无 ACAO；
     无 Origin 放行。
  C) --host 非 loopback（127.0.0.2，整个 127/8 都是回环，Windows/Linux 皆可
     bind）：POST /api/shutdown 被 403 门控拒绝。

绝不碰真实 Mods：workspace 用 temp 目录；只杀自己启动的 PID。

用法（仓库根）：
    python native/tests/smoke_web.py [--backend <exe>]
退出码 0 = 全部断言通过。
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
EXE = ".exe" if sys.platform == "win32" else ""
DEFAULT_BACKEND = os.path.join(REPO, "native", "build", "bin", "backend" + EXE)

PASS = 0
FAIL = 0


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print("PASS %s" % name)
    else:
        FAIL += 1
        print("FAIL %s  %s" % (name, detail))


class Runner:
    """start() 造 temp 工作区、起 backend --port 0 --write-port；stop() 先试
    /api/shutdown（默认档），没退就 kill。host = 实际 bind 地址（探测 URL 用）。"""

    def __init__(self, backend, extra_args=(), env=None, host="127.0.0.1"):
        self.backend = backend
        self.extra = list(extra_args)
        self.env = env
        self.host = host
        self.proc = None
        self.port_file = None
        self.ws = None

    def __enter__(self):
        self.ws = tempfile.mkdtemp(prefix="sa_smoke_web_")
        self.port_file = os.path.join(self.ws, ".port")
        argv = [self.backend, "--port", "0", "--write-port", self.port_file,
                "--workspace-root", self.ws] + self.extra
        e = dict(os.environ)
        e["EDITOR_DISABLE_STEAM_DETECT"] = "1"
        if self.env:
            e.update(self.env)
        self.proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, env=e)
        deadline = time.time() + 15
        while time.time() < deadline:
            if os.path.exists(self.port_file):
                try:
                    if os.path.getsize(self.port_file) > 0:
                        break
                except OSError:
                    pass
            if self.proc.poll() is not None:
                raise SystemExit("backend exited early rc=%s" % self.proc.returncode)
            time.sleep(0.05)
        else:
            self.proc.kill()
            raise SystemExit("backend did not write its port")
        with open(self.port_file) as f:
            self.port = int(f.read().strip())
        return self

    def __exit__(self, *_):
        try:
            self.post("/api/shutdown", {})
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
            self.proc.wait()
        import shutil
        shutil.rmtree(self.ws, ignore_errors=True)

    def url(self, path):
        return "http://%s:%d%s" % (self.host, self.port, path)

    def req(self, method, path, headers=None):
        r = urllib.request.Request(self.url(path), method=method,
                                   headers=headers or {})
        try:
            with urllib.request.urlopen(r, timeout=8) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def get(self, path, headers=None):
        return self.req("GET", path, headers)

    def post(self, path, body, headers=None):
        data = json.dumps(body).encode("utf-8")
        h = {"Content-Type": "application/json"}
        h.update(headers or {})
        r = urllib.request.Request(self.url(path), data=data, method="POST", headers=h)
        try:
            with urllib.request.urlopen(r, timeout=8) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()


def make_webroot():
    root = tempfile.mkdtemp(prefix="sa_webroot_")
    with open(os.path.join(root, "index.html"), "wb") as f:
        f.write(b"<html>WEB</html>")
    os.mkdir(os.path.join(root, "assets"))
    with open(os.path.join(root, "assets", "app.js"), "wb") as f:
        f.write(b"//bundle")
    return root


def t_default_static(root):
    with Runner(DEFAULT_BACKEND, ["--web-root", root]) as b:
        st, hd, body = b.get("/")
        check("static / -> 200 html", st == 200 and body == b"<html>WEB</html>",
              "st=%s body=%r" % (st, body[:40]))
        check("static / content-type", hd.get("Content-Type", "").startswith("text/html"),
              str(hd))
        check("static / no-cache", hd.get("Cache-Control") == "no-cache",
              str(hd.get("Cache-Control")))
        st, hd, _ = b.get("/assets/app.js")
        check("asset 200 + max-age", st == 200 and "max-age=3600" in hd.get("Cache-Control", ""),
              "st=%s cc=%s" % (st, hd.get("Cache-Control")))
        st, hd, body = b.get("/api/ping")
        ok = st == 200 and json.loads(body)["ok"] is True
        check("API precedence over catch-all", ok, "st=%s" % st)
        # 桌面默认档逐字节头块不变
        st, hd, body = b.get("/api/nope")
        check("default-tier fixed ACAO", hd.get("Access-Control-Allow-Origin") == "http://127.0.0.1",
              str(hd))
        check("404 contract envelope kept", st == 404 and json.loads(body)["error"] == "no route: GET /api/nope",
              "st=%s body=%r" % (st, body[:80]))
        st, hd, _ = b.get("/%2e%2e/escape.txt")
        check("traversal refused", st in (400, 403, 404), "st=%s" % st)


def t_default_no_static():
    with Runner(DEFAULT_BACKEND) as b:
        st, hd, body = b.get("/")
        check("no --web-root: / stays 404 JSON",
              st == 404 and json.loads(body)["error"] == "no route: GET /", "st=%s" % st)


def t_server_tier(root):
    with Runner(DEFAULT_BACKEND,
                ["--trusted-origin", "http://web.test", "--web-root", root]) as b:
        st, hd, _ = b.get("/api/ping", {"Origin": "http://web.test"})
        check("trusted origin 200", st == 200, "st=%s" % st)
        check("ACAO echoes origin", hd.get("Access-Control-Allow-Origin") == "http://web.test",
              str(hd))
        check("Authorization allowed", "Authorization" in hd.get("Access-Control-Allow-Headers", ""),
              str(hd.get("Access-Control-Allow-Headers")))
        st, hd, body = b.get("/api/ping", {"Origin": "http://evil.test"})
        check("untrusted origin 403", st == 403 and json.loads(body)["error"] == "forbidden origin",
              "st=%s body=%r" % (st, body[:60]))
        check("untrusted gets NO ACAO", "Access-Control-Allow-Origin" not in hd, str(hd))
        st, _, _ = b.get("/api/ping")
        check("no-origin passes", st == 200, "st=%s" % st)
        # 中继/策略端点存在（未配置 AI 时 policy 可用、relay 拒绝）
        st, _, body = b.get("/api/ai/policy")
        j = json.loads(body)
        check("policy shape", st == 200 and "relay_available" in j and "own_key_allowed" in j
              and j["stream"] is False, body[:120].decode())
        st, _, body = b.post("/api/ai/relay/chat", {"messages": []})
        check("relay 503 unconfigured", st == 503 and "not configured" in json.loads(body)["error"],
              "st=%s body=%r" % (st, body[:80]))


def t_shutdown_gate():
    # 127.0.0.2：整个 127/8 都是回环（Windows/Linux 均可 bind），但字符串非
    # "127.0.0.1"/"localhost"/"::1" -> run.cpp 判定 server 模式并关闭 shutdown。
    # 必须同时给 --trusted-origin：非 loopback 主机名要进 server 档才能被服务
    # （默认档对任何非 loopback Host 一律 forbidden host）。
    b = Runner(DEFAULT_BACKEND,
               ["--host", "127.0.0.2", "--trusted-origin", "http://127.0.0.2"],
               host="127.0.0.2")
    try:
        b.__enter__()
    except SystemExit:
        check("127.0.0.2 bind (skip if unsupported)", False, "could not bind alternate loopback")
        return
    try:
        st, _, body = b.post("/api/shutdown", {})
        check("shutdown 403 in server mode",
              st == 403 and "disabled" in json.loads(body)["error"], "st=%s body=%r" % (st, body[:80]))
        st, _, _ = b.get("/api/ping")
        check("alternate-loopback bind still serves", st == 200, "st=%s" % st)
    finally:
        # Runner.__exit__ would POST shutdown (403) then wait/kill anyway.
        b.proc.kill()
        b.proc.wait()
        import shutil
        shutil.rmtree(b.ws, ignore_errors=True)


def main():
    global DEFAULT_BACKEND
    args = sys.argv[1:]
    if args[:1] == ["--backend"]:
        DEFAULT_BACKEND = args[1]
    if not os.path.exists(DEFAULT_BACKEND):
        raise SystemExit("backend not built: %s (run native/build.cmd first)" % DEFAULT_BACKEND)
    root = make_webroot()
    try:
        t_default_static(root)
        t_default_no_static()
        t_server_tier(root)
        t_shutdown_gate()
    finally:
        import shutil
        shutil.rmtree(root, ignore_errors=True)
    print("RESULT: %s (%d passed, %d failed)" % ("PASS" if FAIL == 0 else "FAIL", PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
