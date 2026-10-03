// server/services/mod_refs_routes.h — 自托管大资源的「COS 引用 + 导出拼接」：
//   POST /api/mods/add_ref       浏览器直传（upload/request + PUT，不落盘）后，
//                                把暂存对象钉成当前模组的持久资源引用
//                                （record→linked，索引写 <mod>/cos_resources.json）。
//   POST /api/mods/export_staged 流式打包模组：本地盘文件 + 引用资源（经内网
//                                从 COS 拉回）拼成 store-only zip，产物登记进
//                                文件流转（archived），客户端拿 file_id 走
//                                /api/v1/files/:id/download 预热直链带进度下载。
#pragma once

#include "server/httpd.h"

namespace sa {

void register_mod_refs_routes(Router& r);

}  // namespace sa
