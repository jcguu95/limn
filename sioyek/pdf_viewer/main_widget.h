#pragma once
#include <qmainwindow.h>

class DocumentView;
class PdfRenderer;
class PdfViewOpenGLWidget;
class DatabaseManager;
class DocumentManager;
class CachedChecksummer;
class LimnChromeBar;

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
    DocumentView*        document_view()    { return document_view_; }
    PdfViewOpenGLWidget* opengl_widget()    { return opengl_widget_; }
    DocumentManager*     document_manager() { return document_manager_; }
    LimnChromeBar*       chrome_bar()       { return chrome_bar_; }

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
};
