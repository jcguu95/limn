#include "limn_engine_mupdf.h"

#include "book.h"          // TocNode, PdfLink, ParsedUri
#include "document.h"      // Document
#include "utils.h"         // parse_uri

#include <mupdf/fitz.h>
#include <cfloat>
#include <cmath>
#include <cstring>
#include <limits>
#include <QByteArray>
#include <QJsonValue>
#include <QString>
#include <QVector>

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
    a.append("buffer/search");                  // v0.27
    return a;
}

// ─────────────────────────────────────────────────────────────────────────
// v0.27: full-document text search.
// v0.39.11 A4: also includes a parallel :texts array, one excerpt per
// rect — the full line of source text that contains the hit.  Used by
// pdf-isearch-narrow / pdf-isearch-fuzzy to filter hits client-side.
// ─────────────────────────────────────────────────────────────────────────

// v0.39.11 helper: collect lines on a page as {text, bbox} pairs.
// Lines are the natural unit for "context" around a hit — they read
// well as excerpts and don't fragment mid-word like single rects can.
struct PageLine {
    QString text;
    fz_rect bbox;
};

static QVector<PageLine> collect_page_lines(Document* doc, int page) {
    QVector<PageLine> out;
    if (!doc) return out;
    fz_stext_page* stext = nullptr;
    fz_try(mupdf_context) {
        stext = doc->get_stext_with_page_number(mupdf_context, page);
    } fz_catch(mupdf_context) {
        return out;
    }
    if (!stext) return out;
    for (fz_stext_block* block = stext->first_block; block; block = block->next) {
        if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
        for (fz_stext_line* line = block->u.t.first_line; line; line = line->next) {
            QString buf;
            fz_rect lb = {FLT_MAX, FLT_MAX, -FLT_MAX, -FLT_MAX};
            for (fz_stext_char* ch = line->first_char; ch; ch = ch->next) {
                const int c = ch->c;
                if (c <= 0x10FFFF) buf.append(QChar(static_cast<uint>(c)));
                double cx0, cy0, cx1, cy1;
                quad_to_rect(ch->quad, cx0, cy0, cx1, cy1);
                lb.x0 = std::min<float>(lb.x0, cx0);
                lb.y0 = std::min<float>(lb.y0, cy0);
                lb.x1 = std::max<float>(lb.x1, cx1);
                lb.y1 = std::max<float>(lb.y1, cy1);
            }
            if (!buf.isEmpty() && lb.x1 > lb.x0 && lb.y1 > lb.y0) {
                out.append({buf, lb});
            }
        }
    }
    return out;
}

// v0.39.11 helper: given a hit quad and the page's lines, pick the line
// whose bbox vertically contains the hit center.  Falls back to the
// closest line by vertical distance when no line strictly encloses it.
static QString line_text_for_hit(const QVector<PageLine>& lines,
                                  const fz_quad& q) {
    if (lines.isEmpty()) return QString();
    double hx0, hy0, hx1, hy1;
    quad_to_rect(q, hx0, hy0, hx1, hy1);
    const double hcy = 0.5 * (hy0 + hy1);
    const double hcx = 0.5 * (hx0 + hx1);
    for (const PageLine& l : lines) {
        if (hcy >= l.bbox.y0 && hcy <= l.bbox.y1) return l.text;
    }
    double best = std::numeric_limits<double>::infinity();
    QString best_text;
    for (const PageLine& l : lines) {
        const double cy = 0.5 * (l.bbox.y0 + l.bbox.y1);
        const double d  = std::abs(cy - hcy);
        const bool x_in = (hcx >= l.bbox.x0 && hcx <= l.bbox.x1);
        const double penalty = x_in ? 0.0 : 1.0;
        const double score = d + penalty;
        if (score < best) { best = score; best_text = l.text; }
    }
    return best_text;
}

QJsonObject extract_search_hits(Document* doc,
                                 const QString& query,
                                 bool case_sensitive) {
    Q_UNUSED(case_sensitive);   // MuPDF's needle match is ASCII-case-insensitive
    QJsonObject result;
    QJsonArray hits;
    if (!doc || query.isEmpty()) {
        result.insert("hits", hits);
        return result;
    }

    const QByteArray needle_bytes = query.toUtf8();
    const char* needle = needle_bytes.constData();
    const int n_pages = doc->num_pages();
    constexpr int kHitMax = 64;        // per-page hit cap

    for (int page = 0; page < n_pages; ++page) {
        fz_quad quads[kHitMax];
        int hit_n = 0;
        fz_try(mupdf_context) {
            hit_n = fz_search_page_number(mupdf_context, doc->doc, page,
                                           needle, nullptr, quads, kHitMax);
        } fz_catch(mupdf_context) {
            hit_n = 0;  // skip pages MuPDF refuses to search
        }
        if (hit_n <= 0) continue;

        // Normalize quad coordinates from MuPDF page-point space to [0,1]²
        // so that view/overlays (which uses page-norm coords) can position
        // highlights correctly. MuPDF page space: Y=0 at top, Y increases
        // downward — same orientation as the overlay renderer, so no Y flip
        // is needed; just divide by page dimensions.
        fz_rect pb = {0, 0, 1, 1};   // safe fallback: unit rect (pass-through)
        fz_try(mupdf_context) {
            fz_page* p = fz_load_page(mupdf_context, doc->doc, page);
            pb = fz_bound_page(mupdf_context, p);
            fz_drop_page(mupdf_context, p);
        } fz_catch(mupdf_context) { /* keep unit rect */ }
        const double pw = (pb.x1 > pb.x0) ? (pb.x1 - pb.x0) : 1.0;
        const double ph = (pb.y1 > pb.y0) ? (pb.y1 - pb.y0) : 1.0;

        // v0.39.11 A4: collect lines so we can attach an excerpt
        // (the full line containing each hit) to enable client-side
        // narrowing / fuzzy filtering without a second wire round-trip.
        // Lines are page-point space (same as the hit quads), so the
        // bbox comparison is direct.
        QVector<PageLine> lines = collect_page_lines(doc, page);

        QJsonArray rects;
        QJsonArray texts;          // v0.39.11 A4 — parallel to rects
        for (int i = 0; i < hit_n; ++i) {
            double x0, y0, x1, y1;
            quad_to_rect(quads[i], x0, y0, x1, y1);
            // Normalize to [0,1]² (page-norm coords expected by view/overlays).
            x0 = (x0 - pb.x0) / pw;
            y0 = (y0 - pb.y0) / ph;
            x1 = (x1 - pb.x0) / pw;
            y1 = (y1 - pb.y0) / ph;
            rects.append(rect_to_json(x0, y0, x1, y1));
            texts.append(line_text_for_hit(lines, quads[i]));
        }
        QJsonObject h;
        h.insert("page", page);
        h.insert("rects", rects);
        h.insert("texts", texts);  // v0.39.11 A4 — parallel to rects
        hits.append(h);
    }
    result.insert("hits", hits);
    return result;
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

// v0.39 W05 honest fix — render a page with the focused window's
// view state applied (dark mode, rotation) and return a QImage.
//
// Pre-v0.39, test/grab-window used QWidget::grab() on the MainWidget,
// which on a QOpenGLWidget child in headless Xvfb returns the bare
// widget chrome WITHOUT the actual PDF render — so dark-mode toggle
// looked identical pixel-for-pixel and the W05 driver had to skip
// the pixel evidence check (relying on view/get state round-trip
// alone).  Rendering via mupdf here sidesteps the GL context
// entirely and produces a deterministic image that legitimately
// changes when dark-mode flips.
//
// Dark mode applies as a post-render colour inversion (mupdf has
// fz_invert_pixmap), matching what the OpenGL fragment shader does
// in production.  Rotation is folded into the matrix (90/180/270
// supported; arbitrary degrees would work too but we never use them).
QImage render_page_with_view_state(Document* doc, int page, int dpi,
                                    bool dark_mode, int rotation) {
    if (!doc || !doc->doc) return QImage();
    if (page < 0 || page >= doc->num_pages()) return QImage();
    if (dpi <= 0 || dpi > 1200) return QImage();

    fz_context* ctx = mupdf_context;
    fz_page*    p   = nullptr;
    fz_pixmap*  pix = nullptr;

    fz_var(p); fz_var(pix);

    QImage out;

    fz_try(ctx) {
        p = fz_load_page(ctx, doc->doc, page);
        if (!p) fz_throw(ctx, FZ_ERROR_GENERIC, "could not load page");

        const float    scale     = static_cast<float>(dpi) / 72.0f;
        const int      rot       = ((rotation % 360) + 360) % 360;
        const fz_matrix transform = fz_concat(fz_rotate(static_cast<float>(rot)),
                                              fz_scale(scale, scale));

        pix = fz_new_pixmap_from_page(
            ctx, p, transform, fz_device_rgb(ctx), 0);
        if (!pix) fz_throw(ctx, FZ_ERROR_GENERIC, "pixmap render failed");

        if (dark_mode) {
            // Invert RGB in place; alpha untouched.  Matches the
            // production OpenGL "dark mode" shader (1.0 - color).
            fz_invert_pixmap(ctx, pix);
        }

        // Copy into a QImage we own (mupdf pixmap is dropped in fz_always).
        // fz_pixmap is RGB or RGBA; we forced device_rgb above with alpha=0,
        // so 3 bytes/pixel, row stride = w * 3 (no padding from mupdf).
        const int w      = fz_pixmap_width(ctx, pix);
        const int h      = fz_pixmap_height(ctx, pix);
        const int stride = fz_pixmap_stride(ctx, pix);
        const unsigned char* samples = fz_pixmap_samples(ctx, pix);

        QImage tmp(w, h, QImage::Format_RGB888);
        // Source stride may equal w*3 (typical) or be padded — copy
        // row by row to be safe.
        for (int y = 0; y < h; ++y) {
            std::memcpy(tmp.scanLine(y),
                        samples + y * stride,
                        std::min(stride, w * 3));
        }
        // Convert to ARGB32 so callers can use QRgb / qRed / qGreen etc.
        out = tmp.convertToFormat(QImage::Format_ARGB32);
    } fz_always(ctx) {
        if (pix) fz_drop_pixmap(ctx, pix);
        if (p)   fz_drop_page(ctx, p);
    } fz_catch(ctx) {
        // Swallow; out stays null and caller decides what to do.
    }
    return out;
}

}  // namespace LimnMupdf
