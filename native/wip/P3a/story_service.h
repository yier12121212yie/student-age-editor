// wip/P3a/story_service.h —— 剧本文本 <-> TalkCfg（port of server/story_service.py）。
//
// 双向转换的文本格式约定全部来自 Python 源码注释与实现（ScriptParser /
// _StoryExporter）：错误、字段名、行拼接符（三个空格）、全角括号等一律逐字。
// 解析用码点级手写匹配器（Python re 的 \d/\s/$ 是 Unicode 语义，且效果行
// 含 (?<!屏幕) 变长后顾，std::regex 不支持——见交付报告）。
#pragma once

#include <string>
#include <vector>

#include "content_util.h"

namespace sa {
namespace story {

using json = content::json;

// story_service.parse_script：文本 -> TalkCfg 片段 {id: record}。
// start_id 非数值抛 ValueError 语义（ApiError），与 Python int(start_id) 一致。
json parse_script(const std::string& start_id, const std::string& text,
                  const json& name_to_id);

// story_service.export_story：opts 为 body 里的 opts 对象（可空对象/缺省）。
std::string export_story(const json& evt_cfg, const json& talk_cfg, const json& opt_cfg,
                         const json& role_dict, const std::vector<std::string>& evt_ids,
                         const json& opts, const std::string& dual_choice);

}  // namespace story
}  // namespace sa
