// wip/P3a/preview_service.h —— 事件场景预览（port of server/preview_service.py）。
//
// 三缓存原样移植：_mod_fp_cache（mod 单表 + 指纹）、_table_cache（本体/包兜底
// 结果，无指纹——失效全靠 invalidate_cache）、_meta_cache/_meta_fp（合并元数据）。
// 本体侧读取经 sa::base_store() 接缝（P4 未注册时 available()==false，等价
// Python 无游戏本体：_load_aa_cfg/_load_pack_cfg 恒 None）。
//
// 线程规则（CONVENTIONS 6 精神）：缓存锁只护 map 操作，磁盘 IO 一律在锁外；
// 竞态最多造成重复解析一次，结果幂等。
#pragma once

#include <cstddef>
#include <memory>
#include <string>

#include "content_util.h"

namespace sa {
namespace preview {

using json = content::json;

// preview_service.preview_event(evt_id)。找不到事件/参数空 -> 抛 sa::SandboxError
// （路由转 400）；数据形态引发的 Python 异常等价物抛 sa::ApiError（带类型名，
// 路由转 500 "%s: %s"）。
//
// 响应契约（对前端 preview_models.dart 只增字段、不改不删）：既有
// ok/evt_id/event/event_title/starts/talks/options/talk_count/meta 之外——
//   "audios": {"<audioId>": {"url": 相对 mod 根路径, "name", "type": int}}
//     覆盖本次 talks 引用到的全部 TalkCfg.audio（不含 -1/0）+ 每条 vocals 首项
//     id + 舞台演进后的当前 BGM id；数据源 mod+本体合并 AudioCfg（合并表缺
//     该 id 时不出键）。
//   每条 talk 的 "stage" 增 "bgm": 当前 BGM id|null —— 状态机沿 BFS 访问序
//     累积：TalkCfg.audio 命中 AudioCfg.type==1 -> 切；audio==-1 -> 清；
//     type==2（音效）不改状态。talk 原始 audio/vocals/screenEffect 字段不动。
//   顶层 "stage": {"bgm": 最终 BGM id|null}；
//   顶层 "screen_effects": {"<talkId>": {code:int, args:[...]}|null} ——
//     TalkCfg.screenEffect（1D 只取第 1 组，如 [4015, CGid]）的归一形式。
json preview_event(const std::string& evt_id);

// GET /api/preview/meta：只读合并元数据（mod+本体的 roles/bgs/bgKeys/charKeys），
// 前端背景/立绘选择器做 TalkCfg.bg 反查与当前值缩略图时消费。
json preview_meta();

// preview_service.invalidate_cache()：三缓存全清。经
// sa::set_preview_invalidator_hook 在 cfg 写路径 / select_mod 上被调。
void invalidate_cache();

namespace test_hooks {
// 缓存观测口（接线实测用；只读计数，不暴露内容）。
std::size_t table_cache_size();
std::size_t mod_fp_cache_size();
bool meta_cached();
}  // namespace test_hooks

}  // namespace preview
}  // namespace sa
