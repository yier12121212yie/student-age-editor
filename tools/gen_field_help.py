#!/usr/bin/env python3
"""从参考资料生成字段帮助文本数据。

数据源：参考资料中的第三方工坊编辑器 schema（catalog-schema.json）
（同款游戏的第三方工坊编辑器 schema，`description` 即官方口径的字段说明）。

产物：`frontend/lib/features/editor/field_help_data.dart`
  * `kFieldCfgLabels`   —— 配置表中文名（用于引用字段的说明里点名目标表）
  * `kFieldDescriptions` —— cfg → key → 说明（仅收录非空项）

其余字段由 `field_meta.dart` 里的「友好描述 → 跨表键描述 → 类型兜底」
补齐，因此本文件只放权威、手写成本高的条目。

用法：python tools/gen_field_help.py
"""

from __future__ import annotations

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(
    ROOT, "参考资料", "友商产品#2", "standalone", "catalog-schema.json"
)
OUT = os.path.join(
    ROOT, "frontend", "lib", "features", "editor", "field_help_data.dart"
)


def dart_str(s: str) -> str:
    """转成 Dart 单引号字符串字面量（含转义）。"""
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "'":
            out.append("\\'")
        elif ch == "$":
            out.append("\\$")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            continue
        else:
            out.append(ch)
    return "".join(out).strip()


def main() -> int:
    with open(SRC, encoding="utf-8") as fh:
        schemas = json.load(fh)["schemas"]

    labels = []
    for cfg, spec in schemas.items():
        label = (spec.get("label") or "").strip()
        if label:
            labels.append((cfg, label))

    descs = []
    for cfg, spec in schemas.items():
        rows = []
        for field in spec.get("fields", []):
            desc = (field.get("description") or "").strip()
            if desc:
                rows.append((field["name"], desc))
        if rows:
            descs.append((cfg, rows))

    lines = [
        "// GENERATED FILE - DO NOT EDIT BY HAND.",
        "// 由 tools/gen_field_help.py 从",
        "// 参考资料中的第三方工坊编辑器 schema 生成。",
        "//",
        "// 同款游戏第三方工坊编辑器的 schema，其 description 为字段的权威说明；",
        "// 只收录非空项，其余交给 field_meta.dart 的规则/类型兜底。",
        "library;",
        "",
        "/// 配置表中文名：引用类字段的说明用它在文案里点名目标表。",
        "const kFieldCfgLabels = <String, String>{",
    ]
    for cfg, label in labels:
        lines.append(f"  '{cfg}': '{dart_str(label)}',")
    lines.append("};")
    lines.append("")
    lines.append("/// 字段级帮助文本（cfg → key → 说明），优先于跨表键描述与类型兜底。")
    lines.append("const kFieldDescriptions = <String, Map<String, String>>{")
    for cfg, rows in descs:
        lines.append(f"  '{cfg}': {{")
        for name, desc in rows:
            lines.append(f"    '{name}': '{dart_str(desc)}',")
        lines.append("  },")
    lines.append("};")
    lines.append("")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))

    n_desc = sum(len(r) for _, r in descs)
    print(f"wrote {OUT}")
    print(f"  cfg labels: {len(labels)}")
    print(f"  descriptions: {n_desc} across {len(descs)} tables")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
