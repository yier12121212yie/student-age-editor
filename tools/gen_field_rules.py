#!/usr/bin/env python3
"""从参考资料生成字段引用目标数据（无代码模式的「只选不敲」依据）。

数据源：`参考资料/友商产品#2/standalone/catalog-schema.json`
（同款游戏的第三方工坊编辑器 schema，字段的 `range.table` 即该字段值引用的
目标配置表；`editorType` 为 Effect/Condition 的字段是效果/条件码）。

产物：`frontend/lib/features/editor/field_ref_data.dart`
  * `kFieldRefTargets` —— `cfg:key` → 目标配置表名（该字段的值是目标表记录 ID）。
    无代码模式下据它把字段判为 `reference`（只选不敲），与手写的
    `kRuleByCfgField` / `kRuleByField` 是「显式优先、生成兜底」的关系。

用法：python tools/gen_field_rules.py
"""

from __future__ import annotations

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(
    ROOT, "参考资料", "友商产品#2", "standalone", "catalog-schema.json"
)
APP_SCHEMA = os.path.join(ROOT, "native", "assets", "schema.json")
OUT = os.path.join(
    ROOT, "frontend", "lib", "features", "editor", "field_ref_data.dart"
)


def dart_str(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "'":
            out.append("\\'")
        elif ch == "$":
            out.append("\\$")
        else:
            out.append(ch)
    return "".join(out).strip()


def main() -> int:
    with open(SRC, encoding="utf-8") as fh:
        schemas = json.load(fh)["schemas"]
    with open(APP_SCHEMA, encoding="utf-8") as fh:
        app_schema = json.load(fh)

    rows = []
    for cfg in sorted(schemas):
        if cfg not in app_schema:
            continue  # 编辑器没有这张表，规则无落点
        app_fields = app_schema[cfg] if isinstance(app_schema[cfg], dict) else {}
        for field in schemas[cfg].get("fields", []):
            rng = field.get("range") or {}
            table = (rng.get("table") or "").strip()
            # 复合目标（如 "ItemCfg / BookCfg"）不是单表引用，交给手写规则兜底。
            if not table or "/" in table or table not in app_schema:
                continue
            key = field["name"]
            if key == "id":
                continue  # 主键：只读，不是「可挑选的引用」
            if key not in app_fields:
                continue  # schema 没有该字段（第三方多出的列），不写规则
            rows.append((cfg, key, table))

    # 去重 + 稳定排序，保证生成结果可复现。
    seen = set()
    uniq = []
    for cfg, key, table in rows:
        ident = f"{cfg}:{key}"
        if ident in seen:
            continue
        seen.add(ident)
        uniq.append((ident, table))
    uniq.sort()

    lines = [
        "// GENERATED FILE - DO NOT EDIT BY HAND.",
        "// 由 tools/gen_field_rules.py 从",
        "// 参考资料/友商产品#2/standalone/catalog-schema.json 生成。",
        "//",
        "// 同款游戏第三方工坊编辑器 schema 的 `range.table`：字段值是目标配置表",
        "// 记录的 ID。无代码模式据此把这类字段判为「只选不敲」的 reference。",
        "library;",
        "",
        "/// `cfg:key` → 目标配置表名（值是该表记录 ID）。",
        "/// 手写的 kRuleByCfgField / kRuleByField 优先，本表只做兜底。",
        "const kFieldRefTargets = <String, String>{",
    ]
    for ident, table in uniq:
        lines.append(f"  '{dart_str(ident)}': '{dart_str(table)}',")
    lines.append("};")
    lines.append("")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))

    print(f"wrote {OUT}")
    print(f"  reference targets: {len(uniq)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
