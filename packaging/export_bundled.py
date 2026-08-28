# -*- coding: utf-8 -*-
"""导出内置资源 Zip（Windows 有游戏时执行）

用法:
  python packaging/export_bundled.py [--out resource_pack.zip]

产物为可在设置中加载的 Zip 扩展，含:
  manifest.json
  aa_index.json (可选，来自 _cache/aa_index/aa_index.json)
  base_data.json (来自 _cache/base_data.pkl 转 JSON)
  Cfgs/zh-cn/*.json (如有分散导出)

也可直接用于打包时内置到 backend/editor/data/bundled/
"""
import argparse
import json
import os
import sys
import time
import zipfile
import pickle

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _editor_root():
    return ROOT

def build_zip(out_path, include_aa=True):
    # 准备临时数据
    editor_root = _editor_root()
    # 兼容 backend/_cache 与 _cache 两种位置
    candidates_aa = [os.path.join(editor_root, "_cache", "aa_index", "aa_index.json"), os.path.join(editor_root, "backend", "_cache", "aa_index", "aa_index.json"), os.path.join(editor_root, "backend", "_cache", "aa_index", "aa_index.json")]
    cache_aa = next((c for c in candidates_aa if os.path.isfile(c)), candidates_aa[0])
    candidates_pkl = [os.path.join(editor_root, "_cache", "base_data.pkl"), os.path.join(editor_root, "backend", "_cache", "base_data.pkl")]
    cache_pkl = next((c for c in candidates_pkl if os.path.isfile(c)), candidates_pkl[0])
    # manifest
    manifest = {
        "name": "StudentAge Bundled Resources",
        "version": time.strftime("%Y.%m.%d"),
        "description": "内置游戏资源扩展包（自动导出）",
        "game_version": "",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        if include_aa and os.path.isfile(cache_aa):
            z.write(cache_aa, "aa_index.json")
            print(f" + aa_index.json ({os.path.getsize(cache_aa)} bytes)")
        else:
            print(" - skip aa_index.json (not found)")
        if os.path.isfile(cache_pkl):
            try:
                with open(cache_pkl, "rb") as f:
                    cached = pickle.load(f)
                data = cached.get("data") if isinstance(cached, dict) else cached
                if isinstance(data, dict) and data:
                    z.writestr("base_data.json", json.dumps(data, ensure_ascii=False))
                    print(f" + base_data.json ({len(data)} cfgs)")
                else:
                    print(" - base_data empty, try loading from resource pack fallback")
            except Exception as e:
                print(f" - base_data.pkl error: {e}")
        # 若有已安装的资源包中的 Cfgs，也可一并导出
        # 检查 _cache/resource_packs/active
        active = ""
        packs_meta = os.path.join(editor_root, "_cache", "resource_packs", "packs.json")
        if os.path.isfile(packs_meta):
            try:
                with open(packs_meta, "r", encoding="utf-8") as f:
                    jm = json.load(f)
                active = jm.get("active") or ""
            except Exception:
                pass
        if active:
            src = os.path.join(editor_root, "_cache", "resource_packs", active)
            for root, dirs, files in os.walk(src):
                for fn in files:
                    if fn.endswith(".json"):
                        full = os.path.join(root, fn)
                        rel = os.path.relpath(full, src)
                        # 避免重复 manifest/aa_index/base_data
                        if rel in ("manifest.json", "aa_index.json", "base_data.json"):
                            continue
                        z.write(full, rel)
                        print(f" + {rel}")
        else:
            # 尝试从 _cache/resource_packs 首个包导出
            rp_root = os.path.join(editor_root, "_cache", "resource_packs")
            if os.path.isdir(rp_root):
                for entry in os.listdir(rp_root):
                    if entry == "packs.json":
                        continue
                    src = os.path.join(rp_root, entry)
                    if not os.path.isdir(src):
                        continue
                    for root, dirs, files in os.walk(src):
                        for fn in files:
                            if fn.endswith(".json") and "manifest" not in fn:
                                full = os.path.join(root, fn)
                                rel = os.path.relpath(full, src)
                                if os.path.isfile(os.path.join(editor_root, "_cache", "resource_packs", entry, rel)):
                                    pass
    size = os.path.getsize(out_path)
    print(f"Done: {out_path} ({size/1024:.1f} KB)")
    return out_path

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "dist", "bundled_resources.zip"))
    ap.add_argument("--no-aa", action="store_true", help="skip aa_index")
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    build_zip(args.out, include_aa=not args.no_aa)

if __name__ == "__main__":
    main()
