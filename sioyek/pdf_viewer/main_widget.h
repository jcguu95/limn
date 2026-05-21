#pragma once
#include <qmainwindow.h>

class DocumentView;
class PdfRenderer;
class PdfViewOpenGLWidget;
class DatabaseManager;
class DocumentManager;
class CachedChecksummer;

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

private:
    PdfViewOpenGLWidget* opengl_widget_    = nullptr;
    DocumentView*        document_view_    = nullptr;
    PdfRenderer*         pdf_renderer_     = nullptr;
    DatabaseManager*     db_manager_       = nullptr;
    DocumentManager*     document_manager_ = nullptr;
    CachedChecksummer*   checksummer_      = nullptr;
};
