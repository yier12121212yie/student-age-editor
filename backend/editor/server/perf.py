"""Performance counters for monitoring big table read/write paths.

Process-wide counters that track:
- cfg.reads / cfg.read_bytes / cfg.parses / cfg.dumps
- cfg.writes / cfg.write_bytes / cfg.snapshot_bytes / cfg.snapshots_written

Thread-safe for ThreadingHTTPServer worker threads. NOT using thread-local:
handler runs in ThreadingHTTPServer worker thread; test threads can't access
them. One socket round-trip is a sync point. In concurrent load testing only
allow asserting >=.

Production side only bumps at "once per request", NEVER inside the 98,963 row
loop (otherwise we're measuring self-benchmarks).

Usage pattern (both assert):
    from editor.server.perf import COUNTERS

    @app.route("/api/cfg/TalkCfg")
    def cfg_read(...):
        with COUNTERS.lock:
            COUNTERS.bump("cfg.reads")
            COUNTERS.bump("cfg.read_bytes", len(raw))
        ...
"""

import threading
from collections import defaultdict
from typing import Optional


class Counters:
    """Process-wide performance counter registry."""

    def __init__(self):
        self._lock = threading.Lock()
        self._counters: dict[str, int] = defaultdict(int)
        # Windowed sums for recent N requests (not implemented yet, just totals)
        self._window: list[tuple[float, str, int]] = []
        self._window_size = 100  # number of samples to keep

    def bump(self, key: str, amount: int = 1) -> None:
        """Increment a counter by amount."""
        with self._lock:
            self._counters[key] += amount
            ts = threading.get_time() if hasattr(threading, "get_time") else __import__("time").time()
            self._window.append((ts, key, amount))
            if len(self._window) > self._window_size:
                self._window.pop(0)

    def add(self, key: str, amount: int) -> None:
        """Add amount to a counter (same as bump, but explicit)."""
        self.bump(key, amount)

    def get(self, key: str) -> int:
        """Get current value of a counter."""
        with self._lock:
            return self._counters.get(key, 0)

    def reset(self, key: Optional[str] = None) -> None:
        """Reset a specific counter or all counters (including window)."""
        with self._lock:
            if key:
                self._counters[key] = 0
                # Also clear window entries for this key
                self._window = [(ts, k, amt) for ts, k, amt in self._window if k != key]
            else:
                self._counters.clear()
                self._window.clear()

    def window_sum(self, key: str) -> int:
        """Get sum of last N samples for a key."""
        with self._lock:
            now = threading.get_time() if hasattr(threading, "get_time") else __import__("time").time()
            cutoff = now - 60  # last 60 seconds
            return sum(amount for ts, k, amount in self._window if k == key and ts > cutoff)

    def get_all(self) -> dict[str, int]:
        """Get snapshot of all counters."""
        with self._lock:
            return dict(self._counters)

    def __repr__(self) -> str:
        with self._lock:
            return f"Counters({dict(self._counters)})"


# Module-level singleton
COUNTERS = Counters()

# Legacy function-style API for backward compatibility (deprecated)
def bump(name, n=1):
    COUNTERS.bump(name, n)

def add(name, n):
    COUNTERS.add(name, n)

def get(name):
    return COUNTERS.get(name)

def reset():
    COUNTERS.reset()

def window_sum(name):
    return COUNTERS.window_sum(name)

def get_all():
    return COUNTERS.get_all()

# Legacy constant names for backward compatibility
class _LegacyConstants:
    CFG_READS = "cfg.reads"
    CFG_READ_BYTES = "cfg.read_bytes"
    CFG_PARSES = "cfg.parses"
    CFG_DUMPS = "cfg.dumps"
    CFG_WRITES = "cfg.writes"
    CFG_WRITE_BYTES = "cfg.write_bytes"
    CFG_SNAPSHOT_BYTES = "cfg.snapshot_bytes"
    CFG_SNAPSHOTS_WRITTEN = "cfg.snapshots_written"

LegacyConstants = _LegacyConstants()

# Alias for testing - provides LC class with same constants
class LC(_LegacyConstants):
    """Legacy constant aliases for backward compatibility in tests."""
    pass

LC = LC()
