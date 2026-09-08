// wip/P3b attachment parsing — port of backend/editor/server/ai_files.py.
//
// docx / xlsx via the vendored miniz ZipReader + a hand-rolled XML skeleton
// extractor (ai_files uses xml.etree iterparse/fromstring — no DOM library;
// the C++ port mirrors that implementation scale: elements/attrs/text +
// namespace-prefix resolution, nothing else). txt/md decode utf-8-replace and
// strip a leading BOM; png/jpg get magic-byte checks + base64.
//
// Official layout at merge: server/services/ai_files_p3b.*
#pragma once

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {
namespace p3b {

using json = nlohmann::ordered_json;

// ai_files.UploadError: message goes straight into {"error": ...} (400).
struct UploadError : std::runtime_error {
    explicit UploadError(const std::string& msg) : std::runtime_error(msg) {}
};

inline constexpr long long kUploadMaxFileBytes = 10 * 1024 * 1024;  // MAX_FILE_BYTES
inline constexpr size_t kMaxTextChars = 200000;                     // MAX_TEXT_CHARS
inline constexpr long long kMaxXmlBytes = 50 * 1024 * 1024;        // MAX_XML_BYTES

// ---------------------------------------------------------------------------
// minimal XML skeleton parser (expat-flavoured errors)
// ---------------------------------------------------------------------------

struct XmlElement {
    std::string tag;                                    // "{uri}local" (Clark)
    std::vector<std::pair<std::string, std::string>> attrs;  // declaration order
    std::vector<std::unique_ptr<XmlElement>> children;
    std::string text;  // ALL direct text runs concatenated (deviation vs
                       // el.text/.tail: the consumers here only read leaf
                       // <t>/<v> elements, where the two agree)

    const std::string* find_attr(const std::string& name) const {
        for (const auto& kv : attrs) {
            if (kv.first == name) return &kv.second;
        }
        return nullptr;
    }
    const XmlElement* find_child(const std::string& name) const {
        for (const auto& c : children) {
            if (c->tag == name) return c.get();
        }
        return nullptr;
    }
    // ElementTree .iter(tag): this node and every descendant, document order,
    // only nodes whose tag matches.
    template <typename Fn>
    void iter(const std::string& name, Fn&& fn) const {
        if (tag == name) fn(*this);
        for (const auto& c : children) c->iter(name, fn);
    }
    // Concatenated text of every descendant element with `name` (incl. self
    // when it matches) — the `"".join(t.text for t in si.iter(S_NS+"t"))` idiom.
    std::string concat_text(const std::string& name) const {
        std::string out;
        iter(name, [&](const XmlElement& el) { out += el.text; });
        return out;
    }
};

// Parses well-formed XML (declaration, comments, PIs, DOCTYPE, CDATA and the
// five predefined + numeric entities are handled; namespace prefixes are
// resolved). Returns nullopt where ElementTree would raise ParseError
// (including unbound prefixes and multi-root documents).
std::unique_ptr<XmlElement> xml_parse(std::string_view data);

// ---------------------------------------------------------------------------
// ai_files.parse_file
// ---------------------------------------------------------------------------

// Returns the result dict WITHOUT the "ok" key (the route prepends it):
//   text : {"kind","name","size","text","truncated"}
//   image: {"kind","name","size","mime","data"}
// Throws UploadError for every Python failure mode (bad type / magic / zip /
// XML / missing member / oversize XML member).
json parse_upload_file(const std::string& name, std::string_view raw);

// Exposed for [p3b] unit tests (ai_files internals).
std::string docx_text(std::string_view raw);            // throws UploadError
std::string xlsx_text(std::string_view raw);            // throws UploadError
std::string ext_of_name(const std::string& name);       // ai_files._ext

}  // namespace p3b
}  // namespace sa
