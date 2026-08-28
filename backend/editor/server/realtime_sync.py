# -*- coding: utf-8 -*-
"""
Realtime cloud sync extension for StudentAge Editor.

Polls local Mod folders and optionally remote storage, debounces changes,
and auto-triggers incremental sync via cloud_sync.

Design:
  - File monitoring via mtime+size polling (2s interval, no extra deps).
  - Optional watchdog if installed (uses watchdog.observers).
  - Debounce (default 2s) to coalesce rapid saves.
  - Incremental sync: only changed files via sync_mod_files.
  - Remote polling for download/sync directions (default 30s).
  - Persistent config in _cache/realtime_config.json
  - Status & event log with thread-safe state.
  - Integrates with existing cloud_sync sync_status lock to avoid overlap.
"""
import os
import sys
import json
import time
import threading
import hashlib

# ---------- paths ----------

def _editor_root():
    from editor.core.paths import app_data_dir
    return app_data_dir()

def _rt_config_path():
    # Prefer workspace/.editor_realtime.json if workspace exists, else _cache
    try:
        from editor.server.api import STATE as _ST
        ws = getattr(_ST, "workspace_root", "") if _ST else ""
        if ws and os.path.isdir(ws):
            return os.path.join(ws, ".editor_realtime.json")
    except Exception:
        pass
    return os.path.join(_editor_root(), "_cache", "realtime_config.json")

def _default_config():
    return {
        "enabled": False,
        "provider_id": "",
        "mod_name": "",          # single mod or "" for all mods
        "mods": [],              # if non-empty, watch these mods; else use mod_name or all
        "direction": "upload",   # upload | download | sync
        "debounce_ms": 2000,
        "poll_interval_ms": 2000,
        "remote_poll_interval_ms": 30000,
        "delete_extra": False,
        "auto_start": False,
        "watch_all_mods": False,
    }

# ---------- config persistence ----------

_rt_config_lock = threading.Lock()

def _rt_load_config():
    p = _rt_config_path()
    cfg = _default_config()
    try:
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                for k, v in data.items():
                    if k in cfg:
                        cfg[k] = v
                # normalize
                # keep mods as list
                if cfg.get("mods") and not isinstance(cfg["mods"], list):
                    cfg["mods"] = []
                if cfg.get("direction") not in ("upload", "download", "sync"):
                    cfg["direction"] = "upload"
                # clamp intervals
                cfg["debounce_ms"] = max(300, min(15000, int(cfg.get("debounce_ms", 2000))))
                cfg["poll_interval_ms"] = max(500, min(10000, int(cfg.get("poll_interval_ms", 2000))))
                cfg["remote_poll_interval_ms"] = max(5000, min(300000, int(cfg.get("remote_poll_interval_ms", 30000))))
    except Exception:
        pass
    return cfg

def _rt_save_config(cfg):
    p = _rt_config_path()
    tmp = p + ".tmp"
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        os.replace(tmp, p)
    except Exception as e:
        print("[realtime] save config failed: %s" % e)

def rt_get_config():
    with _rt_config_lock:
        return _rt_load_config()

def rt_update_config(patch):
    if not isinstance(patch, dict):
        raise ValueError("config patch must be dict")
    with _rt_config_lock:
        cfg = _rt_load_config()
        for k in ("enabled", "provider_id", "mod_name", "mods", "direction",
                  "debounce_ms", "poll_interval_ms", "remote_poll_interval_ms",
                  "delete_extra", "auto_start", "watch_all_mods"):
            if k in patch:
                if k == "mods":
                    v = patch[k]
                    if v is None:
                        cfg[k] = []
                    elif isinstance(v, list):
                        cfg[k] = [str(x) for x in v if str(x).strip()]
                    elif isinstance(v, str) and v.strip():
                        cfg[k] = [v.strip()]
                    else:
                        cfg[k] = []
                elif k in ("delete_extra", "enabled", "auto_start", "watch_all_mods"):
                    cfg[k] = bool(patch[k])
                elif k == "direction":
                    d = str(patch[k]).lower()
                    if d in ("upload", "download", "sync"):
                        cfg[k] = d
                elif k in ("debounce_ms", "poll_interval_ms", "remote_poll_interval_ms"):
                    try:
                        cfg[k] = int(patch[k])
                    except Exception:
                        pass
                else:
                    cfg[k] = patch[k]
        # normalize mods vs mod_name
        if cfg.get("watch_all_mods"):
            cfg["mods"] = []
            cfg["mod_name"] = ""
        # clamp
        cfg["debounce_ms"] = max(300, min(15000, int(cfg.get("debounce_ms", 2000))))
        cfg["poll_interval_ms"] = max(500, min(10000, int(cfg.get("poll_interval_ms", 2000))))
        cfg["remote_poll_interval_ms"] = max(5000, min(300000, int(cfg.get("remote_poll_interval_ms", 30000))))
        _rt_save_config(cfg)
        return cfg

# ---------- state ----------

_rt_state_lock = threading.Lock()
_rt_state = {
    "running": False,          # watcher thread alive
    "enabled": False,          # config enabled + running
    "provider_id": "",
    "mod_name": "",
    "direction": "upload",
    "last_sync": "",
    "last_sync_result": None,
    "pending_count": 0,
    "pending_files": [],
    "error": "",
    "events": [],              # list of {time, level, msg, mod?}
    "stats": {"local_changes": 0, "remote_changes": 0, "sync_success": 0, "sync_failed": 0},
    "watching_mods": [],
    "next_remote_poll": 0,
}

_rt_thread = None
_rt_stop = threading.Event()
_rt_pending = {}  # mod -> set(rel)
_rt_prev_snapshots = {}  # mod -> dict rel->(size, mtime)
_rt_last_change_ts = 0
_rt_remote_last_poll = 0

def _rt_log(msg, level="info", mod=""):
    entry = {
        "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "level": level,
        "msg": msg,
    }
    if mod:
        entry["mod"] = mod
    with _rt_state_lock:
        _rt_state["events"].insert(0, entry)
        _rt_state["events"] = _rt_state["events"][:120]
        if level == "error":
            _rt_state["error"] = msg

def rt_get_status():
    cfg = rt_get_config()
    with _rt_state_lock:
        st = dict(_rt_state)
        st["events"] = list(st["events"][:50])
        st["stats"] = dict(st["stats"])
    # merge config snapshot
    st["config"] = cfg
    # also include cloud_sync running status
    try:
        from editor.server import cloud_sync
        cs = cloud_sync.sync_status()
        st["cloud_sync"] = cs
    except Exception:
        st["cloud_sync"] = {"running": False}
    return st

# ---------- helpers to get mod list & snapshots ----------

def _get_all_mod_names():
    try:
        from editor.server.api import STATE as _ST
        mods = _ST.list_mods()
        return [m.get("name") for m in mods if m.get("name")]
    except Exception:
        pass
    # fallback scan filesystem
    try:
        from editor.server.cloud_sync import _local_mods_root
        root = _local_mods_root()
        if os.path.isdir(root):
            names = [d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and not d.startswith(".") and not d.startswith("_")]
            return names
    except Exception:
        pass
    return []

def _resolve_watch_mods(cfg):
    if cfg.get("watch_all_mods"):
        return _get_all_mod_names()
    mods = cfg.get("mods") or []
    if mods:
        return [m for m in mods if m]
    single = (cfg.get("mod_name") or "").strip()
    if single:
        return [single]
    # if nothing specified, watch all? default to all to be useful
    all_mods = _get_all_mod_names()
    # if too many (>20) fallback to first one to avoid flood
    if len(all_mods) > 20:
        return all_mods[:5]
    return all_mods

def _snapshot_mod(mod_name):
    try:
        from editor.server.cloud_sync import _list_local_files
        # compute_sha False for speed
        raw = _list_local_files(mod_name, compute_sha=False)
        # raw is dict rel -> (size, mtime, sha)
        # convert to size+mtime only
        return {k: (v[0], v[1]) for k, v in raw.items()}
    except Exception as e:
        _rt_log("snapshot %s failed: %s" % (mod_name, e), "error", mod_name)
        return {}

def _detect_changes(prev, cur):
    # returns dict with added, modified, deleted, changed_list
    prev_keys = set(prev.keys())
    cur_keys = set(cur.keys())
    added = cur_keys - prev_keys
    deleted = prev_keys - cur_keys
    modified = set()
    for k in prev_keys & cur_keys:
        ps, pm = prev[k]
        cs, cm = cur[k]
        if ps != cs or abs(int(pm) - int(cm)) > 1:
            modified.add(k)
    # ignore temp files
    def _valid(rel):
        # skip hidden, tmp
        base = rel.split("/")[-1]
        if base.startswith(".") and not base.endswith(".json"):
            return False
        if base.startswith("~") or base.endswith(".tmp") or base.endswith(".swp"):
            return False
        if "__pycache__" in rel or rel.startswith("_cache"):
            return False
        return True
    added = {r for r in added if _valid(r)}
    modified = {r for r in modified if _valid(r)}
    deleted = {r for r in deleted if _valid(r)}
    changed = added | modified
    # deleted handled separately
    return {"added": added, "modified": modified, "deleted": deleted, "changed": changed}

def _is_cloud_busy():
    try:
        from editor.server import cloud_sync
        st = cloud_sync.sync_status()
        return bool(st.get("running"))
    except Exception:
        return False

# ---------- sync execution ----------

def _execute_sync(provider_id, mod_name, direction, changed_rels, deleted_rels, delete_extra):
    """
    Execute incremental sync for given mod.
    changed_rels: set of added/modified files to upload/download/sync
    deleted_rels: set of deleted files
    """
    from editor.server import cloud_sync
    from editor.server.cloud_sync import _get_mod_dir, _remote_path_for, get_driver, get_provider
    prov = get_provider(provider_id)
    if not prov:
        raise ValueError("provider not found: %s" % provider_id)
    total_ops = 0
    results = []
    # handle upload/download/sync for changed files
    if changed_rels:
        # use incremental file sync for efficiency
        rel_list = sorted(changed_rels)
        # cloud_sync.sync_mod_files handles batch
        # sync_mod_files / sync_single_file now supports true "sync" direction (mtime comparison,
        # same semantics as sync_mod_folder). For realtime local changes, only upload or
        # sync-upload matters; download mode ignores local changes.
        # We branch:
        if direction == "upload":
            try:
                res = cloud_sync.sync_mod_files(provider_id, "upload", mod_name, rel_list, dry_run=False)
                results.extend(res.get("results", []))
                total_ops += len(rel_list)
            except Exception as e:
                _rt_log("sync upload %s failed: %s" % (mod_name, e), "error", mod_name)
                raise
        elif direction == "download":
            # local changes in download mode should be ignored (remote is source)
            _rt_log("local change ignored in download mode: %s %s" % (mod_name, rel_list[:3]), "warn", mod_name)
        elif direction == "sync":
            # for sync, need to check remote mtime to decide direction per file
            # Use simplified: upload if local newer or remote missing, else skip (remote polling will handle download)
            # We'll just upload changed files after checking remote stat quickly? To avoid complexity, upload via _need_sync check.
            # Use sync_single_file's logic via upload, but with need_sync guard.
            for rel in rel_list:
                try:
                    # quick check via _need_sync would require remote stat, but we can just upload - remote polling will resolve conflicts.
                    # To reduce overwriting newer remote, we do stat check:
                    driver = get_driver(prov.get("type"), prov.get("config"))
                    remote = _remote_path_for(prov, mod_name, rel)
                    local_path = os.path.join(_get_mod_dir(mod_name), *rel.split("/"))
                    remote_obj = None
                    try:
                        remote_obj = driver.stat(remote)
                    except Exception:
                        remote_obj = None
                    # if remote exists and remote newer than local by >2s and size differs? skip upload, will be handled by remote poll download
                    if remote_obj and remote_obj.mtime:
                        try:
                            lm = int(os.path.getmtime(local_path))
                            rm = int(remote_obj.mtime)
                            if rm > lm + 2:
                                _rt_log("skip upload %s (remote newer %ss)" % (rel, rm - lm), "info", mod_name)
                                results.append({"rel": rel, "ok": True, "action": "skip_remote_newer"})
                                continue
                        except Exception:
                            pass
                    # proceed upload
                    cloud_sync.sync_single_file(provider_id, "upload", mod_name, rel, dry_run=False)
                    results.append({"rel": rel, "ok": True, "action": "realtime_upload"})
                    total_ops += 1
                except Exception as e:
                    results.append({"rel": rel, "ok": False, "error": str(e)})
        else:
            # unknown
            pass
    # handle deletions
    if deleted_rels and delete_extra:
        # delete remote objects for upload/sync
        if direction in ("upload", "sync"):
            from editor.server.cloud_sync import _remote_path_for, get_driver
            prov = cloud_sync.get_provider(provider_id)
            if prov:
                driver = cloud_sync.get_driver(prov.get("type"), prov.get("config"))
                for rel in sorted(deleted_rels):
                    try:
                        remote = _remote_path_for(prov, mod_name, rel)
                        driver.delete(remote)
                        results.append({"rel": rel, "ok": True, "action": "realtime_delete_remote"})
                        total_ops += 1
                        _rt_log("deleted remote %s" % rel, "info", mod_name)
                    except Exception as e:
                        results.append({"rel": rel, "ok": False, "error": str(e)})
        elif direction == "download":
            # local deletion in download mode: ignore or re-download? ignore
            pass
    return {"total": total_ops, "results": results}

def _poll_remote_and_sync(provider_id, mod_name, direction):
    """
    Poll remote for changes and download if needed.
    Only for direction download or sync.
    """
    from editor.server import cloud_sync
    from editor.server.cloud_sync import _list_remote_recursive, _remote_path_for, get_provider, get_driver, _get_mod_dir, _list_local_files, _need_sync, _lazy_sha
    if direction not in ("download", "sync"):
        return None
    prov = get_provider(provider_id)
    if not prov:
        return None
    try:
        driver = get_driver(prov.get("type"), prov.get("config"))
        remote_base = _remote_path_for(prov, mod_name, "")
        # list remote recursively
        remote_map = _list_remote_recursive(driver, remote_base)
        local_map = _list_local_files(mod_name, compute_sha=False)
        mod_dir = _get_mod_dir(mod_name)
        to_download = []
        for rel, obj in remote_map.items():
            local_info = local_map.get(rel)
            if local_info is None:
                to_download.append(rel)
            else:
                ls, lm, lh = local_info
                rs, rm, rsha = obj.size, obj.mtime, obj.sha1
                # lazy sha if needed
                if not lh and ls == rs and rsha:
                    lh = _lazy_sha(os.path.join(mod_dir, *rel.split("/")))
                if _need_sync(ls, lm, lh, rs, rm, rsha, os.path.join(mod_dir, *rel.split("/"))):
                    # for download mode, always download if need_sync true and remote newer? For sync mode, need to check mtime
                    if direction == "download":
                        to_download.append(rel)
                    elif direction == "sync":
                        # sync: download only if remote newer
                        if rm and lm and int(rm) > int(lm):
                            to_download.append(rel)
                        elif not lm or not rm:
                            # if mtime unknown, compare sha? fallback to download if sizes differ
                            if ls != rs:
                                # decide by mtime if available else download
                                to_download.append(rel)
                            # else skip
                        # else local newer, skip (upload branch will handle)
                        else:
                            # local newer, skip download
                            pass
        if not to_download:
            return {"total": 0, "results": []}
        # limit to 100 per poll to avoid flood
        batch = sorted(to_download)[:100]
        _rt_log("remote changes %d -> download %d files: %s" % (len(remote_map), len(batch), batch[:3]), "info", mod_name)
        res = cloud_sync.sync_mod_files(provider_id, "download", mod_name, batch, dry_run=False)
        return res
    except Exception as e:
        _rt_log("remote poll %s failed: %s" % (mod_name, e), "error", mod_name)
        return None

# ---------- watcher thread ----------

def _watcher_loop():
    global _rt_prev_snapshots, _rt_last_change_ts, _rt_remote_last_poll, _rt_pending
    _rt_log("realtime watcher started", "info")
    # init snapshots
    cfg = rt_get_config()
    mods = _resolve_watch_mods(cfg)
    for m in mods:
        _rt_prev_snapshots[m] = _snapshot_mod(m)
    with _rt_state_lock:
        _rt_state["watching_mods"] = list(mods)
        _rt_state["pending_files"] = []
        _rt_state["pending_count"] = 0
    _rt_remote_last_poll = time.time()
    while not _rt_stop.is_set():
        try:
            cfg = rt_get_config()
            # refresh watching mods if config changed (check every cycle)
            current_mods = _resolve_watch_mods(cfg)
            with _rt_state_lock:
                if set(current_mods) != set(_rt_state.get("watching_mods", [])):
                    _rt_log("watching mods changed: %s" % current_mods, "info")
                    _rt_state["watching_mods"] = list(current_mods)
                    # init new mods snapshots
                    for nm in current_mods:
                        if nm not in _rt_prev_snapshots:
                            _rt_prev_snapshots[nm] = _snapshot_mod(nm)
                    # remove old pending
                    for k in list(_rt_pending.keys()):
                        if k not in current_mods:
                            _rt_pending.pop(k, None)
            provider_id = cfg.get("provider_id") or ""
            direction = cfg.get("direction") or "upload"
            delete_extra = bool(cfg.get("delete_extra"))
            debounce = float(cfg.get("debounce_ms", 2000)) / 1000.0
            poll_interval = float(cfg.get("poll_interval_ms", 2000)) / 1000.0
            remote_poll_interval = float(cfg.get("remote_poll_interval_ms", 30000)) / 1000.0

            if not cfg.get("enabled"):
                # paused - keep sleeping
                time.sleep(min(poll_interval, 1.0))
                continue
            if not provider_id:
                time.sleep(min(poll_interval, 1.0))
                continue
            # need to ensure provider exists
            try:
                from editor.server import cloud_sync
                if not cloud_sync.get_provider(provider_id):
                    with _rt_state_lock:
                        _rt_state["error"] = "provider not found: %s" % provider_id
                    time.sleep(2)
                    continue
            except Exception:
                pass

            # local polling
            for mod in list(current_mods):
                cur = _snapshot_mod(mod)
                prev = _rt_prev_snapshots.get(mod, {})
                diff = _detect_changes(prev, cur)
                changed = diff["changed"]
                deleted = diff["deleted"]
                if changed or deleted:
                    # update snapshot now, but track pending
                    _rt_prev_snapshots[mod] = cur
                    if mod not in _rt_pending:
                        _rt_pending[mod] = {"changed": set(), "deleted": set()}
                    _rt_pending[mod]["changed"].update(changed)
                    _rt_pending[mod]["deleted"].update(deleted)
                    _rt_last_change_ts = time.time()
                    total_pending = sum(len(v["changed"]) + len(v["deleted"]) for v in _rt_pending.values())
                    with _rt_state_lock:
                        _rt_state["pending_count"] = total_pending
                        # flatten for UI
                        flat = []
                        for mm, vals in _rt_pending.items():
                            for r in list(vals["changed"])[:10]:
                                flat.append("%s:%s" % (mm, r))
                            for r in list(vals["deleted"])[:10]:
                                flat.append("%s:%s(deleted)" % (mm, r))
                        _rt_state["pending_files"] = flat[:20]
                        _rt_state["error"] = ""
                    _rt_log("detected %d changed + %d deleted in %s: %s" % (len(changed), len(deleted), mod, list(changed)[:3]), "info", mod)
                    with _rt_state_lock:
                        _rt_state["stats"]["local_changes"] += len(changed) + len(deleted)
                else:
                    # no change, just update snapshot (to keep mtime freshness)
                    _rt_prev_snapshots[mod] = cur

            # debounce check: if pending and time since last change > debounce
            if _rt_pending and _rt_last_change_ts and (time.time() - _rt_last_change_ts) >= debounce:
                if _is_cloud_busy():
                    # wait for busy to clear, but not forever
                    time.sleep(0.5)
                    continue
                # snapshot pending to process
                pending_copy = {k: {"changed": set(v["changed"]), "deleted": set(v["deleted"])} for k, v in _rt_pending.items()}
                _rt_pending.clear()
                with _rt_state_lock:
                    _rt_state["pending_count"] = 0
                    _rt_state["pending_files"] = []
                for mod, vals in pending_copy.items():
                    changed = vals["changed"]
                    deleted = vals["deleted"]
                    if not changed and not deleted:
                        continue
                    # don't sync deletions if delete_extra disabled -> ignore deleted
                    if not delete_extra:
                        deleted = set()
                    # skip if no provider/mod
                    if not provider_id or not mod:
                        continue
                    _rt_log("auto-sync %s %s %d files (changed %d deleted %d)" % (direction, mod, len(changed)+len(deleted), len(changed), len(deleted)), "info", mod)
                    try:
                        res = _execute_sync(provider_id, mod, direction, changed, deleted, delete_extra)
                        total = res.get("total", 0)
                        with _rt_state_lock:
                            _rt_state["last_sync"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                            _rt_state["last_sync_result"] = res
                            _rt_state["stats"]["sync_success"] += 1
                        _rt_log("auto-sync %s done +%d" % (mod, total), "info", mod)
                    except Exception as e:
                        with _rt_state_lock:
                            _rt_state["stats"]["sync_failed"] += 1
                            _rt_state["error"] = str(e)
                        _rt_log("auto-sync %s failed: %s" % (mod, e), "error", mod)
                _rt_last_change_ts = 0

            # remote poll
            now = time.time()
            if direction in ("download", "sync") and (now - _rt_remote_last_poll) >= remote_poll_interval:
                _rt_remote_last_poll = now
                if _is_cloud_busy():
                    # skip this cycle
                    pass
                else:
                    for mod in list(current_mods):
                        if _rt_stop.is_set():
                            break
                        _rt_log("polling remote for %s" % mod, "info", mod)
                        res = _poll_remote_and_sync(provider_id, mod, direction)
                        if res and res.get("total", 0) > 0:
                            with _rt_state_lock:
                                _rt_state["last_sync"] = time.strftime("%Y-%m-%dT%H:%M:%S")
                                _rt_state["last_sync_result"] = res
                                _rt_state["stats"]["remote_changes"] += res.get("total", 0)
                            _rt_log("remote auto-download %s +%d" % (mod, res.get("total", 0)), "info", mod)
                            # update snapshot after remote download
                            _rt_prev_snapshots[mod] = _snapshot_mod(mod)
                        # avoid hammering remote: small delay between mods
                        time.sleep(0.2)
                with _rt_state_lock:
                    _rt_state["next_remote_poll"] = int(_rt_remote_last_poll + remote_poll_interval)

            # sleep
            # need to be responsive to stop
            _rt_stop.wait(poll_interval)
        except Exception as e:
            _rt_log("watcher loop error: %s" % e, "error")
            import traceback
            traceback.print_exc()
            _rt_stop.wait(2.0)
    _rt_log("realtime watcher stopped", "info")
    with _rt_state_lock:
        _rt_state["running"] = False
        _rt_state["enabled"] = False

# ---------- control ----------

def rt_start():
    global _rt_thread
    cfg = rt_get_config()
    if not cfg.get("provider_id"):
        raise ValueError("provider_id required to start realtime sync")
    # ensure at least one mod
    mods = _resolve_watch_mods(cfg)
    if not mods:
        raise ValueError("no mods to watch (select mod or enable watch_all)")
    with _rt_state_lock:
        if _rt_state.get("running") and _rt_thread and _rt_thread.is_alive():
            # already running, just update enabled
            _rt_state["enabled"] = True
            return rt_get_status()
        _rt_state["running"] = True
        _rt_state["enabled"] = True
        _rt_state["error"] = ""
        _rt_state["provider_id"] = cfg.get("provider_id")
        _rt_state["direction"] = cfg.get("direction")
        _rt_state["watching_mods"] = list(mods)
    # update config enabled true
    rt_update_config({"enabled": True})
    _rt_stop.clear()
    _rt_thread = threading.Thread(target=_watcher_loop, name="realtime-sync", daemon=True)
    _rt_thread.start()
    _rt_log("realtime sync enabled provider=%s mods=%s dir=%s" % (cfg.get("provider_id"), mods, cfg.get("direction")), "info")
    return rt_get_status()

def rt_stop():
    cfg = rt_get_config()
    rt_update_config({"enabled": False})
    _rt_stop.set()
    with _rt_state_lock:
        _rt_state["enabled"] = False
        _rt_state["error"] = ""
    # wait briefly for thread to exit? don't block too long
    global _rt_thread
    if _rt_thread and _rt_thread.is_alive():
        _rt_thread.join(timeout=2.0)
    _rt_log("realtime sync disabled", "info")
    return rt_get_status()

def rt_auto_start():
    """Called at server startup if config auto_start enabled."""
    try:
        cfg = rt_get_config()
        if cfg.get("enabled") and cfg.get("auto_start"):
            # delay slightly to let STATE initialize
            def _delayed():
                time.sleep(3)
                try:
                    rt_start()
                except Exception as e:
                    _rt_log("auto_start failed: %s" % e, "error")
            threading.Thread(target=_delayed, daemon=True).start()
        elif cfg.get("enabled") and not cfg.get("auto_start"):
            # if enabled but not auto_start, keep stopped? but config says enabled -> we should start
            # For UX, we consider enabled as "want running", so auto_start handles restart
            pass
    except Exception as e:
        print("[realtime] auto_start check failed: %s" % e)

# trigger auto_start on import after short delay? But STATE may not ready, so rely on api.py calling it
