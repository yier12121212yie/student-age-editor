// wip/P3a/test_p3a_content.cpp —— [p3a] 剧情/预览/搜索/舞台 单测（黑盒路由级）。
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <string>

#include "content_routes.h"
#include "preview_service.h"
#include "sa_core/json_wire.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "test_support.h"

using json = sa::json;
using sat::call_router;

namespace {

// fixture + 波次 1 总线 + 本组路由（extra_routes 同 main.cpp）。
struct P3aFixture : sat::CfgFixture {
    P3aFixture() : sat::CfgFixture("p3a") { sa::register_content_routes(router()); }
};

void put_cfg(sa::Router& r, const std::string& name, const json& data) {
    json body;
    body["data"] = data;
    auto resp = call_router(r, "PUT", "/api/cfg/" + name, {}, body);
    REQUIRE(resp.status == 200);
}

json arr(std::initializer_list<json> xs) {
    json a = json::array();
    for (const auto& x : xs) a.push_back(x);
    return a;
}
json iarr(std::initializer_list<long long> xs) {
    json a = json::array();
    for (auto x : xs) a.push_back(x);
    return a;
}
json sarr(std::initializer_list<const char*> xs) {
    json a = json::array();
    for (auto x : xs) a.push_back(x);
    return a;
}

// story import 用例的临时 mod 开关（cfg 文件仍在盘上，只切 STATE 指针）。
std::string g_saved_root, g_saved_name;
void mod_off() {
    std::lock_guard<std::mutex> lk(sa::STATE().mu_);
    g_saved_root = sa::STATE().mod_root;
    g_saved_name = sa::STATE().mod_name;
    sa::STATE().mod_root.clear();
    sa::STATE().mod_name.clear();
}
void mod_on() {
    std::lock_guard<std::mutex> lk(sa::STATE().mu_);
    sa::STATE().mod_root = g_saved_root;
    sa::STATE().mod_name = g_saved_name;
}

}  // namespace

TEST_CASE("p3a story export 组装文本格式", "[p3a][story]") {
    P3aFixture fx;
    auto& r = fx.router();
    {
        json t;
        t["id"] = 101;
        t["name"] = "小美";
        json p;
        p["101"] = t;
        put_cfg(r, "PersonCfg", p);
    }
    {
        json evt;
        evt["id"] = 101;
        evt["title"] = "入学";
        evt["type"] = 2;
        evt["npc"] = 101;
        evt["talkId"] = iarr({101001});
        evt["condition"] = arr({iarr({7, 0, 101, 2})});
        json tbl;
        tbl["101"] = evt;
        put_cfg(r, "EvtCfg", tbl);
    }
    {
        json t1;
        t1["id"] = 101001;
        t1["roleIds"] = iarr({101});
        t1["content"] = "你好呀";
        t1["bg"] = 3;
        t1["audio"] = 5;
        t1["roles"] = arr({iarr({101, 3000, 1}), iarr({101, 1001, 1, 3})});
        t1["nextTalk"] = iarr({101002});
        t1["option"] = iarr({20001});
        json t2;
        t2["id"] = 101002;
        t2["roleIds"] = iarr({101});
        t2["content"] = "选项后";
        t2["nextTalk"] = json::array();
        json tbl;
        tbl["101001"] = t1;
        tbl["101002"] = t2;
        put_cfg(r, "TalkCfg", tbl);
    }
    {
        json o;
        o["id"] = 20001;
        o["content"] = "去操场";
        o["talkId"] = iarr({101002});
        o["effect"] = arr({iarr({3, 1, 10})});
        json tbl;
        tbl["20001"] = o;
        put_cfg(r, "OptionCfg", tbl);
    }

    json body;
    body["evt_ids"] = sarr({"101"});
    auto resp = call_router(r, "POST", "/api/story/export", {}, body);
    REQUIRE(resp.status == 200);
    const std::string text = resp.json_payload.at("text").get<std::string>();
    INFO(text);
    CHECK(text.find("社交事件：入学（小美专属事件，触发条件为：小美是你的朋友） 事件id：101") !=
          std::string::npos);
    CHECK(text.find("小美   [小美开心]   背景：3   BGM：5   动作：小美滑动入场到中侧") !=
          std::string::npos);
    CHECK(text.find("你好呀") != std::string::npos);
    CHECK(text.find("决定1：去操场") != std::string::npos);
    CHECK(text.find("效果：[[3, 1, 10]]") != std::string::npos);
    CHECK(text.find("----- END -----") != std::string::npos);
    CHECK(resp.json_payload.at("evt_ids") == sarr({"101"}));

    body["opts"] = json{{"pure", true}};
    auto resp2 = call_router(r, "POST", "/api/story/export", {}, body);
    REQUIRE(resp2.status == 200);
    const std::string pure = resp2.json_payload.at("text").get<std::string>();
    CHECK(pure.find("小美：你好呀") != std::string::npos);
    CHECK(pure.find("背景：3") == std::string::npos);
    CHECK(pure.find("动作：") == std::string::npos);
    // pure 只裁剪对白行；事件头（含 事件id）仍输出（Python _StoryExporter 行为）
    CHECK(pure.find("事件id：101") != std::string::npos);

    auto e1 = call_router(r, "POST", "/api/story/export", {},
                          json{{"evt_ids", json::array()}});
    CHECK(e1.status == 400);
    CHECK(e1.json_payload["error"] == "evt_ids required");
}

TEST_CASE("p3a story import 解析 + 往返幂等", "[p3a][story]") {
    P3aFixture fx;
    auto& r = fx.router();
    {
        json t;
        t["id"] = 101;
        t["name"] = "小美";
        json p;
        p["101"] = t;
        put_cfg(r, "PersonCfg", p);
        json evt;
        evt["id"] = 101;
        evt["title"] = "测试事件";
        evt["talkId"] = json::array();
        json et;
        et["101"] = evt;
        put_cfg(r, "EvtCfg", et);
    }

    const std::string script =
        "小美：你好呀（开心）\n旁白：（远处传来铃声）\n小美：出发（bg：7）触发效果：[4001,2]\n";

    auto run_import = [&](bool write) {
        json body;
        body["start_id"] = "101";
        body["text"] = script;
        body["write"] = write;
        return call_router(r, "POST", "/api/story/import", {}, body);
    };

    auto resp = run_import(false);
    REQUIRE(resp.status == 200);
    INFO(sa_core::py_dumps(resp.json_payload));
    CHECK(resp.json_payload["ok"] == true);
    CHECK(resp.json_payload["write"] == false);
    CHECK(resp.json_payload["count"] == 3);
    const json& pv = resp.json_payload["preview"];
    REQUIRE(pv.size() == 3);
    auto resp_b = run_import(false);
    REQUIRE(resp_b.status == 200);
    CHECK(sa_core::py_dumps(resp_b.json_payload["preview"]) == sa_core::py_dumps(pv));

    const json& t1 = pv[0][1];
    CHECK(t1["content"] == "你好呀");
    CHECK(t1["roleIds"] == iarr({101}));
    CHECK(t1["roles"] == arr({iarr({101, 3000, 1})}));
    CHECK(t1["id"] == 101001);
    CHECK(t1["nextTalk"] == iarr({101002}));
    const json& t2 = pv[1][1];
    CHECK(t2["roleIds"].empty());
    CHECK(t2["content"].get<std::string>().find("（远处传来铃声）") != std::string::npos);
    const json& t3 = pv[2][1];
    CHECK(t3["bg"] == 7);
    CHECK(t3["effect"] == arr({iarr({4001, 2})}));
    CHECK(t3["nextTalk"] == json::array());  // 末条 nextTalk 置空

    auto w = run_import(true);
    REQUIRE(w.status == 200);
    CHECK(w.json_payload["write"] == true);
    auto get_talk = call_router(r, "GET", "/api/cfg/TalkCfg");
    REQUIRE(get_talk.status == 200);
    CHECK(get_talk.json_payload["data"].contains("101001"));
    auto get_evt = call_router(r, "GET", "/api/cfg/EvtCfg");
    REQUIRE(get_evt.status == 200);
    CHECK(get_evt.json_payload["data"]["101"]["talkId"] == iarr({101001}));

    // 导出刚落盘的 TalkCfg，再导入仍可解析（往返），且同文本重导 preview 相同
    auto ex = call_router(r, "POST", "/api/story/export", {},
                          json{{"evt_ids", sarr({"101"})}});
    REQUIRE(ex.status == 200);
    const std::string exported = ex.json_payload["text"].get<std::string>();
    INFO(exported);
    CHECK(exported.find("你好呀") != std::string::npos);
    json ib;
    ib["start_id"] = "202";
    ib["text"] = exported;
    auto re = call_router(r, "POST", "/api/story/import", {}, ib);
    REQUIRE(re.status == 200);
    CHECK(re.json_payload["count"].get<long long>() >= 1);
    auto re2 = call_router(r, "POST", "/api/story/import", {}, ib);
    CHECK(sa_core::py_dumps(re2.json_payload["preview"]) ==
          sa_core::py_dumps(re.json_payload["preview"]));

    auto miss = call_router(r, "POST", "/api/story/import", {}, json{{"start_id", ""}});
    CHECK(miss.status == 400);
    CHECK(miss.json_payload["error"] == "start_id and text required");
    auto bad = call_router(r, "POST", "/api/story/import", {},
                           json{{"start_id", "abc"}, {"text", "台词"}});
    CHECK(bad.status == 500);
    CHECK(bad.json_payload["error"] ==
          "ValueError: invalid literal for int() with base 10: 'abc'");
}

TEST_CASE("p3a story no mod selected", "[p3a][story]") {
    P3aFixture fx;
    auto& r = fx.router();
    mod_off();
    auto resp = call_router(r, "POST", "/api/story/import", {},
                            json{{"start_id", "1"}, {"text", "甲：好"}, {"write", true}});
    CHECK(resp.status == 400);
    CHECK(resp.json_payload["error"] == "no mod selected");
    auto ex = call_router(r, "POST", "/api/story/export", {},
                          json{{"evt_ids", sarr({"1"})}});
    CHECK(ex.status == 400);
    CHECK(ex.json_payload["error"] == "no mod selected");
    mod_on();
}

TEST_CASE("p3a preview 组装与三缓存失效接线", "[p3a][preview]") {
    P3aFixture fx;
    auto& r = fx.router();

    {
        json evt;
        evt["id"] = 5;
        evt["title"] = "预览测试事件";
        evt["talkId"] = iarr({5001});
        json et;
        et["5"] = evt;
        put_cfg(r, "EvtCfg", et);
    }
    {
        json t1;
        t1["id"] = 5001;
        t1["content"] = "预览台词";
        t1["roleIds"] = iarr({1});
        t1["bg"] = 0;
        t1["roles"] = arr({iarr({101, 1001, 1, 1})});
        t1["nextTalk"] = iarr({5002});
        json t2;
        t2["id"] = 5002;
        t2["content"] = "第二句";
        t2["roles"] = json::array();
        t2["nextTalk"] = json::array();
        json tt;
        tt["5001"] = t1;
        tt["5002"] = t2;
        put_cfg(r, "TalkCfg", tt);
    }
    {
        json p;
        p["id"] = 101;
        p["name"] = "测试角色";
        p["url"] = sarr({"role_x"});
        json pt;
        pt["101"] = p;
        put_cfg(r, "PersonCfg", pt);
    }

    auto e0 = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", ""}});
    CHECK(e0.status == 400);
    CHECK(e0.json_payload["error"] == "evt_id required");
    auto e1 = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", "99999999"}});
    CHECK(e1.status == 400);
    CHECK(e1.json_payload["error"].get<std::string>().find("不存在") != std::string::npos);

    auto resp = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", "5"}});
    REQUIRE(resp.status == 200);
    INFO(sa_core::py_dumps(resp.json_payload));
    const json& data = resp.json_payload;
    CHECK(data["ok"] == true);
    CHECK(data["evt_id"] == "5");
    CHECK(data["event_title"] == "预览测试事件");
    CHECK(data["starts"] == sarr({"5001"}));
    CHECK(data["talk_count"] == 2);
    const json& t1 = data["talks"]["5001"];
    CHECK(t1["id"] == "5001");                   // 字符串化
    CHECK(t1["roleIds"] == sarr({"1"}));         // clean_id 字符串化
    CHECK_FALSE(t1.contains("roles"));           // pop roles 折叠进 stage
    const json& chars = t1["stage"]["chars"];
    REQUIRE(chars.size() == 1);
    CHECK(chars[0]["roleId"] == "101");
    CHECK(chars[0]["pos"] == "left");
    CHECK(chars[0]["tex"] == "role_x");
    CHECK(chars[0]["expr"] == 0);
    CHECK(chars[0]["flip"] == false);
    CHECK(data["talks"]["5002"]["stage"]["chars"][0]["pos"] == "left");  // 状态演进
    CHECK(data["meta"]["roles"]["101"] == "测试角色");
    CHECK(data["options"].empty());

    // ---- invalidate 接线实测 ----
    CHECK(sa::preview::test_hooks::table_cache_size() > 0);  // OptionCfg/BgCfg 缺失 -> {}
    CHECK(sa::preview::test_hooks::meta_cached());
    json evt2;
    evt2["id"] = 5;
    evt2["title"] = "改名后的事件";
    evt2["talkId"] = iarr({5001});
    json et2;
    et2["5"] = evt2;
    put_cfg(r, "EvtCfg", et2);  // 波次 1 写路径 -> sa::invalidate_preview_cache() -> 本组 hook
    CHECK(sa::preview::test_hooks::table_cache_size() == 0);
    CHECK(sa::preview::test_hooks::meta_cached() == false);
    auto resp2 = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", "5"}});
    REQUIRE(resp2.status == 200);
    CHECK(resp2.json_payload["event_title"] == "改名后的事件");  // 黑盒：反映新数据

    // 加选项链：第二轮预览展开选项分支
    {
        json o;
        o["id"] = 6001;
        o["content"] = "选项";
        o["talkId"] = iarr({5003});
        json ot;
        ot["6001"] = o;
        put_cfg(r, "OptionCfg", ot);
        json t1;
        t1["id"] = 5001;
        t1["content"] = "预览台词";
        t1["roleIds"] = iarr({1});
        t1["bg"] = 0;
        t1["roles"] = arr({iarr({101, 1001, 1, 1})});
        t1["option"] = iarr({6001});
        t1["nextTalk"] = iarr({5002});
        json t2;
        t2["id"] = 5002;
        t2["content"] = "第二句";
        t2["nextTalk"] = json::array();
        json t3;
        t3["id"] = 5003;
        t3["content"] = "分支句";
        t3["nextTalk"] = json::array();
        json tt;
        tt["5001"] = t1;
        tt["5002"] = t2;
        tt["5003"] = t3;
        put_cfg(r, "TalkCfg", tt);
    }
    auto resp3 = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", "5"}});
    REQUIRE(resp3.status == 200);
    CHECK(resp3.json_payload["options"].contains("6001"));
    CHECK(resp3.json_payload["options"]["6001"]["id"] == "6001");
    CHECK(resp3.json_payload["talks"].contains("5003"));
    CHECK(resp3.json_payload["talk_count"] == 3);
}

TEST_CASE("p3a stage dicts/encode/describe 往返", "[p3a][stage]") {
    P3aFixture fx;
    auto& r = fx.router();
    {
        json t;
        t["id"] = 7001;
        t["content"] = "你好";
        t["roles"] = json::array();
        json tt;
        tt["7001"] = t;
        put_cfg(r, "TalkCfg", tt);
    }

    auto dicts = call_router(r, "GET", "/api/ai/stage/dicts");
    REQUIRE(dicts.status == 200);
    CHECK(dicts.json_payload["expressions"].size() == 27);
    CHECK(dicts.json_payload["actions"].size() == 27);
    CHECK(dicts.json_payload["positions"].size() == 3);
    CHECK_FALSE(dicts.json_payload["roles"].empty());

    json cmd;
    cmd["talk_id"] = "7001";
    cmd["commands"] = arr({
        json{{"action", "入场"}, {"role", "薛诗蕾"}, {"mode", "滑动"}, {"pos", "左"}},
        json{{"action", "表情"}, {"role", "102"}, {"expr", "开心"}},
        json{{"action", "移动"}, {"role", "102"}, {"value", -80}},
        json{{"action", "退场"}, {"role", "102"}, {"mode", "直接"}},
    });
    auto enc = call_router(r, "POST", "/api/ai/stage/encode", {}, cmd);
    REQUIRE(enc.status == 200);
    const json& payload = enc.json_payload;
    CHECK(payload["talk_id"] == "7001");
    CHECK(payload["old_roles"] == json::array());
    CHECK(payload["new_roles"] == arr({iarr({102, 1001, 1, 1}), iarr({102, 3000, 1}),
                                       iarr({102, 3004, -80}), iarr({102, 2002})}));
    CHECK(payload["added"] == 4);
    const std::string desc = payload["new_desc"].get<std::string>();
    INFO(desc);
    CHECK(desc.find("薛诗蕾滑动到左侧") != std::string::npos);
    CHECK(desc.find("薛诗蕾表情：开心") != std::string::npos);
    CHECK(desc.find("薛诗蕾左右移动 80左") != std::string::npos);
    CHECK(desc.find("薛诗蕾直接退场") != std::string::npos);

    {
        json t;
        t["id"] = 7001;
        t["content"] = "你好";
        t["roles"] = payload["new_roles"];
        json tt;
        tt["7001"] = t;
        put_cfg(r, "TalkCfg", tt);
    }
    auto get = call_router(r, "GET", "/api/ai/stage/roles", {{"talk_id", "7001"}}, json());
    REQUIRE(get.status == 200);
    CHECK(get.json_payload["roles"] == payload["new_roles"]);
    const std::string gd = get.json_payload["desc"].get<std::string>();
    CHECK(gd.find("薛诗蕾滑动到左侧") != std::string::npos);
    CHECK(gd.find("开心") != std::string::npos);
    CHECK(gd.find("直接退场") != std::string::npos);

    auto enc2 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"},
                                 {"commands",
                                  arr({json{{"action", "屏幕特效"}, {"type", "屏幕抖动"}}})}});
    REQUIRE(enc2.status == 200);
    CHECK(enc2.json_payload["new_roles"].size() == 5);
    CHECK(enc2.json_payload["new_roles"].back() == iarr({4001, 1}));
    auto enc3 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"},
                                 {"clear", true},
                                 {"commands",
                                  arr({json{{"action", "表情"}, {"role", "102"}, {"expr", "8"}}})}});
    REQUIRE(enc3.status == 200);
    CHECK(enc3.json_payload["new_roles"] == arr({iarr({102, 3000, 8})}));
    CHECK(enc3.json_payload["new_desc"].get<std::string>().find("惊讶") != std::string::npos);
    CHECK(enc3.json_payload["clear"] == true);

    auto err1 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"},
                                 {"commands",
                                  arr({json{{"action", "入场"}, {"role", "不存在的人"}}})}});
    CHECK(err1.status == 400);
    CHECK(err1.json_payload["error"].get<std::string>().find("找不到角色") != std::string::npos);
    auto err2 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"},
                                 {"commands", arr({json{{"action", "起飞"}}})}});
    CHECK(err2.status == 400);
    CHECK(err2.json_payload["error"].get<std::string>().find("未知 action") != std::string::npos);
    auto err3 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"commands",
                                  arr({json{{"action", "表情"}, {"role", "1"}, {"expr", "1"}}})}});
    CHECK(err3.status == 400);
    CHECK(err3.json_payload["error"].get<std::string>().find("talk_id") != std::string::npos);
    auto err4 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "999999"},
                                 {"commands",
                                  arr({json{{"action", "表情"}, {"role", "1"}, {"expr", "1"}}})}});
    CHECK(err4.status == 400);
    CHECK(err4.json_payload["error"].get<std::string>().find("不存在") != std::string::npos);
    auto err5 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"}, {"commands", "bad"}});
    CHECK(err5.status == 400);
    CHECK(err5.json_payload["error"] == "commands 应为指令数组");
    auto err6 = call_router(r, "GET", "/api/ai/stage/roles", {{"talk_id", ""}}, json());
    CHECK(err6.status == 400);
    CHECK(err6.json_payload["error"].get<std::string>().find("talk_id") != std::string::npos);
    auto err7 = call_router(r, "POST", "/api/ai/stage/encode", {},
                            json{{"talk_id", "7001"},
                                 {"commands",
                                  arr({json{{"action", "表情"}, {"role", "不存在"},
                                            {"expr", "不存在表情"}},
                                       json{{"action", "瞎编"}}})}});
    REQUIRE(err7.status == 400);
    const std::string agg = err7.json_payload["error"].get<std::string>();
    INFO(agg);
    CHECK(agg.find("舞台指令解析失败，请修正后重试：\n") == 0);
    CHECK(agg.find("第 1 条") != std::string::npos);
    CHECK(agg.find("第 2 条") != std::string::npos);
    CHECK(agg.find("找不到角色「不存在」") != std::string::npos);
}

TEST_CASE("p3a search talk 命中/排序/limit 与空降级", "[p3a][search]") {
    P3aFixture fx;
    auto& r = fx.router();

    auto empty = call_router(r, "GET", "/api/search/talk", {{"q", "天气"}, {"limit", "5"}});
    REQUIRE(empty.status == 200);
    CHECK(empty.json_payload["results"] == json::array());
    auto empty_q = call_router(r, "GET", "/api/search/talk", {{"q", ""}});
    REQUIRE(empty_q.status == 200);
    CHECK(empty_q.json_payload["results"] == json::array());

    {
        json evt;
        evt["id"] = 5;
        evt["title"] = "测试事件";
        json et;
        et["5"] = evt;
        put_cfg(r, "EvtCfg", et);
        json a;
        a["id"] = 5001;
        a["content"] = "你好";
        json b;
        b["id"] = 5002;
        b["content"] = "你好啊世界";
        json c;
        c["id"] = 77;
        c["content"] = "无关台词";
        json tt;
        tt["5001"] = a;
        tt["5002"] = b;
        tt["77"] = c;
        put_cfg(r, "TalkCfg", tt);
    }

    auto hit = call_router(r, "GET", "/api/search/talk", {{"q", "你好"}});
    REQUIRE(hit.status == 200);
    const json& rows = hit.json_payload["results"];
    REQUIRE(rows.size() == 2);
    CHECK(rows[0]["src"] == "Mod");
    CHECK(rows[0]["talk_id"] == "5001");
    CHECK(rows[0]["evt_id"] == "5");
    CHECK(rows[0]["evt_title"] == "测试事件");
    CHECK(rows[0]["content"] == "你好");
    CHECK(rows[1]["talk_id"] == "5002");

    auto lim = call_router(r, "GET", "/api/search/talk", {{"q", "你好"}, {"limit", "1"}});
    REQUIRE(lim.status == 200);
    CHECK(lim.json_payload["results"].size() == 1);
    auto bad = call_router(r, "GET", "/api/search/talk", {{"q", "台词"}, {"limit", "abc"}});
    REQUIRE(bad.status == 200);
    CHECK(bad.json_payload["results"].size() == 1);
    auto zero = call_router(r, "GET", "/api/search/talk", {{"q", "台词"}, {"limit", "0"}});
    REQUIRE(zero.status == 200);
    CHECK(zero.json_payload["results"].size() == 1);
}

TEST_CASE("p3a story export 检定链/汇合标记", "[p3a][story]") {
    P3aFixture fx;
    auto& r = fx.router();
    {
        json evt;
        evt["id"] = 9;
        evt["title"] = "检定";
        evt["talkId"] = iarr({9001});
        json et;
        et["9"] = evt;
        put_cfg(r, "EvtCfg", et);
        json t1;
        t1["id"] = 9001;
        t1["roleIds"] = iarr({-1});
        t1["content"] = "开始";
        t1["check"] = arr({iarr({3, 1, 5})});
        t1["nextTalk"] = iarr({9002});
        t1["nextTalk2"] = iarr({9003});
        json t2;
        t2["id"] = 9002;
        t2["content"] = "成";
        t2["nextTalk"] = iarr({9003});
        json t3;
        t3["id"] = 9003;
        t3["content"] = "结";
        t3["nextTalk"] = json::array();
        json tt;
        tt["9001"] = t1;
        tt["9002"] = t2;
        tt["9003"] = t3;
        put_cfg(r, "TalkCfg", tt);
    }
    auto ex = call_router(r, "POST", "/api/story/export", {},
                          json{{"evt_ids", sarr({"9"})}});
    REQUIRE(ex.status == 200);
    const std::string text = ex.json_payload["text"].get<std::string>();
    INFO(text);
    CHECK(text.find("--- 检定成功 ([3, 1, 5]) ---") != std::string::npos);
    CHECK(text.find("--- 检定失败 ---") != std::string::npos);
    CHECK(text.find("剧情汇合/跳转至已读剧情 ID: 9003") != std::string::npos);
    CHECK(text.find("开始") != std::string::npos);
}

TEST_CASE("p3a preview audios/bgm/screen_effects 响应增强", "[p3a][preview]") {
    P3aFixture fx;
    auto& r = fx.router();
    {
        auto row = [](long long id, const char* name, const char* url, long long type) {
            json a;
            a["id"] = id;
            a["name"] = name;
            a["url"] = url;
            a["type"] = type;
            return a;
        };
        json at;
        at["1"] = row(1, "校门口BGM", "Audio/bgm1.mp3", 1);   // type=1 BGM
        at["2"] = row(2, "铃声", "Audio/sfx2.ogg", 2);        // type=2 音效
        at["3"] = row(3, "配音甲", "Audio/v3.ogg", 2);        // vocals 引用
        at["5"] = row(5, "", "Audio/bgm5.mp3", 1);            // name 空 -> 兜底「音频 5」
        put_cfg(r, "AudioCfg", at);
    }
    {
        json evt;
        evt["id"] = 9;
        evt["title"] = "音频链路";
        evt["talkId"] = iarr({9001});
        json et;
        et["9"] = evt;
        put_cfg(r, "EvtCfg", et);
    }
    {
        // 链：BGM(1) -> 结束(-1) -> 音效(2 不改状态) -> BGM(5) -> 未知 id(7777)
        json t1;
        t1["id"] = 9001;
        t1["audio"] = 1;
        t1["vocals"] = iarr({3});
        t1["screenEffect"] = iarr({4015, 900});
        t1["nextTalk"] = iarr({9002});
        json t2;
        t2["id"] = 9002;
        t2["audio"] = -1;
        t2["nextTalk"] = iarr({9003});
        json t3;
        t3["id"] = 9003;
        t3["audio"] = 2;
        t3["nextTalk"] = iarr({9004});
        json t4;
        t4["id"] = 9004;
        t4["audio"] = 5;
        t4["nextTalk"] = iarr({9005});
        json t5;
        t5["id"] = 9005;
        t5["audio"] = 7777;  // 合并表不存在
        t5["nextTalk"] = json::array();
        json tt;
        tt["9001"] = t1;
        tt["9002"] = t2;
        tt["9003"] = t3;
        tt["9004"] = t4;
        tt["9005"] = t5;
        put_cfg(r, "TalkCfg", tt);
    }

    auto resp = call_router(r, "POST", "/api/preview/event", {}, json{{"evt_id", "9"}});
    REQUIRE(resp.status == 200);
    INFO(sa_core::py_dumps(resp.json_payload));
    const json& data = resp.json_payload;
    // 既有契约不回归
    CHECK(data["ok"] == true);
    CHECK(data["talk_count"] == 5);

    // ---- stage.bgm 状态机（BFS 访问序累积）----
    CHECK(data["talks"]["9001"]["stage"]["bgm"] == "1");
    CHECK(data["talks"]["9002"]["stage"]["bgm"].is_null());  // -1 清
    CHECK(data["talks"]["9003"]["stage"]["bgm"].is_null());  // 音效不改
    CHECK(data["talks"]["9004"]["stage"]["bgm"] == "5");
    CHECK(data["talks"]["9005"]["stage"]["bgm"] == "5");
    CHECK(data["stage"]["bgm"] == "5");  // 顶层最终态

    // ---- 原始字段不动 ----
    CHECK(data["talks"]["9001"]["audio"] == 1);
    CHECK(data["talks"]["9001"]["vocals"] == iarr({3}));
    CHECK(data["talks"]["9001"]["screenEffect"] == iarr({4015, 900}));

    // ---- 顶层 audios：引用集（audio 有效值 + vocals 首项 + 当前 BGM）----
    const json& audios = data["audios"];
    CHECK(audios["1"]["url"] == "Audio/bgm1.mp3");
    CHECK(audios["1"]["name"] == "校门口BGM");
    CHECK(audios["1"]["type"] == 1);
    CHECK(audios["2"]["type"] == 2);
    CHECK(audios["3"]["name"] == "配音甲");           // 来自 vocals 首项
    CHECK(audios["5"]["name"] == "音频 5");           // 空名兜底
    CHECK(audios["5"]["url"] == "Audio/bgm5.mp3");    // 来自最终 BGM
    CHECK_FALSE(audios.contains("7777"));             // 合并表缺失 -> 不出键
    CHECK_FALSE(audios.contains("-1"));

    // ---- screen_effects 归一 ----
    const json& se = data["screen_effects"];
    CHECK(se.size() == 5);
    CHECK(se["9001"]["code"] == 4015);
    CHECK(se["9001"]["args"] == iarr({900}));
    CHECK(se["9002"].is_null());
    CHECK(se["9005"].is_null());
}

TEST_CASE("p3a live2d models/render 路由", "[p3a][live2d]") {
    P3aFixture fx;
    auto& r = fx.router();
    namespace fs = std::filesystem;
    auto models_dir = fx.root() / "game" / "DLC" / "DLC_L2DModels" / "girl";
    fs::create_directories(models_dir);
    {
        std::ofstream f1(models_dir / "girl.moc3");
        f1 << "moc3";
        std::ofstream f2(models_dir / "angry.moc3");
        f2 << "moc3";
    }
    std::string prev = sa_core::paths::getenv_utf8("EDITOR_GAME_ROOT");
    sa_core::paths::setenv_utf8("EDITOR_GAME_ROOT", sa_core::paths::path_to_utf8(fx.root() / "game"));

    auto resp = call_router(r, "GET", "/api/live2d/models", {});
    REQUIRE(resp.status == 200);
    const json& ms = resp.json_payload["models"];
    REQUIRE(ms.size() == 1);
    CHECK(ms[0]["name"] == "girl");
    CHECK(ms[0]["expressions"] == sarr({"angry", "girl"}));  // listdir_sorted 字典序
    const std::string model_path = ms[0]["path"].get<std::string>();

    // 入参缺失 -> 400 结构化信封
    auto bad = call_router(r, "POST", "/api/live2d/render", {}, json{{"expression", "angry"}});
    CHECK(bad.status == 400);
    CHECK(bad.json_payload["ok"] == false);
    CHECK(bad.json_payload.contains("error"));

    // 渲染核占位期无产物 -> 200 {"ok":false,"error":"renderer unavailable"}
    auto miss = call_router(r, "POST", "/api/live2d/render", {},
                            json{{"model", model_path}, {"expression", "angry"},
                                 {"width", 512}, {"height", 512}});
    CHECK(miss.status == 200);
    CHECK(miss.json_payload["ok"] == false);
    CHECK(miss.json_payload["error"] == "renderer unavailable");

    // 预置 stub 产物（dirname(model)/_cached_<expr>.png，与 live2d_renderer.cpp
    // 占位实现的缓存路径耦合）-> 成功信封携带 base64 PNG
    {
        std::ofstream f(models_dir.parent_path() / "_cached_happy.png", std::ios::binary);
        f << "fakepng";
    }
    auto ok = call_router(r, "POST", "/api/live2d/render", {},
                          json{{"model", model_path}, {"expression", "happy"}});
    CHECK(ok.status == 200);
    CHECK(ok.json_payload["ok"] == true);
    CHECK(ok.json_payload["mime"] == "image/png");
    CHECK(ok.json_payload["data"] == "ZmFrZXBuZw==");  // b64("fakepng")

    sa_core::paths::setenv_utf8("EDITOR_GAME_ROOT", prev);  // 还原（prev 为空即清）
}
