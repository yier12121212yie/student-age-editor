"""Benchmark data generator for performance testing.

Generates ~40MB synthetic TalkCfg-like data using string join (NOT json.dumps)
to avoid polluting timing measurements with 2.34s json.dumps cost.

Module-level _TEXT_CACHE + TMP_ROOT = mkdtemp() + atexit cleanup.
DO NOT use tearDownModule - we need it alive for cross-file reuse.

Each row padded to ~400B to reach ~40MB total volume.
One-time cost ≈0.4s.

Usage:
    from editor.server.benchdata import generate_synthetic_talk_cfg, TMP_ROOT
    
    # Get text content (~40MB)
    text = generate_synthetic_talk_cfg()
    
    # Files are stored in TMP_ROOT and cleaned up on exit
"""

import atexit
import os
from tempfile import mkdtemp

# Module-level cache - DO NOT clear in tearDownModule
_TEXT_CACHE: str | None = None
TMP_ROOT = mkdtemp(prefix="benchdata_")

# TalkCfg stats from still-stone-stickleback.md
# 98,963 rows, 40,258,490 bytes (~40MB), LF line endings, no BOM
NUM_ROWS = 98963
TARGET_SIZE = 40_258_490  # ~40MB

# 单行字节预算：(TARGET - header/footer - 行间 ",\n") / NUM_ROWS ≈ 405B
_ROW_TARGET_BYTES = 405


def _generate_row(row_id: int) -> str:
    """Generate a single TalkCfg row padded to ~405 bytes (UTF-8)."""
    key = str(row_id)
    label = f'"{key}": '
    prefix = f'{{"id": "{key}", "content": "'
    suffix = (f'", "person": "P{row_id % 1000:03d}", "bg": "BG{row_id % 100:02d}",'
              f' "audio": "SE_{row_id % 500:03d}", "evt_type": 1}}')
    base_content = (f"这是一个测试对白第{row_id}行的内容，用于模拟真实的"
                    "TalkCfg 数据结构。每一行都应该有足够的长度来模拟实际使用场景中的文本长度。")
    budget = (_ROW_TARGET_BYTES - len(label.encode("utf-8"))
              - len(prefix.encode("utf-8")) - len(suffix.encode("utf-8")))
    content = base_content
    deficit = budget - len(content.encode("utf-8"))
    if deficit > 0:
        # 按字节补齐：ASCII 'x' 填充保证行长稳定落在预算上
        content += "x" * deficit
    elif deficit < 0:
        # 中文按字节截断会撕裂字符：按字符收缩后再补齐到预算
        while len(content.encode("utf-8")) > budget:
            content = content[:-1]
        content += "x" * (budget - len(content.encode("utf-8")))
    # TalkCfg.json 是 {"1000": {...}, ...} 键控形态：行片段自带键名
    return label + prefix + content + suffix


def _join_rows(rows: list[str]) -> str:
    """Join rows into a complete JSON object like TalkCfg.json."""
    header = "{\n"
    footer = "\n}"
    # Use ",\n" as separator for LF line endings
    separator = ",\n"

    return header + separator.join(rows) + footer


def generate_synthetic_talk_cfg() -> str:
    """Generate synthetic TalkCfg data (~40MB, 98,963 rows).
    
    Returns:
        Complete JSON text matching TalkCfg.json size/structure.
        Uses string join, NOT json.dumps (which costs 2.34s).
        
    Side effects:
        Caches result in module-level _TEXT_CACHE.
        Creates temporary files in TMP_ROOT for cross-file reuse.
    """
    global _TEXT_CACHE
    
    if _TEXT_CACHE is not None:
        return _TEXT_CACHE
    
    # Generate all rows (one-time cost ≈0.4s)
    rows = [_generate_row(i) for i in range(NUM_ROWS)]
    
    # Join into complete JSON object
    _TEXT_CACHE = _join_rows(rows)
    
    # Verify target size (allow ±5% tolerance)
    actual_size = len(_TEXT_CACHE.encode("utf-8"))
    tolerance = TARGET_SIZE * 0.05
    if abs(actual_size - TARGET_SIZE) > tolerance:
        raise RuntimeError(
            f"Generated {actual_size:,} bytes, expected ~{TARGET_SIZE:,} "
            f"(±{tolerance:,.0f})"
        )
    
    # Write to disk for cross-file reuse
    fp = os.path.join(TMP_ROOT, "TalkCfg.json")
    with open(fp, "w", encoding="utf-8", newline="\n") as f:
        f.write(_TEXT_CACHE)
    
    return _TEXT_CACHE


def get_text_cache() -> str | None:
    """Get current cached text (for testing without regenerating)."""
    return _TEXT_CACHE


def clear_cache():
    """Clear module cache (for testing only)."""
    global _TEXT_CACHE
    _TEXT_CACHE = None


def cleanup_tmp_root():
    """Clean up temporary directory (called by atexit)."""
    try:
        import shutil
        if os.path.exists(TMP_ROOT):
            shutil.rmtree(TMP_ROOT)
    except Exception:
        pass  # Ignore cleanup errors on shutdown


# Register cleanup on exit
atexit.register(cleanup_tmp_root)
