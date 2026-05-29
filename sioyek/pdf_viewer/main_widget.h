#pragma once
#include <qmainwindow.h>
#include <QHash>
#include <QString>

class DocumentView;
class PdfRenderer;
class PdfViewOpenGLWidget;
class DatabaseManager;
class DocumentManager;
class CachedChecksummer;
class LimnChromeBar;
class QStackedWidget;
class QPlainTextEdit;

// MainWidget hosts the PDF view. Bridge / dispatch / events live in
// separate files (limn_bridge.*, limn_command.*). MainWidget exposes
// accessors so the command handler can manipulate view state.
class MainWidget : public QMainWindow {
    Q_OBJECT

public:
    MainWidget(QWidget* parent = nullptr);
    ~MainWidget();

    bool open_document(const std::wstring& path);

    // Accessors used by LimnCommand.
    //
    // document_view()    — the *focused* window's DV. Today there is
    //                      only one DV, so this is just document_view_;
    //                      after Phase 3 (per-win DVs) it will return
    //                      panes_[windows->focused_id()].dv.
    //
    // document_view(id)  — Phase 2 stub for "the DV belonging to a
    //                      specific window". Currently every win-id maps
    //                      to the singleton document_view_; the overload
    //                      exists so LimnCommand can be migrated to a
    //                      win-aware API without behaviour change.
    //                      Empty/unknown win_id falls back to the focused
    //                      DV. See docs/split-frame-design.md.
    //
    // Phase 3a — both now route through panes_ (the per-window pane map).
    // The no-arg form returns the focused pane's DV; the overload returns
    // a specific win's DV (falling back to document_view_ for unknown ids,
    // preserving the Phase 2 contract). In 3a there is still only one pane
    // ("w1") and focus never moves, so both are identical to v0.39.10.
    DocumentView*        document_view();
    DocumentView*        document_view(const QString& win_id);
    PdfViewOpenGLWidget* opengl_widget()    { return opengl_widget_; }
    DocumentManager*     document_manager() { return document_manager_; }
    LimnChromeBar*       chrome_bar()       { return chrome_bar_; }

    // SPEC v0.22 §C — text-engine display widget. Read-only display
    // surface stacked on top of opengl_widget; switched in when the
    // focused window's buffer is text-engine. Input still flows via
    // the app-level LimnInputFilter (text_widget has NoFocus).
    QPlainTextEdit*      text_widget()      { return text_widget_; }
    QStackedWidget*      main_stack()       { return main_stack_; }
    void                 show_text_view();  // stack index → text widget
    void                 show_pdf_view();   // stack index → opengl widget

    // markup-interaction step 2 — side-panel layout for the text view.
    // Instead of the full-screen stack flip (show_text_view), reparent
    // text_widget_ out of main_stack_ and into viewport_splitter_ as a
    // narrow LEFT pane, keeping the PDF visible in the main pane on the
    // right. Used by the M-N annotation list so the reader can manage
    // notes while still seeing the page. ratio = panel fraction (0..1).
    void                 enter_text_panel(double ratio = 0.34);
    void                 exit_text_panel();
    bool                 text_panel_active() const { return text_panel_mode_; }

    // SPEC v0.5 §5.1 — real visible window split. Adds a new pane to the
    // splitter alongside the existing viewport. orientation is "h" (split
    // horizontally → side-by-side) or "v" (vertically → top/bottom).
    // Returns the new widget. v0.8 shares DocumentView/PdfRenderer across
    // panes (so all panes show the same content) — per-window independent
    // state is left for v0.9.
    PdfViewOpenGLWidget* add_split_pane(const QString& orientation);
    int                  viewport_count() const;

    // Phase 3a — per-window viewport pane. Each tiled LimnWindow maps 1:1
    // to a ViewportPane that owns its OWN DocumentView + PdfViewOpenGLWidget
    // (the "fat" approach — decision 二 in docs/split-frame-design.md). The
    // heavy resources (db_manager_/document_manager_/checksummer_/
    // pdf_renderer_/fz_context) stay SHARED across panes.
    struct ViewportPane {
        DocumentView*        dv    = nullptr;
        PdfViewOpenGLWidget* gl    = nullptr;
        QStackedWidget*      stack = nullptr;   // index 0 = PDF, 1 = text
        QPlainTextEdit*      text  = nullptr;
    };

    // Phase 3a — create a fresh per-window pane (new DocumentView sharing the
    // heavy managers, wrapped in a PdfViewOpenGLWidget + QStackedWidget),
    // insert it into viewport_splitter_ with orientation "h"|"v", register it
    // under win_id and return it. NOT called by production in 3a (win-split
    // still uses add_split_pane); 3b switches the wiring over.
    ViewportPane         add_pane_for(const QString& win_id, const QString& orientation);

    // Phase 3a — mark win_id as the focused pane and repoint document_view_
    // at that pane's DV, so the ~585 direct document_view_ accesses in
    // _main_widget.cpp always target the focused window. No-op for unknown
    // win_id. In 3a focus never moves (single "w1"); 3b calls this on
    // bridge/win-focus.
    void                 set_focused_win(const QString& win_id);

private:
    class QSplitter*     viewport_splitter_= nullptr;
    PdfViewOpenGLWidget* opengl_widget_    = nullptr;
    DocumentView*        document_view_    = nullptr;
    PdfRenderer*         pdf_renderer_     = nullptr;
    DatabaseManager*     db_manager_       = nullptr;
    DocumentManager*     document_manager_ = nullptr;
    CachedChecksummer*   checksummer_      = nullptr;
    LimnChromeBar*       chrome_bar_       = nullptr;
    // SPEC v0.22 §C — text-engine display
    QStackedWidget*      main_stack_       = nullptr;
    QPlainTextEdit*      text_widget_      = nullptr;
    // markup-interaction step 2 — true when text_widget_ is currently
    // reparented into viewport_splitter_ as a side panel (vs. living in
    // main_stack_ as the full-screen text view).
    bool                 text_panel_mode_  = false;

    // Phase 3a — per-window panes. The initial pane (document_view_/
    // opengl_widget_/main_stack_/text_widget_) is registered under "w1" in
    // the constructor. focused_win_id_ names the pane that document_view()
    // (no-arg) resolves to; document_view_ is kept as its cached DV pointer.
    QHash<QString, ViewportPane> panes_;
    QString              focused_win_id_   = "w1";
};
