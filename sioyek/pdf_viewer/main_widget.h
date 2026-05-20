#pragma once
#include <qmainwindow.h>
#include <qlocalsocket.h>
#include <qlocalserver.h>

class DocumentView;
class PdfRenderer;
class PdfViewOpenGLWidget;
class DatabaseManager;
class DocumentManager;
class CachedChecksummer;

class MainWidget : public QMainWindow {
    Q_OBJECT

public:
    MainWidget(QWidget* parent = nullptr);
    ~MainWidget();

    bool open_document(const std::wstring& path);

private slots:
    void on_socket_data();

private:
    void setup_socket_server();
    void dispatch_command(const QByteArray& json);

    PdfViewOpenGLWidget* opengl_widget = nullptr;
    DocumentView* document_view = nullptr;
    PdfRenderer* pdf_renderer = nullptr;
    DatabaseManager* db_manager = nullptr;
    DocumentManager* document_manager = nullptr;
    CachedChecksummer* checksummer = nullptr;

    QLocalServer* socket_server = nullptr;
    QLocalSocket* socket_client = nullptr;
};
