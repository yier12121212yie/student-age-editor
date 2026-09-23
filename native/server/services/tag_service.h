// server/services/tag_service.h — 资源标签（读时派生，供 /api/assets/* 使用）。
//
// 设计要点（与旧实现的差异，见 git 历史里那份从未编译过的版本）：
//   * 标签**不写进任何产物**：aa_index.json 保持 v3 冻结契约
//     （tools/resource_scan/ARTIFACT_FORMAT.md §1），标签由索引里的键 + bundle
//     路径现算，因此不需要重跑外部 scanner、也不会让旧缓存失效。
//   * 规则按**词元**匹配（用 _ - . / \ 空白切词），而不是旧实现里写死的
//     "_role_" 子串：真实 bundle 名形如
//     ...\StandaloneWindows64\atlas_assets_assets\res\atlas\role_comic_1168c761….bundle，
//     下划线包裹的写法一个都匹配不上，标签只会落兜底分支。
#pragma once

#include <string>
#include <vector>

namespace sa {

class TagService {
  public:
    // section: "tex" | "aud" | "txt"（aa_index 的三个分节，未知值返回空）。
    // key: 规范化资源键（norm_key 的结果，如 "character_sakura_001"）。
    // location: 资源所在 bundle 的完整路径；解码包来源没有 bundle，传空串。
    // 返回：类型标签在前、ID 标签在后，已去重且顺序稳定（首个命中的规则胜出）。
    std::vector<std::string> tags_for(const std::string& section,
                                      const std::string& key,
                                      const std::string& location) const;

    // 类型标签的固定顺序：前端标签云与 /api/assets/tags 的排序基准。
    static const std::vector<std::string>& base_types();
};

}  // namespace sa
