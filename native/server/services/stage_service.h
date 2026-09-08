// wip/P3a/stage_service.h —— AI 舞台调度（port of server/stage_service.py）。
//
// 语义化指令 <-> TalkCfg.roles 二维编码；错误消息（SandboxError 中文原文）
// 是前端/AI 侧栏契约，逐字保留。
#pragma once

#include <string>

#include "content_util.h"

namespace sa {
namespace stage {

using json = content::json;

// stage_service.get_stage_dicts()：全部字典（expressions/actions/positions/roles）。
json get_stage_dicts();

// get_role_dict()：仅 data_dicts.ROLE_DICT（含旁白 -1）。注意：舞台链路
// 不合并 mod PersonCfg —— 与 Python 一致（golden api_ai_stage_dicts 锁定）。
json get_role_dict();

// describe_roles(roles)：roles 二维数组 -> 逐行中文描述。
std::string describe_roles(const json& roles);

// encode_commands(commands, role_dict)：语义指令 -> roles；任一非法整体抛
// SandboxError（Python 同名）。errors 聚合消息逐字保留。
json encode_commands(const json& commands, const json& role_dict);

// resolve_role / resolve_expr：名称或 ID -> int（错误抛 SandboxError）。
long long resolve_role(const json& ref, const json& role_dict);

// _load_talk 族（ai_domain_service.cfg_exists/load_cfg 的等价，错误消息逐字）：
// 读 <mod>/Cfgs/zh-cn/TalkCfg.json；抛 sa::SandboxError。
// get_talk_stage / encode_talk_stage：stage_service.py 同名函数返回体。
json get_talk_stage(const std::string& talk_id);
json encode_talk_stage(const std::string& talk_id, const json& commands, bool clear);

}  // namespace stage
}  // namespace sa
