# 条件 / 效果积木库（导演布局的专属功能界面 + 无代码模式新入口）

第 2 批（内容编排）的第一个功能。它既是一个**导演专属工作台**，也是原有
**「无代码模式」条件 / 效果编辑机制的替代品**。

- 专属工作台：`frontend/lib/features/blocks/blocks_workbench.dart`
  （导演功能 `_DirectorFeature.blocks`，主页「积木库」卡片进入）。
- 共享组件与引擎：
  - `frontend/lib/features/blocks/block_catalog.dart` —— 类别 / 分类 / 取数；
  - `frontend/lib/features/blocks/block_library.dart` —— 目录栏、已添加清单、积木库弹窗。
- 字段内入口：`frontend/lib/features/nocode/nocode_effect_field.dart`
  新增「打开积木库」按钮。

## 「积木」是什么

一行指令代码（如 `[1, 1, 3, 5]`）即一条积木。行模型、文本解析与序列化**单点复用**
`features/nocode/effect_block_editor.dart` 的 `EffectBlockRow` /
`parseEffectText` / `serializeBlockRows`，所以「目录拼出来的代码」与「字段里内联编辑的代码」
永远一致。

## 工作台布局（三栏）

| 栏 | 内容 |
| --- | --- |
| 左（300–350） | 模式标签（条件 / 效果 / 指令 / 消耗 / 屏幕效果）+ 搜索 + 分类胶囊 + 分页目录 |
| 中（自适应） | 构建清单：可编辑积木行 + 输出代码（可复制 / 清空） |
| 右（≥1040 显示） | 说明栏：功能定位、当前类别、执行语义、小贴士 |

## 目录（对标成熟方案的目录栏）

- **模式标签**：对应 `/api/effect_suggest` 的 `mode`：
  `condition / effect / action / cost / screen`。
- **分类**：按代码首元素查游戏自带 `ConditionTypeCfg` / `EffectTypeCfg`
  的中文类型名（表缺失时用内置名兜底，见 `block_catalog.dart` 的
  `kConditionTypeNames` / `kEffectTypeNames`）。
- **搜索**：走 `/api/effect_suggest?q=`（后端打分 + 最近使用置顶）。
- **分页**：每页 24 条。
- **自定义**：直接输入逗号分隔的原始参数，成一条无模板积木。

## 构建清单（已添加）

- 顶部实时显示「已添加 N 条 + 中文摘要」。
- 每行：中文人话（`template.desc` 代入槽值 + 字典名称）、原始代码小字、异常红标、取反徽章。
- 行操作：点卡体编辑参数（字典槽 → 「ID · 名称」下拉）、取反、上移 / 下移、复制、删除。
- 无模板行（自定义 / 解析失败）：内嵌原始参数编辑框，绝不丢用户数据。

## 无代码模式的替代与优化

原来无代码模式下，条件 / 效果字段用「点选目录 + 槽表单」逐条追加；本次把它替换 / 升级为：

1. **字段内「打开积木库」**（`NoCodeEffectField`，三个编辑面共用）：
   直接拉起积木库弹窗，可分类浏览、多行搭建、复制输出，一次替换整段字段值；
   仍然遵守「开启无代码后不出现代码输入框」的约束（自定义 / 原始框只出现在积木库内部）。
2. **点选目录升级**：`effect_slot_form.dart` 的目录弹窗加入**分类胶囊 + 分页**，
   描述放在主行、类别与代码放在次行，浏览体验与积木库一致。

> 说明：内联积木行列表本身仍由 `EffectBlockEditor(embedded: true)` 承担（零文本输入、
> 非法内容只读不覆写的数据安全边界不变）；本次替换的是它的**浏览 / 选码 / 整段搭建**入口。

## 数据端点

- `GET /api/effect_suggest?mode=&q=` —— 目录候选（`code` / `desc` / `raw_code` / `slots`）。
- `POST /api/effect/parse` —— 文本 → 行模型（模板 / 槽 / 嵌套 / error）。
- `GET /api/cfg/ConditionTypeCfg`、`GET /api/cfg/EffectTypeCfg` —— 分类名（懒加载 + 兜底）。
- `POST /api/usage` —— 接受候选时上报（fire-and-forget，空 q 的「最近使用」头部靠它）。

## 测试

`frontend/test/blocks_library_test.dart`：目录 + 清单渲染、切换条件模式 / 分类筛选 / 点击入库
生成代码、窄窗（隐藏说明栏）无溢出、导演主页「积木库」卡片进入、无代码字段显示「打开积木库」。

## 当前版本的边界（对照成熟方案尚未接入的部分）

- **数值比较的算符切换**（把「≥」一键切成「范围 / = / ≤」并改写行）：目录已为每种比较
  提供独立候选（如 `[1,1,V]` / `[1,3,X,Y]`），但尚未做行内算符切换控件。
- **前提（premise）创建 / 重命名 / 引用**：未接入前提库与派生条件模板。
- **条件配置（configs）**：未接入「用户配置 / 模组配置」的保存与整组引用。
- **原版已有条件索引**：未扫描工作区里已被引用的条件组合并按「已有组合」补全目录。
- **引用表搜索框**：参数槽引用目前靠候选项下拉（后端已给选项），未做槽内搜索输入框。
