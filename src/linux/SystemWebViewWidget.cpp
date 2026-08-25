#include "fit_webview_bridge/SystemWebViewWidget.h"

#include <QApplication>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QFocusEvent>
#include <QHash>
#include <QKeyEvent>
#include <QMetaObject>
#include <QMouseEvent>
#include <QPointer>
#include <QResizeEvent>
#include <QShowEvent>
#include <QTimer>
#include <QVBoxLayout>
#include <QVariant>
#include <QWindow>
#include <QtMath>

#include <atomic>
#include <limits>
#include <memory>

// GLib/GTK headers contain structure members named "signals", which conflicts
// with Qt's keyword compatibility macro after the Qt headers are parsed.
#ifdef signals
#undef signals
#endif
#include <gtk/gtk.h>
#include <gtk/gtkx.h>
#include <webkit2/webkit2.h>

namespace {

constexpr auto unsupportedMessage = "Not implemented by the Linux WebKitGTK proof of concept";
std::atomic<quint64> jsToken{0};

struct JavaScriptRequest {
    QPointer<SystemWebViewWidget> owner;
    quint64 token = 0;
    bool emitResult = false;
};

void warnUnsupported(const char* method) {
    qWarning().nospace() << "SystemWebViewWidget::" << method << ": " << unsupportedMessage;
}

bool isX11Session() {
    const QString qtPlatform = QGuiApplication::platformName();
    if (qtPlatform != QStringLiteral("xcb")) {
        qCritical().noquote()
            << "FIT WebView Bridge Linux proof of concept requires Qt's X11/xcb platform; active platform is"
            << qtPlatform;
        return false;
    }

    const char* display = g_getenv("DISPLAY");
    if (display == nullptr || *display == '\0') {
        qCritical() << "FIT WebView Bridge Linux proof of concept requires an X11 DISPLAY.";
        return false;
    }
    return true;
}

bool initializeGtkX11() {
    static const bool initialized = [] {
        if (g_getenv("GDK_BACKEND") == nullptr) {
            g_setenv("GDK_BACKEND", "x11", FALSE);
        }
        if (!gtk_init_check(nullptr, nullptr)) {
            qCritical() << "Unable to initialize GTK3 with its X11 backend.";
            return false;
        }
        if (!GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
            qCritical() << "GTK3 is not using X11; native Wayland embedding is not supported.";
            return false;
        }
        return true;
    }();
    return initialized;
}

QVariant variantFromJscValue(JSCValue* value) {
    if (value == nullptr || jsc_value_is_null(value) || jsc_value_is_undefined(value)) {
        return {};
    }
    if (jsc_value_is_boolean(value)) {
        return QVariant::fromValue(static_cast<bool>(jsc_value_to_boolean(value)));
    }
    if (jsc_value_is_number(value)) {
        return QVariant::fromValue(jsc_value_to_double(value));
    }
    if (jsc_value_is_string(value)) {
        char* text = jsc_value_to_string(value);
        const QString result = text != nullptr ? QString::fromUtf8(text) : QString();
        g_free(text);
        return result;
    }
    return {};
}

void javascriptFinished(GObject* source, GAsyncResult* result, gpointer userData) {
    std::unique_ptr<JavaScriptRequest> request(static_cast<JavaScriptRequest*>(userData));
    GError* error = nullptr;
    JSCValue* value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source), result, &error);
    const QVariant output = variantFromJscValue(value);
    const QString errorText = error != nullptr ? QString::fromUtf8(error->message) : QString();

    if (value != nullptr) {
        g_object_unref(value);
    }
    if (error != nullptr) {
        g_error_free(error);
    }

    if (!request->emitResult || request->owner.isNull()) {
        return;
    }
    const QPointer<SystemWebViewWidget> owner = request->owner;
    const quint64 token = request->token;
    QMetaObject::invokeMethod(
        owner.data(),
        [owner, output, token, errorText] {
            if (!owner.isNull()) {
                emit owner->javaScriptResult(output, token, errorText);
            }
        },
        Qt::QueuedConnection);
}

void websiteDataCleared(GObject* source, GAsyncResult* result, gpointer) {
    GError* error = nullptr;
    if (!webkit_website_data_manager_clear_finish(WEBKIT_WEBSITE_DATA_MANAGER(source), result, &error)) {
        qWarning() << "Failed to clear WebKitGTK website data:"
                   << (error != nullptr ? QString::fromUtf8(error->message) : QStringLiteral("unknown error"));
    }
    if (error != nullptr) {
        g_error_free(error);
    }
}

} // namespace

struct SystemWebViewWidget::Impl {
    struct DownloadState {
        QString suggestedFileName;
        QString finalPath;
        QUrl sourceUrl;
        qint64 expectedBytes = -1;
        bool failed = false;
    };

    SystemWebViewWidget* owner = nullptr;
    GtkWidget* plug = nullptr;
    GtkWidget* webView = nullptr;
    QWindow* foreignWindow = nullptr;
    QWidget* container = nullptr;
    QTimer* glibPump = nullptr;
    QUrl currentUrl;
    QUrl navigationDisplayUrl;
    QString currentTitle;
    int currentProgress = -1;
    bool loadFailed = false;
    bool canGoBack = false;
    bool canGoForward = false;
    bool available = false;
    QString customUserAgent;
    QString applicationNameForUserAgent;
    QString downloadDirectory;
    WebKitWebContext* webContext = nullptr;
    gulong downloadStartedHandler = 0;
    QHash<WebKitDownload*, DownloadState*> downloads;

    WebKitWebView* nativeWebView() const { return WEBKIT_WEB_VIEW(webView); }

    static QString safeFileName(const char* suggestedFileName) {
        QString name = suggestedFileName != nullptr ? QString::fromUtf8(suggestedFileName).trimmed() : QString();
        name.replace('/', '_');
        name.replace('\\', '_');
        for (qsizetype i = name.size() - 1; i >= 0; --i) {
            if (name.at(i).isNull() || name.at(i).category() == QChar::Other_Control) {
                name.remove(i, 1);
            }
        }
        if (name.isEmpty() || name == QStringLiteral(".") || name == QStringLiteral("..")) {
            return QStringLiteral("download");
        }
        return name;
    }

    static QString uniqueDownloadPath(const QString& directory, const QString& fileName) {
        const QDir dir(directory);
        const QString initialPath = dir.filePath(fileName);
        if (!QFileInfo::exists(initialPath)) {
            return initialPath;
        }

        const qsizetype dot = fileName.lastIndexOf('.');
        const bool hasExtension = dot > 0 && dot < fileName.size() - 1;
        const QString baseName = hasExtension ? fileName.left(dot) : fileName;
        const QString extension = hasExtension ? fileName.mid(dot) : QString();
        for (int index = 1; index < 10000; ++index) {
            const QString candidate = dir.filePath(QStringLiteral("%1 (%2)%3").arg(baseName).arg(index).arg(extension));
            if (!QFileInfo::exists(candidate)) {
                return candidate;
            }
        }
        return {};
    }

    void emitDownloadFailure(DownloadState* state, const QString& error) {
        if (owner != nullptr) {
            emit owner->downloadFailed(state != nullptr ? state->finalPath : QString(), error);
        }
    }

    void cleanupDownload(WebKitDownload* download) {
        DownloadState* state = downloads.take(download);
        if (state == nullptr) {
            return;
        }
        g_signal_handlers_disconnect_by_data(download, this);
        delete state;
        g_object_unref(download);
        updateNavigationDisplayUrl();
    }

    void updateNavigationDisplayUrl() {
        if (downloads.isEmpty() && owner != nullptr && navigationDisplayUrl != currentUrl) {
            navigationDisplayUrl = currentUrl;
            emit owner->navigationDisplayUrlChanged(currentUrl);
        }
    }

    static gboolean decideDownloadDestination(WebKitDownload* download, const char* suggested, gpointer data) {
        auto* self = static_cast<Impl*>(data);
        DownloadState* state = self->downloads.value(download, nullptr);
        if (state == nullptr) {
            return FALSE;
        }

        state->suggestedFileName = safeFileName(suggested);
        const QString configuredDirectory = self->downloadDirectory;
        if (configuredDirectory.isEmpty()) {
            state->failed = true;
            self->emitDownloadFailure(state, QStringLiteral("Download directory is not configured"));
            webkit_download_cancel(download);
            return TRUE;
        }

        QDir directory(configuredDirectory);
        if (!directory.exists() && !QDir().mkpath(configuredDirectory)) {
            state->failed = true;
            self->emitDownloadFailure(
                state, QStringLiteral("Cannot create download directory: %1").arg(configuredDirectory));
            webkit_download_cancel(download);
            return TRUE;
        }
        const QFileInfo directoryInfo(configuredDirectory);
        if (!directoryInfo.isDir() || !directoryInfo.isWritable()) {
            state->failed = true;
            self->emitDownloadFailure(
                state, QStringLiteral("Download directory is not writable: %1").arg(configuredDirectory));
            webkit_download_cancel(download);
            return TRUE;
        }

        state->finalPath = uniqueDownloadPath(configuredDirectory, state->suggestedFileName);
        if (state->finalPath.isEmpty()) {
            state->failed = true;
            self->emitDownloadFailure(state, QStringLiteral("Cannot select a unique download filename"));
            webkit_download_cancel(download);
            return TRUE;
        }

        WebKitURIResponse* response = webkit_download_get_response(download);
        if (response != nullptr) {
            const guint64 contentLength = webkit_uri_response_get_content_length(response);
            if (contentLength > 0 && contentLength <= static_cast<guint64>(std::numeric_limits<qint64>::max())) {
                state->expectedBytes = static_cast<qint64>(contentLength);
            }
        }

        const QByteArray destination = QUrl::fromLocalFile(state->finalPath).toEncoded();
        webkit_download_set_allow_overwrite(download, FALSE);
        webkit_download_set_destination(download, destination.constData());
        emit self->owner->downloadStarted(state->suggestedFileName, state->finalPath);
        emit self->owner->downloadProgress(0, state->expectedBytes);
        return TRUE;
    }

    static void downloadReceivedData(WebKitDownload* download, guint64, gpointer data) {
        auto* self = static_cast<Impl*>(data);
        DownloadState* state = self->downloads.value(download, nullptr);
        if (state == nullptr || state->failed || self->owner == nullptr) {
            return;
        }
        const guint64 received = webkit_download_get_received_data_length(download);
        const qint64 receivedBytes = received <= static_cast<guint64>(std::numeric_limits<qint64>::max())
            ? static_cast<qint64>(received)
            : std::numeric_limits<qint64>::max();
        emit self->owner->downloadProgress(receivedBytes, state->expectedBytes);
    }

    static void downloadFailed(WebKitDownload* download, GError* error, gpointer data) {
        auto* self = static_cast<Impl*>(data);
        DownloadState* state = self->downloads.value(download, nullptr);
        if (state == nullptr || state->failed) {
            return;
        }
        state->failed = true;
        self->emitDownloadFailure(
            state, error != nullptr ? QString::fromUtf8(error->message) : QStringLiteral("Unknown download error"));
    }

    static void downloadFinished(WebKitDownload* download, gpointer data) {
        auto* self = static_cast<Impl*>(data);
        DownloadState* state = self->downloads.value(download, nullptr);
        if (state == nullptr) {
            return;
        }
        if (!state->failed && self->owner != nullptr) {
            const QFileInfo finalFile(state->finalPath);
            auto* info = new DownloadInfo(finalFile.fileName(), finalFile.absolutePath(), state->sourceUrl, self->owner);
            emit self->owner->downloadFinished(info);
        }
        self->cleanupDownload(download);
    }

    static void contextDownloadStarted(WebKitWebContext*, WebKitDownload* download, gpointer data) {
        auto* self = static_cast<Impl*>(data);
        if (webkit_download_get_web_view(download) != self->nativeWebView() || self->downloads.contains(download)) {
            return;
        }

        auto* state = new DownloadState;
        WebKitURIRequest* request = webkit_download_get_request(download);
        const char* sourceUri = request != nullptr ? webkit_uri_request_get_uri(request) : nullptr;
        if (sourceUri != nullptr) {
            state->sourceUrl = QUrl(QString::fromUtf8(sourceUri));
        }

        g_object_ref(download);
        self->downloads.insert(download, state);
        g_signal_connect(download, "decide-destination", G_CALLBACK(decideDownloadDestination), self);
        g_signal_connect(download, "received-data", G_CALLBACK(downloadReceivedData), self);
        g_signal_connect(download, "failed", G_CALLBACK(downloadFailed), self);
        g_signal_connect(download, "finished", G_CALLBACK(downloadFinished), self);
    }

    void updateUrl() {
        const char* uri = webkit_web_view_get_uri(nativeWebView());
        const QUrl url = uri != nullptr ? QUrl(QString::fromUtf8(uri)) : QUrl();
        if (currentUrl == url) {
            return;
        }
        currentUrl = url;
        emit owner->urlChanged(url);
        if (!webkit_web_view_is_loading(nativeWebView())) {
            updateNavigationDisplayUrl();
        }
    }

    void updateTitle() {
        const char* title = webkit_web_view_get_title(nativeWebView());
        const QString value = title != nullptr ? QString::fromUtf8(title) : QString();
        if (currentTitle == value) {
            return;
        }
        currentTitle = value;
        emit owner->titleChanged(value);
    }

    void updateProgress() {
        if (loadFailed) {
            return;
        }
        const int percent = qBound(0, qRound(webkit_web_view_get_estimated_load_progress(nativeWebView()) * 100.0), 100);
        if (currentProgress == percent) {
            return;
        }
        currentProgress = percent;
        emit owner->loadProgress(percent);
    }

    void updateNavigationState() {
        const bool back = webkit_web_view_can_go_back(nativeWebView());
        const bool forward = webkit_web_view_can_go_forward(nativeWebView());
        if (canGoBack != back) {
            canGoBack = back;
            emit owner->canGoBackChanged(back);
        }
        if (canGoForward != forward) {
            canGoForward = forward;
            emit owner->canGoForwardChanged(forward);
        }
    }
};

SystemWebViewWidget::SystemWebViewWidget(QWidget* parent) : QWidget(parent), d(new Impl) {
    d->owner = this;
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    if (!isX11Session() || !initializeGtkX11()) {
        setEnabled(false);
        return;
    }

    d->plug = gtk_plug_new(0);
    g_signal_connect(
        d->plug,
        "delete-event",
        G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer) -> gboolean { return TRUE; }),
        nullptr);
    d->webView = webkit_web_view_new();
    d->webContext = webkit_web_view_get_context(WEBKIT_WEB_VIEW(d->webView));
    d->downloadStartedHandler = g_signal_connect(
        d->webContext, "download-started", G_CALLBACK(Impl::contextDownloadStarted), d);
    gtk_container_add(GTK_CONTAINER(d->plug), d->webView);
    gtk_widget_show_all(d->plug);

    const WId plugId = static_cast<WId>(gtk_plug_get_id(GTK_PLUG(d->plug)));
    d->foreignWindow = QWindow::fromWinId(plugId);
    if (d->foreignWindow == nullptr) {
        qCritical() << "Qt could not wrap the GTK X11 window; WebKitGTK embedding is unavailable.";
        gtk_widget_destroy(d->plug);
        d->plug = nullptr;
        d->webView = nullptr;
        setEnabled(false);
        return;
    }

    d->container = QWidget::createWindowContainer(d->foreignWindow, this);
    d->container->setFocusPolicy(Qt::StrongFocus);
    layout->addWidget(d->container);

    g_signal_connect(
        d->webView,
        "notify::uri",
        G_CALLBACK(+[](WebKitWebView*, GParamSpec*, gpointer data) {
            static_cast<SystemWebViewWidget*>(data)->d->updateUrl();
        }),
        this);
    g_signal_connect(
        d->webView,
        "notify::title",
        G_CALLBACK(+[](WebKitWebView*, GParamSpec*, gpointer data) {
            static_cast<SystemWebViewWidget*>(data)->d->updateTitle();
        }),
        this);
    g_signal_connect(
        d->webView,
        "notify::estimated-load-progress",
        G_CALLBACK(+[](WebKitWebView*, GParamSpec*, gpointer data) {
            static_cast<SystemWebViewWidget*>(data)->d->updateProgress();
        }),
        this);
    g_signal_connect(
        d->webView,
        "load-changed",
        G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent event, gpointer data) {
            auto* self = static_cast<SystemWebViewWidget*>(data);
            if (event == WEBKIT_LOAD_STARTED) {
                self->d->loadFailed = false;
                self->d->updateProgress();
            } else if (event == WEBKIT_LOAD_COMMITTED) {
                self->d->updateUrl();
                self->d->updateNavigationDisplayUrl();
            } else if (event == WEBKIT_LOAD_FINISHED) {
                self->d->updateUrl();
                self->d->updateTitle();
                self->d->updateNavigationDisplayUrl();
                if (!self->d->loadFailed) {
                    self->d->updateProgress();
                    if (self->d->currentProgress != 100) {
                        self->d->currentProgress = 100;
                        emit self->loadProgress(100);
                    }
                    emit self->loadFinished(true);
                }
            }
        }),
        this);
    g_signal_connect(
        d->webView,
        "load-failed",
        G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent, const char*, GError*, gpointer data) -> gboolean {
            auto* self = static_cast<SystemWebViewWidget*>(data);
            self->d->loadFailed = true;
            if (self->d->currentProgress != 0) {
                self->d->currentProgress = 0;
                emit self->loadProgress(0);
            }
            emit self->loadFinished(false);
            return TRUE;
        }),
        this);

    WebKitBackForwardList* history = webkit_web_view_get_back_forward_list(WEBKIT_WEB_VIEW(d->webView));
    g_signal_connect(
        history,
        "changed",
        G_CALLBACK(+[](WebKitBackForwardList*, WebKitBackForwardListItem*, GList*, gpointer data) {
            static_cast<SystemWebViewWidget*>(data)->d->updateNavigationState();
        }),
        this);

    // Provisional proof-of-concept integration: let Qt periodically dispatch
    // pending GLib/GTK/WebKit work while Qt remains the owning event loop.
    d->glibPump = new QTimer(this);
    d->glibPump->setInterval(5);
    connect(d->glibPump, &QTimer::timeout, this, [] {
        while (g_main_context_iteration(nullptr, FALSE)) {
        }
    });
    d->glibPump->start();
    d->available = true;
}

SystemWebViewWidget::~SystemWebViewWidget() {
    if (d->glibPump != nullptr) {
        d->glibPump->stop();
    }
    if (d->webContext != nullptr && d->downloadStartedHandler != 0) {
        g_signal_handler_disconnect(d->webContext, d->downloadStartedHandler);
        d->downloadStartedHandler = 0;
    }
    const QList<WebKitDownload*> activeDownloads = d->downloads.keys();
    for (WebKitDownload* download : activeDownloads) {
        g_signal_handlers_disconnect_by_data(download, d);
        webkit_download_cancel(download);
        delete d->downloads.take(download);
        g_object_unref(download);
    }
    delete d->container;
    d->container = nullptr;
    d->foreignWindow = nullptr;
    if (d->plug != nullptr) {
        gtk_widget_destroy(d->plug);
    }
    delete d;
}

QUrl SystemWebViewWidget::url() const {
    return d->currentUrl;
}

void SystemWebViewWidget::setUrl(const QUrl& url) {
    if (!d->available || !url.isValid()) {
        if (!d->available) {
            qWarning() << "Cannot load URL because the Linux X11 WebKitGTK backend is unavailable.";
        }
        return;
    }
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(d->webView), url.toString().toUtf8().constData());
}

void SystemWebViewWidget::showEvent(QShowEvent* event) {
    QWidget::showEvent(event);
}

void SystemWebViewWidget::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
}

void SystemWebViewWidget::focusInEvent(QFocusEvent* event) {
    QWidget::focusInEvent(event);
    if (d->container != nullptr) {
        d->container->setFocus(Qt::OtherFocusReason);
    }
}

void SystemWebViewWidget::mousePressEvent(QMouseEvent* event) {
    QWidget::mousePressEvent(event);
}

void SystemWebViewWidget::keyPressEvent(QKeyEvent* event) {
    QWidget::keyPressEvent(event);
}

void SystemWebViewWidget::back() {
    if (d->available && webkit_web_view_can_go_back(d->nativeWebView())) {
        webkit_web_view_go_back(d->nativeWebView());
    }
}
void SystemWebViewWidget::forward() {
    if (d->available && webkit_web_view_can_go_forward(d->nativeWebView())) {
        webkit_web_view_go_forward(d->nativeWebView());
    }
}
void SystemWebViewWidget::stop() {
    if (d->available) {
        webkit_web_view_stop_loading(d->nativeWebView());
    }
}
void SystemWebViewWidget::reload() {
    if (d->available) {
        webkit_web_view_reload(d->nativeWebView());
    }
}
void SystemWebViewWidget::clearWebsiteData() {
    if (!d->available) {
        return;
    }
    webkit_website_data_manager_clear(
        webkit_web_view_get_website_data_manager(d->nativeWebView()),
        WEBKIT_WEBSITE_DATA_ALL,
        0,
        nullptr,
        websiteDataCleared,
        nullptr);
}
void SystemWebViewWidget::clearCacheData() {
    if (!d->available) {
        return;
    }
    const auto cacheTypes = static_cast<WebKitWebsiteDataTypes>(
        WEBKIT_WEBSITE_DATA_MEMORY_CACHE | WEBKIT_WEBSITE_DATA_DISK_CACHE);
    webkit_website_data_manager_clear(
        webkit_web_view_get_website_data_manager(d->nativeWebView()),
        cacheTypes,
        0,
        nullptr,
        websiteDataCleared,
        nullptr);
}
bool SystemWebViewWidget::setProxy(const QString&, int) { warnUnsupported("setProxy()"); return false; }
void SystemWebViewWidget::clearProxy() { warnUnsupported("clearProxy()"); }
bool SystemWebViewWidget::hasExplicitProxySupport() const { return false; }
void SystemWebViewWidget::evaluateJavaScript(const QString& script) {
    if (!d->available) {
        return;
    }
    const QByteArray utf8 = script.toUtf8();
    auto* request = new JavaScriptRequest{QPointer<SystemWebViewWidget>(this), 0, false};
    webkit_web_view_evaluate_javascript(
        d->nativeWebView(), utf8.constData(), utf8.size(), nullptr, nullptr, nullptr, javascriptFinished, request);
}
quint64 SystemWebViewWidget::evaluateJavaScriptWithResult(const QString& script) {
    if (!d->available) {
        return 0;
    }
    const quint64 token = ++jsToken;
    const QByteArray utf8 = script.toUtf8();
    auto* request = new JavaScriptRequest{QPointer<SystemWebViewWidget>(this), token, true};
    webkit_web_view_evaluate_javascript(
        d->nativeWebView(), utf8.constData(), utf8.size(), nullptr, nullptr, nullptr, javascriptFinished, request);
    return token;
}
void SystemWebViewWidget::setDownloadDirectory(const QString& directoryPath) {
    d->downloadDirectory = QDir::cleanPath(QDir::fromNativeSeparators(directoryPath.trimmed()));
    if (directoryPath.trimmed().isEmpty()) {
        d->downloadDirectory.clear();
    }
}
QString SystemWebViewWidget::downloadDirectory() const { return d->downloadDirectory; }
void SystemWebViewWidget::renderErrorPage(const QUrl&, const QString&, int) { warnUnsupported("renderErrorPage()"); }
void SystemWebViewWidget::setUserAgent(const QString& userAgent) {
    d->customUserAgent = userAgent.trimmed();
    applyUserAgent();
}
QString SystemWebViewWidget::userAgent() const { return d->customUserAgent; }
void SystemWebViewWidget::resetUserAgent() {
    d->customUserAgent.clear();
    applyUserAgent();
}
void SystemWebViewWidget::setApplicationNameForUserAgent(const QString& name) {
    d->applicationNameForUserAgent = name.trimmed();
    applyUserAgent();
}
quint64 SystemWebViewWidget::captureVisiblePage(const QString& filePath) {
    warnUnsupported("captureVisiblePage()");
    emit captureFinished(0, false, filePath, QString::fromLatin1(unsupportedMessage));
    return 0;
}
quint64 SystemWebViewWidget::_captureVisiblePage_onGui(const QString&, quint64) { return 0; }
void SystemWebViewWidget::applyUserAgent() {
    if (!d->available) {
        return;
    }
    WebKitSettings* settings = webkit_web_view_get_settings(d->nativeWebView());
    if (!d->customUserAgent.isEmpty()) {
        const QByteArray custom = d->customUserAgent.toUtf8();
        webkit_settings_set_user_agent(settings, custom.constData());
        return;
    }

    const QByteArray applicationName = d->applicationNameForUserAgent.toUtf8();
    webkit_settings_set_user_agent_with_application_details(
        settings, applicationName.isEmpty() ? nullptr : applicationName.constData(), nullptr);
}
