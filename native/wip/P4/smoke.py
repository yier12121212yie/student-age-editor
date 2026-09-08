# -*- coding: utf-8 -*-
"""P4 golden diff smoke: boots backend_wip in an isolated temp editor root
(steam detection off, no artifacts, no .editor_ai.json) and compares four
endpoints against the recorded goldens:

    api_tts_settings / api_aa_status / api_base_status / api_base_events

This is the "no artifacts / steam off" empty-degradation contract. Usage:

    python native/wip/P4/smoke.py [path\\to\\backend_wip.exe]

Exit 0 == all four PASS.
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
NATIVE = os.path.abspath(os.path.join(HERE, "..", ".."))
GOLDEN_DIR = os.path.join(NATIVE, "tests", "contract", "golden")
CONTRACT_DIR = os.path.join(NATIVE, "tests", "contract")
sys.path.insert(0, CONTRACT_DIR)
import normalize  # noqa: E402  (project comparator: normalize + compare)

# (golden slug, method, endpoint path, request body or None)
CASES = [
    ("api_tts_settings", "GET", "/api/tts/settings", None),
    ("api_aa_status", "GET", "/api/aa/status", None),
    ("api_base_status", "GET", "/api/base/status", None),
    ("api_base_events", "GET", "/api/base/events", None),
]


def _find_backend():
    if len(sys.argv) > 1:
        return sys.argv[1]
    cand = os.path.join(NATIVE, "build-P4", "bin", "backend_wip.exe")
    if os.path.isfile(cand):
        return cand
    cand = os.path.join(NATIVE, "build", "bin", "backend_wip.exe")
    return cand


def _http(port, method, path, body=None, timeout=8):
    url = "http://127.0.0.1:%d%s" % (port, path)
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}


def main():
    backend = _find_backend()
    if not os.path.isfile(backend):
        print("ERROR: backend_wip not found at %s" % backend)
        return 2

    root = tempfile.mkdtemp(prefix="p4_smoke_")
    ws = os.path.join(root, "ws")
    os.makedirs(ws, exist_ok=True)
    # editor_env.json present (empty) so /api/base/status reports env_exists=true,
    # matching the golden recorder's isolated data root.
    with open(os.path.join(root, "editor_env.json"), "w", encoding="utf-8") as f:
        json.dump({"workspace_root": ws}, f, ensure_ascii=False)

    port_file = os.path.join(root, "port")
    env = dict(os.environ)
    env["EDITOR_DATA_ROOT"] = root
    env["EDITOR_DISABLE_STEAM_DETECT"] = "1"
    env.pop("EDITOR_BASE_ARTIFACT_DIR", None)
    env.pop("EDITOR_DECODED_PACK_DIR", None)
    env.pop("EDITOR_UPDATE_URL", None)

    proc = subprocess.Popen(
        [backend, "--port", "0", "--write-port", port_file, "--workspace-root", ws],
        cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        port = _wait_port(port_file, proc)
        if port is None:
            print("ERROR: backend did not become ready")
            return 2
        ok_all = True
        for slug, method, path, body in CASES:
            status, payload = _http(port, method, path, body)
            with open(os.path.join(GOLDEN_DIR, slug + ".json"), encoding="utf-8") as f:
                golden = json.load(f)
            exp_status = golden.get("status")
            ok = (status == exp_status)
            if ok:
                e_norm = normalize.normalize(golden.get("response"))
                a_norm = normalize.normalize(payload)
                same, diffs = normalize.compare(e_norm, a_norm)
                ok = same
                if not same:
                    print("  diff %s: %s" % (slug, diffs[:3]))
            print("%-22s %s (status %s, expected %s)" %
                  (slug, "PASS" if ok else "FAIL", status, exp_status))
            ok_all = ok_all and ok
        # Best-effort shutdown.
        try:
            _http(port, "POST", "/api/shutdown", {})
        except Exception:
            pass
        print("RESULT:", "PASS (%d/%d)" % (len(CASES), len(CASES)) if ok_all else "FAIL")
        return 0 if ok_all else 1
    finally:
        time.sleep(0.2)
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


def _wait_port(port_file, proc, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            return None
        if os.path.isfile(port_file):
            try:
                with open(port_file) as f:
                    p = int(f.read().strip())
                if p > 0:
                    # Confirm /api/ping answers.
                    for _ in range(50):
                        try:
                            _http(p, "GET", "/api/ping", timeout=1)
                            return p
                        except Exception:
                            time.sleep(0.1)
                    return p
            except ValueError:
                pass
        time.sleep(0.1)
    return None


if __name__ == "__main__":
    sys.exit(main())
