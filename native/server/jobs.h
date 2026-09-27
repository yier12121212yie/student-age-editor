// server/jobs: 后台长任务队列（性能 P1）。
//
// AI 中继 / TTS 合成 / SD 生图 / 全量云同步这类分钟级端点经 wrap_async_job()
// 包装后：调用方带 query `async=1` 即 202 {"job_id"} 立即返回，handler 交给
// 这里的 4 线程池执行，结果经 GET /api/jobs/{id} 轮询取回；不带标记则保持
// 同步执行（旧客户端零影响）。请求线程不再被长任务钉死在 httpd 槽位上
// （httpd 空闲超时 15s 也不再掐断长任务的 keep-alive）。
//
// 线程模型：单 FIFO 队列 + 定长 worker 池；任务表 map<id, Job> 在一把互斥锁
// 下，handler 在锁外执行（可运行数分钟）。完成条目保留 15 分钟（轮询宽限），
// 超过 512 条防御上限时淘汰最老完成项。
#pragma once

#include <functional>
#include <string>

#include "server/httpd.h"

namespace sa::jobs {

// 启动 worker 池（默认 4 线程）。幂等；run_server 启动时调用一次。
void start(int workers = 4);

// 停止：唤醒 worker 并让它们退出（排队任务被放弃，在跑任务跑完当前 handler
// 后自然结束——进程退出前调用，不做优雅取消）。
void stop();

// 提交一个任务（fn 在 worker 线程执行）。返回 32-hex job id。
std::string submit(std::function<Resp()> fn);

// 取回任务结果快照。未知 id 返回 false；未完成任务返回
// {"status":"queued"|"running"}；完成：JSON 结果包成
// {"status":"done","result":...}（原 handler >= 400 时折算为
// {"status":"error","error":...}，HTTP 仍 200，轮询客户端按 status 字段分
// 支）；bytes 响应原样透传（当前包装端点均返回 JSON，透传仅为兜底）。
bool fetch(const std::string& id, Resp* out);

}  // namespace sa::jobs
