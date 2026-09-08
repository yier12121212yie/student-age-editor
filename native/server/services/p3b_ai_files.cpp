// wip/P3b — see p3b_ai_files.h for the contract (port of ai_files.py).
#include "p3b_ai_files.h"

#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <set>

#include "p3b_support.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"
#include "sa_core/util.h"

namespace sa {
namespace p3b {
namespace {

// ai_files namespace URIs (verbatim, Clark-notation form).
const char* kW_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}";
const char* kS_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}";
const char* kR_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}";
const char* kP_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}";

// ---------------------------------------------------------------------------
// XML skeleton parser (elements/attrs/text + namespace scoping, nothing else —
// the same implementation scale as the ElementTree calls it replaces).
// ---------------------------------------------------------------------------

struct XmlParser {
    struct ParseAbort {};  // malformed -> xml_parse() yields nullptr

    std::string_view s;
    size_t i = 0;
    int depth = 0;
    static constexpr int kMaxDepth = 256;

    explicit XmlParser(std::string_view data) : s(data) {}

    [[noreturn]] void fail() { throw ParseAbort{}; }
    bool eof() const { return i >= s.size(); }
    char peek() const { return i < s.size() ? s[i] : '\0'; }
    bool starts(const char* lit) const { return s.compare(i, std::strlen(lit), lit) == 0; }

    void skip_ws() {
        while (!eof()) {
            const char c = s[i];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++i;
            } else {
                break;
            }
        }
    }

    static bool is_name_char(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
               c == '.' || c == '_' || c == '-' || c == ':' ||
               static_cast<unsigned char>(c) >= 0x80;
    }
    std::string read_name() {
        const size_t start = i;
        while (!eof() && is_name_char(s[i])) ++i;
        if (start == i) fail();
        return std::string(s.substr(start, i - start));
    }

    void skip_until(std::string_view lit) {
        const size_t hit = s.find(lit, i);
        if (hit == std::string_view::npos) fail();
        i = hit + lit.size();
    }

    // Skip/consume misc markup: <?pi?>, <!--comment-->, <![CDATA[...]]>
    // (returned as text), <!DOCTYPE ...> (bracket-depth + quoting aware).
    void consume_decl_or_comment(std::string* cdata_out) {
        if (starts("<?")) return skip_until("?>");
        if (starts("<!--")) return skip_until("-->");
        if (starts("<![CDATA[")) {
            i += 9;
            const size_t start = i;
            skip_until("]]>");
            if (cdata_out) cdata_out->append(s.substr(start, i - start - 3));
            return;
        }
        if (starts("<!")) {  // DOCTYPE / entity decls: scan to matching '>'
            size_t j = i + 2;
            int brackets = 0;
            bool quoted = false;
            char q = 0;
            while (j < s.size()) {
                const char c = s[j];
                if (quoted) {
                    if (c == q) quoted = false;
                } else if (c == '"' || c == '\'') {
                    quoted = true;
                    q = c;
                } else if (c == '[') {
                    ++brackets;
                } else if (c == ']') {
                    --brackets;
                } else if (c == '>' && brackets <= 0) {
                    break;
                }
                ++j;
            }
            if (j >= s.size()) fail();
            i = j + 1;
            return;
        }
        fail();
    }

    static std::string decode_entities(std::string_view raw, XmlParser* self) {
        std::string out;
        out.reserve(raw.size());
        for (size_t k = 0; k < raw.size();) {
            if (raw[k] != '&') {
                out.push_back(raw[k]);
                ++k;
                continue;
            }
            const size_t semi = raw.find(';', k + 1);
            if (semi == std::string_view::npos) self->fail();
            const std::string_view ent = raw.substr(k + 1, semi - k - 1);
            if (ent == "amp") {
                out.push_back('&');
            } else if (ent == "lt") {
                out.push_back('<');
            } else if (ent == "gt") {
                out.push_back('>');
            } else if (ent == "quot") {
                out.push_back('"');
            } else if (ent == "apos") {
                out.push_back('\'');
            } else if (ent.size() > 1 && ent[0] == '#') {
                unsigned long cp = 0;
                size_t consumed = 0;
                const bool hex = ent.size() > 2 && (ent[1] == 'x' || ent[1] == 'X');
                try {
                    cp = std::stoul(std::string(ent.substr(hex ? 2 : 1)), &consumed,
                                    hex ? 16 : 10);
                } catch (...) {
                    self->fail();
                }
                const std::string_view digits = ent.substr(hex ? 2 : 1);
                if (consumed != digits.size() || cp > 0x10FFFFu) self->fail();
                sa_core::append_codepoint(out, cp);
            } else {
                self->fail();  // undefined entity: expat raises too
            }
            k = semi + 1;
        }
        return out;
    }

    std::string attr_text(std::string_view raw) { return decode_entities(raw, this); }

    std::unique_ptr<XmlElement> parse_element(
        std::vector<std::map<std::string, std::string>>& scopes) {
        if (++depth > kMaxDepth) fail();
        struct DepthGuard {
            int& d;
            ~DepthGuard() { --d; }
        } guard{depth};

        if (eof() || s[i] != '<') fail();
        ++i;
        const std::string qname = read_name();

        auto node = std::make_unique<XmlElement>();
        std::map<std::string, std::string> local;  // this element's xmlns scope
        std::vector<std::pair<std::string, std::string>> raw_attrs;

        for (;;) {  // attributes
            skip_ws();
            if (eof()) fail();
            if (s[i] == '/' || s[i] == '>') break;
            const std::string aname = read_name();
            skip_ws();
            if (eof() || s[i] != '=') fail();
            ++i;
            skip_ws();
            if (eof() || (s[i] != '"' && s[i] != '\'')) fail();
            const char q = s[i];
            ++i;
            const size_t start = i;
            const size_t close = s.find(q, i);
            if (close == std::string_view::npos) fail();
            i = close + 1;
            raw_attrs.emplace_back(aname, attr_text(s.substr(start, close - start)));
            if (aname == "xmlns") {
                local[""] = raw_attrs.back().second;
            } else if (aname.size() > 6 && aname.compare(0, 6, "xmlns:") == 0) {
                local[aname.substr(6)] = raw_attrs.back().second;
            }
        }

        // default_ns=true applies xmlns to UNPREFIXED names (element tags);
        // attributes must NOT take the default namespace (XML spec — expat and
        // ElementTree leave them bare, so c.get("r")/sheet.get("name") work).
        auto resolveQ = [&](const std::string& name, bool default_ns) -> std::string {
            const size_t colon = name.find(':');
            if (colon == std::string::npos) {
                if (!default_ns) return name;
                for (auto it = scopes.rbegin(); it != scopes.rend(); ++it) {
                    auto f = it->find("");
                    if (f != it->end()) return "{" + f->second + "}" + name;
                }
                return name;
            }
            const std::string prefix = name.substr(0, colon);
            const std::string lname = name.substr(colon + 1);
            if (prefix == "xml") return "{http://www.w3.org/XML/1998/namespace}" + lname;
            if (prefix == "xmlns") return name;
            for (auto it = scopes.rbegin(); it != scopes.rend(); ++it) {
                auto f = it->find(prefix);
                if (f != it->end()) return "{" + f->second + "}" + lname;
            }
            fail();  // unbound prefix: expat not-well-formed
        };
        auto resolve = [&](const std::string& name) { return resolveQ(name, true); };
        auto resolve_attr = [&](const std::string& name) { return resolveQ(name, false); };

        // The element's OWN xmlns declarations are in scope for resolving its
        // own tag and attributes (expat semantics) -> push before resolve().
        scopes.push_back(std::move(local));
        struct ScopeGuard {
            std::vector<std::map<std::string, std::string>>& sc;
            ~ScopeGuard() { sc.pop_back(); }
        } guard2{scopes};

        node->tag = resolve(qname);
        for (const auto& kv : raw_attrs) {
            if (kv.first == "xmlns" || kv.first.compare(0, 6, "xmlns:") == 0) continue;
            node->attrs.emplace_back(resolve_attr(kv.first), kv.second);
        }

        if (s[i] == '/') {  // self-closing
            ++i;
            if (eof() || s[i] != '>') fail();
            ++i;
            return node;
        }
        ++i;  // consume '>'

        for (;;) {  // content
            if (eof()) fail();
            if (s[i] == '<') {
                if (starts("</")) {
                    i += 2;
                    const std::string close_qname = read_name();
                    skip_ws();
                    if (eof() || s[i] != '>') fail();
                    ++i;
                    if (resolve(close_qname) != node->tag) fail();  // tag mismatch
                    break;
                }
                if (starts("<!")) {
                    consume_decl_or_comment(&node->text);  // CDATA -> text
                    continue;
                }
                node->children.push_back(parse_element(scopes));
                continue;
            }
            const size_t start = i;
            while (!eof() && s[i] != '<') ++i;
            node->text += attr_text(s.substr(start, i - start));  // entity decode
            if (eof()) fail();
        }
        return node;
    }
};

}  // namespace

std::unique_ptr<XmlElement> xml_parse(std::string_view data) {
    XmlParser p(data);
    try {
        if (p.s.compare(0, 3, "\xef\xbb\xbf") == 0) p.i = 3;  // leading BOM
        for (;;) {
            p.skip_ws();
            if (p.starts("<?") || p.starts("<!--") || p.starts("<!")) {
                p.consume_decl_or_comment(nullptr);
                continue;
            }
            break;
        }
        if (p.eof() || p.peek() != '<') return nullptr;
        std::vector<std::map<std::string, std::string>> scopes;
        auto root = p.parse_element(scopes);
        for (;;) {  // trailing misc; exactly one root
            p.skip_ws();
            if (p.eof()) break;
            if (p.starts("<?") || p.starts("<!--") || p.starts("<!")) {
                p.consume_decl_or_comment(nullptr);
                continue;
            }
            return nullptr;  // multi-root
        }
        return root;
    } catch (XmlParser::ParseAbort&) {
        return nullptr;
    } catch (const std::exception&) {
        return nullptr;
    }
}

namespace {

// _read_limited: getinfo + size cap + read, mapping every Python failure.
std::string read_limited(const ZipReader& zf, const std::string& name) {
    const auto size = zf.uncompressed_size(name);
    if (!size) throw UploadError("压缩包内缺少文件：" + name);
    if (*size > kMaxXmlBytes) {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%.1f", static_cast<double>(*size) / 1048576.0);
        throw UploadError(std::string("压缩包内文件过大（") + buf + "MB）");
    }
    auto raw = zf.read(name);
    if (!raw) throw UploadError("压缩包内缺少文件：" + name);
    return *raw;
}

// _docx_para_text: p.iter() over W:t / W:tab / W:br in document order.
std::string docx_para_text(const XmlElement& p) {
    std::string out;
    std::function<void(const XmlElement&)> walk = [&](const XmlElement& el) {
        if (el.tag == std::string(kW_NS) + "t") {
            out += el.text;
        } else if (el.tag == std::string(kW_NS) + "tab") {
            out += '\t';
        } else if (el.tag == std::string(kW_NS) + "br") {
            out += '\n';
        }
        for (const auto& c : el.children) walk(*c);
    };
    walk(p);
    return py_strip(out);
}

}  // namespace

std::string docx_text(std::string_view raw) {
    auto zf = ZipReader::open_bytes(raw);
    if (!zf) throw UploadError("docx 文件损坏：无法解压");
    // materialize first: names() returns by value — pairing begin() of one
    // temporary with end() of another is UB (iterator ranges must share a
    // container).
    const std::vector<std::string> name_list = zf->names();
    const std::set<std::string> names(name_list.begin(), name_list.end());
    if (!names.count("word/document.xml")) throw UploadError("docx 文件缺少 word/document.xml");
    auto root = xml_parse(read_limited(*zf, "word/document.xml"));
    if (!root) throw UploadError("docx 文档 XML 解析失败");
    std::vector<std::string> paragraphs;
    // ET.iterparse events=("end",): post-order — nested <p> (table cells) fire
    // before their ancestor, exactly like the Python end-event order.
    std::function<void(const XmlElement&)> collect = [&](const XmlElement& el) {
        for (const auto& c : el.children) collect(*c);
        if (el.tag == std::string(kW_NS) + "p") paragraphs.push_back(docx_para_text(el));
    };
    collect(*root);
    std::vector<std::string> non_empty;
    for (const auto& para : paragraphs) {
        if (!para.empty()) non_empty.push_back(para);
    }
    std::string text;
    for (size_t k = 0; k < non_empty.size(); ++k) {
        if (k) text += '\n';
        text += non_empty[k];
    }
    return text.empty() ? std::string("（docx 未提取到文本内容）") : text;
}

namespace {

// _col_index: "AB12" -> 28 (A=1); no letters+digits prefix -> nullopt.
std::optional<int> col_index(const std::string& ref) {
    size_t k = 0;
    while (k < ref.size() && ((ref[k] >= 'A' && ref[k] <= 'Z') || (ref[k] >= 'a' && ref[k] <= 'z')))
        ++k;
    if (k == 0) return std::nullopt;
    size_t d = k;
    while (d < ref.size() && ref[d] >= '0' && ref[d] <= '9') ++d;
    if (d == k) return std::nullopt;
    int n = 0;
    for (size_t j = 0; j < k; ++j) {
        n = n * 26 + (std::toupper(static_cast<unsigned char>(ref[j])) - 'A' + 1);
    }
    return n;
}

std::string cell_value(const XmlElement& c, const std::vector<std::string>& shared) {
    const std::string* t = c.find_attr("t");
    if (t && *t == "inlineStr") {
        const XmlElement* is_el = c.find_child(std::string(kS_NS) + "is");
        if (is_el) return is_el->concat_text(std::string(kS_NS) + "t");
        return {};
    }
    const XmlElement* v = c.find_child(std::string(kS_NS) + "v");
    if (v == nullptr || v->text.empty()) return {};
    const std::string val = v->text;
    if (t && *t == "s") {
        auto idx = sa_core::py_int(val);
        if (!idx || *idx < 0 || *idx >= static_cast<long long>(shared.size())) return {};
        return shared[static_cast<size_t>(*idx)];
    }
    return val;
}

std::optional<std::vector<std::string>> sheet_lines(const ZipReader& zf, const std::string& path,
                                                    const std::vector<std::string>& shared) {
    auto root = xml_parse(read_limited(zf, path));
    if (!root) return std::nullopt;  // ParseError -> None -> sheet skipped
    std::vector<std::string> rows;
    root->iter(std::string(kS_NS) + "row", [&](const XmlElement& row) {
        std::map<int, std::string> cells;
        int max_col = 0;
        row.iter(std::string(kS_NS) + "c", [&](const XmlElement& c) {
            const std::string* r = c.find_attr("r");
            auto col = col_index(r ? *r : std::string());
            if (!col) return;
            std::string val = cell_value(c, shared);
            if (val != "") {
                cells[*col] = std::move(val);
                if (*col > max_col) max_col = *col;
            }
        });
        if (cells.empty()) return;
        std::string line;
        for (int cnum = 1; cnum <= max_col; ++cnum) {
            if (cnum > 1) line += '\t';
            auto it = cells.find(cnum);
            if (it != cells.end()) line += it->second;
        }
        rows.push_back(std::move(line));
    });
    return rows;
}

std::string join_lines(const std::vector<std::string>& parts) {
    std::string out;
    for (size_t k = 0; k < parts.size(); ++k) {
        if (k) out += '\n';
        out += parts[k];
    }
    return out;
}

}  // namespace

std::string xlsx_text(std::string_view raw) {
    auto zf = ZipReader::open_bytes(raw);
    if (!zf) throw UploadError("xlsx 文件损坏：无法解压");
    const std::vector<std::string> name_list = zf->names();
    const std::set<std::string> names(name_list.begin(), name_list.end());
    if (!names.count("xl/workbook.xml")) throw UploadError("xlsx 文件缺少 xl/workbook.xml");

    auto wb = xml_parse(read_limited(*zf, "xl/workbook.xml"));
    if (!wb) throw UploadError("xlsx workbook.xml 解析失败");

    std::map<std::string, std::string> rels;
    if (names.count("xl/_rels/workbook.xml.rels")) {
        auto rel_root = xml_parse(read_limited(*zf, "xl/_rels/workbook.xml.rels"));
        if (rel_root) {  // ParseError -> rel_root None -> rels stay empty
            rel_root->iter(std::string(kP_NS) + "Relationship", [&](const XmlElement& rel) {
                const std::string* rid = rel.find_attr("Id");
                const std::string* tgt = rel.find_attr("Target");
                if (!rid || rid->empty()) return;
                std::string t = tgt ? *tgt : std::string();
                while (!t.empty() && t.front() == '/') t.erase(t.begin());
                if (t.empty()) return;
                if (t.rfind("xl/", 0) != 0) t = "xl/" + t;
                rels[*rid] = std::move(t);
            });
        }
    }

    // Python dict{name -> path} with insertion order; a repeated sheet name
    // overwrites the path and keeps its first slot.
    std::vector<std::pair<std::string, std::string>> sheet_paths;
    wb->iter(std::string(kS_NS) + "sheet", [&](const XmlElement& sheet) {
        const std::string* name_attr = sheet.find_attr("name");
        std::string name = (name_attr && !name_attr->empty()) ? *name_attr : "Sheet";
        const std::string* rid = sheet.find_attr(std::string(kR_NS) + "id");
        if (!rid) return;
        auto it = rels.find(*rid);
        if (it == rels.end()) return;
        for (auto& sp : sheet_paths) {
            if (sp.first == name) {
                sp.second = it->second;
                return;
            }
        }
        sheet_paths.emplace_back(name, it->second);
    });

    std::vector<std::string> shared;
    if (names.count("xl/sharedStrings.xml")) {
        auto s_root = xml_parse(read_limited(*zf, "xl/sharedStrings.xml"));
        if (s_root) {
            s_root->iter(std::string(kS_NS) + "si", [&](const XmlElement& si) {
                shared.push_back(si.concat_text(std::string(kS_NS) + "t"));
            });
        }
        // ParseError -> shared = [] (default state).
    }

    std::vector<std::string> blocks;
    for (const auto& sp : sheet_paths) {
        if (!names.count(sp.second)) continue;
        auto lines = sheet_lines(*zf, sp.second, shared);
        if (!lines) continue;
        blocks.push_back("【工作表：" + sp.first + "】");
        for (auto& l : *lines) blocks.push_back(std::move(l));
    }
    const std::string text = join_lines(blocks);
    return text.empty() ? std::string("（xlsx 未提取到文本内容）") : text;
}

std::string ext_of_name(const std::string& name) {
    // ai_files._ext: name.rsplit(".",1)[-1].lower() if "." in name else ""
    const size_t dot = name.rfind('.');
    if (dot == std::string::npos) return {};
    return sa_core::str::lower(name.substr(dot + 1));
}

json parse_upload_file(const std::string& name, std::string_view raw) {
    const std::string ext = ext_of_name(name);
    json out = json::object();
    if (ext == "txt" || ext == "md" || ext == "docx" || ext == "xlsx") {
        std::string text;
        if (ext == "txt" || ext == "md") {
            // raw.decode("utf-8", errors="replace") + leading-BOM drop
            text = sa_core::decode_utf8_sig_replace(raw);
        } else if (ext == "docx") {
            text = docx_text(raw);
        } else {
            text = xlsx_text(raw);
        }
        const bool truncated = utf8_len(text) > kMaxTextChars;
        out["kind"] = "text";
        out["name"] = name;
        out["size"] = static_cast<long long>(raw.size());
        out["text"] = utf8_head(text, kMaxTextChars);
        out["truncated"] = truncated;
        return out;
    }
    if (ext == "png" || ext == "jpg" || ext == "jpeg") {
        if (ext == "png" && !raw.starts_with("\x89PNG\r\n\x1a\n")) {
            throw UploadError("文件不是有效的 PNG 图片");
        }
        if ((ext == "jpg" || ext == "jpeg") && !raw.starts_with("\xff\xd8\xff")) {
            throw UploadError("文件不是有效的 JPG 图片");
        }
        out["kind"] = "image";
        out["name"] = name;
        out["size"] = static_cast<long long>(raw.size());
        out["mime"] = ext == "png" ? "image/png" : "image/jpeg";
        out["data"] = b64_encode(raw);
        return out;
    }
    throw UploadError("不支持的文件类型：" + (ext.empty() ? std::string("无扩展名") : ext) +
                      "（支持 docx / txt / md / xlsx / png / jpg）");
}

}  // namespace p3b
}  // namespace sa
