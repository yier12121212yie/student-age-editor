# -*- coding: utf-8 -*-
"""资源扩展包管理：Zip 形式的内置资源分发"""
import json
import os
import sys
import time
import zipfile
import hashlib
import shutil

from editor.core import atomic_io

def _editor_root():
    from editor.core.paths import app_data_dir
    return app_data_dir()

def packs_root():
    # EDITOR_PACKS_ROOT：Android（Chaquopy）等无写权限环境的覆盖入口，
    # 由 start_server(data_root/packs_root) 写入，指向 filesDir/resource_packs。
    root = os.environ.get("EDITOR_PACKS_ROOT") or os.path.join(_editor_root(), "_cache", "resource_packs")
    alt = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "resource_packs")
    try:
        os.makedirs(root, exist_ok=True)
    except Exception:
        pass
    if os.path.isdir(alt) and not os.listdir(root):
        try:
            for name in os.listdir(alt):
                src = os.path.join(alt, name)
                dst = os.path.join(root, name)
                if not os.path.exists(dst):
                    if os.path.isdir(src):
                        shutil.copytree(src, dst)
                    else:
                        shutil.copy2(src, dst)
        except Exception:
            pass
    return root

def system_packs_root():
    """只读系统资源包根目录：安装包内嵌的官方包（随程序分发）。

    位于 backend 可执行文件同级的 official_pack/ 下（Linux/macOS 的便携
    zip、deb /opt、AppImage、.app/Contents/MacOS 均满足），只读查找、
    不拷贝不写入。Windows Inno 安装包仍走安装时解包到 packs_root 的
    历史机制，official_pack 目录不存在时本函数返回空串、无任何效果。
    """
    if not getattr(sys, "frozen", False):
        return ""
    root = os.path.join(os.path.dirname(os.path.abspath(sys.executable)), "official_pack")
    return root if os.path.isdir(root) else ""

def _pack_dir(pack_id):
    """按 id 解析包目录：先可写根，再只读系统根；找不到返回空串。"""
    if not pack_id or "/" in pack_id or "\\" in pack_id or ".." in pack_id:
        return ""
    for root in (packs_root(), system_packs_root()):
        if not root:
            continue
        d = os.path.join(root, pack_id)
        if os.path.isdir(d):
            return d
    return ""

def _is_builtin(pack_id):
    """包是否只存在于只读系统根（不可删除）。"""
    root = system_packs_root()
    if not root or not os.path.isdir(os.path.join(root, pack_id)):
        return False
    return not os.path.isdir(os.path.join(packs_root(), pack_id))

def meta_path():
    return os.path.join(packs_root(), "packs.json")

def _load_meta():
    try:
        with open(meta_path(), "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "packs" in data:
            return data
    except Exception:
        pass
    return {"active": "", "packs": []}

def _save_meta(meta):
    try:
        atomic_io.write_text_atomic(
            meta_path(), json.dumps(meta, ensure_ascii=False, indent=2))
    except Exception:
        pass

def _pack_id_from_name(name):
    base = os.path.splitext(os.path.basename(name or ""))[0].strip()
    if not base:
        base = "pack_%d" % int(time.time())
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in base)
    return safe[:64] or "pack"

def _pack_entry(pid, d, builtin):
    """构造包列表条目；builtin 为 True 表示只读系统包（不可删除）。"""
    manifest = {}
    try:
        with open(os.path.join(d, "manifest.json"), "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except Exception:
        manifest = {}
    cnt = 0
    try:
        for _, _, files in os.walk(d):
            cnt += len(files)
    except Exception:
        pass
    return {"id": pid, "name": manifest.get("name") or pid, "version": manifest.get("version") or "", "description": manifest.get("description") or "", "game_version": manifest.get("game_version") or "", "created_at": manifest.get("created_at") or "", "files": cnt, "builtin": bool(builtin)}

def list_packs():
    meta = _load_meta()
    wroot, sroot = packs_root(), system_packs_root()
    def _list_existing(root):
        existing = set()
        try:
            for d in os.listdir(root):
                if os.path.isdir(os.path.join(root, d)) and d != "__pycache__":
                    existing.add(d)
        except Exception:
            pass
        return existing
    existing = _list_existing(wroot)
    builtin_ids = _list_existing(sroot) if sroot else set()
    packs = [p for p in meta.get("packs", []) if p.get("id") in existing]
    active = meta.get("active") or ""
    if active and active not in existing and active not in builtin_ids:
        active = ""
    ids = {p.get("id") for p in packs}
    for pid in existing:
        if pid not in ids and pid != "__pycache__":
            packs.append(_pack_entry(pid, os.path.join(wroot, pid), builtin=False))
    for pid in sorted(builtin_ids):
        if pid not in ids and pid not in existing and pid != "__pycache__":
            packs.append(_pack_entry(pid, os.path.join(sroot, pid), builtin=True))
    # 首启（尚无 packs.json）且恰好只发现一个包时默认激活，
    # 保证安装包内嵌官方资源包后开箱即用（对齐 Windows 安装包行为）
    if not os.path.isfile(meta_path()) and not active and len(packs) == 1:
        active = packs[0]["id"]
        _save_meta({"active": active, "packs": packs})
    meta = {"active": active, "packs": packs}
    return meta

def _count_files(pack_id):
    d = _pack_dir(pack_id)
    cnt = 0
    try:
        for root, dirs, files in os.walk(d):
            cnt += len(files)
    except Exception:
        pass
    return cnt

def get_active_dir():
    meta = _load_meta()
    active = meta.get("active") or ""
    if not active:
        return ""
    d = _pack_dir(active)
    return d if d and os.path.isdir(d) else ""

def set_active(pack_id):
    meta = _load_meta()
    if pack_id:
        d = _pack_dir(pack_id)
        if not d:
            raise ValueError("pack not found: %s" % pack_id)
    meta["active"] = pack_id or ""
    _save_meta(meta)
    try:
        from editor.server import preview_service as _ps
        _ps.invalidate_cache()
    except Exception:
        pass
    try:
        from editor.server.api import STATE as _ST
        if _ST.base is not None:
            _ST.base.status = "idle"
    except Exception:
        pass
    return meta

def _install_zip(z, filename=""):
    """通用 zip 安装：校验条目安全 → 解压 → 补 manifest → 注册元数据。

    z 为已打开的 zipfile.ZipFile；install_pack（base64）与
    install_pack_from_path（按路径）共用校验与注册逻辑。
    """
    names = z.namelist()
    if not names:
        raise ValueError("empty zip")
    for n in names:
        if n.startswith("/") or ".." in n or ":" in n:
            raise ValueError("illegal entry: %r" % n)
    pack_id = _pack_id_from_name(filename)
    base_id = pack_id
    i = 1
    while os.path.exists(os.path.join(packs_root(), pack_id)):
        pack_id = "%s_%d" % (base_id, i)
        i += 1
    dest = os.path.join(packs_root(), pack_id)
    os.makedirs(dest, exist_ok=True)
    try:
        z.extractall(dest)
    except Exception as e:
        shutil.rmtree(dest, ignore_errors=True)
        raise ValueError("extract failed: %s" % e)
    mp = os.path.join(dest, "manifest.json")
    manifest = {}
    if os.path.isfile(mp):
        try:
            with open(mp, "r", encoding="utf-8-sig") as f:
                manifest = json.load(f)
        except Exception:
            manifest = {}
    if not isinstance(manifest, dict):
        manifest = {}
    manifest.setdefault("name", pack_id)
    manifest.setdefault("version", "1.0.0")
    manifest.setdefault("description", "")
    manifest.setdefault("created_at", time.strftime("%Y-%m-%dT%H:%M:%S"))
    try:
        atomic_io.write_text_atomic(
            mp, json.dumps(manifest, ensure_ascii=False, indent=2))
    except Exception:
        pass
    has_content = False
    for probe in ("aa_index.json", "base_data.json", "dicts.json", "game_schema.json", "manifest.json"):
        if os.path.isfile(os.path.join(dest, probe)):
            has_content = True
            break
    if not has_content:
        for root, dirs, files in os.walk(dest):
            if any(f.endswith(".json") for f in files):
                has_content = True
                break
    if not has_content:
        shutil.rmtree(dest, ignore_errors=True)
        raise ValueError("zip missing valid resources")
    meta = _load_meta()
    meta["packs"] = [p for p in meta.get("packs", []) if p.get("id") != pack_id]
    meta["packs"].append({"id": pack_id, "name": manifest.get("name") or pack_id, "version": manifest.get("version") or "", "description": manifest.get("description") or "", "game_version": manifest.get("game_version") or "", "created_at": manifest.get("created_at") or "", "files": _count_files(pack_id)})
    if not meta.get("active"):
        meta["active"] = pack_id
    _save_meta(meta)
    return {"id": pack_id, "manifest": manifest, "meta": meta}


def install_pack(zip_bytes, filename=""):
    if not zip_bytes or len(zip_bytes) < 4:
        raise ValueError("empty zip")
    if len(zip_bytes) > 500 * 1024 * 1024:
        raise ValueError("zip too large (>500MB)")
    import io
    try:
        z = zipfile.ZipFile(io.BytesIO(zip_bytes))
    except Exception as e:
        raise ValueError("invalid zip: %s" % e)
    return _install_zip(z, filename)


def install_pack_from_path(path, filename=""):
    """按本地路径安装资源包 zip（移动端导入：绕过 base64 与 500MB 限制）。

    文件保留在原地（前端导入时已拷贝到其可写临时目录），本函数不负责清理。
    """
    if not path or not os.path.isfile(path):
        raise ValueError("file not found: %s" % path)
    try:
        size = os.path.getsize(path)
    except Exception:
        size = 0
    if size <= 0:
        raise ValueError("empty file")
    if size > 4 * 1024 * 1024 * 1024:
        raise ValueError("zip too large (>4GB)")
    try:
        z = zipfile.ZipFile(path)
    except Exception as e:
        raise ValueError("invalid zip: %s" % e)
    return _install_zip(z, filename or os.path.basename(path))

def uninstall_pack(pack_id):
    if not pack_id or "/" in pack_id or "\\" in pack_id or ".." in pack_id:
        raise ValueError("invalid pack id")
    if _is_builtin(pack_id):
        raise ValueError("内置资源包不可删除：%s" % pack_id)
    d = os.path.join(packs_root(), pack_id)
    if not os.path.isdir(d):
        raise ValueError("pack not found: %s" % pack_id)
    shutil.rmtree(d, ignore_errors=True)
    meta = _load_meta()
    meta["packs"] = [p for p in meta.get("packs", []) if p.get("id") != pack_id]
    if meta.get("active") == pack_id:
        meta["active"] = meta["packs"][0]["id"] if meta["packs"] else ""
    _save_meta(meta)
    return meta

def get_pack_info(pack_id):
    d = _pack_dir(pack_id)
    if not d:
        return None
    mp = os.path.join(d, "manifest.json")
    manifest = {}
    try:
        with open(mp, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except Exception:
        pass
    stats = {"total_files": 0, "has_aa": False, "has_base": False, "has_cfgs": 0}
    stats["has_aa"] = os.path.isfile(os.path.join(d, "aa_index.json"))
    stats["has_base"] = os.path.isfile(os.path.join(d, "base_data.json"))
    cfgs_dir = os.path.join(d, "Cfgs", "zh-cn")
    if os.path.isdir(cfgs_dir):
        try:
            stats["has_cfgs"] = len([f for f in os.listdir(cfgs_dir) if f.endswith(".json")])
        except Exception:
            pass
    else:
        alt = os.path.join(d, "Cfgs")
        if os.path.isdir(alt):
            try:
                stats["has_cfgs"] = sum(1 for _, _, files in os.walk(alt) for f in files if f.endswith(".json"))
            except Exception:
                pass
    try:
        for _, _, files in os.walk(d):
            stats["total_files"] += len(files)
    except Exception:
        pass
    return {"id": pack_id, "manifest": manifest, "stats": stats, "dir": d}
