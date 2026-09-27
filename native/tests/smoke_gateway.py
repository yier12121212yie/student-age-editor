#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""网页版计划 M2 黑盒冒烟（backend_gateway，stdlib-only，一次性驱动脚本）。

Linux/POSIX ONLY：网关的实例池依赖 fork/exec，Windows 上不构建该 target。
Windows 侧复跑方式（本脚本本体在 Linux 里跑）：
    wsl.exe -d Ubuntu-24.04 -e python3 /mnt/d/workspace/editor/native/tests/smoke_gateway.py

覆盖（全部走真 socket，独立 temp 环境，绝不碰真实数据）：
  A) --hash-password 输出格式（salt:hash，32+64 位小写 hex）；
  B) 登录流：坏密码 401 / 好密码 200+token / whoami / logout 后旧 token 401；
  C) 反代懒启动：带 Bearer 的 GET /api/state 透传到该账号的 backend 实例
     （workspace_root == 账号目录）；无 token 401；封禁端点 403；
  D) 静态托管：非 /api 的 GET / -> web_root/index.html；
  E) /api/ai/policy 如实上报（relay off）+ 未启用时 /api/ai/relay/chat 503；
  F) 退出清理：网关 SIGTERM 后，它拉起的 backend 实例不留孤儿。

用法（仓库根）：
    python3 native/tests/smoke_gateway.py [--gateway <exe>] [--backend <exe>]
缺省取 native/build-wsl/bin/{backend_gateway,backend}。退出码 0 = 全过。
"""
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
BIN = os.path.join(REPO, "native", "build-wsl", "bin")
DEFAULT_GATEWAY = os.path.join(BIN, "backend_gateway")
DEFAULT_BACKEND = os.path.join(BIN, "backend")

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


def req(method, url, token=None, body=None, timeout=90):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def argv_flag(exe, args, tmo=30):
    return subprocess.run([exe] + args, capture_output=True, timeout=tmo)


def main():
    gateway = DEFAULT_GATEWAY
    backend = DEFAULT_BACKEND
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--gateway":
            gateway = args[i + 1]
            i += 2
        elif args[i] == "--backend":
            backend = args[i + 1]
            i += 2
        else:
            print("unknown arg:", args[i])
            return 2
    if not os.path.isfile(gateway) or not os.access(gateway, os.X_OK):
        print("gateway exe not found/executable:", gateway)
        return 2
    if not os.path.isfile(backend):
        print("backend exe not found:", backend)
        return 2

    tmp = tempfile.mkdtemp(prefix="gwsmoke_")
    data_root = os.path.join(tmp, "data")
    web_root = os.path.join(tmp, "web")
    os.makedirs(web_root)
    with open(os.path.join(web_root, "index.html"), "w") as f:
        f.write("<html><body>GWSTATIC</body></html>")
    ws_a = os.path.join(data_root, "alice")

    # A) --hash-password: inline and stdin forms, format + determinism.
    h = argv_flag(gateway, ["--hash-password", "s3cret"])
    check("hash-password exit0", h.returncode == 0, h.stderr.decode())
    line = h.stdout.decode().strip()
    m = re.fullmatch(r"([0-9a-f]{32}):([0-9a-f]{64})", line)
    check("hash-password format", bool(m), line)
    h2 = subprocess.run([gateway, "--hash-password"], input=b"s3cret\n",
                        capture_output=True, timeout=30)
    m2 = re.fullmatch(r"([0-9a-f]{32}):([0-9a-f]{64})", h2.stdout.decode().strip())
    check("hash-password stdin form", bool(m2), h2.stdout.decode())
    check("hash-password salt random", m and m2 and m.group(1) != m2.group(1))

    # gateway.json for the run.
    salt, pwdhash = m.group(1), m.group(2)
    cfg = {
        "user_data_root": data_root,
        "web_root": web_root,
        "listen_port": 8770,
        "trusted_origins": ["https://editor.test"],
        "session_ttl_hours": 24,
        "instance": {"max": 4, "idle_minutes": 30},
        "state_dir": None,
        "accounts": [
            {"name": "alice", "salt": salt, "password_sha256": pwdhash,
             "data_dir": None, "disabled": False},
        ],
        "ai_relay": {"enabled": False, "provider": "openai_compatible",
                     "base_url": "", "api_key": "", "models": [], "daily_limit": 0},
    }
    cfg_path = os.path.join(tmp, "gateway.json")
    with open(cfg_path, "w") as f:
        f.write(json.dumps(cfg))

    port_file = os.path.join(tmp, "gw.port")
    log_file = os.path.join(tmp, "gw.log")
    env = dict(os.environ, EDITOR_GATEWAY_BACKEND_EXE=backend)
    with open(log_file, "wb") as lf:
        proc = subprocess.Popen(
            [gateway, "--config", cfg_path, "--port", "0", "--write-port", port_file],
            stdout=lf, stderr=lf, env=env, start_new_session=True)
    try:
        t0 = time.time()
        port = None
        while time.time() - t0 < 20:
            try:
                with open(port_file) as f:
                    txt = f.read().strip()
                if txt:
                    port = int(txt)
                    break
            except (OSError, ValueError):
                pass
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        check("gateway boots + writes port", port is not None,
              "log:\n" + open(log_file).read())
        if port is None:
            return finish(tmp)
        base = "http://127.0.0.1:%d" % port

        # B) login flow.
        st, body = req("POST", base + "/api/auth/login", body={"name": "alice", "password": "BAD"})
        check("login wrong pw 401", st == 401 and json.loads(body).get("error") == "invalid credentials",
              "%d %s" % (st, body[:120]))
        st, body = req("POST", base + "/api/auth/login", body={"name": "ghost", "password": "x"})
        check("login unknown 401", st == 401, str(st))
        st, body = req("POST", base + "/api/auth/login", body={"name": "alice", "password": "s3cret"})
        check("login ok 200", st == 200, "%d %s" % (st, body[:120]))
        tok = json.loads(body).get("token", "") if st == 200 else ""
        check("login token 64hex", re.fullmatch(r"[0-9a-f]{64}", tok) is not None)
        st, body = req("GET", base + "/api/auth/whoami", token=tok)
        check("whoami 200", st == 200 and json.loads(body).get("name") == "alice", str(st))

        # C) reverse proxy: lazy boot + account workspace + auth/ban gates.
        st, body = req("GET", base + "/api/state", token=tok)
        ok_proxy = st == 200 and os.path.realpath(json.loads(body).get("workspace_root", "")) == \
            os.path.realpath(ws_a)
        check("proxy /api/state booted instance for acct", ok_proxy,
              "%d %s" % (st, body[:200]))
        st, _ = req("GET", base + "/api/state")
        check("proxy without token 401", st == 401, str(st))
        st, body = req("POST", base + "/api/workspace", token=tok, body={"path": "/etc"})
        check("POST /api/workspace banned 403", st == 403 and
              json.loads(body).get("error") == "endpoint disabled in hosted mode", str(st))
        st, _ = req("PUT", base + "/api/ai/settings", token=tok, body={"apiKey": "x"})
        check("PUT /api/ai/settings banned 403", st == 403, str(st))

        # D) static hosting.
        st, body = req("GET", base + "/")
        check("static GET / index", st == 200 and b"GWSTATIC" in body, str(st))
        st, _ = req("GET", base + "/nope-missing")
        check("static missing 404", st == 404, str(st))

        # E) AI policy + relay.
        st, body = req("GET", base + "/api/ai/policy", token=tok)
        pol = json.loads(body) if st == 200 else {}
        check("policy relay off", st == 200 and pol.get("relay_available") is False and
              pol.get("own_key_allowed") is True and pol.get("tts_image_available") is False,
              "%d %s" % (st, body[:200]))
        st, _ = req("POST", base + "/api/ai/relay/chat", token=tok,
                    body={"model": "gpt-4", "messages": []})
        check("relay disabled 503", st == 503, str(st))
        st, _ = req("POST", base + "/api/ai/relay/chat", body={"model": "gpt-4"})
        check("relay no token 401", st == 401, str(st))

        # F) logout kills the token (proxy + whoami).
        st, _ = req("POST", base + "/api/auth/logout", token=tok)
        check("logout 200", st == 200, str(st))
        st, _ = req("GET", base + "/api/auth/whoami", token=tok)
        check("stale token 401", st == 401, str(st))

        # instance port file exists while live.
        check("instance port file", os.path.isfile(os.path.join(data_root, ".gateway", "alice.port")))
    finally:
        if proc.poll() is None:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            proc.wait(timeout=10)
    time.sleep(0.5)
    gone = subprocess.run(["pgrep", "-f", ws_a], capture_output=True)
    check("backend instance cleaned up on gateway exit", gone.returncode != 0,
          "leftover pids: " + gone.stdout.decode())
    return finish(tmp)


def finish(tmp):
    print("RESULT: %d passed, %d failed" % (PASS, FAIL))
    try:
        subprocess.run(["rm", "-rf", tmp], timeout=60)
    except Exception:
        pass
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
