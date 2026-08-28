"""Unity Addressables bundle 资源服务：索引 + 懒解码导出 + 惰性缓存包装。

- UnityFsIndex: 扫描 bundle 目录，建 资源名->(bundle,path_id) 索引（json 缓存）。
- LazyTexCache / LazyAudioCache: dict 子类，get 命中虚拟前缀值时惰性物化为真实磁盘文件。
"""

import json
import os
import sys
import threading

TEX_PREFIX = "unityfs_tex://"
AUD_PREFIX = "unityfs_aud://"
_SLOW_TAG = "_role_"
_MAX_ENVS = 2
# aa_index.json 缓存格式版本：索引结构变化（如新增 cabs 映射）时递增以强制重建
CACHE_VERSION = 2


def _collect_cabs(env, bundle_path, out):
    """收集 bundle 内所有 SerializedFile 的 CAB 名 -> bundle 路径 映射。

    跨 bundle 依赖（如本地化包里的 Sprite 引用其它包中的图集纹理）解码时，
    需要用该映射把外部 CAB 对应的 bundle 一并加载进同一个 Environment。
    """
    for f in env.files.values():
        for sf in (f.get_assets() if hasattr(f, "get_assets") else []):
            name = (getattr(sf, "name", "") or "").lower()
            if name:
                out.setdefault(name, bundle_path)


def _norm_key(name):
    return os.path.splitext(name or "")[0].split(" #")[0].strip().lower()


def detect_game_aa_dir():
    """在 Steam 库目录中查找游戏的 Addressables 根目录，找不到返回空串。

    跨平台实现见 core/steam_paths.py（Windows/Linux/macOS，含 Proton 场景）。
    """
    try:
        from editor.core.steam_paths import detect_game_aa_dir as _impl
        return _impl()
    except Exception:
        return ""


def _collect_env(env, bundle_path, tex, aud, txt):
    """从 env 收集纹理/音频/配置表键。"""
    for obj in env.objects:
        obj_type = obj.type.name
        if obj_type not in ("Texture2D", "Sprite", "AudioClip", "TextAsset"):
            continue
        try:
            name = obj.peek_name() or ""
        except Exception:
            try:
                name = obj.read().m_Name or ""
            except Exception:
                continue
        if not name:
            continue
        key = _norm_key(name)
        if not key:
            continue
        if obj_type == "AudioClip":
            if key not in aud:
                aud[key] = [bundle_path, obj.path_id]
        elif obj_type == "TextAsset":
            if key not in txt:
                txt[key] = [bundle_path, obj.path_id]
        elif key not in tex:
            tex[key] = [bundle_path, obj.path_id]


def _index_bundle_batch(paths):
    """进程池 worker：批量扫 bundle，返回 [(path, tex, aud, txt, cabs), ...] 供主进程合并。"""
    import UnityPy
    results = []
    for bundle_path in paths:
        tex = {}
        aud = {}
        txt = {}
        cabs = {}
        try:
            env = UnityPy.load(bundle_path)
            _collect_env(env, bundle_path, tex, aud, txt)
            _collect_cabs(env, bundle_path, cabs)
        except Exception:
            pass
        results.append((bundle_path, tex, aud, txt, cabs))
    return results


class UnityFsIndex(object):

    def __init__(self, bundle_dirs, cache_root="", fingerprint=""):
        self.bundle_dirs = [d for d in (bundle_dirs or []) if d and os.path.isdir(d)]
        self.cache_root = cache_root or ""
        self.fingerprint = fingerprint or ""
        self._tex = {}
        self._aud = {}
        self._txt = {}
        self._cabs = {}
        self._bundle_set = set()
        self._envs = {}
        self._lock = threading.Lock()
        self.index_total = 0
        self.index_done = 0

    def progress(self):
        return self.index_done, self.index_total

    def _cache_file(self, name):
        if not self.cache_root:
            return ""
        try:
            os.makedirs(self.cache_root, exist_ok=True)
        except Exception:
            pass
        return os.path.join(self.cache_root, name)

    def try_load_cached(self):
        idx = self._cache_file("aa_index.json")
        if not idx or not os.path.exists(idx):
            return False
        try:
            with open(idx, "r", encoding="utf-8") as f:
                data = json.load(f)
            if data.get("v") != CACHE_VERSION:
                return False
            if data.get("fp") != self.fingerprint:
                return False
            self._tex = dict(data.get("tex") or {})
            self._aud = dict(data.get("aud") or {})
            self._txt = dict(data.get("txt") or {})
            self._cabs = dict(data.get("cabs") or {})
            self._bundle_set = set(data.get("bundles") or [])
            return True
        except Exception:
            return False

    def scan(self, include_slow=False):
        if self.try_load_cached():
            return True
        self._scan_dirs(include_slow)
        self._save_index()
        return False

    def scan_extra(self, tags):
        """只扫描文件名含任一 tag 的 bundle，增量补入索引并刷新缓存。"""
        before = len(self._tex) + len(self._aud) + len(self._txt)
        paths = []
        for d in self.bundle_dirs:
            for root, dirs, files in os.walk(d):
                dirs[:] = [x for x in dirs if not x.endswith("_unpacked")]
                for f in sorted(files):
                    if not f.lower().endswith(".bundle"):
                        continue
                    if not any(tag in f for tag in tags):
                        continue
                    p = os.path.join(root, f)
                    if p in self._bundle_set:
                        continue
                    try:
                        if os.path.getsize(p) == 0:
                            continue
                    except Exception:
                        continue
                    paths.append(p)
        if paths:
            self.index_total += len(paths)
            self._run_pool(paths)
        if len(self._tex) + len(self._aud) + len(self._txt) > before:
            self._save_index()

    def _save_index(self):
        idx = self._cache_file("aa_index.json")
        if not idx:
            return
        try:
            tex = dict(self._tex)
            aud = dict(self._aud)
            txt = dict(self._txt)
            bundles = sorted(self._bundle_set)
            payload = {
                "v": CACHE_VERSION,
                "fp": self.fingerprint,
                "tex": tex,
                "aud": aud,
                "txt": txt,
                "cabs": dict(self._cabs),
                "bundles": bundles,
            }
            tmp = idx + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
            os.replace(tmp, idx)
        except Exception:
            pass

    def _merge_batch(self, results):
        for path, tex, aud, txt, cabs in results:
            self._bundle_set.add(path)
            for k, v in tex.items():
                if k not in self._tex:
                    self._tex[k] = v
            for k, v in aud.items():
                if k not in self._aud:
                    self._aud[k] = v
            for k, v in txt.items():
                if k not in self._txt:
                    self._txt[k] = v
            for k, v in cabs.items():
                if k not in self._cabs:
                    self._cabs[k] = v
        self.index_done = len(self._bundle_set)

    def _run_pool(self, paths):
        """并行索引；大包（role）即使单包也走池以释放主进程 GIL。

        分批合并：每批完成后立即落盘，中途退出后下次只补扫剩余 bundle。
        桶内按体积升序（小包先完成），让首批小资源尽快可用。
        打包(frozen)环境下 multiprocessing spawn 不稳定，回退为串行（由后台线程执行，不影响 UI）。
        """
        if getattr(sys, "frozen", False):
            for p in paths:
                self._index_bundle(p)
            return
        from concurrent.futures import ProcessPoolExecutor
        slow = any(_SLOW_TAG in p for p in paths)
        if len(paths) <= 2 and not slow:
            for p in paths:
                self._index_bundle(p)
            return
        try:
            big_first = sorted(paths, key=os.path.getsize, reverse=True)
            if len(big_first) > 1:
                buckets = [[], []]
                sums = [0, 0]
                for p in big_first:
                    i = 0 if sums[0] <= sums[1] else 1
                    buckets[i].append(p)
                    sums[i] += os.path.getsize(p)
            else:
                buckets = [big_first, []]
            batches = []
            for b in buckets:
                if b:
                    b.reverse()
                    batches.append(b)
            with ProcessPoolExecutor(max_workers=len(batches)) as pool:
                for results in pool.map(_index_bundle_batch, batches):
                    self._merge_batch(results)
                    self._save_index()
        except Exception:
            for p in paths:
                self._index_bundle(p)

    def _scan_dirs(self, include_slow):
        paths = []
        for d in self.bundle_dirs:
            for root, dirs, files in os.walk(d):
                dirs[:] = [x for x in dirs if not x.endswith("_unpacked")]
                for f in sorted(files):
                    if not f.lower().endswith(".bundle"):
                        continue
                    if not include_slow and _SLOW_TAG in f:
                        continue
                    p = os.path.join(root, f)
                    if p in self._bundle_set:
                        continue
                    try:
                        if os.path.getsize(p) == 0:
                            continue
                    except Exception:
                        continue
                    paths.append(p)
        if paths:
            self.index_total = len(paths)
            self.index_done = len(self._bundle_set)
            self._run_pool(paths)

    def _index_bundle(self, path):
        import UnityPy
        try:
            env = UnityPy.load(path)
        except Exception:
            return
        self._bundle_set.add(path)
        self.index_done = len(self._bundle_set)
        _collect_env(env, path, self._tex, self._aud, self._txt)
        _collect_cabs(env, path, self._cabs)

    def has_tex(self, key):
        return _norm_key(key) in self._tex

    def has_aud(self, key):
        return _norm_key(key) in self._aud

    def has_txt(self, key):
        return _norm_key(key) in self._txt

    def tex_keys(self):
        return list(self._tex)

    def aud_keys(self):
        return list(self._aud)

    def txt_keys(self):
        return list(self._txt)

    def export_text(self, key):
        """读取配置表 TextAsset 内容（utf-8 字节）。"""
        item = self._txt.get(_norm_key(key))
        if not item:
            return None
        try:
            env = self._get_env(item[0])
            obj = self._find_object(env, item[0], item[1])
            if obj is not None:
                script = obj.read().m_Script
                if isinstance(script, str):
                    return script.encode("utf-8")
                return bytes(script)
        except Exception:
            return None
        return None

    def _get_env(self, path):
        with self._lock:
            env = self._envs.get(path)
        if env is None:
            import UnityPy
            env = UnityPy.load(path)
            self._load_dependencies(env, path)
            with self._lock:
                if len(self._envs) >= _MAX_ENVS:
                    self._envs.pop(next(iter(self._envs)))
                self._envs[path] = env
        return env

    def _load_dependencies(self, env, path):
        """把主 bundle 外部引用的 CAB 所对应的 bundle 一并加载进同一 Environment。

        本地化包中的 Sprite 常引用其它 bundle（图集包）里的纹理，
        单文件 Environment 无法解析该外部引用，解码会失败。此方法按
        CAB 名 -> bundle 路径 映射把依赖包补加载进来（BFS，去重），
        使 UnityPy 能通过 register_cab 解析跨 bundle 的 PPtr。
        """
        if not self._cabs:
            return
        seen = {path}
        stack = [path]
        while stack:
            cur = stack.pop()
            fobj = env.files.get(cur)
            if fobj is None:
                continue
            for sf in (fobj.get_assets() if hasattr(fobj, "get_assets") else []):
                for ext in getattr(sf, "externals", []) or []:
                    if isinstance(ext, (tuple, list)):
                        cab = str(ext[0])
                    else:
                        cab = str(getattr(ext, "name", ext))
                    cab = cab.lower()
                    dep = self._cabs.get(cab)
                    if dep and dep not in seen:
                        try:
                            env.load_file(dep)
                        except Exception:
                            continue
                        seen.add(dep)
                        stack.append(dep)

    def _find_object(self, env, bundle_path, path_id):
        """在 env 中定位 (bundle_path, path_id) 对应的对象（仅查主 bundle 的文件）。

        env 可能包含为解析跨 bundle 依赖而额外加载的文件，直接遍历
        env.objects 会因 path_id 冲突而取错对象，因此必须限定在主文件内查找。
        """
        fobj = env.files.get(bundle_path)
        if fobj is None:
            return None
        for sf in (fobj.get_assets() if hasattr(fobj, "get_assets") else []):
            obj = (sf.objects or {}).get(path_id)
            if obj is not None:
                return obj
        return None

    def export_tex_png(self, key, out_path):
        item = self._tex.get(key)
        if not item:
            return False
        try:
            env = self._get_env(item[0])
            obj = self._find_object(env, item[0], item[1])
            if obj is None:
                return False
            img = obj.read().image
            img.save(out_path, "PNG")
            return True
        except Exception:
            return False

    def preview_tex_png(self, key):
        """读取纹理并返回 PNG 字节（内存，不落盘）；失败返回 None。"""
        item = self._tex.get(_norm_key(key))
        if not item:
            return None
        try:
            env = self._get_env(item[0])
            obj = self._find_object(env, item[0], item[1])
            if obj is None:
                return None
            img = obj.read().image
            from io import BytesIO
            buf = BytesIO()
            img.save(buf, "PNG")
            return buf.getvalue()
        except Exception:
            return None

    def _read_audio(self, key):
        """读取音频并解码为 (blob, ext)；失败返回 None。"""
        item = self._aud.get(_norm_key(key))
        if not item:
            return None
        try:
            env = self._get_env(item[0])
            obj = self._find_object(env, item[0], item[1])
            if obj is None:
                return None
            audio = obj.read()
            from UnityPy.helpers.ResourceReader import get_resource_data
            if getattr(audio, "m_AudioData", None):
                data = bytes(audio.m_AudioData)
            elif getattr(audio, "m_Resource", None):
                res = audio.m_Resource
                data = get_resource_data(res.m_Source, obj.assets_file, res.m_Offset, res.m_Size)
            else:
                return None
            magic = memoryview(data)[:8]
            if magic[:4] == b"OggS":
                return data, ".ogg"
            if magic[:4] == b"RIFF":
                return data, ".wav"
            if magic[4:8] == b"ftyp":
                return data, ".m4a"
            import fmod_toolkit
            res_map = fmod_toolkit.raw_to_wav(
                data, "clip", audio.m_Channels or 2, audio.m_Frequency or 44100)
            return next(iter(res_map.values())), ".wav"
        except Exception:
            return None

    def export_audio(self, key, out_path):
        result = self._read_audio(key)
        if result is None:
            return None
        blob, ext = result
        try:
            with open(out_path + ext, "wb") as f:
                f.write(blob)
            return out_path + ext
        except Exception:
            return None

    def preview_audio(self, key):
        """读取音频并返回 (blob, ext)（内存，不落盘）；失败返回 None。"""
        return self._read_audio(key)


def _export_png_worker(payload):
    """进程池导出 PNG（kind=tex）。payload=(key, item, out)。"""
    key, item, out = payload
    try:
        import UnityPy
        env = UnityPy.load(item[0])
        for obj in env.objects:
            if obj.path_id == item[1]:
                img = obj.read().image
                img.save(out, "PNG")
                return out if os.path.exists(out) else None
    except Exception:
        return None
    return None


def _export_png_batch_worker(payloads):
    """批量导出 PNG：按 bundle 分组，每个 bundle 只 load 一次，导出其下所有待导纹理。

    payloads = [(key, item, out), ...]，返回 [(key, out), ...]。
    相比逐 key 导出，消除了对同一 bundle 的重复 UnityPy.load（大包单次 load 可超过 5s）。
    """
    import UnityPy
    by_bundle = {}
    order = []
    for key, item, out in payloads:
        if item[0] not in by_bundle:
            by_bundle[item[0]] = []
            order.append(item[0])
        by_bundle[item[0]].append((key, item[1], out))
    done = []
    for bundle_path in order:
        items = by_bundle[bundle_path]
        try:
            env = UnityPy.load(bundle_path)
            by_path = {obj.path_id: obj for obj in env.objects}
            for key, path_id, out in items:
                try:
                    obj = by_path.get(path_id)
                    if obj is None:
                        continue
                    img = obj.read().image
                    img.save(out, "PNG")
                    if os.path.exists(out):
                        done.append((key, out))
                except Exception:
                    continue
        except Exception:
            continue
    return done


def _export_audio_worker(payload):
    """进程池导出音频（kind=aud）。payload=(key, item, base)。"""
    key, item, base = payload
    try:
        import UnityPy
        from UnityPy.helpers.ResourceReader import get_resource_data
        env = UnityPy.load(item[0])
        audio = None
        for obj in env.objects:
            if obj.path_id == item[1]:
                audio = obj.read()
                break
        if audio is None:
            return None
        if getattr(audio, "m_AudioData", None):
            data = bytes(audio.m_AudioData)
        elif getattr(audio, "m_Resource", None):
            res = audio.m_Resource
            data = get_resource_data(res.m_Source, obj.assets_file, res.m_Offset, res.m_Size)
        else:
            return None
        magic = memoryview(data)[:8]
        if magic[:4] == b"OggS":
            ext = ".ogg"
            blob = data
        elif magic[:4] == b"RIFF":
            ext = ".wav"
            blob = data
        elif magic[4:8] == b"ftyp":
            ext = ".m4a"
            blob = data
        else:
            import fmod_toolkit
            res_map = fmod_toolkit.raw_to_wav(
                data, "clip", audio.m_Channels or 2, audio.m_Frequency or 44100)
            blob = next(iter(res_map.values()))
            ext = ".wav"
        with open(base + ext, "wb") as f:
            f.write(blob)
        return base + ext
    except Exception:
        return None


class LazyCache(dict):

    kind = ""

    def __init__(self, data, materialize):
        super(LazyCache, self).__init__({k: v for k, v in (data or {}).items()})
        self._materialize = materialize
        self._pending = {}

    def _resolve(self, key, val):
        if isinstance(val, str) and val.startswith(self.kind):
            real = self._materialize(key)
            if real:
                dict.__setitem__(self, key, real)
                return real
        return val

    def __getitem__(self, key):
        return self._resolve(key, dict.__getitem__(self, key))

    def get(self, key, default=None):
        try:
            return self.__getitem__(key)
        except KeyError:
            return default

    def poll_ready(self):
        """后台导出完成检查：返回新就绪的 [(key, path)] 并写回缓存。"""
        ready = []
        for key, fut in list(self._pending.items()):
            if not fut.done():
                continue
            self._pending.pop(key, None)
            try:
                out = fut.result()
            except Exception:
                out = None
            if out:
                dict.__setitem__(self, key, out)
                ready.append((key, out))
        return ready


class LazyTexCache(LazyCache):

    kind = TEX_PREFIX


class LazyAudioCache(LazyCache):

    kind = AUD_PREFIX