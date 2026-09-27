// 本地资源文件导入 (网页版计划 M3): server/services/mod_files_routes.*
//
//   POST /api/mod/import_files
//     请求 {"files":[{"name":"a.png","data":"<base64>","dir":"Textures"(可选)}],
//           "register_audio":bool(默认 false)}
//     响应 200 {"saved":[{"name":"原名","path":"Textures/a.png","size":123,
//                         "audio_id":int|null,"audio_error":str|null}],
//               "errors":[{"name":"原名","error":"原因"}]}
//          400 {"error":"未选择模组"}；files 缺失/空数组/非对象/非数组 -> 400。
//
// 落盘规则（详见 .cpp 顶部）：按扩展名归类目录（图片->Textures、音频->Audios，
// 或显式 dir 单层目录名）、名字净化去目录穿越、重名不覆盖自动加后缀、经
// p3b_fs_tools 沙箱写入、可选把音频登记进 AudioCfg。前端已按此契约开发。
#pragma once

#include "server/httpd.h"

namespace sa {

void register_mod_files_routes(Router& r);

}  // namespace sa
