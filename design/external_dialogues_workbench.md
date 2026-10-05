# 外部对话工作台（导演布局的专属功能界面）

「每个功能都有专属界面」重建的第 3 批第三个功能。落在
`frontend/lib/features/external/external_dialogues_workbench.dart`，由导演工作台的
「外部对话」功能（`_DirectorFeature.external`）承载；主页「外部对话」卡片直接进入。

把游戏里**主线剧情之外**的对白入口汇总到一处，按用途分类浏览与编辑。

## 覆盖的用途（用途 → 数据表）

| 用途 | 数据来源 | 绑定字段 |
| --- | --- | --- |
| 送礼对话 | `GiftEvtCfg` | `npc[i]`（收礼人）× `item`（礼物）→ `talkId[i]` |
| 小游戏开场 | `MinigameActionCfg` | `startTalk` |
| 小游戏胜利 | `MinigameActionCfg` | `winTalk` |
| 小游戏失败 | `MinigameActionCfg` | `loseTalk` |
| 闲聊 | `InteractCfg` | `talkId` |

- 小游戏的「人物」由 `PersonGrowCfg.minigame` 反查（游戏编号 = `MinigameActionCfg.id ~/ 100`）。
- 对白内容统一落在 `TalkCfg`，沿 `nextTalk[0]` 串成线性对白链就地编辑。

## 布局（三栏）

| 栏 | 内容 |
| --- | --- |
| 左（270–310） | 搜索 + 用途分类胶囊（全部 / 送礼 / 小游戏开场·胜利·失败 / 闲聊）+ 入口列表（用途图标、入口标签、绑定对白、缺失标记） |
| 中（自适应） | 入口头 + 用途参数（按类型）+ 对白链（逐句：说话人 / 内容 / 删除 / ＋追加）+ 保存条 |
| 右（≥1080 显示，280–320） | 对话预览（聊天气泡）+ 统计与引用 |

窄窗（<1080）自动隐藏右栏；<1340 收窄左右栏。

## 用途参数

- **送礼**：收礼人（人物选择器写 `npc[i]`）、具体礼物（物品/书籍选择器写 `item`）、
  赠送方式（`type[i]`：交付礼物 / 仅播放对话）、触发条件 `cond`（积木库·条件）。
- **小游戏**：人物与关卡只读展示，精力消耗 `cost`、关系要求 `needRelation`（`RelationCfg` 名）、
  关卡效果 `effect`（积木库·效果）。
- **闲聊**：闲聊人物 `npc`、进度文字 `text`、地点 `map`（只读展示）、触发条件 `cond`、
  闲聊效果 `effect`（均走积木库）。

## 对白链（TalkCfg）

- 从入口对白起沿 `nextTalk[0]` 串联；逐句编辑说话人（`roleIds[0]`，白雨 = 0、旁白 = -1）
  与内容 `content`；删除某句时自动把上一句的 `nextTalk` 接到下一句（首句则改写入入口绑定）。
- 「＋ 白雨对白」/「＋ {人物}对白」在链尾追加新 `TalkCfg` 行（id 取全表最大值 +1）。
- 右侧「对话预览」按聊天样式渲染气泡：白雨靠右、人物靠左、旁白斜体居中。

## 数据与保存

- **同时编辑四张表**，各自整表读写：
  - `GiftEvtCfg`（送礼入口）；
  - `MinigameActionCfg`（小游戏对白入口）；
  - `InteractCfg`（闲聊入口）；
  - `TalkCfg`（对白内容）。
- 只读字典：`PersonGrowCfg`（人物→小游戏）、`ItemCfg` / `BookCfg`（礼物名）、
  `MinigameCfg`（小游戏名）、`RelationCfg`（关系名）、`game_dicts.maps`（地点名）。
- 读取 `GET /api/cfg/<name>`（`data` + `mtime_ns`）；写回 `PUT` 带 `expect_mtime_ns`，
  409 逐表弹「重新加载 / 强制覆盖」。保存按 `GiftEvtCfg → MinigameActionCfg → InteractCfg →
  TalkCfg` 只写脏表。
- 「保存修改」写回脏表；「放弃修改」回滚到本次加载快照。

## 当前版本的边界

- **不做「对话夹」持久化**：对标把对话夹作为编辑器私有元数据（`doc.externalDialogueFolders`）
  保存在剧情文档里；本编辑器直接编辑游戏表、没有剧情文档元数据存储，因此改以**用途（kind）
  分类**对入口分组，不新增元数据文件，也不写入游戏表之外的任何数据。
- **不做「用途自动发现」**：对标会扫描原生绑定并提示补齐；这里直接按表字段列出入口。
- **送礼只编辑已有 (人物,礼物) 项**：不在本界面新增 / 拆分送礼规则（`npc` / `talkId` 平行数组
  的增删仍建议在「物品仓库」或配置表处理）。
- **小游戏人物只读**：改绑小游戏需要改 `PersonGrowCfg.minigame`，请去「人物工作台」。
- **只做 `nextTalk` 主线**：分支 `nextTalk2`、选项 `option`、条件 `check` 不在此编辑，去「剧情舞台」。
- **送礼对白的性别分列**：若 `talkId[i]` 是数组（男/女），本界面只编辑/展示首项。
- **仅覆盖三类入口表**：`ActionTalkCfg` / `ClassTalkCfg` 等以字符串存对白、不接 `TalkCfg` 的表未纳入。

## 测试

`frontend/test/external_dialogues_workbench_test.dart`：三栏渲染 + 入口列表、按用途筛选、
小游戏入口显示人物与关卡、添加对白并置脏、保存写回入口表与 TalkCfg、800×600 无溢出、
导演主页「外部对话」卡片进入。
