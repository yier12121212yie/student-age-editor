// wip/P3b — port of backend/editor/server/resource_pack.py (zip-based
// extension packs: install / list / activate / uninstall / info).
//
// All zip work goes through the vendored miniz reader (brief §4): install
// validates every member name first (the Python _install_zip check), then
// extracts via ZipReader::extract_all.
//
// Deviations (documented for the report):
//   * system_packs_root(): Python gates on sys.frozen; a native build is
//     never "frozen" -> "" (dev behaviour identical). EDITOR_SYSTEM_PACK_ROOT
//     can inject a read-only root for packaged builds later.
//   * the "alt" first-run copy source (<backend editor dir>/data/resource_packs)
//     does not exist in this repo; the port anchors it at
//     <editor_root>/../data/resource_packs so the branch exists but never
//     fires in dev/golden runs.
//   * Python iterates `for pid in existing` over a SET (hash-random order);
//     the port iterates sorted — deterministic superset of the contract.
#pragma once

#include <stdexcept>
#include <string>

#include <nlohmann/json.hpp>

namespace sa {
namespace p3b {
using json = nlohmann::ordered_json;

// Python ValueError analogue inside this service (routes render it as the
// 400 {"error": str(e)} envelope; anything else becomes a 500 envelope).
struct PyValueError : std::runtime_error {
    explicit PyValueError(const std::string& msg) : std::runtime_error(msg) {}
};

namespace resource_pack {

// packs_root(): EDITOR_PACKS_ROOT or <editor_root()>/_cache/resource_packs
// (created best-effort; alt-copy when still empty).
std::string packs_root();
std::string system_packs_root();
std::string meta_path();

json list_packs();                        // {"active": str, "packs": [...]}
json set_active(const std::string& id);   // throws std::invalid_argument(ValueError)
json install_pack_bytes(std::string_view zip_bytes, const std::string& filename);
json install_pack_from_path(const std::string& path, const std::string& filename);
json uninstall_pack(const std::string& pack_id);
json get_pack_info(const std::string& pack_id);  // null json when unknown

// _pack_id_from_name (exposed for [p3b] tests).
std::string pack_id_from_name(const std::string& name);

}  // namespace resource_pack
}  // namespace p3b
}  // namespace sa
