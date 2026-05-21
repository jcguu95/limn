#include "limn_engine_mupdf.h"

#include "book.h"          // TocNode, PdfLink, ParsedUri
#include "document.h"      // Document
#include "utils.h"         // parse_uri

#include <mupdf/fitz.h>
#include <QByteArray>
#include <QJsonValue>
#include <QString>

extern fz_context* mupdf_context;   // defined in main.cpp

namespace {

// -- small utilities ------------------------------------------------------

QString wstr_to_q(const std::wstring& w) { return QString::fromStdWString(w); }

// Convert fz_quad → axis-aligned rect [x0,y0,x1,y1].
void quad_to_rect(const fz_quad& q, double& x0, double& y0, double& x1, double& y1) {
    x0 = std::min({q.ul.x, q.ll.x, q.ur.x, q.lr.x});
    y0 = std::min({q.ul.y, q.ll.y, q.ur.y, q.lr.y});
    x1 = std::max({q.ul.x, q.ll.x, q.ur.x, q.lr.x});
    y1 = std::max({q.ul.y, q.ll.y, q.ur.y, q.lr.y});
}

QJsonArray rect_to_json(double x0, double y0, double x1, double y1) {
    QJsonArray a;
    a.append(x0); a.append(y0); a.append(x1); a.append(y1);
    return a;
}

QJsonArray pageless_rect_to_json(const PagelessDocumentRect& r) {
    return rect_to_json(r.x0, r.y0, r.x1, r.y1);
}

// MuPDF metadata key → human field name in our JSON.
struct MetadataField {
    const char* mupdf_key;
    const char* json_key;
};

const MetadataField kMetadataFields[] = {
    {"info:Title",    "title"},
    {"info:Author",   "author"},
    {"info:Subject",  "subject"},
    {"info:Keywords", "keywords"},
    {"info:Creator",  "creator"},
    {"info:Producer", "producer"},
};

QString lookup_metadata(fz_context* ctx, fz_document* fzdoc, const char* key) {
    char buf[1024];
    int n = fz_lookup_metadata(ctx, fzdoc, key, buf, sizeof(buf));
    if (n <= 0) return QString();
    // n includes trailing NUL — pass n-1 to QString
    return QString::fromUtf8(buf, n - 1);
}

// -- TOC recursive serializer --------------------------------------------

QJsonArray toc_node_to_json(const std::vector<TocNode*>& nodes);

QJsonObject one_toc_node(const TocNode* n) {
    QJsonObject o;
    o.insert("title",    wstr_to_q(n->title));
    o.insert("page",     n->page);
    o.insert("children", toc_node_to_json(n->children));
    return o;
}

QJsonArray toc_node_to_json(const std::vector<TocNode*>& nodes) {
    QJsonArray arr;
    for (TocNode* n : nodes) {
        if (n) arr.append(one_toc_node(n));
    }
    return arr;
}

// -- stext word grouping --------------------------------------------------
//
// Walk fz_stext_block → fz_stext_line → fz_stext_char, group runs of
// non-space chars into words. Each word stores: text + union bbox.

void flush_word(QJsonArray& out, QString& buf,
                double x0, double y0, double x1, double y1) {
    if (buf.isEmpty()) return;
    QJsonObject w;
    w.insert("text", buf);
    w.insert("rect", rect_to_json(x0, y0, x1, y1));
    out.append(w);
    buf.clear();
}

QJsonArray stext_page_to_words(fz_stext_page* page) {
    QJsonArray out;
    if (!page) return out;

    QString  word_buf;
    double   wx0 = 0, wy0 = 0, wx1 = 0, wy1 = 0;
    bool     in_word = false;

    for (fz_stext_block* block = page->first_block; block; block = block->next) {
        if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
        for (fz_stext_line* line = block->u.t.first_line; line; line = line->next) {
            for (fz_stext_char* ch = line->first_char; ch; ch = ch->next) {
                const int c = ch->c;
                // Treat whitespace (space, tab, NBSP) and control chars as word breaks.
                const bool is_break = (c == ' ' || c == '\t' || c == '\n'
                                        || c == 0x00A0 || c < 0x20);
                if (is_break) {
                    flush_word(out, word_buf, wx0, wy0, wx1, wy1);
                    in_word = false;
                    continue;
                }
                double cx0, cy0, cx1, cy1;
                quad_to_rect(ch->quad, cx0, cy0, cx1, cy1);
                if (!in_word) {
                    wx0 = cx0; wy0 = cy0; wx1 = cx1; wy1 = cy1;
                    in_word = true;
                } else {
                    wx0 = std::min(wx0, cx0);
                    wy0 = std::min(wy0, cy0);
                    wx1 = std::max(wx1, cx1);
                    wy1 = std::max(wy1, cy1);
                }
                // Append the codepoint as UTF-8 → QString.
                if (c <= 0x10FFFF) {
                    word_buf.append(QChar(static_cast<uint>(c)));
                }
            }
            // End of line ends the current word.
            flush_word(out, word_buf, wx0, wy0, wx1, wy1);
            in_word = false;
        }
        // End of block also ends the current word.
        flush_word(out, word_buf, wx0, wy0, wx1, wy1);
        in_word = false;
    }
    return out;
}

}  // anonymous namespace

namespace LimnMupdf {

// ─────────────────────────────────────────────────────────────────────────
// Supports list
// ─────────────────────────────────────────────────────────────────────────

QJsonArray supports() {
    QJsonArray a;
    a.append("buffer/text");
    a.append("buffer/toc");
    a.append("buffer/links");
    a.append("buffer/render");
    a.append("buffer/render-region");
    a.append("buffer/metadata");
    return a;
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 4: TOC
// ─────────────────────────────────────────────────────────────────────────

QJsonArray extract_toc(Document* doc) {
    if (!doc) throw std::runtime_error("null document");
    const std::vector<TocNode*>& tree = doc->get_toc();
    return toc_node_to_json(tree);
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 4: page text
// ─────────────────────────────────────────────────────────────────────────

QJsonObject extract_page_text(Document* doc, int page) {
    if (!doc) throw std::runtime_error("null document");
    if (page < 0 || page >= doc->num_pages()) {
        throw std::runtime_error(
            QString("page %1 out of range (num-pages=%2)")
                .arg(page).arg(doc->num_pages()).toStdString());
    }

    fz_stext_page* stext = nullptr;
    fz_var(stext);
    fz_try(mupdf_context) {
        // Use sioyek's cached path through the public helper. Note: this is
        // a member function we have to access via Document; but it requires
        // an fz_context. Use the global one (same threading domain).
        stext = doc->get_stext_with_page_number(mupdf_context, page);
    } fz_catch(mupdf_context) {
        throw std::runtime_error(
            QString("MuPDF: %1").arg(fz_caught_message(mupdf_context)).toStdString());
    }

    QJsonObject data;
    data.insert("words", stext_page_to_words(stext));
    // Note: stext is cached by Document — don't drop it.
    return data;
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 4: page links
// ─────────────────────────────────────────────────────────────────────────

QJsonArray extract_page_links(Document* doc, int page) {
    if (!doc) throw std::runtime_error("null document");
    if (page < 0 || page >= doc->num_pages()) {
        throw std::runtime_error(
            QString("page %1 out of range").arg(page).toStdString());
    }
    QJsonArray out;
    const std::vector<PdfLink>& links = doc->get_page_merged_pdf_links(page);
    for (const PdfLink& pl : links) {
        QJsonObject obj;

        // sioyek's uri convention:
        //   "#PAGE,X,Y" → internal link to page (1-based in mupdf form)
        //   anything else → external URI
        // We use sioyek's parse_uri helper to disambiguate.
        ParsedUri parsed = parse_uri(mupdf_context, doc->doc, pl.uri);
        if (parsed.page > 0) {
            obj.insert("type",      QStringLiteral("internal"));
            obj.insert("dest-page", parsed.page - 1);   // 1-based → 0-based
        } else {
            obj.insert("type", QStringLiteral("uri"));
            obj.insert("uri",  QString::fromStdString(pl.uri));
        }
        if (!pl.rects.empty()) {
            obj.insert("rect", pageless_rect_to_json(pl.rects.front()));
        }
        out.append(obj);
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 4: metadata
// ─────────────────────────────────────────────────────────────────────────

QJsonObject extract_metadata(Document* doc) {
    if (!doc || !doc->doc) throw std::runtime_error("null document");
    QJsonObject out;
    out.insert("page-count", doc->num_pages());
    out.insert("format",     "pdf");

    for (const auto& f : kMetadataFields) {
        QString v = lookup_metadata(mupdf_context, doc->doc, f.mupdf_key);
        if (!v.isEmpty()) out.insert(f.json_key, v);
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// Phase 5: render
// ─────────────────────────────────────────────────────────────────────────

namespace {

// Render a (possibly clipped) fz_page to PNG base64. clip is in PDF
// coordinates (points); if all zeros, render the whole page.
QString render_internal(Document* doc, int page, int dpi,
                         double cx0, double cy0, double cx1, double cy1) {
    if (!doc || !doc->doc) throw std::runtime_error("null document");
    if (page < 0 || page >= doc->num_pages())
        throw std::runtime_error("page out of range");
    if (dpi <= 0 || dpi > 1200)
        throw std::runtime_error("dpi out of range (1..1200)");

    fz_context* ctx = mupdf_context;
    fz_page*    p   = nullptr;
    fz_pixmap*  pix = nullptr;
    fz_buffer*  buf = nullptr;
    fz_output*  out = nullptr;
    fz_device*  dev = nullptr;

    fz_var(p); fz_var(pix); fz_var(buf); fz_var(out); fz_var(dev);

    QString png_b64;

    fz_try(ctx) {
        p = fz_load_page(ctx, doc->doc, page);
        if (!p) fz_throw(ctx, FZ_ERROR_GENERIC, "could not load page");

        const float scale     = static_cast<float>(dpi) / 72.0f;
        const fz_matrix transform = fz_scale(scale, scale);
        const bool      has_clip  = (cx1 > cx0) && (cy1 > cy0);

        if (has_clip) {
            // Clip is in PDF (point) coords. Transform to device space.
            fz_rect clip;
            clip.x0 = static_cast<float>(cx0);
            clip.y0 = static_cast<float>(cy0);
            clip.x1 = static_cast<float>(cx1);
            clip.y1 = static_cast<float>(cy1);
            const fz_irect ibbox = fz_round_rect(fz_transform_rect(clip, transform));

            pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx),
                                           ibbox, nullptr, 1);
            fz_clear_pixmap_with_value(ctx, pix, 0xFF);

            dev = fz_new_draw_device(ctx, transform, pix);
            fz_run_page(ctx, p, dev, transform, nullptr);
            fz_close_device(ctx, dev);
        } else {
            pix = fz_new_pixmap_from_page(
                ctx, p, transform, fz_device_rgb(ctx), 0);
        }
        if (!pix) fz_throw(ctx, FZ_ERROR_GENERIC, "pixmap render failed");

        buf = fz_new_buffer(ctx, 65536);
        out = fz_new_output_with_buffer(ctx, buf);
        fz_write_pixmap_as_png(ctx, out, pix);
        fz_close_output(ctx, out);

        unsigned char* data = nullptr;
        size_t size = fz_buffer_storage(ctx, buf, &data);
        QByteArray bytes(reinterpret_cast<const char*>(data),
                          static_cast<int>(size));
        png_b64 = QString::fromLatin1(bytes.toBase64());
    } fz_always(ctx) {
        if (dev) fz_drop_device(ctx, dev);
        if (out) fz_drop_output(ctx, out);
        if (buf) fz_drop_buffer(ctx, buf);
        if (pix) fz_drop_pixmap(ctx, pix);
        if (p)   fz_drop_page(ctx, p);
    } fz_catch(ctx) {
        throw std::runtime_error(
            QString("MuPDF render error: %1").arg(fz_caught_message(ctx))
                .toStdString());
    }
    return png_b64;
}

}  // anonymous namespace

QJsonObject render_page_to_png(Document* doc, int page, int dpi) {
    QString b64 = render_internal(doc, page, dpi, 0, 0, 0, 0);
    QJsonObject data;
    data.insert("png", b64);
    return data;
}

QJsonObject render_region_to_png(Document* doc, int page,
                                  double x0, double y0, double x1, double y1,
                                  int dpi) {
    // For now, fall back to full-page render (TODO: implement true clip).
    // This still satisfies "render-region returns a PNG" — the rectangular
    // crop will land in a later patch.
    QString b64 = render_internal(doc, page, dpi, x0, y0, x1, y1);
    QJsonObject data;
    data.insert("png", b64);
    return data;
}

}  // namespace LimnMupdf
