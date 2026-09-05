# -*- coding: utf-8 -*-
"""预解码资源包访问：读取资源包 tex/aud 目录中的解码文件，绕开 UnityPy。

背景：Android（Chaquopy）无游戏目录且缺 ASTC/FSB 原生解码器，桌面管线
packaging/export_decoded_pack.py 在构建期把纹理转 WebP、音频/文本原样导出为
资源包（aa_index.json v3 携带 tex/aud/txt 键列表 + tex/*.webp、aud/*.ogg）。
本类只做目录扫描映射，供 /api/aa/preview|export|keys 在无游戏索引时回落。
"""
import json
import os

_TEX_EXTS = (".webp", ".png", ".jpg", ".jpeg")
_AUD_EXTS = (".ogg", ".wav", ".m4a", ".mp3")
_TEX_MIME = {
    ".webp": "image/webp",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}
_AUD_MIME = {
    ".ogg": "audio/ogg",
    ".wav": "audio/wav",
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
}


class DecodedPackStore(object):
    """活动资源包中的预解码文件索引：key（小写规范键）→ 磁盘文件路径。"""

    def __init__(self):
        self._dir = ""
        self._tex = {}
        self._aud = {}
        self._txt = []

    @property
    def active(self):
        return bool(self._dir)

    def refresh(self, pack_dir):
        """重建索引。pack_dir 变化时才真正扫描（列表项可能上千，避免高频 IO）。

        先构建到局部变量、末尾整体交换引用：服务端是 ThreadingHTTPServer，
        扫描期间并发读者仍拿到完整旧索引，不会看到被清空的 dict 或半写状态。
        """
        pack_dir = pack_dir or ""
        if pack_dir == self._dir:
            return
        tex = {}
        aud = {}
        txt = []
        tex_dir = os.path.join(pack_dir, "tex")
        aud_dir = os.path.join(pack_dir, "aud")
        try:
            if os.path.isdir(tex_dir):
                for fn in os.listdir(tex_dir):
                    ext = os.path.splitext(fn)[1].lower()
                    if ext in _TEX_EXTS:
                        tex[os.path.splitext(fn)[0].lower()] = os.path.join(tex_dir, fn)
        except Exception:
            pass
        try:
            if os.path.isdir(aud_dir):
                for fn in os.listdir(aud_dir):
                    ext = os.path.splitext(fn)[1].lower()
                    if ext in _AUD_EXTS:
                        aud[os.path.splitext(fn)[0].lower()] = os.path.join(aud_dir, fn)
        except Exception:
            pass
        # 文本键：优先 v3 aa_index.json 的 txt 列表，缺失时回退扫描 Cfgs/zh-cn
        try:
            with open(os.path.join(pack_dir, "aa_index.json"), "r", encoding="utf-8") as f:
                j = json.load(f)
            if isinstance(j, dict) and j.get("v") == 3:
                t = j.get("txt")
                if isinstance(t, list):
                    txt = [str(k) for k in t]
        except Exception:
            pass
        if not txt:
            zh = os.path.join(pack_dir, "Cfgs", "zh-cn")
            try:
                if os.path.isdir(zh):
                    txt = sorted(
                        os.path.splitext(f)[0]
                        for f in os.listdir(zh)
                        if f.lower().endswith(".json")
                    )
            except Exception:
                pass
        # 原子交换：读者要么拿到旧的完整索引，要么新的完整索引
        self._tex = tex
        self._aud = aud
        self._txt = txt
        self._texsizes = {}
        self._dir = pack_dir

    def tex_count(self):
        return len(self._tex)

    def aud_count(self):
        return len(self._aud)

    def tex_keys(self):
        return sorted(self._tex.keys())

    def aud_keys(self):
        return sorted(self._aud.keys())

    def txt_keys(self):
        return list(self._txt)

    def tex_path(self, key):
        return self._tex.get((key or "").strip().lower())

    def aud_path(self, key):
        return self._aud.get((key or "").strip().lower())

    def tex_meta(self, key):
        """返回贴图文件 [w, h]：PIL 只读图像头部，按需缓存；失败 None。

        与 UnityFsIndex.tex_meta 接口对齐（剧情图 CG 判定用）。资源包目录
        是平铺的解码文件（无 bundle 分组信息），仅有尺寸信号可用。
        """
        path = self.tex_path(key)
        if not path:
            return None
        ck = (key or "").strip().lower()
        if not hasattr(self, "_texsizes"):
            self._texsizes = {}
        if ck in self._texsizes:
            return self._texsizes[ck]
        size = None
        try:
            from PIL import Image
            with Image.open(path) as im:
                w, h = im.size
            if w > 0 and h > 0:
                size = [int(w), int(h)]
        except Exception:
            size = None
        self._texsizes[ck] = size
        return size

    def read_file(self, path):
        """读取解码文件字节与扩展名；失败返回 None。"""
        if not path:
            return None
        try:
            with open(path, "rb") as f:
                return f.read(), os.path.splitext(path)[1].lower()
        except Exception:
            return None