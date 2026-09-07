# -*- coding: utf-8 -*-
"""resource_scan：Unity 资源解析命令行工具（C++ 后端重写的构建期剥离产物）。

子命令：
  index        扫描 Addressables bundle，产出 aa_index.json（v3 逐字段兼容
               backend/_cache/aa_index/aa_index.json）+ keys.json。
  base-tables  原版配置表（TextAsset / 解包 Cfgs 目录）导出为
               base_data/<Table>.json + base_meta.json，替代 pickle base_data.pkl。
  decoded-pack 薄封装透传 packaging/export_decoded_pack.py（预解码资源包）。

零 editor 包依赖：所需常量/函数均自 backend 复制（注明来源文件），
波次 4 删除 backend 原件后本工具须独立存活。
产物格式契约见同目录 ARTIFACT_FORMAT.md。
"""

TOOL_VERSION = "1.0.0"
