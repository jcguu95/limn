#pragma once
#include <qmainwindow.h>

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
    DocumentView*        document_view()    { return document_view_; }
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

    // SPEC v0.5 §5.1 — real visible window split. Adds a new pane to the
    // splitter alongside the existing viewport. orientation is "h" (split
    // horizontally → side-by-side) or "v" (vertically → top/bottom).
    // Returns the new widget. v0.8 shares DocumentView/PdfRenderer across
    // panes (so all panes show the same content) — per-window independent
    // state is left for v0.9.
    PdfViewOpenGLWidget* add_split_pane(const QString& orientation);
    int                  viewport_count() const;

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
};
