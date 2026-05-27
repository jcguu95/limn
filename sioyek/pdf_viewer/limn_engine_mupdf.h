#pragma once
//
// LimnMupdf — MuPDF-specific helpers used by Phase 4/5/6 commands.
//
// Pulls the heavy MuPDF lifting out of limn_command.cpp:
//   - toc, page text, page links, metadata extraction
//   - PNG rendering (full page & region)
//   - the engine's supports() capability list
//
// On failure each helper throws std::runtime_error; the dispatcher catches
// it and translates to a fail-response.
//
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <stdexcept>

class Document;

namespace LimnMupdf {

// Capability list reported in buffer/open response.
QJsonArray supports();

// ── Phase 4: data extraction ─────────────────────────────────────────────

QJsonArray  extract_toc          (Document* doc);
QJsonObject extract_page_text    (Document* doc, int page);
QJsonArray  extract_page_links   (Document* doc, int page);
QJsonObject extract_metadata     (Document* doc);

// v0.27: text search across all pages. Returns {"hits": [{page, rects}, ...]}.
// case_sensitive == false: MuPDF's default needle-match is case-insensitive
//                          for the ASCII subset; that's good enough for now.
QJsonObject extract_search_hits  (Document* doc,
                                   const QString& query,
                                   bool case_sensitive);

// ── Phase 5: rendering ───────────────────────────────────────────────────

QJsonObject render_page_to_png   (Document* doc, int page, int dpi);
QJsonObject render_region_to_png (Document* doc, int page,
                                   double x0, double y0, double x1, double y1,
                                   int dpi);

// v0.39 W05 honest fix — render with view state applied (dark-mode +
// rotation).  Used by test/grab-window so the captured PNG actually
// reflects what the user sees, not what mupdf would render with
// defaults.  Returns the raw QImage so test/grab-window can compute
// avg-luminance and opaque-pixels itself.
QImage render_page_with_view_state(Document* doc, int page, int dpi,
                                    bool dark_mode, int rotation);

}  // namespace LimnMupdf
