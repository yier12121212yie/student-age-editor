# -*- coding: utf-8 -*-
"""网页版计划 M0.5 黑盒冒烟：base64 zip 上传安装端点（一次性驱动脚本）。

覆盖（全部走真 socket，独立 temp 环境，绝不碰真实 Mods / 插件目录）：
  A) /api/plugins/install_upload：
     - 最小合法插件 zip（manifest.json 带 id）→ 200 {ok,id,plugin}，
       与 install_path 同管线（随后 /api/plugins/<id> 可读、DELETE 可清理）；
     - 非法 zip（随机字节）→ 400，错误文案与路径端点一致；
     - data_base64 缺失 / 非法 base64 → 400；
     - 超过 100MB 解码上限（少量字节充长度）→ 413；
     - filename 路径穿越成分（../evil.zip）被剥离，安装仍成功。
  B) /api/resource_packs/import_upload：非法 zip → 400（与 import_path
     同包络）；缺 data_base64 → 400。
  C) install_path 既有行为不变（未传 filename 也能装）——新端点不许扰动老路。

用法（仓库根）：
    python native/tests/smoke_upload.py [--backend <exe>]
缺省取 native/build/bin/backend(.exe)。退出码 0 = 全部断言通过。
"""
import base64
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

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


def request(url, method="GET", body=None, headers=None, timeout=30):
    req = urllib.request.Request(url, method=method, data=body,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


class Runner:
    """起 backend --port 0 --write-port（temp 工作区 + temp 数据根），
    轮询端口文件；stop() 走 /api/shutdown，没退就 kill。"""

    def __init__(self, backend):
        self.backend = backend
        self.proc = None
        self.port_file = None
        self.ws = None
        self.data_root = None
        self.base = None

    def __enter__(self):
        self.ws = tempfile.mkdtemp(prefix="sa_smoke_ws_")
        self.data_root = tempfile.mkdtemp(prefix="sa_smoke_data_")
        self.port_file = os.path.join(self.data_root, "port.txt")
        env = dict(os.environ)
        env["EDITOR_DATA_ROOT"] = self.data_root
        env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
        self.proc = subprocess.Popen(
            [self.backend, "--workspace-root", self.ws,
             "--port", "0", "--write-port", self.port_file],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while time.time() < deadline:
            if os.path.exists(self.port_file):
                try:
                    port = int(open(self.port_file).read().strip())
                    self.base = "http://127.0.0.1:%d" % port
                    break
                except (ValueError, OSError):
                    pass
            if self.proc.poll() is not None:
                raise RuntimeError("backend exited early: %s" % self.proc.returncode)
            time.sleep(0.05)
        if self.base is None:
            raise RuntimeError("backend did not write port file in time")
        return self

    def __exit__(self, *exc):
        if self.base:
            try:
                request(self.base + "/api/shutdown", method="POST")
            except Exception:
                pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)

    def api(self, path, method="GET", body=None, headers=None, timeout=30):
        data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
        return request(self.base + path, method=method, body=data, headers=headers,
                       timeout=timeout)


def zip_bytes(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


def upload_body(data, filename="plugin.zip"):
    return {"filename": filename, "data_base64": base64.b64encode(data).decode()}


def main():
    backend = DEFAULT_BACKEND
    if "--backend" in sys.argv:
        backend = sys.argv[sys.argv.index("--backend") + 1]

    plugin_zip = zip_bytes({
        "manifest.json": json.dumps({"id": "smoke_upload_pl",
                                     "name": "Smoke Upload Plugin"}),
    })

    with Runner(backend) as r:
        # A) 合法插件 zip → 与 install_path 同包络的成功
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body=upload_body(plugin_zip))
        check("install_upload valid zip -> 200", st == 200, "%s %s" % (st, body[:200]))
        ok_doc = json.loads(body) if st == 200 else {}
        check("install_upload ok envelope", ok_doc.get("ok") is True
              and ok_doc.get("id") == "smoke_upload_pl", str(ok_doc)[:200])
        st, body = r.api("/api/plugins/smoke_upload_pl")
        check("installed plugin readable via GET", st == 200, "%s %s" % (st, body[:120]))
        st, _ = r.api("/api/plugins/smoke_upload_pl", method="DELETE")
        check("cleanup uninstall", st in (200, 204), str(st))

        # A) 非法 zip → 400（与路径端点同一管线的报错）
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body=upload_body(b"\x00\x01not-a-zip"))
        check("install_upload invalid zip -> 400", st == 400, "%s %s" % (st, body[:160]))
        check("invalid zip error text matches path endpoint",
              b"invalid zip" in body or b"not a zip" in body, body[:160])

        # A) 请求体缺 data_base64 / 非法 base64
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body={"filename": "x.zip"})
        check("missing data_base64 -> 400", st == 400, str(st))
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body={"filename": "x.zip", "data_base64": "!!!not-base64!!!"})
        check("bad base64 -> 400", st == 400, "%s %s" % (st, body[:160]))

        # A) 超 100MB 解码上限 → 413（用无压缩重复字节压长度，不真占磁盘）
        huge = b"A" * (100 * 1024 * 1024 + 16)
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body={"filename": "x.zip",
                               "data_base64": base64.b64encode(huge).decode()},
                         timeout=120)
        check("oversize -> 413", st == 413, "%s %s" % (st, body[:160]))

        # A) filename 穿越成分被剥离
        st, body = r.api("/api/plugins/install_upload", method="POST",
                         body=upload_body(plugin_zip, filename="../../evil.zip"))
        check("traversal filename still installs -> 200", st == 200,
              "%s %s" % (st, body[:200]))
        if st == 200:
            r.api("/api/plugins/smoke_upload_pl", method="DELETE")

        # A) 临时文件不留痕（editor_upload_*.zip 应被清理）
        leftover = [f for f in os.listdir(tempfile.gettempdir())
                    if f.startswith("editor_upload_")]
        check("temp staged zips removed", not leftover, str(leftover[:3]))

        # B) 资源包 upload 端点：非法 zip → 400；缺字段 → 400
        st, body = r.api("/api/resource_packs/import_upload", method="POST",
                         body=upload_body(b"\x00\x01not-a-zip"))
        check("pack import_upload invalid zip -> 400", st == 400,
              "%s %s" % (st, body[:160]))
        st, body = r.api("/api/resource_packs/import_upload", method="POST",
                         body={"filename": "p.zip"})
        check("pack import_upload missing data -> 400", st == 400, str(st))

        # C) install_path 既有行为不变
        tmp = tempfile.mkdtemp(prefix="sa_smoke_zips_")
        ppath = os.path.join(tmp, "plain.zip")
        open(ppath, "wb").write(plugin_zip)
        st, body = r.api("/api/plugins/install_path", method="POST",
                         body={"path": ppath})
        check("install_path legacy flow still 200", st == 200, "%s %s" % (st, body[:200]))
        if st == 200:
            r.api("/api/plugins/smoke_upload_pl", method="DELETE")

    print("RESULT: %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
