// TagService（server/services/tag_service.*）规则表：[assets]。
//
// 这组用例钉住三件事：
//   1. 规则按**词元**匹配真实 bundle 路径——旧实现要求 "_role_" 这样的下划线
//      包裹子串，而真数据是 ...\atlas\role_comic_1168c761….bundle，一个都匹配不上；
//   2. 固定优先级（首个命中即停）；
//   3. ID 后缀只从 key 取最后一个 >=3 位的数字串，bundle 里的 32 位 hash 绝不参与。
#include <catch_amalgamated.hpp>

#include <string>
#include <vector>

#include "tag_service.h"

using sa::TagService;

namespace {

std::vector<std::string> tags_of(const char* section, const char* key, const char* location) {
    static const TagService svc;
    return svc.tags_for(section, key, location);
}

// 真实形态的 bundle 路径（照 _cache/aa_index/aa_index.json 里的分组编码抄）。
const char* kRoleBundle =
    R"(D:\aa\StandaloneWindows64\atlas_assets_assets\res\atlas\role_comic_1168c761bc507e56b7fb2064d262ee7e.bundle)";
const char* kRole2Bundle =
    R"(D:\aa\StandaloneWindows64\atlas_assets_assets\res\atlas\role2_ec04c6efe2b8761623f406db65226d34.bundle)";
const char* kComicBundle =
    R"(D:\aa\StandaloneWindows64\textures_assets_comic_d3f82cbf211920cffc65dd76902d9ca8.bundle)";
const char* kIconBundle =
    R"(D:\aa\StandaloneWindows64\atlas_assets_assets\res\atlas\icon3_f8d0b4b8fed4df3b60a5a8f12f2890b5.bundle)";
const char* kBgmBundle =
    R"(D:\aa\StandaloneWindows64\audios_assets_bgm_f23e224bdd8d4d1ef898afd4f3236bde.bundle)";
const char* kSfxBundle =
    R"(D:\aa\StandaloneWindows64\audios_assets__93d8d8ed3f5dabca16b589fe23e7b97b.bundle)";

}  // namespace

TEST_CASE("tags: 真实 bundle 路径按词元命中（下划线包裹的旧写法全部失效）", "[assets]") {
    CHECK(tags_of("tex", "role_comic_1", kRoleBundle) == std::vector<std::string>{"role"});
    CHECK(tags_of("tex", "portrait_a", kRole2Bundle) == std::vector<std::string>{"role"});
    CHECK(tags_of("tex", "img_brickgame_tri", kComicBundle) == std::vector<std::string>{"cg"});
    CHECK(tags_of("tex", "icon_1", kIconBundle) == std::vector<std::string>{"ui"});
    CHECK(tags_of("aud", "theme_a", kBgmBundle) == std::vector<std::string>{"bgm"});
    CHECK(tags_of("aud", "jump", kSfxBundle) == std::vector<std::string>{"se"});
    CHECK(tags_of("txt", "personcfg", "") == std::vector<std::string>{"cfg"});
}

TEST_CASE("tags: 词元边界——完全相等或 <词元>+纯数字后缀", "[assets]") {
    // role2_….bundle 的词元是 "role2"：前缀 + 纯数字后缀算命中。
    CHECK(tags_of("tex", "hero", kRole2Bundle) == std::vector<std::string>{"role"});
    // 但 "bgm" 不满足 background 的 "bg"（后缀必须全是数字）。
    CHECK(tags_of("tex", "bgm_theme", "") == std::vector<std::string>{"texture"});
    // 键侧同理：session 不是 se 词元。
    CHECK(tags_of("aud", "session", "") == std::vector<std::string>{"se"});
    // 正常命中 background 的场景键。
    CHECK(tags_of("tex", "scene_open", "") == std::vector<std::string>{"background"});
}

TEST_CASE("tags: 大小写不敏感，分隔符覆盖 _ - . / 反斜杠 与空白", "[assets]") {
    CHECK(tags_of("tex", "Character_Sakura_001", "") ==
          std::vector<std::string>{"role", "role-001"});
    CHECK(tags_of("tex", "UI.Main-Menu", "") == std::vector<std::string>{"ui"});
    CHECK(tags_of("tex", "a\\b/c d", "") == std::vector<std::string>{"texture"});
}

TEST_CASE("tags: 固定优先级，首个命中即停", "[assets]") {
    // role 与 comic 同时出现时 role 胜（规则表第一条）。
    CHECK(tags_of("tex", "role_comic_1", kRoleBundle).front() == "role");
    // role 优先于 atlas/ui。
    CHECK(tags_of("tex", "icon_1", kRoleBundle).front() == "role");
    // 兜底规则在最后：没有任何词元命中才落到 texture。
    CHECK(tags_of("tex", "unknown_asset", "") == std::vector<std::string>{"texture"});
}

TEST_CASE("tags: ID 后缀只取 key 里最后一个 >=3 位的数字串", "[assets]") {
    CHECK(tags_of("tex", "character_sakura_001", "") ==
          std::vector<std::string>{"role", "role-001"});
    CHECK(tags_of("tex", "img_1001_2", "") == std::vector<std::string>{"texture", "texture-1001"});
    CHECK(tags_of("aud", "bgm_theme_789", "") ==
          std::vector<std::string>{"bgm", "bgm-789"});   // 键里的 bgm 词元
    CHECK(tags_of("aud", "jump_789", "") == std::vector<std::string>{"se", "se-789"});
    // 全部数字串都短于 3 位 -> 只有类型标签。
    CHECK(tags_of("tex", "a_12_b", "") == std::vector<std::string>{"texture"});
    // 数字原样保留（不补零），与旧实现 "%02d" 相反。
    CHECK(tags_of("tex", "cg_7", "") == std::vector<std::string>{"cg"});
    CHECK(tags_of("tex", "cg_012", "") == std::vector<std::string>{"cg", "cg-012"});
}

TEST_CASE("tags: bundle 里的 32 位内容 hash 绝不参与 ID", "[assets]") {
    // 键侧没有数字串，只有 bundle 名带 hash -> 不得产出 ID 标签。
    CHECK(tags_of("tex", "hero", kRoleBundle) == std::vector<std::string>{"role"});
    CHECK(tags_of("aud", "theme", kBgmBundle) == std::vector<std::string>{"bgm"});
}

TEST_CASE("tags: 未知分节返回空；base_types 是固定顺序", "[assets]") {
    CHECK(tags_of("nope", "whatever", "").empty());
    CHECK(TagService::base_types() ==
          std::vector<std::string>{"role", "cg", "ui", "background", "texture", "bgm", "se", "cfg"});
}
