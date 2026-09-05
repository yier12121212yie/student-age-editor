# -*- coding: utf-8 -*-
"""类 OpenList 云同步：Driver 抽象 + 单文件同步引擎

参考 OpenList internal/driver + internal/op 的分层：
  Driver 负责 List/Stat/Get/Put/Delete/Mkdir 的存储抽象
  SyncEngine 负责单文件的 hash 校验与冲突处理

首期驱动：
  local   - 本地目录映射，用于测试与局域网同步
  webdav  - 标准 WebDAV (PROPFIND/GET/PUT/DELETE/MKCOL)，兼容 坚果云、Alist、Nextcloud
  openlist/alist - 代理远端 OpenList 实例的 /api/fs/* 接口，一次配置即可复用其 40+ 存储

单文件同步语义：
  上传:  本地 file -> 远端 /mods/<mod>/<relPath>
  下载:  远端 -> 本地
  同步:  以 mtime+size+sha1 三元组判定，冲突时保留新者并备份旧者
"""
import base64
import hashlib
import json
import os
import sys
import time
import threading
import urllib.request
import urllib.parse
import urllib.error
import re

from editor.core import atomic_io

def _editor_root():
    from editor.core.paths import app_data_dir
    return app_data_dir()

def _cloud_config_path():
    # 优先 workspace 的 .editor_cloud.json，其次 _cache
    try:
        from editor.server.api import STATE as _ST
        ws = getattr(_ST, "workspace_root", "") if _ST else ""
        if ws and os.path.isdir(ws):
            return os.path.join(ws, ".editor_cloud.json")
    except Exception:
        pass
    return os.path.join(_editor_root(), "_cache", "cloud_config.json")

def _sync_state_path():
    return os.path.join(_editor_root(), "_cache", "cloud_sync_state.json")

# ---------- 工具 ----------

def _sha1_file(path):
    h = hashlib.sha1()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""

def _norm_remote(p):
    p = (p or "").replace("\\", "/").strip()
    p = re.sub(r"/+", "/", p)
    p = p.lstrip("/")
    if not p:
        return ""
    # 禁止越界
    if ".." in p.split("/"):
        raise ValueError("invalid remote path: %s" % p)
    return p


def _parse_http_date(s):
    """把 HTTP Last-Modified（RFC1123）或 RFC3339 时间串解析为 epoch 秒；失败返回 0。"""
    s = (s or "").strip()
    if not s:
        return 0
    try:
        import email.utils
        dt = email.utils.parsedate_to_datetime(s)
        if dt is not None:
            if dt.tzinfo is None:
                from datetime import timezone
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
    except Exception:
        pass
    try:
        from datetime import datetime, timezone as _tz
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        return int(dt.replace(tzinfo=_tz.utc).timestamp())
    except Exception:
        pass
    return 0


def _get_presigned(data):
    if not isinstance(data, dict):
        return {}
    for k in ["PreSignedUrls", "preSignedUrls", "presignedUrls", "presignedurls", "PreSignedURLS"]:
        if k in data and isinstance(data[k], dict):
            return data[k]
    for k,v in data.items():
        if "presigned" in k.lower() and isinstance(v, dict):
            return v
    return {}


def _http_request(url, method="GET", headers=None, data=None, timeout=30):
    h = dict(headers or {})
    # 使用浏览器 UA 避免被 Cloudflare 拦截（oplist.org 公共实例对 Python UA 返回 1010）
    if "User-Agent" not in h and "user-agent" not in h:
        h["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    # OpenList 需要的 Accept
    if "Accept" not in h:
        h["Accept"] = "application/json, text/plain, */*"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except Exception as e:
        raise

# ---------- Driver 抽象 ----------

class Obj:
    def __init__(self, name, path, is_dir, size=0, mtime=0, sha1=""):
        self.name = name
        self.path = path
        self.is_dir = is_dir
        self.size = size
        self.mtime = mtime
        self.sha1 = sha1
    def to_dict(self):
        return {"name": self.name, "path": self.path, "is_dir": self.is_dir, "size": self.size, "mtime": self.mtime, "sha1": self.sha1}

class BaseDriver:
    type_name = "base"
    def __init__(self, config):
        self.config = config or {}
    def test(self):
        raise NotImplementedError
    def list(self, remote_path):
        raise NotImplementedError
    def stat(self, remote_path):
        raise NotImplementedError
    def get(self, remote_path, local_path):
        raise NotImplementedError
    def put(self, local_path, remote_path):
        raise NotImplementedError
    def delete(self, remote_path):
        raise NotImplementedError
    def mkdir(self, remote_path):
        raise NotImplementedError
    def config_schema(self):
        return {}

# ---------- LocalDriver ----------

class LocalDriver(BaseDriver):
    type_name = "local"
    def _root(self):
        r = self.config.get("root") or self.config.get("path") or ""
        if not r:
            raise ValueError("local root required")
        return os.path.abspath(r)
    def _abs(self, remote_path):
        rp = _norm_remote(remote_path)
        base = self._root()
        abs_p = os.path.abspath(os.path.join(base, rp)) if rp else base
        if abs_p != base and not abs_p.startswith(base + os.sep):
            raise ValueError("path escapes root")
        return abs_p
    def test(self):
        r = self._root()
        if not os.path.isdir(r):
            raise ValueError("local root not found: %s" % r)
        return True
    def list(self, remote_path):
        ap = self._abs(remote_path)
        if not os.path.isdir(ap):
            return []
        out = []
        for name in sorted(os.listdir(ap)):
            fp = os.path.join(ap, name)
            rp = (_norm_remote(remote_path) + "/" + name).lstrip("/") if _norm_remote(remote_path) else name
            try:
                st = os.stat(fp)
                out.append(Obj(name, rp, os.path.isdir(fp), st.st_size if os.path.isfile(fp) else 0, int(st.st_mtime), ""))
            except Exception:
                continue
        return out
    def stat(self, remote_path):
        ap = self._abs(remote_path)
        if not os.path.exists(ap):
            return None
        st = os.stat(ap)
        name = os.path.basename(ap)
        rp = _norm_remote(remote_path)
        return Obj(name, rp, os.path.isdir(ap), st.st_size if os.path.isfile(ap) else 0, int(st.st_mtime), _sha1_file(ap) if os.path.isfile(ap) else "")
    def get(self, remote_path, local_path):
        ap = self._abs(remote_path)
        if not os.path.isfile(ap):
            raise FileNotFoundError(remote_path)
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        import shutil
        shutil.copy2(ap, local_path)
        return True
    def put(self, local_path, remote_path):
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        ap = self._abs(remote_path)
        os.makedirs(os.path.dirname(ap), exist_ok=True)
        import shutil
        shutil.copy2(local_path, ap)
        return True
    def delete(self, remote_path):
        ap = self._abs(remote_path)
        if os.path.isfile(ap):
            os.remove(ap)
        elif os.path.isdir(ap):
            import shutil
            shutil.rmtree(ap)
        return True
    def mkdir(self, remote_path):
        ap = self._abs(remote_path)
        os.makedirs(ap, exist_ok=True)
        return True
    def config_schema(self):
        return {"root": "本地根目录绝对路径"}

# ---------- WebDAVDriver ----------

class WebDAVDriver(BaseDriver):
    type_name = "webdav"
    def _base(self):
        u = (self.config.get("url") or self.config.get("address") or "").strip().rstrip("/")
        if not u:
            raise ValueError("webdav url required")
        if not u.startswith("http"):
            u = "https://" + u
        return u
    def _headers(self):
        h = {}
        user = self.config.get("username") or self.config.get("user") or ""
        pwd = self.config.get("password") or self.config.get("pass") or ""
        if user or pwd:
            token = base64.b64encode(("%s:%s" % (user, pwd)).encode()).decode()
            h["Authorization"] = "Basic " + token
        return h
    def _url(self, remote_path):
        base = self._base()
        rp = _norm_remote(remote_path)
        if rp:
            return base + "/" + urllib.parse.quote(rp, safe="/")
        return base + "/"
    def test(self):
        url = self._url("")
        headers = self._headers()
        headers["Depth"] = "0"
        body = b"<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/></prop></propfind>"
        headers["Content-Type"] = "application/xml"
        status, data, _ = _http_request(url, method="PROPFIND", headers=headers, data=body, timeout=15)
        if status in (207, 200, 301, 302):
            return True
        raise ValueError("webdav test failed: %s" % status)
    def list(self, remote_path):
        url = self._url(remote_path)
        headers = self._headers()
        headers["Depth"] = "1"
        headers["Content-Type"] = "application/xml"
        body = b"<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/><getcontentlength/><getlastmodified/><resourcetype/></prop></propfind>"
        status, data, _ = _http_request(url, method="PROPFIND", headers=headers, data=body, timeout=30)
        if status not in (207, 200):
            return []
        text = data.decode("utf-8", errors="ignore")
        # 简易解析：提取 href / displayname / length
        import re
        out = []
        # 分割 response 块
        blocks = re.split(r"<D:response|<response", text, flags=re.I)
        for blk in blocks[1:]:
            m_href = re.search(r"<D:href[^>]*>(.*?)</D:href>", blk, re.I | re.S)
            if not m_href:
                m_href = re.search(r"<href[^>]*>(.*?)</href>", blk, re.I | re.S)
            if not m_href:
                continue
            href = urllib.parse.unquote(m_href.group(1).strip())
            # 提取相对路径
            try:
                path_part = urllib.parse.urlparse(href).path
                base_path = urllib.parse.urlparse(self._base()).path.rstrip("/")
                rel = path_part
                if base_path and rel.startswith(base_path):
                    rel = rel[len(base_path):]
                rel = rel.strip("/")
                # 跳过自身
                if rel == _norm_remote(remote_path):
                    continue
                # 仅保留直接子级
                prefix = _norm_remote(remote_path)
                if prefix:
                    if not rel.startswith(prefix + "/"):
                        continue
                    tail = rel[len(prefix)+1:]
                else:
                    tail = rel
                if "/" in tail:
                    continue
                name = tail
                if not name:
                    continue
                is_dir = "<D:collection" in blk or "<collection" in blk
                m_len = re.search(r"<D:getcontentlength[^>]*>(.*?)</D:getcontentlength>", blk, re.I | re.S)
                size = int(m_len.group(1).strip()) if m_len and m_len.group(1).strip().isdigit() else 0
                m_lm = re.search(r"<[^>]*getlastmodified[^>]*>(.*?)</[^>]*getlastmodified>", blk, re.I | re.S)
                mtime = _parse_http_date(m_lm.group(1)) if m_lm else 0
                out.append(Obj(name, rel, is_dir, size, mtime, ""))
            except Exception:
                continue
        return out
    def stat(self, remote_path):
        # 用 PROPFIND Depth 0
        url = self._url(remote_path)
        headers = self._headers()
        headers["Depth"] = "0"
        headers["Content-Type"] = "application/xml"
        body = b"<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><getcontentlength/><resourcetype/><getlastmodified/></prop></propfind>"
        status, data, hdrs = _http_request(url, method="PROPFIND", headers=headers, data=body, timeout=15)
        if status not in (207, 200):
            return None
        text = data.decode("utf-8", errors="ignore")
        is_dir = "<D:collection" in text or "<collection" in text
        m_len = re.search(r"<D:getcontentlength[^>]*>(.*?)</D:getcontentlength>", text, re.I | re.S)
        size = int(m_len.group(1).strip()) if m_len and m_len.group(1).strip().isdigit() else 0
        m_lm = re.search(r"<[^>]*getlastmodified[^>]*>(.*?)</[^>]*getlastmodified>", text, re.I | re.S)
        mtime = _parse_http_date(m_lm.group(1)) if m_lm else 0
        return Obj(os.path.basename(_norm_remote(remote_path)), _norm_remote(remote_path), is_dir, size, mtime, "")
    def get(self, remote_path, local_path):
        url = self._url(remote_path)
        headers = self._headers()
        status, data, _ = _http_request(url, method="GET", headers=headers, timeout=60)
        if status != 200:
            raise ValueError("webdav get failed: %s" % status)
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(data)
        return True
    def put(self, local_path, remote_path):
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        # 确保父目录
        parent = os.path.dirname(_norm_remote(remote_path))
        if parent:
            self.mkdir(parent)
        url = self._url(remote_path)
        headers = self._headers()
        with open(local_path, "rb") as f:
            data = f.read()
        status, _, _ = _http_request(url, method="PUT", headers=headers, data=data, timeout=60)
        if status not in (200, 201, 204):
            raise ValueError("webdav put failed: %s" % status)
        return True
    def delete(self, remote_path):
        url = self._url(remote_path)
        headers = self._headers()
        status, _, _ = _http_request(url, method="DELETE", headers=headers, timeout=15)
        if status not in (200, 204, 404):
            raise ValueError("webdav delete failed: %s" % status)
        return True
    def mkdir(self, remote_path):
        parts = _norm_remote(remote_path).split("/")
        cur = ""
        for p in parts:
            cur = cur + "/" + p if cur else p
            url = self._url(cur)
            headers = self._headers()
            status, _, _ = _http_request(url, method="MKCOL", headers=headers, timeout=15)
            if status not in (201, 405, 200):
                # 405 已存在
                pass
        return True
    def config_schema(self):
        return {"url": "WebDAV 地址 (https://dav.example.com/path)", "username": "用户名", "password": "密码"}

# ---------- OpenListDriver (兼容 Alist/OpenList) ----------

class OpenListDriver(BaseDriver):
    type_name = "openlist"
    def _base(self):
        u = (self.config.get("url") or self.config.get("address") or "").strip().rstrip("/")
        if not u:
            raise ValueError("openlist url required")
        low = u.lower()
        # 拦截常见的误填：把 Token 刷新接口当成 OpenList 实例地址
        if "renewapi" in low or "googleui" in low or "baiduyun/renew" in low or "aliyundrive/renew" in low:
            raise ValueError("openlist url 填写错误：%s 是 Token 刷新接口（/renewapi），不是 OpenList 实例地址。请填你的 OpenList 服务地址，如 http://127.0.0.1:5244 或 http://host:5244" % u)
        if not u.startswith("http"):
            u = "http://" + u
        return u
    def _headers(self):
        h = {"Content-Type": "application/json"}
        token = self.config.get("token") or self.config.get("password") or ""
        if token:
            # OpenList 兼容 Alist 的 Authorization: token
            h["Authorization"] = token
        return h
    def _api(self, path, payload=None, method="POST"):
        url = self._base() + path
        headers = self._headers()
        data = json.dumps(payload or {}).encode() if payload is not None else None
        status, raw, _ = _http_request(url, method=method, headers=headers, data=data, timeout=30)
        if status != 200:
            body = raw[:800].decode(errors="ignore") if isinstance(raw, (bytes, bytearray)) else str(raw)[:800]
            if status == 403 and "1010" in body:
                raise ValueError("openlist api %s failed: 403 error code: 1010 (Cloudflare 拦截)。原因：OpenList 地址 %s 无法访问，可能是填错了地址（把 https://api.oplist.org/.../renewapi 当成了 OpenList 地址），或该公共服务已禁止此请求。请检查：1) OpenList 地址应为你的 OpenList 实例如 http://127.0.0.1:5244；2) 若走直连 Google Drive 请清空 OpenList 地址，仅填 refresh_token 并确保网络可访问 https://www.googleapis.com" % (path, self._base()))
            if status == 403:
                raise ValueError("openlist api %s failed: 403 Forbidden %s。检查 OpenList 地址/Token 是否正确，及防火墙/Cloudflare 是否拦截。" % (path, body[:300]))
            raise ValueError("openlist api %s failed: %s %s" % (path, status, raw[:500]))
        try:
            j = json.loads(raw.decode())
        except Exception as e:
            raise ValueError("openlist invalid json: %s" % e)
        if j.get("code") != 200:
            raise ValueError("openlist error: %s" % j.get("message"))
        return j.get("data")
    def test(self):
        # /api/me 或 /api/fs/list 根
        try:
            self._api("/api/me", {}, method="GET")
            return True
        except Exception:
            pass
        self.list("")
        return True
    def list(self, remote_path):
        rp = "/" + _norm_remote(remote_path)
        data = self._api("/api/fs/list", {"path": rp, "password": "", "page": 1, "per_page": 0, "refresh": True})
        out = []
        for item in (data.get("content") or []):
            name = item.get("name") or ""
            is_dir = bool(item.get("is_dir"))
            size = int(item.get("size") or 0)
            mtime = 0
            try:
                mtime = int(item.get("modified") or 0)
                # alist 可能是字符串
                if isinstance(item.get("modified"), str):
                    import datetime
                    dt = datetime.datetime.fromisoformat(item["modified"].replace("Z", "+00:00"))
                    mtime = int(dt.timestamp())
            except Exception:
                pass
            rel = (_norm_remote(remote_path) + "/" + name).lstrip("/") if _norm_remote(remote_path) else name
            out.append(Obj(name, rel, is_dir, size, mtime, ""))
        return out
    def stat(self, remote_path):
        rp = "/" + _norm_remote(remote_path)
        try:
            data = self._api("/api/fs/get", {"path": rp, "password": ""})
            # data 可能是文件对象
            if not data:
                return None
            name = data.get("name") or os.path.basename(rp)
            is_dir = bool(data.get("is_dir"))
            size = int(data.get("size") or 0)
            # mtime 必须解析：恒 0 会让"远端较新则跳过上传"守卫失效，
            # 双向同步退化为无条件本地覆盖远端
            mtime = 0
            try:
                if isinstance(data.get("modified"), str):
                    import datetime
                    dt = datetime.datetime.fromisoformat(
                        data["modified"].replace("Z", "+00:00"))
                    mtime = int(dt.timestamp())
                else:
                    mtime = int(data.get("modified") or 0)
            except (ValueError, TypeError, OSError):
                mtime = 0
            return Obj(name, _norm_remote(remote_path), is_dir, size, mtime, "")
        except Exception:
            return None
    def get(self, remote_path, local_path):
        rp = "/" + _norm_remote(remote_path)
        data = self._api("/api/fs/get", {"path": rp, "password": ""})
        raw_url = data.get("raw_url") or data.get("url") or ""
        if not raw_url:
            raise ValueError("no raw_url for %s" % remote_path)
        # 相对 url 需拼接 base
        if raw_url.startswith("/"):
            raw_url = self._base() + raw_url
        # 直接下载
        status, body, _ = _http_request(raw_url, method="GET", headers={}, timeout=60)
        if status != 200:
            raise ValueError("download failed: %s" % status)
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(body)
        return True
    def put(self, local_path, remote_path):
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        rp = "/" + _norm_remote(remote_path)
        # OpenList 上传：/api/fs/put 需 Stream，改为 /api/fs/form? path 兼容 alist
        # 使用 multipart
        import mimetypes
        url = self._base() + "/api/fs/put"
        # 简化：用 /api/fs/put 直传二进制，需 header File-Path
        headers = self._headers()
        headers["File-Path"] = urllib.parse.quote(rp, safe="/")
        headers["Content-Type"] = "application/octet-stream"
        with open(local_path, "rb") as f:
            data = f.read()
        status, raw, _ = _http_request(url, method="PUT", headers=headers, data=data, timeout=60)
        if status != 200:
            # 尝试 form 方式
            import http.client
            # fallback error
            raise ValueError("openlist put failed: %s %s" % (status, raw[:500]))
        j = json.loads(raw.decode())
        if j.get("code") != 200:
            raise ValueError("openlist put error: %s" % j.get("message"))
        return True
    def delete(self, remote_path):
        rp = "/" + _norm_remote(remote_path)
        self._api("/api/fs/remove", {"dir": os.path.dirname(rp) or "/", "names": [os.path.basename(rp)]})
        return True
    def mkdir(self, remote_path):
        rp = "/" + _norm_remote(remote_path)
        self._api("/api/fs/mkdir", {"path": rp})
        return True
    def config_schema(self):
        return {"url": "OpenList/Alist 地址 (http://host:5244)", "token": "Token (设置-后端-令牌)", "username": "可选用户名", "password": "可选密码"}


# ---------- 主流网盘驱动（类 OpenList，单文件/文件夹通用） ----------
# 为保持与 OpenList 配置兼容，字段名与 OpenList drivers/*/meta.go 的 Addition 对齐
# 实际实现上：若提供了 openlist_url，则走 OpenList 代理；否则尝试直连云 API（需 refresh_token/access_token）

class BaiduNetdiskDriver(BaseDriver):
    type_name = "baidu_netdisk"
    def _refresh(self):
        rt = self.config.get("refresh_token") or self.config.get("refreshToken") or ""
        if not rt:
            raise ValueError("baidu refresh_token required")
        # 优先尝试 OpenList 在线 API
        api_url = self.config.get("api_url_address") or "https://api.oplist.org/baiduyun/renewapi"
        try:
            status, raw, _ = _http_request(api_url + "?refresh_ui=" + __import__("urllib.parse").parse.quote(rt) + "&server_use=true&driver_txt=baiduyun_go", method="GET", headers={}, timeout=15)
            j = __import__("json").loads(raw.decode())
            if j.get("access_token") and j.get("refresh_token"):
                self.config["access_token"] = j["access_token"]
                self.config["refresh_token"] = j["refresh_token"]
                self._token = j["access_token"]
                return
        except Exception:
            pass
        # 回退到官方 OAuth
        cid = self.config.get("client_id") or self.config.get("clientId") or ""
        csec = self.config.get("client_secret") or self.config.get("clientSecret") or ""
        if not cid or not csec:
            # 无在线 API 也无 client，尝试直接使用 refresh_token 作为 access_token（部分旧 token）
            self._token = rt
            return
        status, raw, _ = _http_request("https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=" + __import__("urllib.parse").parse.quote(rt) + "&client_id=" + cid + "&client_secret=" + csec, method="GET", headers={}, timeout=15)
        j = __import__("json").loads(raw.decode())
        if not j.get("access_token"):
            raise ValueError(f"baidu 刷新失败: {j}")
        self._token = j["access_token"]
        self.config["access_token"] = j["access_token"]
        if j.get("refresh_token"):
            self.config["refresh_token"] = j["refresh_token"]
    def _ensure_token(self):
        if hasattr(self, "_token") and self._token:
            return
        if self.config.get("access_token"):
            self._token = self.config["access_token"]
            return
        self._refresh()
    def _api(self, path, method="GET", params=None, body=None):
        self._ensure_token()
        url = "https://pan.baidu.com" + path
        headers = {"User-Agent": "pan.baidu.com"}
        params = params or {}
        params["access_token"] = self._token
        # 使用 _http_request
        import json as _json, urllib.parse
        full = url + "?" + urllib.parse.urlencode(params)
        data = _json.dumps(body).encode() if body else None
        if data:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        status, raw, _ = _http_request(full, method=method, headers=headers, data=data, timeout=30)
        j = _json.loads(raw.decode())
        if j.get("errno") not in (0, None) or j.get("error_code") not in (0, None):
            # 尝试刷新一次
            self._refresh()
            params["access_token"] = self._token
            full = url + "?" + urllib.parse.urlencode(params)
            status, raw, _ = _http_request(full, method=method, headers=headers, data=data, timeout=30)
            j = _json.loads(raw.decode())
        if j.get("errno") not in (0, None) or j.get("error_code") not in (0, None):
            raise ValueError(f"baidu API {path} errno {j.get('errno')} error_code {j.get('error_code')}: {j}")
        return j
    def test(self):
        if self.config.get("root"):
            return LocalDriver(self.config).test()
        if self.config.get("openlist_url"):
            return OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""}).test()
        self._ensure_token()
        self._api("/rest/2.0/xpan/nas", params={"method":"uinfo"})
        return True
    def list(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.list(full)
        if self.config.get("root"):
            return LocalDriver(self.config).list(remote_path)
        rel = _norm_remote(remote_path)
        # 根目录为 / 时直接列出
        dir_path = "/" + rel if rel else "/"
        j = self._api("/rest/2.0/xpan/file", params={"method":"list", "dir":dir_path, "order":"name", "limit":"1000"})
        out=[]
        for fi in j.get("list") or []:
            name=fi["server_filename"]
            is_dir=fi["isdir"]==1
            size=fi.get("size") or 0
            try:
                mtime = int(fi.get("local_mtime") or fi.get("server_mtime") or 0)
            except Exception:
                mtime = 0
            full = (rel + "/" + name).strip("/") if rel else name
            out.append(Obj(name, full, is_dir, size, mtime, ""))
        return out
    def stat(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.stat(full)
        if self.config.get("root"):
            return LocalDriver(self.config).stat(remote_path)
        rel=_norm_remote(remote_path)
        parent="/".join(rel.split("/")[:-1])
        name=rel.split("/")[-1]
        for o in self.list(parent):
            if o.name==name:
                return o
        return None
    def mkdir(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.mkdir(full)
        if self.config.get("root"):
            return LocalDriver(self.config).mkdir(remote_path)
        rel=_norm_remote(remote_path)
        parent="/".join(rel.split("/")[:-1])
        name=rel.split("/")[-1]
        dir_path = "/" + parent if parent else "/"
        self._api("/rest/2.0/xpan/file", params={"method":"create", "access_token": self._token}, body={"path": dir_path + "/" + name, "isdir":1, "rtype":0})
        return True
    def delete(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.delete(full)
        if self.config.get("root"):
            return LocalDriver(self.config).delete(remote_path)
        rel=_norm_remote(remote_path)
        self._api("/rest/2.0/xpan/file", params={"method":"filemanager", "opera":"delete", "access_token": self._token}, body={"async":0, "filelist": '[{"path":"/' + rel + '"}]'})
        return True
    def get(self, remote_path, local_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.get(full, local_path)
        if self.config.get("root"):
            return LocalDriver(self.config).get(remote_path, local_path)
        rel=_norm_remote(remote_path)
        j=self._api("/rest/2.0/xpan/multimedia", params={"method":"filemetas", "target":'["/' + rel + '"]', "dlink":1})
        # filemetas 包含 dlink
        info=(j.get("list") or [{}])[0]
        dlink=info.get("dlink") or ""
        if not dlink:
            raise FileNotFoundError(rel)
        # dlink 需加 access_token
        url=dlink + "&access_token=" + self._token
        status, raw, _ = _http_request(url, method="GET", headers={"User-Agent":"pan.baidu.com"}, timeout=60)
        if status!=200:
            raise ValueError(f"baidu 下载失败 {status}")
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(raw)
        return True
    def put(self, local_path, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/baidu"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.put(local_path, full)
        if self.config.get("root"):
            return LocalDriver(self.config).put(local_path, remote_path)
        # 直连上传（小文件单片）
        rel=_norm_remote(remote_path)
        parent="/".join(rel.split("/")[:-1])
        name=rel.split("/")[-1]
        dir_path = "/" + parent if parent else "/"
        # 预创建
        size=os.path.getsize(local_path)
        # 获取上传需要的 block_list 需先计算 md5
        import hashlib
        with open(local_path, "rb") as f:
            data=f.read()
            md5=hashlib.md5(data).hexdigest()
            # 百度要求 block_list 为每 4M 分片的 md5，这里简化单片
            block_list = '["' + md5 + '"]'
        # create
        j=self._api("/rest/2.0/xpan/file", params={"method":"create", "access_token": self._token}, body={"path": dir_path + "/" + name, "isdir":0, "size":size, "rtype":0, "block_list": block_list})
        # 若返回 uploadid 则需上传数据，这里简化：若百度返回直接成功则完成，否则走 superfile2
        if j.get("errno")==0 and "path" in str(j):
            # 对于小文件，create 即可完成，无需额外上传（部分情况）
            return True
        # 否则尝试 superfile2（分片上传）简化为单片上传到 pcs
        # 使用 pcs 上传（path 必须做 URL 编码，mod/文件名常含中文与空格）
        remote_file_path = urllib.parse.quote(dir_path + "/" + name, safe="/")
        url = f"https://d.pcs.baidu.com/rest/2.0/pcs/superfile2?method=upload&access_token={self._token}&path={remote_file_path}&ondup=overwrite"
        with open(local_path, "rb") as f:
            status, raw, _ = _http_request(url, method="POST", headers={"Content-Type":"application/octet-stream"}, data=f.read(), timeout=60)
        if status not in (200,206):
            raise ValueError(f"baidu 上传失败 {status} {raw[:200]}")
        return True
    def config_schema(self):
        return {"refresh_token": "百度 refresh_token（必填）", "client_id": "Client ID（可选，官方 OAuth）", "client_secret": "Client Secret", "api_url_address": "在线刷新地址", "openlist_url": "OpenList 代理（可选）", "mount_path": "/baidu", "root": "本地测试根"}

class Pan123Driver(BaseDriver):
    type_name = "123"
    def _login(self):
        # 123 登录：优先使用已保存的 token，否则用 username/password 登录
        if self.config.get("access_token"):
            self._token = self.config["access_token"]
            return
        username = self.config.get("username") or self.config.get("passport") or ""
        password = self.config.get("password") or ""
        if not username or not password:
            raise ValueError("123 需要 username/password")
        # 调用 123 登录接口
        import json as _json
        data = {"passport": username, "password": password, "remember": True}
        if "@" in username:
            data = {"mail": username, "password": password, "type": 2}
        headers = {"origin": "https://www.123pan.com", "referer": "https://www.123pan.com/", "user-agent": "Mozilla/5.0", "platform": "web", "app-version": "3", "Content-Type": "application/json"}
        # 复用 _http_request
        import urllib.request, urllib.parse, urllib.error
        # 直接使用 _http_request 需构造
        url = "https://login.123pan.com/api/user/sign_in"
        body = _json.dumps(data).encode()
        status, raw, _ = _http_request(url, method="POST", headers=headers, data=body, timeout=15)
        try:
            j = _json.loads(raw.decode())
        except Exception:
            raise ValueError(f"123 登录失败: {raw[:200]}")
        if j.get("code") != 200:
            raise ValueError(f"123 登录失败: {j.get('message')}")
        self._token = j["data"]["token"]
        self.config["access_token"] = self._token

    def _api_request(self, url, method="GET", params=None, body=None, retry=True):
        if not hasattr(self, "_token") or not self._token:
            self._login()
        headers = {"origin": "https://www.123pan.com", "referer": "https://www.123pan.com/", "authorization": "Bearer " + self._token, "user-agent": "Mozilla/5.0", "platform": "web", "app-version": "3", "Content-Type": "application/json"}
        # 签名
        # 简化：直接调用 GetApi 逻辑（复用 Go 的 signPath）
        # 若失败则不加签
        try:
            # 构造签名 query
            import time as _time, random as _rand, binascii, os as _os
            table = b"adefghlmyijnopkqrstubcvwsz"
            rand_str = str(int(round(1e7*_rand.random())))
            now = _time.time()
            # CST
            timestamp = str(int(now))
            import datetime
            now_dt = datetime.datetime.fromtimestamp(now, tz=datetime.timezone(datetime.timedelta(hours=8)))
            now_str = now_dt.strftime("%Y%m%d%H%M").encode()
            tmp = bytearray(now_str)
            for i in range(len(tmp)):
                tmp[i] = table[tmp[i]-48]
            time_sign = str(binascii.crc32(tmp) & 0xffffffff)
            data = "|".join([timestamp, rand_str, urllib.parse.urlparse(url).path, "web", "3", time_sign])
            data_sign = str(binascii.crc32(data.encode()) & 0xffffffff)
            sign = f"{time_sign}={timestamp}-{rand_str}-{data_sign}"
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{sign}"
        except Exception:
            pass
        if params:
            qs = urllib.parse.urlencode(params)
            url = f"{url}&{qs}" if "?" in url else f"{url}?{qs}"
        data_bytes = None
        if body is not None:
            import json as _json
            data_bytes = _json.dumps(body).encode()
        status, raw, _ = _http_request(url, method=method, headers=headers, data=data_bytes, timeout=30)
        # 若返回 HTML（标题含 123云盘），尝试切换 yun/www 域名重试
        if raw[:15].lower().startswith(b"<!doctype"):
            # 尝试切换域名
            alt = url.replace("https://yun.123pan.com", "https://www.123pan.com") if "yun.123pan.com" in url else url.replace("https://www.123pan.com", "https://yun.123pan.com")
            if alt != url:
                status2, raw2, _ = _http_request(alt, method=method, headers=headers, data=data_bytes, timeout=30)
                if not raw2[:15].lower().startswith(b"<!doctype"):
                    raw = raw2
                    url = alt
        try:
            j = __import__("json").loads(raw.decode())
        except Exception:
            raise ValueError(f"123 API 非 JSON: {raw[:500]}")
        if j.get("code") not in (0,200):
            if j.get("code")==401 and retry:
                self._login()
                return self._api_request(url.split("?")[0], method, params, body, retry=False)
            raise ValueError(f"123 API 错误 {j.get('code')}: {j.get('message')}")
        return j

    def _resolve_path(self, remote_path):
        # 将路径转为 fileId，通过逐级 FileList
        rel = _norm_remote(remote_path)
        if not rel:
            return "0"
        parts = rel.split("/")
        cur_id = "0"
        for part in parts[:-1]:
            # 查找父目录下的同名文件夹
            j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":cur_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
            found = None
            for fi in j["data"]["InfoList"]:
                if fi["FileName"]==part and fi["Type"]==1:
                    found = fi
                    break
            if not found:
                # 目录不存在，需要创建
                self._api_request("https://yun.123pan.com/b/api/file/upload_request", method="POST", body={"driveId":0,"etag":"","fileName":part,"parentFileId":int(cur_id),"size":0,"type":1, "duplicate":1})
                # 重新查找
                j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":cur_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
                for fi in j["data"]["InfoList"]:
                    if fi["FileName"]==part and fi["Type"]==1:
                        found=fi
                        break
            if not found:
                raise ValueError(f"123 目录不存在且创建失败: {part}")
            cur_id = str(found["FileId"])
        return cur_id, parts[-1] if parts else ""

    def test(self):
        if self.config.get("root"):
            return LocalDriver(self.config).test()
        if self.config.get("openlist_url"):
            return OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""}).test()
        # 尝试直连登录
        self._login()
        self._api_request("https://yun.123pan.com/b/api/user/info", method="GET")
        return True

    def list(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.list(full)
        if self.config.get("root"):
            return LocalDriver(self.config).list(remote_path)
        # 直连
        try:
            rel = _norm_remote(remote_path)
            if not rel:
                cur_id="0"
            else:
                cur_id, _ = self._resolve_path(rel)
                # 需要找到该路径对应的 fileId
                # 若 rel 指向文件，需取其父目录的 fileId 查找
                # 简化：若 rel 是目录，则 cur_id 为该目录的 fileId
                # 尝试获取该目录的 fileId
                parts = rel.split("/")
                cur_id="0"
                for part in parts:
                    j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":cur_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
                    found=None
                    for fi in j["data"]["InfoList"]:
                        if fi["FileName"]==part:
                            found=fi
                            break
                    if found and found["Type"]==1:
                        cur_id=str(found["FileId"])
                    elif found:
                        cur_id=str(found["FileId"])
                        break
                    else:
                        return []
            j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":cur_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
            out=[]
            for fi in j["data"]["InfoList"]:
                name=fi["FileName"]
                is_dir=fi["Type"]==1
                size=fi.get("Size") or 0
                # 123 的路径
                full_path = (rel + "/" + name).strip("/") if rel else name
                out.append(Obj(name, full_path, is_dir, size, 0, ""))
            return out
        except Exception as e:
            # 若直连失败，提示用户可用 openlist_url
            if "openlist" not in str(e).lower():
                print(f"123 list fallback: {e}")
            return []

    def stat(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.stat(full)
        if self.config.get("root"):
            return LocalDriver(self.config).stat(remote_path)
        # 直连 stat 简化为 list 父目录
        try:
            rel=_norm_remote(remote_path)
            parent="/".join(rel.split("/")[:-1])
            name=rel.split("/")[-1]
            objs=self.list(parent)
            for o in objs:
                if o.name==name:
                    return o
            return None
        except Exception:
            return None

    def get(self, remote_path, local_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.get(full, local_path)
        if self.config.get("root"):
            return LocalDriver(self.config).get(remote_path, local_path)
        # 直连下载：通过 download_info 获取直链
        rel=_norm_remote(remote_path)
        parent_id, fname = self._resolve_path(rel)
        # 查找文件的 fileId
        j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":parent_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
        target=None
        for fi in j["data"]["InfoList"]:
            if fi["FileName"]==fname:
                target=fi
                break
        if not target:
            raise FileNotFoundError(rel)
        data={"driveId":0,"etag":target["Etag"],"fileId":target["FileId"],"fileName":target["FileName"],"s3keyFlag":target["S3KeyFlag"],"size":target["Size"],"type":target["Type"]}
        j2=self._api_request("https://yun.123pan.com/b/api/file/download_info", method="POST", body=data)
        url=j2["data"]["DownloadUrl"]
        # 处理 params 情况
        import base64 as _b64, urllib.request as _req
        parsed=urllib.parse.urlparse(url)
        qs=urllib.parse.parse_qs(parsed.query)
        if "params" in qs:
            try:
                du=_b64.b64decode(qs["params"][0]).decode()
                url=du
            except Exception:
                pass
        # 下载
        status, raw, _ = _http_request(url, method="GET", headers={"Referer":"https://www.123pan.com/"}, timeout=60)
        if status not in (200,302):
            raise ValueError(f"123 下载失败 {status}")
        # 若 302，需跟随
        if status==302:
            loc = _[ "location" ] if isinstance(_, dict) else ""
            # 简化：直接请求 location
            status, raw, _ = _http_request(loc, method="GET", timeout=60)
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(raw)
        return True

    def put(self, local_path, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.put(local_path, full)
        if self.config.get("root"):
            return LocalDriver(self.config).put(local_path, remote_path)
        # 直连上传：小文件简化（<100MB 单片）
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        rel=_norm_remote(remote_path)
        parent_id, fname = self._resolve_path(rel)
        size=os.path.getsize(local_path)
        # 计算 etag (MD5)
        import hashlib
        h=hashlib.md5()
        with open(local_path, "rb") as f:
            for chunk in iter(lambda: f.read(8192), b""):
                h.update(chunk)
        etag=h.hexdigest()
        j=self._api_request("https://yun.123pan.com/b/api/file/upload_request", method="POST", body={"driveId":0,"etag":etag,"fileName":fname,"parentFileId":int(parent_id),"size":size,"type":0,"duplicate":2})
        # j 包含 Bucket, Key, UploadId, StorageNode
        # 获取 S3 URL
        import json as _json
        bucket=j["data"]["Bucket"]
        key=j["data"]["Key"]
        upload_id=j["data"]["UploadId"]
        storage_node=j["data"]["StorageNode"]
        file_id=j["data"]["FileId"]
        # 获取预签名 URL
        j2=self._api_request("https://yun.123pan.com/b/api/file/s3_upload_object/auth", method="POST", body={"bucket":bucket,"key":key,"partNumberEnd":1,"partNumberStart":1,"uploadId":upload_id,"StorageNode":storage_node})
        # 简化：取第一个 URL
        pres = _get_presigned(j2.get("data") or {})
        if not pres:
            # 尝试旧接口
            j2=self._api_request("https://yun.123pan.com/b/api/file/s3_upload_object/auth", method="POST", body={"bucket":bucket,"key":key,"partNumberEnd":1,"partNumberStart":1,"uploadId":upload_id,"StorageNode":storage_node})
            pres = _get_presigned(j2.get("data") or {})
        url = pres.get("1") or (list(pres.values())[0] if pres else "")
        if not url:
            import json as _js2
            print(f"123 pres empty debug j2={_js2.dumps(j2, ensure_ascii=False)[:1500]} j={_js2.dumps(j, ensure_ascii=False)[:1000]}")
            raise ValueError(f"123 获取上传 URL 失败 j2_keys={list((j2.get('data') or {}).keys())} j_keys={list(j.keys())}")
        with open(local_path, "rb") as f:
            data=f.read()
        status, raw, _ = _http_request(url, method="PUT", headers={}, data=data, timeout=60)
        if status not in (200,204):
            raise ValueError(f"123 S3 上传失败 {status}")
        # 完成
        self._api_request("https://yun.123pan.com/b/api/file/upload_complete/v2", method="POST", body={"StorageNode":storage_node,"bucket":bucket,"fileId":file_id,"fileSize":size,"isMultipart":False,"key":key,"uploadId":upload_id})
        return True

    def delete(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.delete(full)
        if self.config.get("root"):
            return LocalDriver(self.config).delete(remote_path)
        # 直连删除：通过 file/trash
        rel=_norm_remote(remote_path)
        parent_id, fname = self._resolve_path(rel)
        j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":parent_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
        target=None
        for fi in j["data"]["InfoList"]:
            if fi["FileName"]==fname:
                target=fi
                break
        if not target:
            return True
        self._api_request("https://yun.123pan.com/b/api/file/trash", method="POST", body={"driveId":0,"fileIds":[target["FileId"]]})
        return True

    def mkdir(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/123"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.mkdir(full)
        if self.config.get("root"):
            return LocalDriver(self.config).mkdir(remote_path)
        # 直连 mkdir
        rel=_norm_remote(remote_path)
        parent_id, fname = self._resolve_path(rel)
        # 若已存在则返回
        j = self._api_request("https://yun.123pan.com/b/api/file/list/new", method="GET", params={"driveId":"0","limit":"100","next":"0","orderBy":"file_id","orderDirection":"desc","parentFileId":parent_id,"trashed":"false","SearchData":"","Page":"1","OnlyLookAbnormalFile":"0","event":"homeListFile","operateType":"4","inDirectSpace":"false"})
        for fi in j["data"]["InfoList"]:
            if fi["FileName"]==fname and fi["Type"]==1:
                return True
        self._api_request("https://yun.123pan.com/b/api/file/upload_request", method="POST", body={"driveId":0,"etag":"","fileName":fname,"parentFileId":int(parent_id),"size":0,"type":1,"duplicate":1})
        return True
    def config_schema(self):
        return {"username": "123 用户名/邮箱", "password": "密码", "passport": "passport（可选）", "openlist_url": "OpenList 地址（可选，直连失败时走代理）", "openlist_token": "OpenList Token", "mount_path": "/123", "root": "本地测试根"}

class GoogleDriveDriver(BaseDriver):
    type_name = "google_drive"
    def _ensure_token(self):
        if hasattr(self, "_token") and self._token:
            return
        cid=self.config.get("client_id") or ""
        csec=self.config.get("client_secret") or ""
        rt=self.config.get("refresh_token") or ""
        if rt:
            # 先尝试 OpenList 公共刷新接口（兼容仅填 refresh_token 或 token 与 client 不匹配的情况）
            try:
                import json as _json2, urllib.parse as _up2
                q = _up2.quote(rt, safe="")
                for api_try in [
                    f"https://api.oplist.org/googleui/renewapi?refresh_ui={q}&server_use=true&driver_txt=google_drive",
                    f"https://api.oplist.org/googleui/renewapi?refresh_token={q}",
                ]:
                    try:
                        status2, raw2, _ = _http_request(api_try, method="GET", headers={}, timeout=15)
                        # 若被 Cloudflare 拦截会返回 403 1010，直接跳过
                        if status2 == 403 and b"1010" in raw2:
                            continue
                        j2 = _json2.loads(raw2.decode(errors="ignore"))
                        at = j2.get("access_token") or (j2.get("data") or {}).get("access_token")
                        if at:
                            self._token = at
                            nr = j2.get("refresh_token") or (j2.get("data") or {}).get("refresh_token")
                            if nr:
                                self.config["refresh_token"] = nr
                            return
                    except Exception:
                        continue
            except Exception:
                pass
            if cid:
                import json as _json, urllib.parse
                data=urllib.parse.urlencode({"client_id":cid,"client_secret":csec,"refresh_token":rt,"grant_type":"refresh_token"}).encode()
                status, raw, _ = _http_request("https://oauth2.googleapis.com/token", method="POST", headers={"Content-Type":"application/x-www-form-urlencoded"}, data=data, timeout=15)
                j=_json.loads(raw.decode())
                if not j.get("access_token"):
                    raise ValueError(f"google token 刷新失败: {j}。若仅填 refresh_token 请补充 client_id/client_secret，或走 OpenList（推荐：将 refresh_token 配置到 OpenList 存储，再在编辑器填 OpenList 地址 http://127.0.0.1:5244）")
                self._token=j["access_token"]
                return
            # 到此：有 refresh_token 但无 client_id 且 oplist 刷新也失败
            raise ValueError("google 需要 refresh_token + client_id/client_secret（或 access_token）。当前仅提供 refresh_token 且公共刷新接口不可用。请：1) 走 OpenList（推荐，见上方 OpenList 地址提示）2) 或在下方补充 Client ID/Secret 再重试")
        elif self.config.get("access_token"):
            self._token=self.config["access_token"]
        else:
            raise ValueError("google 需要 refresh_token/client_id 或 access_token")

    def _drive_headers(self):
        self._ensure_token()
        return {"Authorization": "Bearer " + self._token}

    def _drive_request(self, url, method="GET", params=None, body=None, headers=None):
        import json as _js, urllib.parse as _up
        h = headers or {}
        # 合并 _drive_headers
        dh = self._drive_headers()
        h.update(dh)
        full = url
        if params:
            qs = _up.urlencode(params)
            full = url + ("&" if "?" in url else "?") + qs
        data = None
        if body is not None:
            if isinstance(body, dict):
                data = _js.dumps(body).encode()
                h["Content-Type"] = "application/json"
            else:
                data = body
        status, raw, _ = _http_request(full, method=method, headers=h, data=data, timeout=30)
        return status, raw, _

    def _drive_find_child(self, parent_id, name):
        # 在 parent_id 下查找名为 name 的文件/文件夹，返回 id 或 None
        import json as _js, urllib.parse as _up
        # Drive API: q="'parent_id' in parents and name = 'name' and trashed=false"
        q = f"'{parent_id}' in parents and name = '{name.replace("'", "\\'")}' and trashed=false"
        status, raw, _ = self._drive_request("https://www.googleapis.com/drive/v3/files", params={"q": q, "fields": "files(id,name,mimeType)", "pageSize": "10", "spaces": "drive"})
        if status != 200:
            return None
        try:
            j = _js.loads(raw.decode())
            for f in j.get("files", []):
                if f.get("name") == name:
                    return f.get("id")
        except Exception:
            pass
        return None

    def _drive_resolve(self, remote_path):
        # 将 remote_path (如 mods/3666/file.txt 的目录部分) 解析为 folderId
        # 支持首段为 Drive 文件ID（长度>15）的情况：若首段形如 1sMu5FnCO... 则视为根ID
        rp = _norm_remote(remote_path)
        if not rp:
            return "root"
        parts = rp.split("/")
        # 检测首段是否为 ID（Drive ID 通常 20+ 字符，含 -_）
        first = parts[0]
        if len(first) > 15 and re.match(r"^[A-Za-z0-9_-]+$", first):
            # 尝试将首段当作 ID 直接验证：尝试列该 ID 的文件，若成功则视为 ID
            # 为避免误判，若首段长度>20 且不含常见文件夹名特征，则当 ID
            # 简单启发：若首段长度>20 且包含 - 或 _ 且首字符为数字/字母，则当 ID
            if len(first) >= 20:
                # 验证：尝试 Drive API 获取该 ID 信息
                try:
                    status, raw, _ = self._drive_request(f"https://www.googleapis.com/drive/v3/files/{first}", params={"fields": "id,mimeType"})
                    if status == 200:
                        # 是有效 ID，剩余部分在其下解析
                        cur = first
                        for name in parts[1:]:
                            if not name:
                                continue
                            nid = self._drive_find_child(cur, name)
                            if not nid:
                                return None
                            cur = nid
                        return cur
                except Exception:
                    pass
        # 否则按路径从 root 开始解析
        cur = "root"
        for name in parts:
            if not name:
                continue
            nid = self._drive_find_child(cur, name)
            if not nid:
                return None
            cur = nid
        return cur

    def _drive_list_direct(self, remote_path):
        # 直接通过 Drive API 列目录
        import json as _js
        folder_id = self._drive_resolve(remote_path)
        if not folder_id:
            return []
        # 列该 folder_id 下的所有文件
        q = f"'{folder_id}' in parents and trashed=false"
        status, raw, _ = self._drive_request("https://www.googleapis.com/drive/v3/files", params={"q": q, "fields": "files(id,name,mimeType,size,modifiedTime,md5Checksum)", "pageSize": "1000", "spaces": "drive"})
        if status != 200:
            try:
                j = _js.loads(raw.decode())
                raise ValueError(f"drive list failed {status}: {j}")
            except Exception as e:
                raise ValueError(f"drive list failed {status}: {raw[:300]}")
        j = _js.loads(raw.decode())
        out = []
        for f in j.get("files", []):
            name = f.get("name") or ""
            is_dir = f.get("mimeType") == "application/vnd.google-apps.folder"
            size = int(f.get("size") or 0) if not is_dir else 0
            mtime = 0
            try:
                import datetime
                mt = f.get("modifiedTime") or ""
                if mt:
                    dt = datetime.datetime.fromisoformat(mt.replace("Z", "+00:00"))
                    mtime = int(dt.timestamp())
            except Exception:
                pass
            sha1 = ""
            # Drive 提供 md5Checksum，可留空（同步时按需计算）
            rel = (_norm_remote(remote_path) + "/" + name).lstrip("/") if _norm_remote(remote_path) else name
            out.append(Obj(name, rel, is_dir, size, mtime, sha1))
        return out

    def _drive_get_file_id(self, remote_path):
        # 返回文件/文件夹的 ID，若不存在返回 None
        rp = _norm_remote(remote_path)
        if not rp:
            return "root"
        # 若 remote_path 本身是单个 ID 且有效，直接返回
        if "/" not in rp and len(rp) > 15 and re.match(r"^[A-Za-z0-9_-]+$", rp):
            try:
                status, _, _ = self._drive_request(f"https://www.googleapis.com/drive/v3/files/{rp}", params={"fields": "id"})
                if status == 200:
                    return rp
            except Exception:
                pass
        parent = "/".join(rp.split("/")[:-1])
        name = rp.split("/")[-1]
        parent_id = self._drive_resolve(parent) if parent else "root"
        if not parent_id:
            # 尝试将 parent 当作 ID
            if parent and len(parent) > 15:
                parent_id = parent
            else:
                return None
        return self._drive_find_child(parent_id, name)

    def _drive_download(self, file_id, local_path):
        import os
        status, raw, _ = self._drive_request(f"https://www.googleapis.com/drive/v3/files/{file_id}", params={"alt": "media"}, headers={})
        if status != 200:
            raise ValueError(f"drive download failed {status}: {raw[:300]}")
        os.makedirs(os.path.dirname(os.path.abspath(local_path)), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(raw)
        return True

    def _drive_upload(self, local_path, remote_path):
        import os, json as _js, mimetypes
        if not os.path.isfile(local_path):
            raise FileNotFoundError(local_path)
        rp = _norm_remote(remote_path)
        parent = "/".join(rp.split("/")[:-1])
        name = rp.split("/")[-1]
        parent_id = self._drive_resolve(parent) if parent else "root"
        # 若 parent 还不存在，尝试逐级创建
        if not parent_id and parent:
            # 创建缺失的文件夹
            cur = "root"
            for part in parent.split("/"):
                if not part:
                    continue
                nid = self._drive_find_child(cur, part)
                if not nid:
                    # 创建文件夹
                    status, raw, _ = self._drive_request("https://www.googleapis.com/drive/v3/files", method="POST", body={"name": part, "mimeType": "application/vnd.google-apps.folder", "parents": [cur]}, headers={"Content-Type": "application/json"})
                    if status not in (200, 201):
                        raise ValueError(f"drive mkdir {part} failed {status}: {raw[:500]}")
                    j = _js.loads(raw.decode())
                    nid = j.get("id")
                cur = nid
            parent_id = cur
        if not parent_id:
            parent_id = "root"
        # 检查是否已存在同名文件
        existing_id = self._drive_find_child(parent_id, name)
        with open(local_path, "rb") as f:
            data = f.read()
        ctype = mimetypes.guess_type(local_path)[0] or "application/octet-stream"
        if existing_id:
            # 更新已有文件
            status, raw, _ = self._drive_request(f"https://www.googleapis.com/upload/drive/v3/files/{existing_id}", method="PATCH", params={"uploadType": "media"}, body=data, headers={"Content-Type": ctype})
            if status not in (200, 201):
                raise ValueError(f"drive update failed {status}: {raw[:500]}")
        else:
            # 创建新文件：先用 multipart 创建带 parent，再上传内容；简化：直接用 uploadType=multipart
            import json as _js2
            # 需要 boundary
            # 简化：先创建空文件再 update
            status, raw, _ = self._drive_request("https://www.googleapis.com/drive/v3/files", method="POST", body={"name": name, "parents": [parent_id]}, headers={"Content-Type": "application/json"})
            if status not in (200, 201):
                raise ValueError(f"drive create failed {status}: {raw[:500]}")
            j = _js.loads(raw.decode())
            fid = j.get("id")
            status, raw, _ = self._drive_request(f"https://www.googleapis.com/upload/drive/v3/files/{fid}", method="PATCH", params={"uploadType": "media"}, body=data, headers={"Content-Type": ctype})
            if status not in (200, 201):
                raise ValueError(f"drive upload failed {status}: {raw[:500]}")
        return True

    def _drive_delete(self, remote_path):
        fid = self._drive_get_file_id(remote_path)
        if not fid or fid == "root":
            return True
        status, raw, _ = self._drive_request(f"https://www.googleapis.com/drive/v3/files/{fid}", method="DELETE")
        if status not in (200, 204, 404):
            raise ValueError(f"drive delete failed {status}: {raw[:300]}")
        return True

    def _drive_mkdir(self, remote_path):
        rp = _norm_remote(remote_path)
        if not rp:
            return True
        # 逐级创建
        cur = "root"
        # 若首段是 ID，跳过
        parts = rp.split("/")
        start_idx = 0
        if len(parts[0]) > 15 and re.match(r"^[A-Za-z0-9_-]+$", parts[0]):
            try:
                status, _, _ = self._drive_request(f"https://www.googleapis.com/drive/v3/files/{parts[0]}", params={"fields": "id"})
                if status == 200:
                    cur = parts[0]
                    start_idx = 1
            except Exception:
                pass
        for part in parts[start_idx:]:
            if not part:
                continue
            nid = self._drive_find_child(cur, part)
            if not nid:
                import json as _js
                status, raw, _ = self._drive_request("https://www.googleapis.com/drive/v3/files", method="POST", body={"name": part, "mimeType": "application/vnd.google-apps.folder", "parents": [cur]}, headers={"Content-Type": "application/json"})
                if status not in (200, 201):
                    raise ValueError(f"drive mkdir {part} failed {status}: {raw[:300]}")
                j = _js.loads(raw.decode())
                nid = j.get("id")
            cur = nid
        return True


    def test(self):
        if self.config.get("root"):
            return LocalDriver(self.config).test()
        if self.config.get("openlist_url"):
            url = (self.config.get("openlist_url") or "").strip()
            low = url.lower()
            if "renewapi" in low or "googleui" in low:
                raise ValueError("Google Drive 的 OpenList 地址填写错误：%s 是 Google Token 刷新接口，不是 OpenList 实例。请留空该字段以走直连，或填你的 OpenList 服务地址如 http://127.0.0.1:5244（需在 OpenList 中挂载 Google Drive 到 /gdrive），并确保挂载路径正确（如 /gdrive）" % url)
            try:
                return OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""}).test()
            except Exception as e:
                msg = str(e)
                if "10061" in msg or "ConnectionRefused" in msg or "Failed to establish" in msg or "urlopen error" in msg:
                    raise ValueError(f"无法连接 OpenList {url}：{msg}。请确认 OpenList 已启动（双击 OpenList.exe 或运行 openlist server），端口 5244 可访问，且已在 OpenList 后台添加 Google Drive 存储并挂载到 {self.config.get('mount_path') or '/gdrive'}。若不想自建，请清空 OpenList 地址走直连（需补充 Client ID）")
                raise
        self._ensure_token()
        status, raw, _ = _http_request("https://www.googleapis.com/drive/v3/about?fields=user", method="GET", headers={"Authorization":"Bearer "+self._token}, timeout=15)
        if status!=200:
            body = raw[:600].decode(errors="ignore") if isinstance(raw, (bytes, bytearray)) else str(raw)[:600]
            raise ValueError(f"google 授权失败 {status}: {body[:300]}。检查 refresh_token/client_id 是否正确，及网络是否可访问 Google")
        return True
    def list(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.list(full)
            except Exception as e:
                msg = str(e)
                if ("10061" in msg or "ConnectionRefused" in msg or "urlopen error" in msg or "Failed to establish" in msg) and self.config.get("refresh_token"):
                    try:
                        return self._drive_list_direct(remote_path)
                    except Exception as e2:
                        raise ValueError(f"OpenList {self.config.get('openlist_url')} 不可用且直连也失败: {e2}（原始 OpenList 错误: {e}）")
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).list(remote_path)
        try:
            return self._drive_list_direct(remote_path)
        except Exception as e:
            raise ValueError(f"Google Drive 直连列目录失败（需 openlist_url 或本地 root，或确保 refresh_token/client_id 正确且网络可达）：{e}。建议：在 OpenList 中挂载 Google Drive 后填入 openlist_url=http://127.0.0.1:5244")
    def stat(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.stat(full)
            except Exception:
                pass
        if self.config.get("root"):
            return LocalDriver(self.config).stat(remote_path)
        # 直连：尝试通过 list 查找
        try:
            parent = "/".join(_norm_remote(remote_path).split("/")[:-1])
            name = _norm_remote(remote_path).split("/")[-1] if _norm_remote(remote_path) else ""
            if not name:
                return None
            for o in self._drive_list_direct(parent):
                if o.name == name:
                    return o
        except Exception:
            pass
        return None
    def get(self, remote_path, local_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.get(full, local_path)
            except Exception as e:
                if ("10061" in str(e) or "urlopen error" in str(e)) and self.config.get("refresh_token"):
                    fid = self._drive_get_file_id(remote_path)
                    if not fid:
                        raise ValueError(f"openlist {self.config.get('openlist_url')} 不可用且直连找不到文件 {remote_path}: {e}")
                    return self._drive_download(fid, local_path)
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).get(remote_path, local_path)
        fid = self._drive_get_file_id(remote_path)
        if not fid:
            raise FileNotFoundError(remote_path)
        return self._drive_download(fid, local_path)
    def put(self, local_path, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.put(local_path, full)
            except Exception as e:
                if ("10061" in str(e) or "urlopen error" in str(e)) and self.config.get("refresh_token"):
                    return self._drive_upload(local_path, remote_path)
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).put(local_path, remote_path)
        return self._drive_upload(local_path, remote_path)
    def delete(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.delete(full)
            except Exception as e:
                if ("10061" in str(e) or "urlopen error" in str(e)) and self.config.get("refresh_token"):
                    return self._drive_delete(remote_path)
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).delete(remote_path)
        try:
            return self._drive_delete(remote_path)
        except Exception:
            return True
    def mkdir(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/gdrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.mkdir(full)
            except Exception as e:
                if ("10061" in str(e) or "urlopen error" in str(e)) and self.config.get("refresh_token"):
                    return self._drive_mkdir(remote_path)
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).mkdir(remote_path)
        return self._drive_mkdir(remote_path)
    def config_schema(self):
        return {"client_id": "Client ID", "client_secret": "Client Secret", "refresh_token": "refresh_token", "openlist_url": "OpenList 地址", "mount_path": "/gdrive", "root": "本地测试根"}

class OneDriveDriver(BaseDriver):
    type_name = "onedrive"
    def _ensure_token(self):
        if hasattr(self, "_token") and self._token:
            return
        rt=self.config.get("refresh_token") or ""
        cid=self.config.get("client_id") or ""
        csec=self.config.get("client_secret") or ""
        # 若未填 client_id，尝试 oplist 公共刷新接口（与 Google 逻辑一致）
        if (not cid or cid == "f0e3cad9-1bf3-4006-9999-1a1a1e1a4ae0") and rt:
            try:
                import json as _js2, urllib.parse as _up2
                q = _up2.quote(rt, safe="")
                for api_try in [
                    f"https://api.oplist.org/onedrive/renewapi?refresh_token={q}",
                    f"https://api.oplist.org/microsoft/renewapi?refresh_token={q}",
                    f"https://api.oplist.org/onedrive/renewapi?refresh_ui={q}&server_use=true",
                ]:
                    try:
                        s2, r2, _ = _http_request(api_try, method="GET", headers={}, timeout=15)
                        if s2 == 403 and b"1010" in r2:
                            continue
                        j2 = _js2.loads(r2.decode(errors="ignore"))
                        at = j2.get("access_token") or (j2.get("data") or {}).get("access_token")
                        if at:
                            self._token = at
                            return
                    except Exception:
                        continue
            except Exception:
                pass
            if rt:
                raise ValueError("OneDrive 需要 refresh_token + Client ID（Azure 应用客户端 ID）。当前仅提供 refresh_token 但未填 Client ID（默认示例 4b3492b7-... 仅占位，需填你自己的 Azure 应用 ID，见 Azure 门户->应用注册，或使用 oplist.org 提供的完整 Client ID）。或走 OpenList：填 OpenList 地址如 http://127.0.0.1:5244 并在 OpenList 中挂载 OneDrive（推荐），此时无需在编辑器填 refresh_token")
        if rt:
            import json as _json, urllib.parse
            data=urllib.parse.urlencode({"client_id":cid,"client_secret":csec,"refresh_token":rt,"grant_type":"refresh_token","redirect_uri":"https://api.oplist.org/onedrive/callback"}).encode() if cid=="f0e3cad9-1bf3-4006-9999-1a1a1e1a4ae0" else urllib.parse.urlencode({"client_id":cid,"client_secret":csec,"refresh_token":rt,"grant_type":"refresh_token","redirect_uri":"https://login.microsoftonline.com/common/oauth2/nativeclient"}).encode() if csec else urllib.parse.urlencode({"client_id":cid,"refresh_token":rt,"grant_type":"refresh_token"}).encode()
            status, raw, _ = _http_request("https://login.microsoftonline.com/common/oauth2/v2.0/token", method="POST", headers={"Content-Type":"application/x-www-form-urlencoded"}, data=data, timeout=15)
            try:
                j=_js2=json.loads(raw.decode())
            except Exception:
                j={}
                try:
                    j=_json.loads(raw.decode())
                except Exception:
                    pass
            if not j.get("access_token"):
                err = j.get("error") or j.get("error_description") or str(j)
                if "700016" in str(j) or "70001" in str(j) or "unauthorized_client" in str(j):
                    raise ValueError(f"onedrive 刷新失败 700016: Application {cid} 未在租户中找到。请在 Azure 门户检查：1) 应用已在租户 9188040d... 中管理员同意 2) 重定向 URI 为 https://login.microsoftonline.com/common/oauth2/nativeclient 3) 或改用 OpenList 挂载。原始错误: {j}")
                raise ValueError(f"onedrive 刷新失败: {j}。检查 refresh_token 是否过期、Client ID/Secret 是否匹配创建时的 Azure 应用，或走 OpenList")
            self._token=j["access_token"]
        elif self.config.get("access_token"):
            self._token=self.config["access_token"]
        else:
            raise ValueError("onedrive 需要 refresh_token（+ Client ID）或 access_token，或填 OpenList 地址走代理")

    def _onedrive_list_direct(self, remote_path):
        # 通过 Microsoft Graph 直连列目录
        import json as _js
        self._ensure_token()
        rp = _norm_remote(remote_path)
        # Graph 路径：/me/drive/root:/path:/children  或 /me/drive/root/children 当 rp 为空
        if not rp:
            url = "https://graph.microsoft.com/v1.0/me/drive/root/children"
            params = {"$select": "name,folder,size,lastModifiedDateTime,file"}
        else:
            # 编码路径段
            import urllib.parse as _up
            # Graph 要求路径每段编码
            enc = "/".join(_up.quote(part) for part in rp.split("/"))
            url = f"https://graph.microsoft.com/v1.0/me/drive/root:/{enc}:/children"
            params = {"$select": "name,folder,size,lastModifiedDateTime,file"}
        status, raw, _ = _http_request(url, method="GET", headers={"Authorization": "Bearer "+self._token}, timeout=30)
        if status == 404:
            return []
        if status != 200:
            try:
                j = _js.loads(raw.decode())
                raise ValueError(f"graph list {status}: {j}")
            except Exception as e:
                raise ValueError(f"graph list {status}: {raw[:400]}")
        j = _js.loads(raw.decode())
        out = []
        for item in j.get("value", []):
            name = item.get("name") or ""
            is_dir = "folder" in item
            size = int(item.get("size") or 0) if not is_dir else 0
            mtime = 0
            try:
                import datetime
                mt = item.get("lastModifiedDateTime") or ""
                if mt:
                    dt = datetime.datetime.fromisoformat(mt.replace("Z", "+00:00"))
                    mtime = int(dt.timestamp())
            except Exception:
                pass
            rel = (rp + "/" + name).lstrip("/") if rp else name
            out.append(Obj(name, rel, is_dir, size, mtime, ""))
        return out

    def test(self):
        if self.config.get("root"):
            return LocalDriver(self.config).test()
        if self.config.get("openlist_url"):
            try:
                return OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""}).test()
            except Exception as e:
                msg = str(e)
                if ("10061" in msg or "ConnectionRefused" in msg or "urlopen error" in msg) and self.config.get("refresh_token"):
                    try:
                        self._ensure_token()
                        status, raw, _ = _http_request("https://graph.microsoft.com/v1.0/me/drive", method="GET", headers={"Authorization":"Bearer "+self._token}, timeout=15)
                        if status==200:
                            return True
                    except Exception:
                        pass
                raise ValueError(f"无法连接 OpenList {self.config.get('openlist_url')}: {e}。请确认 OpenList 已启动，或清空 OpenList 地址走直连并补充 Client ID")
        self._ensure_token()
        status, raw, _ = _http_request("https://graph.microsoft.com/v1.0/me/drive", method="GET", headers={"Authorization":"Bearer "+self._token}, timeout=15)
        if status!=200:
            body = raw[:400].decode(errors="ignore") if isinstance(raw, (bytes, bytearray)) else str(raw)[:400]
            raise ValueError(f"onedrive 授权失败 {status}: {body[:300]}。检查 Client ID/refresh_token 是否正确或已管理员同意")
        return True
    def list(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            try:
                return drv.list(full)
            except Exception as e:
                msg = str(e)
                if ("10061" in msg or "ConnectionRefused" in msg or "urlopen error" in msg) and self.config.get("refresh_token"):
                    try:
                        return self._onedrive_list_direct(remote_path)
                    except Exception as e2:
                        raise ValueError(f"OpenList {self.config.get('openlist_url')} 不可用且直连也失败: {e2}（原始: {e}）")
                raise
        if self.config.get("root"):
            return LocalDriver(self.config).list(remote_path)
        try:
            return self._onedrive_list_direct(remote_path)
        except Exception as e:
            raise ValueError(f"OneDrive 直连列目录失败（需 openlist_url 或本地 root，或确保 refresh_token/Client ID 正确）：{e}。建议 OpenList 挂载后填 openlist_url=http://127.0.0.1:5244")
    def stat(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.stat(full)
        if self.config.get("root"):
            return LocalDriver(self.config).stat(remote_path)
        return None
    def get(self, remote_path, local_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.get(full, local_path)
        if self.config.get("root"):
            return LocalDriver(self.config).get(remote_path, local_path)
        raise ValueError("OneDrive 直连下载需配置 openlist_url，请通过 OpenList 代理")
    def put(self, local_path, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.put(local_path, full)
        if self.config.get("root"):
            return LocalDriver(self.config).put(local_path, remote_path)
        raise NotImplementedError("onedrive requires openlist_url")
    def delete(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.delete(full)
        if self.config.get("root"):
            return LocalDriver(self.config).delete(remote_path)
        return True
    def mkdir(self, remote_path):
        if self.config.get("openlist_url"):
            drv = OpenListDriver({"url": self.config["openlist_url"], "token": self.config.get("openlist_token") or ""})
            mount = self.config.get("mount_path") or "/onedrive"
            full = (mount.rstrip("/") + "/" + _norm_remote(remote_path)).strip("/")
            return drv.mkdir(full)
        if self.config.get("root"):
            return LocalDriver(self.config).mkdir(remote_path)
        return True
    def config_schema(self):
        return {"refresh_token": "refresh_token", "client_id": "Client ID", "client_secret": "Client Secret", "openlist_url": "OpenList 地址", "mount_path": "/onedrive", "root": "本地测试根"}


# 已停止支持的云盘类型：历史配置条目保留展示，实际操作时给出明确提示
REMOVED_DRIVERS = {
    "aliyundrive": "阿里云盘", "aliyun": "阿里云盘", "quark": "夸克云盘",
    "189": "天翼云盘", "tianyi": "天翼云盘",
}

DRIVERS = {
    "local": LocalDriver,
    "webdav": WebDAVDriver,
    "openlist": OpenListDriver,
    "alist": OpenListDriver,
    "baidu_netdisk": BaiduNetdiskDriver,
    "baidu": BaiduNetdiskDriver,
    "123": Pan123Driver,
    "123pan": Pan123Driver,
    "google_drive": GoogleDriveDriver,
    "gdrive": GoogleDriveDriver,
    "onedrive": OneDriveDriver,
}

def get_driver(type_name, config):
    key = (type_name or "").lower()
    if key in REMOVED_DRIVERS:
        raise ValueError(
            "%s已停止支持：请删除该云存储配置，改用 OpenList 代理"
            "（在 OpenList 中添加对应存储后，此处填 OpenList 地址 + 挂载路径）。"
            % REMOVED_DRIVERS[key])
    cls = DRIVERS.get(key)
    if not cls:
        raise ValueError("unknown driver: %s" % type_name)
    return cls(config)

# ---------- 配置管理 ----------

def _load_config():
    p = _cloud_config_path()
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            data.setdefault("providers", [])
            return data
    except Exception:
        pass
    return {"providers": []}

def _save_config(data):
    p = _cloud_config_path()
    try:
        atomic_io.write_text_atomic(
            p, json.dumps(data, ensure_ascii=False, indent=2))
    except Exception:
        pass

def list_providers():
    cfg = _load_config()
    return cfg.get("providers", [])

def add_provider(info):
    cfg = _load_config()
    pid = (info.get("id") or "").strip()
    if not pid:
        pid = "p_%d" % int(time.time()*1000 % 1000000)
    # 去重
    cfg["providers"] = [p for p in cfg.get("providers", []) if p.get("id") != pid]
    entry = {
        "id": pid,
        "name": info.get("name") or pid,
        "type": (info.get("type") or "webdav").lower(),
        "config": info.get("config") or {},
        "remote_root": _norm_remote(info.get("remote_root") or info.get("remoteRoot") or "mods"),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    if entry["type"] not in DRIVERS:
        raise ValueError("unsupported driver type: %s" % entry["type"])
    cfg["providers"].append(entry)
    _save_config(cfg)
    return entry

def update_provider(pid, patch):
    cfg = _load_config()
    found = None
    for p in cfg.get("providers", []):
        if p.get("id") == pid:
            found = p
            break
    if not found:
        raise ValueError("provider not found: %s" % pid)
    for k in ("name", "type", "config", "remote_root", "remoteRoot"):
        if k in patch:
            if k in ("remote_root", "remoteRoot"):
                found["remote_root"] = _norm_remote(patch[k])
            elif k == "type":
                t = (patch[k] or "").lower()
                if t not in DRIVERS:
                    raise ValueError("unsupported type")
                found["type"] = t
            elif k == "config" and isinstance(patch[k], dict):
                # 防脱敏回写：若值为 "***" 则保留原值
                new_cfg = dict(patch[k])
                orig_cfg = found.get("config") or {}
                for ck, cv in list(new_cfg.items()):
                    if cv == "***" and ck in orig_cfg:
                        new_cfg[ck] = orig_cfg[ck]
                # 合并而非覆盖：保留未传的键
                merged = dict(orig_cfg)
                merged.update(new_cfg)
                found["config"] = merged
            else:
                found[k] = patch[k]
    _save_config(cfg)
    return found

def remove_provider(pid):
    cfg = _load_config()
    before = len(cfg.get("providers", []))
    cfg["providers"] = [p for p in cfg.get("providers", []) if p.get("id") != pid]
    if len(cfg["providers"]) == before:
        raise ValueError("provider not found: %s" % pid)
    _save_config(cfg)
    return True

def get_provider(pid):
    for p in list_providers():
        if p.get("id") == pid:
            return p
    return None

# ---------- 单文件同步引擎 ----------

def _local_mods_root():
    try:
        from editor.server.api import STATE as _ST
        # 调试：直接返回 workspace_root 若其存在且为目录
        if _ST.workspace_root and os.path.isdir(_ST.workspace_root):
            return _ST.workspace_root
        if _ST.mod_root and os.path.isdir(os.path.dirname(_ST.mod_root)):
            return os.path.dirname(_ST.mod_root)
    except Exception as e:
        print(f"_local_mods_root inner {e}")
        pass
    try:
        from editor.server.api import _user_mods_dir
        return _user_mods_dir()
    except Exception:
        return os.path.join(_editor_root(), "_cache", "mods")

_sync_lock = threading.Lock()
_sync_state = {"running": False, "provider": "", "action": "", "progress": 0, "total": 0, "last": "", "error": "", "history": []}

def sync_status():
    with _sync_lock:
        return dict(_sync_state)

def _set_state(**kw):
    with _sync_lock:
        _sync_state.update(kw)

def _remote_path_for(provider, mod_name, rel_path):
    root = _norm_remote(provider.get("remote_root") or "mods")
    # 单文件同步：remote = <root>/<mod>/<rel>
    parts = []
    if root:
        parts.append(root)
    if mod_name:
        parts.append(_norm_remote(mod_name))
    if rel_path:
        parts.append(_norm_remote(rel_path))
    return "/".join([p for p in parts if p])


def _get_mod_dir(mod_name):
    """统一获取 Mod 真实目录，优先 STATE.list_mods()，否则回退到 workspace。"""
    mod_dir = ""
    try:
        from editor.server.api import STATE as _ST
        for m in _ST.list_mods():
            if m.get("name") == mod_name:
                mod_dir = m.get("root") or ""
                break
    except Exception:
        pass
    if not mod_dir:
        local_root = _local_mods_root()
        mod_dir = os.path.join(local_root, mod_name)
    return mod_dir

def _list_local_files(mod_name, compute_sha=False):
    """递归列出本地 Mod 下所有文件，返回 {rel: (size, mtime, sha1)} 映射

    compute_sha=False 时 sha1 置空，需比对时再按需计算，避免大 Mod 全量读文件。
    """
    mod_dir = _get_mod_dir(mod_name)
    if not mod_dir or not os.path.isdir(mod_dir):
        return {}
    out = {}
    for root, dirs, files in os.walk(mod_dir):
        # 跳过常见的缓存/临时目录与编辑器历史快照目录（.editor_history）
        dirs[:] = [d for d in dirs if not d.startswith("_cache") and not d.startswith(".tmp") and d != "__pycache__" and d != ".editor_history"]
        rel_root = os.path.relpath(root, mod_dir).replace("\\", "/")
        if rel_root == ".":
            rel_root = ""
        for fn in files:
            full = os.path.join(root, fn)
            rel = (rel_root + "/" + fn).lstrip("/") if rel_root else fn
            # 忽略缓存/临时
            if rel.startswith("_cache") or rel.startswith(".git/") or rel.endswith(".tmp"):
                continue
            # 忽略编辑器内部状态文件（流程配置不参与同步）
            if rel == ".editor_flow.json":
                continue
            # 忽略隐藏的临时文件
            if fn.startswith("~") or fn.startswith("."):
                # 但保留 .json 等隐藏配置？常见 Mod 不会有隐藏关键文件
                if not fn.endswith(".json"):
                    continue
            try:
                st = os.stat(full)
                sha = _sha1_file(full) if compute_sha else ""
                out[rel.replace("\\", "/")] = (st.st_size, int(st.st_mtime), sha)
            except Exception:
                continue
    return out

def _lazy_sha(local_path):
    """按需计算 sha1，失败返回空串。"""
    try:
        if os.path.isfile(local_path):
            # 大于 20MB 的文件跳过 sha 以提升速度，回退到 size+mtime 判定
            if os.path.getsize(local_path) > 20 * 1024 * 1024:
                return ""
            return _sha1_file(local_path)
    except Exception:
        pass
    return ""

def _need_sync(ls, lm, lh, rs, rm, rsha, local_path=""):
    """判定是否需要同步（返回 True 需上传/下载）。

    修复旧逻辑中 mtime=0 时误判/漏判：
      - size 不等 => 必须同步
      - 双方 sha 均有效且不等 => 必须同步
      - 仅一方 sha 有效时，若 size 相等则需计算另一方 sha 再比对
      - mtime 仅当双方均有效 (>0) 时参与判定，差值>2秒才视为不同
    """
    if ls != rs:
        return True
    # sha 比对：若双方都有 sha，直接比对
    if lh and rsha:
        return lh != rsha
    # 一方有 sha，另一方缺失：按需补算后比对
    if lh and not rsha and local_path:
        # 远端无 sha，无法判定，保守认为若本地 mtime 较新则需同步？此处返回 False 由上层按 mtime 决定
        pass
    if rsha and not lh and local_path:
        lh2 = _lazy_sha(local_path)
        if lh2 and lh2 != rsha:
            return True
    # mtime 仅当双方都提供时有效
    if lm and rm and abs(int(lm) - int(rm)) > 2:
        # 若 size 相同但 mtime 差值大，仍需同步（时间戳被触碰）
        # 若本地 sha 已计算且远端也有 sha 已在上层比较过，此处作为最后兜底
        return True
    return False

def _list_remote_recursive(driver, remote_base):
    """递归列出远端 Mod 目录，返回 {rel: Obj} 映射

    修复：原实现静默吞掉所有异常，导致网络失败时前端显示 total=0 误导。
    现改为：首层失败直接抛出；深层失败记录并跳过，最终若全部失败则抛出。
    同时兼容 driver 返回相对/绝对路径两种形态。
    """
    out = {}
    errors = []
    stack = [""]
    visited = set()
    base_norm = _norm_remote(remote_base)
    while stack:
        cur = stack.pop()
        if cur in visited:
            continue
        visited.add(cur)
        remote = (remote_base + "/" + cur).strip("/") if cur else remote_base
        try:
            objs = driver.list(remote)
        except Exception as e:
            errors.append("%s: %s" % (remote, e))
            # 首层失败直接向上抛，让调用方感知“远端不可达”
            if cur == "":
                raise ValueError("remote list failed at %s: %s" % (remote, e))
            continue
        if not objs:
            continue
        for o in objs:
            try:
                rel = o.path or ""
                # 兼容不同 driver 的 path 风格：
                # 1) 完整路径含 base 前缀 -> 去前缀
                # 2) 仅相对 cur 的 name -> 拼 cur
                # 3) 已是相对 base 的 rel
                if base_norm and rel.startswith(base_norm + "/"):
                    rel = rel[len(base_norm)+1:]
                elif rel == base_norm:
                    rel = ""
                elif "/" not in rel and cur:
                    # 某些驱动返回仅 name，需补 cur 前缀
                    rel = (cur + "/" + rel).lstrip("/")
                # 归一化
                rel = rel.replace("\\", "/").lstrip("/")
                if not rel:
                    # 跳过 base 自身
                    continue
                if o.is_dir:
                    # 仅当该目录在当前遍历层级下直接子级才入栈，避免跨层重复
                    # 通过判断 rel 是否以 cur 为前缀（若 cur 非空）
                    if cur and not (rel == cur or rel.startswith(cur + "/")):
                        # 若 driver 返回了跨层目录，仍尝试入栈其相对路径
                        pass
                    # 去重入栈
                    if rel not in visited:
                        stack.append(rel)
                else:
                    # 兼容部分驱动返回的 rel 包含 cur 前缀重复的情况
                    out[rel] = o
            except Exception:
                continue
    # 若完全无结果且有错误，抛出以便前端展示而非静默 total=0
    if not out and errors:
        raise ValueError("remote list failed: " + "; ".join(errors))
    return out

def _drv_get(driver, remote, local_path):
    """driver.get 的统一入口：下载覆盖配置表文件后清掉 cfg_store 的 undo 栈。

    下载用 shutil.copy2/流写直接覆盖磁盘，绕过了 write_cfg 统一写入口；
    内存 undo 栈里滞留的「写入前内容」与磁盘新数据已脱节，此后再撤销会把
    刚同步下来的整表一起回滚掉。覆盖 Cfgs/*.json 后丢弃该表栈即可。
    """
    driver.get(remote, local_path)
    try:
        rp = os.path.normpath(local_path).replace("\\", "/")
        if rp.endswith(".json") and "/Cfgs/" in rp:
            from editor.server import cfg_store
            cfg_store.forget(local_path)
    except Exception:
        pass


def _safe_rel_join(mod_dir, rel):
    """远端 rel → 本地路径的安全拼接（sync_mod_folder 用）。

    远端列表（WebDAV/Alist 自建等）可能返回任意对象名：rel 含 ``..`` 段、
    盘符或绝对路径时返回 None，由调用方跳过该条目，防止下载/删除越出 Mod 目录
    （对照 sync_single_file 的 startswith 边界校验）。
    """
    rel = (rel or "").replace("\\", "/").strip("/")
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    if os.path.isabs(rel) or (len(parts[0]) >= 2 and parts[0][1] == ":"):
        return None
    base = os.path.abspath(mod_dir)
    full = os.path.abspath(os.path.join(base, *parts))
    if full != base and not full.startswith(base + os.sep):
        return None
    return full


def sync_mod_folder(provider_id, direction, mod_name, dry_run=False, delete_extra=False):
    """整 Mod 文件夹同步：direction = upload|download|sync(mirror)
    upload: 本地 -> 远端（增量，本地新增/更新的文件上传，远端多余的可选删除）
    download: 远端 -> 本地
    sync: 双向（以 mtime 新者为准，冲突时本地优先）

    修复要点：
      - 本地列表按需计算 sha，避免大 Mod 卡顿
      - 远端列表首层失败直接抛出，而非静默 total=0
      - 同步判定使用 _need_sync，修复 mtime=0 误判
    """
    prov = get_provider(provider_id)
    if not prov:
        raise ValueError("provider not found")
    driver = get_driver(prov.get("type"), prov.get("config"))
    if not mod_name or ".." in mod_name or "/" in mod_name or "\\" in mod_name:
        raise ValueError("invalid mod_name")
    mod_dir = _get_mod_dir(mod_name)
    remote_base = _remote_path_for(prov, mod_name, "")
    _set_state(running=True, provider=provider_id, action=f"folder_{direction}", progress=0, total=0, error="")
    try:
        # 本地全量（不预计算 sha，按需算）
        local_map = _list_local_files(mod_name, compute_sha=False)
        # 远端递归（异常会直接抛出，已在 _list_remote_recursive 中处理）
        try:
            remote_map = _list_remote_recursive(driver, remote_base)
        except Exception as e:
            _set_state(running=False, error="%s: %s" % (type(e).__name__, e))
            raise ValueError("远端列举失败: %s" % e)
        # 统计
        all_rels = set(local_map.keys()) | set(remote_map.keys())
        total = len(all_rels)
        _set_state(total=total)
        if total == 0:
            # 提供更明确的提示：检查 Mod 是否存在或为空
            mod_exists = False
            try:
                local_root = _local_mods_root()
                # 检查真实路径
                check_dir = ""
                try:
                    from editor.server.api import STATE as _ST2
                    for m in _ST2.list_mods():
                        if m.get("name") == mod_name:
                            check_dir = m.get("root") or ""
                            break
                except Exception:
                    pass
                if not check_dir:
                    check_dir = os.path.join(local_root, mod_name)
                mod_exists = os.path.isdir(check_dir)
            except Exception:
                pass
            if not mod_exists:
                raise ValueError(f"本地 Mod 不存在: {mod_name}，请先在 Mod 列表中选择或创建")
            # else 远端与本地均为空，返回友好提示而非静默成功
            _set_state(running=False, progress=0)
            return {"results": [], "dry_run": dry_run, "direction": direction, "total": 0, "message": "未发现文件：本地与远端均为空或 Mod 为空，请确认 Mod 名称与远端路径"}
        results = []
        for idx, rel in enumerate(sorted(all_rels)):
            _set_state(progress=idx+1, last=rel)
            local_info = local_map.get(rel)
            remote_obj = remote_map.get(rel)
            local_path_full = _safe_rel_join(mod_dir, rel) if rel else mod_dir
            if local_path_full is None:
                # 远端对象名含路径穿越段（../、盘符等）：跳过且绝不落盘/删除
                results.append({"rel": rel, "ok": False, "action": "skip_unsafe_path",
                                "error": "远端路径不安全（含 .. 或盘符），已跳过"})
                continue
            try:
                if direction == "upload":
                    if local_info is None:
                        if delete_extra and remote_obj is not None:
                            if not dry_run:
                                driver.delete(remote_base + "/" + rel)
                            results.append({"rel": rel, "ok": True, "action": "delete_remote"})
                        else:
                            results.append({"rel": rel, "ok": True, "action": "skip_extra_remote"})
                    elif remote_obj is None:
                        if not dry_run:
                            driver.put(local_path_full, remote_base + "/" + rel)
                        results.append({"rel": rel, "ok": True, "action": "upload_new"})
                    else:
                        ls, lm, lh = local_info
                        rs, rm, rsha = remote_obj.size, remote_obj.mtime, remote_obj.sha1
                        # 懒补 sha：若本地 sha 为空且 size 相等，则按需计算
                        if not lh and ls == rs:
                            lh = _lazy_sha(local_path_full)
                            # 更新 map 供后续复用
                            local_map[rel] = (ls, lm, lh)
                        need = _need_sync(ls, lm, lh, rs, rm, rsha, local_path_full)
                        if need:
                            if not dry_run:
                                driver.put(local_path_full, remote_base + "/" + rel)
                            results.append({"rel": rel, "ok": True, "action": "upload_update"})
                        else:
                            results.append({"rel": rel, "ok": True, "action": "skip_unchanged"})
                elif direction == "download":
                    if remote_obj is None:
                        results.append({"rel": rel, "ok": True, "action": "skip_local_extra"})
                    elif local_info is None:
                        if not dry_run:
                            os.makedirs(os.path.dirname(local_path_full), exist_ok=True)
                            _drv_get(driver, remote_base + "/" + rel, local_path_full)
                        results.append({"rel": rel, "ok": True, "action": "download_new"})
                    else:
                        ls, lm, lh = local_info
                        rs, rm, rsha = remote_obj.size, remote_obj.mtime, remote_obj.sha1
                        if not lh and ls == rs and rsha:
                            lh = _lazy_sha(local_path_full)
                            local_map[rel] = (ls, lm, lh)
                        need = _need_sync(ls, lm, lh, rs, rm, rsha, local_path_full)
                        if need:
                            if not dry_run:
                                os.makedirs(os.path.dirname(local_path_full), exist_ok=True)
                                _drv_get(driver, remote_base + "/" + rel, local_path_full)
                            results.append({"rel": rel, "ok": True, "action": "download_update"})
                        else:
                            results.append({"rel": rel, "ok": True, "action": "skip_unchanged"})
                elif direction == "sync":
                    if local_info is None and remote_obj is not None:
                        if not dry_run:
                            os.makedirs(os.path.dirname(local_path_full), exist_ok=True)
                            _drv_get(driver, remote_base + "/" + rel, local_path_full)
                        results.append({"rel": rel, "ok": True, "action": "sync_download"})
                    elif remote_obj is None and local_info is not None:
                        if not dry_run:
                            driver.put(local_path_full, remote_base + "/" + rel)
                        results.append({"rel": rel, "ok": True, "action": "sync_upload"})
                    elif local_info and remote_obj:
                        ls, lm, lh = local_info
                        rs, rm, rsha = remote_obj.size, remote_obj.mtime, remote_obj.sha1
                        if not lh and ls == rs and rsha:
                            lh = _lazy_sha(local_path_full)
                            local_map[rel] = (ls, lm, lh)
                        # 若仍需同步，则以 mtime 决定方向
                        if _need_sync(ls, lm, lh, rs, rm, rsha, local_path_full):
                            # rm==0 视为远端时间未知，本地优先上传
                            if rm and lm and int(rm) > int(lm):
                                if not dry_run:
                                    os.makedirs(os.path.dirname(local_path_full), exist_ok=True)
                                    _drv_get(driver, remote_base + "/" + rel, local_path_full)
                                results.append({"rel": rel, "ok": True, "action": "sync_download_update"})
                            else:
                                if not dry_run:
                                    driver.put(local_path_full, remote_base + "/" + rel)
                                results.append({"rel": rel, "ok": True, "action": "sync_upload_update"})
                        else:
                            results.append({"rel": rel, "ok": True, "action": "skip"})
                else:
                    raise ValueError("unknown direction")
            except Exception as e:
                results.append({"rel": rel, "ok": False, "error": f"{type(e).__name__}: {e}"})
        _set_state(running=False, progress=total)
        with _sync_lock:
            _sync_state["history"] = ([{"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "provider": provider_id, "mod": mod_name, "direction": f"folder_{direction}", "count": len(results)}] + _sync_state.get("history", []))[:20]
        return {"results": results, "dry_run": dry_run, "direction": direction, "total": total}
    except Exception as e:
        _set_state(running=False, error=f"{type(e).__name__}: {e}")
        raise


def sync_single_file(provider_id, direction, mod_name, rel_path, dry_run=False):
    """单文件同步核心：direction = upload|download|sync|delete_remote|delete_local"""
    prov = get_provider(provider_id)
    if not prov:
        raise ValueError("provider not found")
    driver = get_driver(prov.get("type"), prov.get("config"))
    mod_dir_real = _get_mod_dir(mod_name)
    if not mod_name or ".." in mod_name or "/" in mod_name or "\\" in mod_name:
        raise ValueError("invalid mod_name")
    rel = _norm_remote(rel_path)
    if not rel:
        raise ValueError("rel_path required")
    local_path = os.path.abspath(os.path.join(mod_dir_real, rel))
    base = os.path.abspath(mod_dir_real)
    if local_path != base and not local_path.startswith(base + os.sep):
        raise ValueError("path escapes mod")
    remote = _remote_path_for(prov, mod_name, rel)
    if dry_run:
        local_exists = os.path.isfile(local_path)
        remote_obj = None
        try:
            remote_obj = driver.stat(remote)
        except Exception:
            remote_obj = None
        return {"dry_run": True, "local_exists": local_exists, "local_size": os.path.getsize(local_path) if local_exists else 0, "remote_exists": remote_obj is not None, "remote_size": remote_obj.size if remote_obj else 0, "remote": remote, "local": local_path, "direction": direction}
    if direction == "upload":
        if not os.path.isfile(local_path):
            raise FileNotFoundError("local file not found: %s" % rel)
        driver.put(local_path, remote)
        _set_state(last="upload %s -> %s" % (rel, remote))
        return {"ok": True, "remote": remote}
    elif direction == "download":
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        _drv_get(driver, remote, local_path)
        _set_state(last="download %s" % rel)
        return {"ok": True, "local": local_path}
    elif direction == "delete_remote":
        driver.delete(remote)
        return {"ok": True}
    elif direction == "delete_local":
        if os.path.isfile(local_path):
            os.remove(local_path)
        return {"ok": True}
    elif direction == "sync":
        # 双向同步（单文件）：mtime 新者为准，语义与 sync_mod_folder 的 sync 一致
        local_exists = os.path.isfile(local_path)
        remote_obj = None
        try:
            remote_obj = driver.stat(remote)
        except Exception:
            remote_obj = None
        if not local_exists and remote_obj is None:
            raise FileNotFoundError("neither local nor remote exists: %s" % rel)
        if local_exists and remote_obj is None:
            driver.put(local_path, remote)
            _set_state(last="sync upload %s -> %s" % (rel, remote))
            return {"ok": True, "action": "sync_upload", "remote": remote}
        if not local_exists and remote_obj is not None:
            os.makedirs(os.path.dirname(local_path), exist_ok=True)
            _drv_get(driver, remote, local_path)
            _set_state(last="sync download %s" % rel)
            return {"ok": True, "action": "sync_download", "local": local_path}
        ls = os.path.getsize(local_path)
        lm = int(os.path.getmtime(local_path))
        if not _need_sync(ls, lm, "", remote_obj.size, remote_obj.mtime, remote_obj.sha1, local_path):
            return {"ok": True, "action": "skip"}
        # rm==0 视为远端时间未知，本地优先上传
        if remote_obj.mtime and lm and int(remote_obj.mtime) > lm:
            _drv_get(driver, remote, local_path)
            _set_state(last="sync download %s" % rel)
            return {"ok": True, "action": "sync_download_update", "local": local_path}
        driver.put(local_path, remote)
        _set_state(last="sync upload %s -> %s" % (rel, remote))
        return {"ok": True, "action": "sync_upload_update", "remote": remote}
    else:
        raise ValueError("unknown direction: %s" % direction)

def sync_mod_files(provider_id, direction, mod_name, rel_paths=None, dry_run=False):
    """批量单文件同步的编排：对 rel_paths 逐个调用 sync_single_file，带进度"""
    prov = get_provider(provider_id)
    if not prov:
        raise ValueError("provider not found")
    if not mod_name:
        raise ValueError("mod_name required")
    paths = rel_paths or []
    if not isinstance(paths, list):
        raise ValueError("rel_paths must be list")
    paths = [_norm_remote(p) for p in paths if p]
    if not paths:
        raise ValueError("no files to sync")
    if len(paths) > 500:
        raise ValueError("too many files (>500)")
    _set_state(running=True, provider=provider_id, action=direction, progress=0, total=len(paths), error="")
    results = []
    try:
        for i, rel in enumerate(paths):
            _set_state(progress=i+1, last=rel)
            try:
                r = sync_single_file(provider_id, direction, mod_name, rel, dry_run=dry_run)
                results.append({"rel": rel, "ok": True, "result": r})
            except Exception as e:
                results.append({"rel": rel, "ok": False, "error": "%s: %s" % (type(e).__name__, e)})
                # 单文件失败不中断整体
        _set_state(running=False, progress=len(paths))
        # 历史
        with _sync_lock:
            _sync_state["history"] = ([{"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "provider": provider_id, "mod": mod_name, "direction": direction, "count": len(paths)}] + _sync_state.get("history", []))[:20]
        return {"results": results, "dry_run": dry_run}
    except Exception as e:
        _set_state(running=False, error="%s: %s" % (type(e).__name__, e))
        raise
