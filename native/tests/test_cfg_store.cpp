// tests/test_cfg_store.cpp — write-pipeline acceptance, ported from
// backend/editor/server/test_cfg_store.py and test_s2_write_path.py.
//
// Every case names its Python origin and pitfall id (CONVENTIONS 10):
// A7 one-read-per-save, A8 snapshot-backed stack, A9 rolling keep=10,
// B2 lossy guard, B3 peek-then-pop, B4 forced LF, B5 BOM preserved,
// B6 digest beats mtime.
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <string>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include "sa_core/atomic_io.h"
#include "sa_core/paths.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/sha1.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"
#include "server/cfg_cache.h"
#include "server/cfg_store.h"
#include "server/perf.h"
#include "test_support.h"

namespace {

namespace cs = sa_core::paths;
using sa::json;
namespace store = sa::cfg_store;

struct StoreFixture {
    std::filesystem::path root, mod_root, cfg_dir, path, history_dir;
    StoreFixture(const std::string& tag) {
        root = sat::make_temp_dir(tag);
        mod_root = root / "mod";
        cfg_dir = mod_root / "Cfgs" / "zh-cn";
        std::filesystem::create_directories(cfg_dir);
        path = cfg_dir / "EvtCfg.json";
        history_dir = mod_root / store::kHistoryDir;
        store::debug_reset_stacks();
        store::set_parse_provider(nullptr);
        sa::reset();
    }
    ~StoreFixture() {
        store::debug_reset_stacks();
        store::set_parse_provider(nullptr);
        sa::reset();
        std::error_code ec;
        std::filesystem::remove_all(root, ec);
    }
    std::string p() const { return sa_core::paths::path_to_utf8(path); }
    std::string other(const std::string& name) const {
        return sa_core::paths::path_to_utf8(cfg_dir / std::filesystem::u8path(name + ".json"));
    }

    // _write_direct (newline="" -> LF, no BOM, indent=2, ensure_ascii=False)
    void write_direct(const json& data, const std::string& pth = "") {
        cs::write_bytes_simple(pth.empty() ? p() : pth, sa_core::py_dumps_indent(data));
    }
    json read_direct(const std::string& pth = "") {
        auto raw = cs::read_bytes(pth.empty() ? p() : pth);
        REQUIRE(raw.has_value());
        auto text = sa_core::decode_utf8_sig_strict(*raw);
        REQUIRE(text.has_value());
        return json::parse(*text);
    }
    std::string raw_bytes(const std::string& pth = "") {
        auto raw = cs::read_bytes(pth.empty() ? p() : pth);
        REQUIRE(raw.has_value());
        return *raw;
    }
};

// Push the mtime forward deterministically (Windows 15.6ms granularity).
void bump_mtime(const std::string& p) {
    auto st = cs::stat(p);
    REQUIRE(st.has_value());
    REQUIRE(cs::set_mtime_ns(p, st->mtime_ns + 1000000000LL));
}

std::string sha1_of_file(const std::string& p) {
    auto raw = cs::read_bytes(p);
    REQUIRE(raw.has_value());
    return sa_core::sha1_hex(*raw);
}

}  // namespace

// ---------------------------------------------------------------------------
// test_cfg_store.py: WriteSnapshotTest
// ---------------------------------------------------------------------------

TEST_CASE("overwrite creates snapshot with old content", "[cfg_store][A9]") {
    StoreFixture fx("cs_snap");
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "old"}}}});
    auto old_mtime = cs::stat(fx.p())->mtime_ns;
    // The Python original sleeps 20ms to guarantee the mtime advance
    // (test_cfg_store.py:48-52); force it backwards deterministically.
    REQUIRE(cs::set_mtime_ns(fx.p(), old_mtime - 1000000000LL));
    old_mtime = cs::stat(fx.p())->mtime_ns;
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "new"}}}});
    CHECK(r["ok"] == true);
    CHECK_FALSE(r["snapshot"].is_null());
    CHECK(r["mtime_ns"].get<long long>() == cs::stat(fx.p())->mtime_ns);
    CHECK(r["mtime_ns"].get<long long>() != old_mtime);
    bool ok = false;
    auto snaps = cs::listdir_sorted(sa_core::paths::path_to_utf8(fx.history_dir), &ok);
    REQUIRE(ok);
    REQUIRE(snaps.size() == 1);
    CHECK(snaps[0].rfind("EvtCfg_", 0) == 0);
    auto snap_text = cs::read_bytes(sa_core::paths::path_to_utf8(fx.history_dir / std::filesystem::u8path(snaps[0])));
    REQUIRE(snap_text.has_value());
    auto parsed = json::parse(sa_core::decode_utf8_sig_strict(*snap_text).value());
    CHECK(parsed == json{{"1", json{{"id", 1}, {"name", "old"}}}});
}

TEST_CASE("create file has no snapshot", "[cfg_store]") {
    StoreFixture fx("cs_create");
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}}}});
    CHECK(r["ok"] == true);
    CHECK(r["snapshot"].is_null());
    CHECK_FALSE(std::filesystem::exists(fx.history_dir));
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}}}});
}

TEST_CASE("snapshot=false skips history", "[cfg_store]") {
    StoreFixture fx("cs_nosnap");
    fx.write_direct(json{{"1", json{{"id", 1}}}});
    auto r = store::write_cfg(fx.p(), json{{"2", json{{"id", 2}}}}, std::nullopt, nullptr, false,
                              /*snapshot=*/false);
    CHECK(r["ok"] == true);
    CHECK(r["snapshot"].is_null());
    CHECK_FALSE(std::filesystem::exists(fx.history_dir));
}

TEST_CASE("flat <mod>/Cfgs layout still snapshots under <mod>/.editor_history",
          "[cfg_store][mod_root_of]") {
    StoreFixture fx("cs_flat");
    auto flat_dir = fx.mod_root / "Cfgs";
    std::filesystem::create_directories(flat_dir);
    std::string flat = sa_core::paths::path_to_utf8(flat_dir / "ItemCfg.json");
    fx.write_direct(json{{"1", json{{"id", 1}}}}, flat);
    auto r = store::write_cfg(flat, json{{"1", json{{"id", 1}, {"name", "x"}}}});
    CHECK(r["ok"] == true);
    CHECK(std::filesystem::exists(fx.history_dir));
}

// ---------------------------------------------------------------------------
// test_cfg_store.py: ConflictDetectionTest
// ---------------------------------------------------------------------------

TEST_CASE("conflict rejected when mtime differs", "[cfg_store][B6]") {
    StoreFixture fx("cs_conf");
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "disk"}}}});
    long long stale = cs::stat(fx.p())->mtime_ns;
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "changed-externally"}}}});
    bump_mtime(fx.p());  // force a different tick (Windows granularity)
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "local"}}}}, stale);
    CHECK(r["ok"] == false);
    CHECK(r["conflict"] == true);
    CHECK(r["mtime_ns"].get<long long>() == cs::stat(fx.p())->mtime_ns);
    CHECK(r["data"] == json{{"1", json{{"id", 1}, {"name", "changed-externally"}}}});
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "changed-externally"}}}});
}

TEST_CASE("matching mtime passes / expect none skips / force overrides", "[cfg_store]") {
    StoreFixture fx("cs_conf2");
    fx.write_direct(json{{"1", json{{"id", 1}}}});
    auto ok = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "ok"}}}},
                               cs::stat(fx.p())->mtime_ns);
    CHECK(ok["ok"] == true);
    auto none = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "no-check"}}}});
    CHECK(none["ok"] == true);

    long long stale = cs::stat(fx.p())->mtime_ns;
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "changed-externally"}}}});
    bump_mtime(fx.p());
    auto forced = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "local"}}}}, stale,
                                   nullptr, /*force=*/true);
    CHECK(forced["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "local"}}}});
}

TEST_CASE("expect_mtime on missing file writes", "[cfg_store]") {
    StoreFixture fx("cs_conf3");
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}}}}, 12345LL);
    CHECK(r["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}}}});
}

// ---------------------------------------------------------------------------
// test_cfg_store.py: UndoRedoTest
// ---------------------------------------------------------------------------

TEST_CASE("undo/redo round trip", "[cfg_store][B3]") {
    StoreFixture fx("cs_ur");
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "v1"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "v2"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "v3"}}}});
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == true);
    CHECK(r["data"] == json{{"1", json{{"id", 1}, {"name", "v2"}}}});
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "v2"}}}});
    store::undo(fx.p());
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "v1"}}}});
    auto none = store::undo(fx.p());
    CHECK(none["ok"] == false);
    CHECK(none["error"] == "nothing to undo");
    auto rr = store::redo(fx.p());
    CHECK(rr["ok"] == true);
    CHECK(rr["data"] == json{{"1", json{{"id", 1}, {"name", "v2"}}}});
    store::redo(fx.p());
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "v3"}}}});
    CHECK(store::redo(fx.p())["ok"] == false);
}

TEST_CASE("new write clears redo", "[cfg_store]") {
    StoreFixture fx("cs_redo");
    fx.write_direct(json{{"1", json{{"id", 1}, {"name", "v1"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "v2"}}}});
    store::undo(fx.p());
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "v3"}}}});
    CHECK(store::redo(fx.p())["ok"] == false);
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}, {"name", "v3"}}}});
}

TEST_CASE("undo of a create removes the file", "[cfg_store][A8]") {
    StoreFixture fx("cs_undo_create");
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}}}});
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == true);
    CHECK_FALSE(std::filesystem::exists(fx.path));
    CHECK(r["data"].is_null());
    auto rr = store::redo(fx.p());
    CHECK(rr["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}}}});
}

TEST_CASE("undo stack limit prunes oldest; disk keep=10 governs depth",
          "[cfg_store][A9][HISTORY_LIMIT]") {
    StoreFixture fx("cs_limit");
    fx.write_direct(json{{"0", json{{"id", 0}}}});
    for (int i = 1; i <= store::kHistoryLimit + 5; ++i) {
        store::write_cfg(fx.p(), json{{"i", i}});
    }
    for (int k = 0; k < store::kHistoryKeep; ++k) {
        auto r = store::undo(fx.p());
        REQUIRE(r["ok"] == true);
    }
    auto cur = fx.read_direct();
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == false);
    CHECK(r["error"] == "history snapshot missing");
    CHECK(fx.read_direct() == cur);  // never deletes the file on a safe failure
    CHECK(cur == json{{"i", store::kHistoryLimit + 5 - store::kHistoryKeep}});
}

// ---------------------------------------------------------------------------
// test_cfg_store.py: ListHistoryTest
// ---------------------------------------------------------------------------

TEST_CASE("list_history newest-first and filtered by cfg", "[cfg_store][A9]") {
    StoreFixture fx("cs_hist");
    fx.write_direct(json{{"1", json{{"id", 1}}}});
    for (int i = 0; i < 3; ++i) store::write_cfg(fx.p(), json{{"i", i}});
    std::string other = fx.other("TalkCfg");
    fx.write_direct(json{{"1", json{{"id", 1}}}}, other);
    store::write_cfg(other, json{{"i", 1}});
    auto entries = store::list_history(fx.p());
    REQUIRE(entries.size() == 3);
    long long prev = -1;
    for (const auto& e : entries) {
        CHECK(sa_core::str::starts_with(e["file"].get<std::string>(), "EvtCfg_"));
        if (prev >= 0) CHECK(e["ts"].get<long long>() <= prev);  // ts descending
        prev = e["ts"].get<long long>();
        CHECK(e["size"].get<long long>() > 0);
    }
}

TEST_CASE("list_history empty when no dir", "[cfg_store]") {
    StoreFixture fx("cs_hist0");
    CHECK(store::list_history(fx.p()).empty());
}

// ---------------------------------------------------------------------------
// test_cfg_store.py: RobustDecodeTest
// ---------------------------------------------------------------------------

namespace {
std::string gbk_bytes(const std::string& utf8_text) {
    // Encode U+5B57 U+65E7 ("旧") style CJK text as GBK via the Windows API so
    // the test works on any host ANSI codepage.
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8_text.data(), (int)utf8_text.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8_text.data(), (int)utf8_text.size(), w.data(), n);
    int m = WideCharToMultiByte(936, 0, w.data(), n, nullptr, 0, nullptr, nullptr);
    std::string out(m, '\0');
    WideCharToMultiByte(936, 0, w.data(), n, out.data(), m, nullptr, nullptr);
    return out;
}
}  // namespace

TEST_CASE("write_cfg survives a non-UTF-8 source file", "[cfg_store][B2]") {
    StoreFixture fx("cs_gbk");
    cs::write_bytes_simple(fx.p(), gbk_bytes(R"({"1": {"name": "旧数据"}})"));
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "新"}}}});
    CHECK(r["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"name", "新"}}}});
}

TEST_CASE("undo survives a non-UTF-8 current file", "[cfg_store][B2][B3]") {
    StoreFixture fx("cs_gbk2");
    fx.write_direct(json{{"1", json{{"name", "a"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"name", "b"}}}});
    cs::write_bytes_simple(fx.p(), gbk_bytes(R"({"1": {"name": "外部"}})"));
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == true);
    CHECK(std::filesystem::exists(fx.path));  // decode failure never means "missing"
    CHECK(fx.read_direct() == json{{"1", json{{"name", "a"}}}});
}

TEST_CASE("undo restores BOM bytes from snapshot exactly", "[cfg_store][B5]") {
    StoreFixture fx("cs_bom");
    std::string original = std::string(sa_core::kBom) + R"({"1": {"name": "旧"}})";
    cs::write_bytes_simple(fx.p(), original);
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "新"}}}});
    CHECK(r["ok"] == true);
    store::undo(fx.p());
    CHECK(fx.raw_bytes() == original);
}

TEST_CASE("forget drops the undo stack", "[cfg_store][5.5.7]") {
    StoreFixture fx("cs_forget");
    fx.write_direct(json{{"1", json{{"name", "a"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"name", "b"}}}});
    store::forget(fx.p());
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == false);
    CHECK(r["error"] == "nothing to undo");
    CHECK(fx.read_direct() == json{{"1", json{{"name", "b"}}}});  // disk untouched
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: UnchangedWriteTest (cfg.writes short circuit)
// ---------------------------------------------------------------------------

TEST_CASE("unchanged content: no snapshot, no write, counters stay flat",
          "[s2][unchanged]") {
    StoreFixture fx("s2_unch");
    json data{{"1", json{{"id", 1}, {"name", "same"}}}};
    fx.write_direct(data);
    auto before_bytes = sa::get(sa::lc::kCfgSnapshotBytes);
    long long before_mtime = cs::stat(fx.p())->mtime_ns;
    auto r = store::write_cfg(fx.p(), data);
    CHECK(r["ok"] == true);
    CHECK(r["unchanged"] == true);
    CHECK(r["snapshot"].is_null());
    CHECK(sa::get(sa::lc::kCfgSnapshotBytes) == before_bytes);
    CHECK(sa::get(sa::lc::kCfgSnapshotsWritten) == 0);
    CHECK(sa::get(sa::lc::kCfgWrites) == 0);  // CONVENTIONS 7: short circuit no bump
    CHECK_FALSE(std::filesystem::exists(fx.history_dir));
    CHECK(cs::stat(fx.p())->mtime_ns == before_mtime);  // mtime untouched
}

TEST_CASE("unchanged write does not disturb the undo stack", "[s2][unchanged]") {
    StoreFixture fx("s2_unch2");
    fx.write_direct(json{{"1", json{{"id", 1}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"id", 1}}}});  // unchanged
    store::write_cfg(fx.p(), json{{"2", json{{"id", 2}}}});  // changed
    // Only the real change registered: exactly one undo, and it lands on the
    // pre-change content ({"1":...}); a second undo is already empty.
    auto u = store::undo(fx.p());
    CHECK(u["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"id", 1}}}});
    CHECK(store::undo(fx.p())["ok"] == false);
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: HistoryPruneTest / UndoStackBytesTest
// ---------------------------------------------------------------------------

TEST_CASE("prune keeps newest 10 and spares other tables", "[s2][A9]") {
    StoreFixture fx("s2_prune");
    fx.write_direct(json{{"v", 0}});
    auto r1 = store::write_cfg(fx.p(), json{{"v", 1}});
    std::string first_snap = r1["snapshot"].get<std::string>();
    for (int i = 2; i <= 12; ++i) store::write_cfg(fx.p(), json{{"v", i}});
    auto entries = store::list_history(fx.p());
    REQUIRE(entries.size() == (size_t)store::kHistoryKeep);
    bool first_gone = true;
    for (const auto& e : entries)
        if (e["file"].get<std::string>() == first_snap) first_gone = false;
    CHECK(first_gone);  // oldest deleted
    std::string other = fx.other("TalkCfg");
    fx.write_direct(json{{"1", json{{"id", 1}}}}, other);
    store::write_cfg(other, json{{"2", json{{"id", 2}}}});
    CHECK(store::list_history(other).size() == 1);  // no cross-table pruning
    CHECK(store::list_history(fx.p()).size() == (size_t)store::kHistoryKeep);
}

namespace {
json big_payload(int rows = 400) {
    json out = json::object();
    std::string content = "对白" + std::string(200, 'x');
    for (int i = 0; i < rows; ++i) out[std::to_string(i)] = json{{"id", i}, {"content", content}};
    return out;
}
}  // namespace

TEST_CASE("snapshot writes leave the in-memory stack empty", "[s2][A8]") {
    StoreFixture fx("s2_stack");
    json payload = big_payload();
    fx.write_direct(payload);
    for (int i = 0; i < 3; ++i) {
        json p2 = payload;
        p2[std::to_string(i)] = json{{"id", i}, {"marker", i}};
        auto r = store::write_cfg(fx.p(), p2);
        REQUIRE(r["ok"] == true);
        REQUIRE_FALSE(r["snapshot"].is_null());
    }
    CHECK(store::debug_stack_bytes() == 0);  // A8: no 3x40MB resident text
}

TEST_CASE("snapshot=false writes fall back to in-memory text", "[s2][A8]") {
    StoreFixture fx("s2_stack2");
    fx.write_direct(big_payload());
    for (int i = 0; i < 3; ++i) {
        auto r = store::write_cfg(fx.p(), json{{"i", i}}, std::nullopt, nullptr, false, false);
        REQUIRE(r["ok"] == true);
        REQUIRE(r["snapshot"].is_null());
    }
    CHECK(store::debug_stack_bytes() > 0);
    store::debug_reset_stacks();
    CHECK(store::debug_stack_bytes() == 0);
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: ByteEquivalenceTest (B4/B5)
// ---------------------------------------------------------------------------

TEST_CASE("undo restores original bytes exactly (BOM table)", "[s2][B5][A8]") {
    StoreFixture fx("s2_bytes");
    std::string original =
        std::string(sa_core::kBom) + "{\n  \"1\": {\n    \"id\": 1,\n    \"name\": \"旧\"\n  }\n}";
    cs::write_bytes_simple(fx.p(), original);
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"id", 1}, {"name", "新"}}}});
    REQUIRE(r["ok"] == true);
    CHECK(store::undo(fx.p())["ok"] == true);
    CHECK(fx.raw_bytes() == original);
}

TEST_CASE("save preserves BOM and forces LF", "[s2][B4][B5]") {
    StoreFixture fx("s2_bom");
    cs::write_bytes_simple(fx.p(),
                           std::string(sa_core::kBom) + R"({"1": {"id": 1}})" + "\n");
    auto r = store::write_cfg(fx.p(),
                              json{{"1", json{{"id", 1}, {"name", "新"}}},
                                   {"2", json{{"id", 2}}}});
    REQUIRE(r["ok"] == true);
    auto raw = fx.raw_bytes();
    CHECK(sa_core::starts_with_bom(raw));           // B5 source BOM kept
    CHECK(raw.find("\r\n") == std::string::npos);  // B4 no CRLF drift
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: UndoRestoreFailureTest (B3)
// ---------------------------------------------------------------------------

TEST_CASE("undo restore failure keeps the stack intact", "[s2][B3]") {
    StoreFixture fx("s2_fail");
    fx.write_direct(json{{"1", json{{"name", "v1"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"name", "v2"}}}});
    store::write_cfg(fx.p(), json{{"1", json{{"name", "v3"}}}});
    store::test_hooks::fail_next_restore = true;
    auto r = store::undo(fx.p());
    CHECK(r["ok"] == false);
    CHECK(r["error"].get<std::string>().find("撤销失败") != std::string::npos);
    // Stack NOT consumed: the same undo must succeed once the fault clears.
    auto r2 = store::undo(fx.p());
    CHECK(r2["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"name", "v2"}}}});
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: DigestConflictTest (B6)
// ---------------------------------------------------------------------------

TEST_CASE("digest conflict fires inside one mtime tick", "[s2][B6]") {
    StoreFixture fx("s2_digest");
    fx.write_direct(json{{"1", json{{"name", "v1"}}}});
    std::string stale_digest = sha1_of_file(fx.p());
    long long stale_mtime = cs::stat(fx.p())->mtime_ns;
    fx.write_direct(json{{"1", json{{"name", "changed-externally"}}}});
    REQUIRE(cs::set_mtime_ns(fx.p(), stale_mtime));  // erase the mtime evidence
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "local"}}}}, stale_mtime,
                              &stale_digest);
    CHECK(r["ok"] == false);
    CHECK(r["conflict"] == true);
    CHECK(r["reason"] == "digest");
    CHECK(fx.read_direct() == json{{"1", json{{"name", "changed-externally"}}}});
}

TEST_CASE("matching digest passes", "[s2][B6]") {
    StoreFixture fx("s2_digest2");
    fx.write_direct(json{{"1", json{{"name", "v1"}}}});
    std::string digest = sha1_of_file(fx.p());
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "local"}}}}, std::nullopt, &digest);
    CHECK(r["ok"] == true);
    CHECK(fx.read_direct() == json{{"1", json{{"name", "local"}}}});
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: ApplyPatchTest
// ---------------------------------------------------------------------------

namespace {
struct PatchFixture : StoreFixture {
    PatchFixture() : StoreFixture("s2_patch") {
        write_direct(json{{"1000", json{{"id", 1000}, {"content", "旧"}}},
                          {"1001", json{{"id", 1001}, {"content", "待删"}}}});
    }
};
}  // namespace

TEST_CASE("apply_patch set and remove", "[s2][S2]") {
    PatchFixture fx;
    auto r = store::apply_patch(fx.p(), json{{"1000", json{{"id", 1000}, {"content", "新"}}}},
                                json::array({"1001"}), nullptr);
    REQUIRE(r["ok"] == true);
    CHECK(r["applied"] == json{{"set", 1}, {"remove", 1}});
    CHECK(fx.read_direct() == json{{"1000", json{{"id", 1000}, {"content", "新"}}}});
    CHECK(store::list_history(fx.p()).size() == 1);
}

TEST_CASE("if_match conflict reports keys without data", "[s2][S2]") {
    PatchFixture fx;
    json ifm{{"1000", json{{"id", 1000}, {"content", "过期基线"}}}};
    auto r = store::apply_patch(fx.p(), json{{"1000", json{{"id", 1000}, {"content", "改"}}}},
                                json::array(), &ifm);
    CHECK(r["ok"] == false);
    CHECK(r["conflict"] == true);
    CHECK(r["reason"] == "rows");
    CHECK(r["conflicting_keys"] == json::array({"1000"}));
    CHECK_FALSE(r.contains("data"));  // row conflicts never ship the full table
    CHECK(fx.read_direct()["1000"]["content"] == "旧");
}

TEST_CASE("if_match deep compare passes", "[s2]") {
    PatchFixture fx;
    json ifm{{"1000", json{{"id", 1000}, {"content", "旧"}}},
             {"1001", json{{"id", 1001}, {"content", "待删"}}}};
    auto r = store::apply_patch(fx.p(), json{{"1000", json{{"id", 1000}, {"content", "新"}}}},
                                json::array(), &ifm);
    CHECK(r["ok"] == true);
    CHECK(fx.read_direct()["1000"]["content"] == "新");
}

TEST_CASE("table-level mtime conflict returns disk data", "[s2]") {
    PatchFixture fx;
    long long stale = cs::stat(fx.p())->mtime_ns;
    fx.write_direct(json{{"1", json{{"name", "external"}}}});
    bump_mtime(fx.p());
    auto r = store::apply_patch(fx.p(), json{{"2", json{{"id", 2}}}}, json::array(), nullptr,
                                stale);
    CHECK(r["ok"] == false);
    CHECK(r["conflict"] == true);
    REQUIRE(r.contains("data"));  // table-level conflicts feed the 409 three-way UI
    CHECK(r["data"] == json{{"1", json{{"name", "external"}}}});
}

TEST_CASE("patch values are deep copied", "[s2]") {
    PatchFixture fx;
    json value{{"id", 1002}, {"tags", json::array({"a"})}};
    auto r = store::apply_patch(fx.p(), json{{"1002", value}}, json::array(), nullptr);
    REQUIRE(r["ok"] == true);
    value["tags"].push_back("b");  // mutating the caller's object must not leak
    CHECK(r["data"]["1002"]["tags"] == json::array({"a"}));
    CHECK(fx.read_direct()["1002"]["tags"] == json::array({"a"}));
}

TEST_CASE("apply_patch uses the parse provider", "[s2][S1]") {
    PatchFixture fx;
    auto cached = std::make_shared<const json>(
        json{{"1000", json{{"id", 1000}, {"content", "缓存态"}}}});
    std::string p = fx.p();
    store::set_parse_provider([cached, p](const std::string& path) -> std::optional<store::ProviderHit> {
        if (cs::path_key(path) != cs::path_key(p)) return std::nullopt;
        store::ProviderHit hit;
        hit.data = cached;
        hit.mtime_ns = 12345;
        return hit;
    });
    std::filesystem::remove(fx.path);  // succeeds from cache alone => proves provider use
    auto r = store::apply_patch(fx.p(), json{{"1001", json{{"id", 1001}}}}, json::array(), nullptr);
    REQUIRE(r["ok"] == true);
    CHECK(r["data"]["1000"] == (*cached)["1000"]);
    CHECK(r["data"]["1001"] == json{{"id", 1001}});
    CHECK(fx.read_direct()["1000"] == (*cached)["1000"]);
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: PatchCacheHitCommitSemanticsTest
// (cache hit skips parsing, NOT the raw read)
// ---------------------------------------------------------------------------

namespace {
void register_cache(const std::string& p, std::shared_ptr<const json> data) {
    store::set_parse_provider(
        [data, p](const std::string& path) -> std::optional<store::ProviderHit> {
            if (cs::path_key(path) != cs::path_key(p)) return std::nullopt;
            store::ProviderHit hit;
            hit.data = data;
            hit.mtime_ns = 12345;
            return hit;
        });
}
}  // namespace

TEST_CASE("cache hit still detects the mtime conflict", "[s2][A8][A7]") {
    StoreFixture fx("s2_cachehit1");
    fx.write_direct(json{{"1", json{{"name", "external"}}}});
    long long stale = cs::stat(fx.p())->mtime_ns;
    register_cache(fx.p(), std::make_shared<const json>(json{{"1", json{{"name", "缓存态"}}}}));
    fx.write_direct(json{{"2", json{{"name", "外部改动"}}}});  // external rewrite
    bump_mtime(fx.p());
    auto r = store::apply_patch(fx.p(), json{{"3", json{{"id", 3}}}}, json::array(), nullptr,
                                stale);
    CHECK(r["ok"] == false);
    CHECK(r["conflict"] == true);
    CHECK(r["reason"] == "mtime");
    CHECK(r["data"] == json{{"2", json{{"name", "外部改动"}}}});
}

TEST_CASE("cache hit patch then undo restores previous content", "[s2][A8][A7]") {
    StoreFixture fx("s2_cachehit2");
    json data{{"1000", json{{"id", 1000}, {"content", "旧"}}}};
    fx.write_direct(data);
    register_cache(fx.p(), std::make_shared<const json>(data));
    auto r = store::apply_patch(fx.p(), json{{"1001", json{{"id", 1001}}}}, json::array(), nullptr);
    REQUIRE(r["ok"] == true);
    auto u = store::undo(fx.p());
    CHECK(u["ok"] == true);  // existed=True came from raw read, not from cache
    CHECK(fx.read_direct() == data);
}

// ---------------------------------------------------------------------------
// test_s2_write_path.py: UndoTextFallbackTest / ReadLossyTest
// ---------------------------------------------------------------------------

TEST_CASE("undo text fallback restores the BOM", "[s2][B5][B2]") {
    StoreFixture fx("s2_textbom");
    std::string bom = std::string(sa_core::kBom) +
                      sa_core::py_dumps_indent(json{{"1", json{{"name", "旧"}}}});
    cs::write_bytes_simple(fx.p(), bom);
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "新"}}}}, std::nullopt, nullptr,
                              false, false);
    REQUIRE(r["ok"] == true);
    auto u = store::undo(fx.p());
    REQUIRE(u["ok"] == true);
    auto raw = fx.raw_bytes();
    CHECK(sa_core::starts_with_bom(raw));  // text fallback re-adds the BOM
    CHECK(json::parse(sa_core::decode_utf8_sig_strict(raw).value()) ==
          json{{"1", json{{"name", "旧"}}}});
}

TEST_CASE("redo text fallback restores the BOM", "[s2][B5]") {
    StoreFixture fx("s2_redobom");
    std::string bom = std::string(sa_core::kBom) +
                      sa_core::py_dumps_indent(json{{"1", json{{"name", "旧"}}}});
    cs::write_bytes_simple(fx.p(), bom);
    store::write_cfg(fx.p(), json{{"1", json{{"name", "新"}}}}, std::nullopt, nullptr, false,
                     false);
    REQUIRE(store::undo(fx.p())["ok"] == true);
    auto rd = store::redo(fx.p());
    CHECK(rd["ok"] == true);
    CHECK(sa_core::starts_with_bom(fx.raw_bytes()));
}

TEST_CASE("undo without snapshot on a lossy source fails safely", "[s2][B2]") {
    StoreFixture fx("s2_lossy");
    cs::write_bytes_simple(fx.p(), gbk_bytes(R"({"1": {"name": "旧"}})"));
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "新"}}}}, std::nullopt, nullptr,
                              false, false);
    REQUIRE(r["ok"] == true);
    auto u = store::undo(fx.p());
    CHECK(u["ok"] == false);
    CHECK(u["error"].get<std::string>().find("有损") != std::string::npos);
    CHECK(fx.read_direct() == json{{"1", json{{"name", "新"}}}});  // no U+FFFD written back
}

TEST_CASE("read_lossy: gbk flagged, utf-8 clean, missing is triple-none", "[s2][B2]") {
    StoreFixture fx("s2_lossy_read");
    cs::write_bytes_simple(fx.p(), gbk_bytes(R"({"1": {"name": "旧"}})"));
    auto lr = store::read_lossy(fx.p());
    CHECK(lr.lossy == true);
    CHECK(lr.text->find("\xEF\xBF\xBD") != std::string::npos);  // U+FFFD present
    CHECK(lr.raw == fx.raw_bytes());
    fx.write_direct(json{{"1", json{{"name", "旧"}}}});
    auto clean = store::read_lossy(fx.p());
    CHECK(clean.lossy == false);
    CHECK(json::parse(*clean.text) == json{{"1", json{{"name", "旧"}}}});
    auto missing = store::read_lossy(fx.other("缺"));
    CHECK_FALSE(missing.raw.has_value());
    CHECK_FALSE(missing.text.has_value());
    CHECK(missing.lossy == false);
}

TEST_CASE("undo of a created file with no snapshot unlinks it", "[cfg_store][A8]") {
    StoreFixture fx("cs_undo_text");
    auto r = store::write_cfg(fx.p(), json{{"1", json{{"name", "b"}}}});
    CHECK(r["ok"] == true);  // create: no snapshot
    auto r2 = store::undo(fx.p());
    CHECK(r2["ok"] == true);
    CHECK_FALSE(std::filesystem::exists(fx.path));
}

// ---------------------------------------------------------------------------
// CONVENTIONS 3/5.5 wire-format unit checks that underpin the byte tests
// ---------------------------------------------------------------------------

TEST_CASE("py_dumps_indent matches CPython indent=2 output", "[json][B5]") {
    json j;
    j["1"] = json{{"id", 1}, {"name", "旧"}, {"tags", json::array()}, {"sub", json::object()}};
    j["arr"] = json::array({1, true, nullptr, "x"});
    j["empty"] = json::object();
    std::string s = sa_core::py_dumps_indent(j);
    // Reference captured from `json.dumps(j, ensure_ascii=False, indent=2)`.
    std::string ref = "{\n  \"1\": {\n    \"id\": 1,\n    \"name\": \"旧\",\n"
                      "    \"tags\": [],\n    \"sub\": {}\n  },\n  \"arr\": [\n"
                      "    1,\n    true,\n    null,\n    \"x\"\n  ],\n  \"empty\": {}\n}";
    CHECK(s == ref);
}

TEST_CASE("sha1_hex matches hashlib", "[digest][B6]") {
    CHECK(sa_core::sha1_hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    CHECK(sa_core::sha1_hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d");
    CHECK(sa_core::sha1_hex(std::string(1000000, 'a')) ==
          "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}

TEST_CASE("atomic write naming and content", "[atomic_io][A7]") {
    auto root = sat::make_temp_dir("atomic");
    std::string target = sa_core::paths::path_to_utf8(root / "sub" / "file.json");
    auto n = sa_core::write_bytes_atomic(target, "{\"a\": 1}");
    CHECK(n == 8);  // eight bytes, not seven: the literal includes the space
    auto raw = cs::read_bytes(target);
    REQUIRE(raw.has_value());
    CHECK(*raw == "{\"a\": 1}");
    // replace-on-existing works too
    sa_core::write_bytes_atomic(target, "bom:" + std::string(sa_core::kBom));
    CHECK(sa_core::starts_with_bom(cs::read_bytes(target)->substr(4)));
    // text path forces LF from CRLF input
    sa_core::write_text_atomic(target, "a\r\nb\r\n");
    CHECK(cs::read_bytes(target) == "a\nb\n");
    // unique temp names follow the documented pattern
    std::string tmp = sa_core::unique_tmp_path(target);
    CHECK(sa_core::str::starts_with(tmp, target + ".tmp_"));
    CHECK(tmp.find(".tmp_") + 5 < tmp.size());
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
}

TEST_CASE("atomic write retries through a transient sharing violation", "[atomic_io][B13]") {
    // Hold the target open without share-write (simulating an AV/indexer lock)
    // while atomic_io's rename retry window (5 x 20ms) runs.
#ifdef _WIN32
    auto root = sat::make_temp_dir("atomic_retry");
    std::string target = sa_core::paths::path_to_utf8(root / "held.json");
    cs::write_bytes_simple(target, "old");
    std::wstring wtarget(sa_core::paths::to_path(target).wstring());
    HANDLE h = CreateFileW(wtarget.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    bool threw = false;
    try {
        sa_core::write_bytes_atomic(target, "new", 2, 0.02);  // target locked -> should fail
    } catch (const sa_core::FsError&) {
        threw = true;
    }
    CloseHandle(h);
    CHECK(threw);
    // no temp litter after the failure path
    bool ok = false;
    auto names = cs::listdir_sorted(sa_core::paths::path_to_utf8(root), &ok);
    for (const auto& n : names) CHECK(n.find(".tmp_") == std::string::npos);
    // release the lock -> retry succeeds
    sa_core::write_bytes_atomic(target, "new");
    CHECK(cs::read_bytes(target) == "new");
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
#endif
}

TEST_CASE("decode_utf8_sig_replace: one U+FFFD per maximal subpart", "[utf8][B2]") {
    // b'\xe0\x80' -> two substitutions (maximal-subpart rule, CPython parity)
    CHECK(sa_core::decode_utf8_sig_replace("\xe0\x80") == "\xEF\xBF\xBD\xEF\xBF\xBD");
    // truncated valid prefix -> one substitution
    CHECK(sa_core::decode_utf8_sig_replace("a\xF0\x9F\x98") == "a\xEF\xBF\xBD");
    // valid 4-byte emoji passes through
    CHECK(sa_core::decode_utf8_sig_replace("\xF0\x9F\x98\x80") == "\xF0\x9F\x98\x80");
    // BOM stripped on strict path
    auto strict = sa_core::decode_utf8_sig_strict(std::string(sa_core::kBom) + "x");
    REQUIRE(strict.has_value());
    CHECK(*strict == "x");
    CHECK_FALSE(sa_core::decode_utf8_sig_strict("\xff").has_value());
}
