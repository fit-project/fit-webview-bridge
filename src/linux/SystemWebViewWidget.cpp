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
#include <QThread>
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
#include <gdk/gdkpixbuf.h>
#include <webkit2/webkit2.h>

namespace {

constexpr auto unsupportedMessage = "Not implemented by the Linux WebKitGTK proof of concept";
std::atomic<quint64> jsToken{0};
std::atomic<quint64> captureToken{0};

struct JavaScriptRequest {
    QPointer<SystemWebViewWidget> owner;
    quint64 token = 0;
    bool emitResult = false;
};

struct CaptureRequest {
    QPointer<SystemWebViewWidget> owner;
    quint64 token = 0;
    QString filePath;
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

bool isSupportedPopupUrl(const QUrl& url) {
    if (!url.isValid() || url.isEmpty()) {
        return false;
    }
    const QString scheme = url.scheme().toLower();
    return scheme == QStringLiteral("http") || scheme == QStringLiteral("https")
        || scheme == QStringLiteral("file") || scheme == QStringLiteral("data")
        || scheme == QStringLiteral("about") || scheme == QStringLiteral("blob");
}

struct JavaScriptConversion {
    QVariant value;
    QString error;
};

JavaScriptConversion variantFromJscValue(JSCValue* value) {
    if (value == nullptr || jsc_value_is_null(value) || jsc_value_is_undefined(value)) {
        return {};
    }
    if (jsc_value_is_boolean(value)) {
        return {QVariant::fromValue(static_cast<bool>(jsc_value_to_boolean(value))), {}};
    }
    if (jsc_value_is_number(value)) {
        return {QVariant::fromValue(jsc_value_to_double(value)), {}};
    }
    if (jsc_value_is_string(value)) {
        char* text = jsc_value_to_string(value);
        const QString result = text != nullptr ? QString::fromUtf8(text) : QString();
        g_free(text);
        return {result, {}};
    }
    if (jsc_value_is_object(value)) {
        char* json = jsc_value_to_json(value, 0);
        if (json == nullptr) {
            return {{}, QStringLiteral("JavaScript result could not be serialized as JSON")};
        }
        const QString result = QString::fromUtf8(json);
        g_free(json);
        if (result.isEmpty()) {
            return {{}, QStringLiteral("JavaScript result produced empty JSON")};
        }
        return {result, {}};
    }
    return {{}, QStringLiteral("Unsupported JavaScript result type")};
}

void javascriptFinished(GObject* source, GAsyncResult* result, gpointer userData) {
    std::unique_ptr<JavaScriptRequest> request(static_cast<JavaScriptRequest*>(userData));
    GError* error = nullptr;
    JSCValue* value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source), result, &error);
    const JavaScriptConversion conversion = variantFromJscValue(value);
    const QVariant output = conversion.value;
    const QString errorText = error != nullptr ? QString::fromUtf8(error->message) : conversion.error;

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

void snapshotFinished(GObject* source, GAsyncResult* result, gpointer userData) {
    std::unique_ptr<CaptureRequest> request(static_cast<CaptureRequest*>(userData));
    GError* snapshotError = nullptr;
    cairo_surface_t* surface = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(source), result, &snapshotError);
    bool success = false;
    QString errorText;

    if (surface == nullptr) {
        errorText = snapshotError != nullptr ? QString::fromUtf8(snapshotError->message)
                                             : QStringLiteral("WebKitGTK snapshot failed");
    } else if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        errorText = QStringLiteral("Invalid Cairo snapshot surface: %1")
                        .arg(QString::fromLatin1(cairo_status_to_string(cairo_surface_status(surface))));
    } else if (cairo_surface_get_type(surface) != CAIRO_SURFACE_TYPE_IMAGE) {
        errorText = QStringLiteral("Unsupported Cairo snapshot surface type");
    } else {
        const QByteArray outputPath = request->filePath.toUtf8();
        const QString extension = QFileInfo(request->filePath).suffix().toLower();
        if (extension == QStringLiteral("jpg") || extension == QStringLiteral("jpeg")) {
            const int width = cairo_image_surface_get_width(surface);
            const int height = cairo_image_surface_get_height(surface);
            GdkPixbuf* pixbuf = gdk_pixbuf_get_from_surface(surface, 0, 0, width, height);
            if (pixbuf == nullptr) {
                errorText = QStringLiteral("Cannot convert snapshot to JPEG pixels");
            } else {
                GError* encodeError = nullptr;
                success = gdk_pixbuf_save(
                    pixbuf, outputPath.constData(), "jpeg", &encodeError, "quality", "95", nullptr);
                if (!success) {
                    errorText = encodeError != nullptr ? QString::fromUtf8(encodeError->message)
                                                       : QStringLiteral("JPEG encoding failed");
                }
                if (encodeError != nullptr) {
                    g_error_free(encodeError);
                }
                g_object_unref(pixbuf);
            }
        } else {
            const cairo_status_t status = cairo_surface_write_to_png(surface, outputPath.constData());
            success = status == CAIRO_STATUS_SUCCESS;
            if (!success) {
                errorText = QStringLiteral("PNG encoding failed: %1")
                                .arg(QString::fromLatin1(cairo_status_to_string(status)));
            }
        }
    }

    if (surface != nullptr) {
        cairo_surface_destroy(surface);
    }
    if (snapshotError != nullptr) {
        g_error_free(snapshotError);
    }
    if (!request->owner.isNull()) {
        emit request->owner->captureFinished(request->token, success, request->filePath, errorText);
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
    bool intentionalDownloadPending = false;
    bool httpErrorPending = false;
    bool internalErrorPageLoading = false;
    bool internalErrorPageCommitted = false;
    QUrl internalErrorUrl;
    bool canGoBack = false;
    bool canGoForward = false;
    bool available = false;
    QString customUserAgent;
    QString applicationNameForUserAgent;
    QString downloadDirectory;
    WebKitWebContext* webContext = nullptr;
    WebKitWebsiteDataManager* websiteDataManager = nullptr;
    gulong downloadStartedHandler = 0;
    QHash<WebKitDownload*, DownloadState*> downloads;
    QPointer<QWidget> fullscreenWindow;
    Qt::WindowStates preFullscreenWindowState;
    QList<QPointer<QWidget>> hiddenFullscreenSiblings;
    bool htmlFullscreen = false;

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
        const QUrl url = internalErrorPageLoading ? internalErrorUrl
                                                  : (uri != nullptr ? QUrl(QString::fromUtf8(uri)) : QUrl());
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

    void enterFullscreen() {
        if (htmlFullscreen || owner == nullptr) {
            return;
        }
        QWidget* topLevel = owner->window();
        if (topLevel == nullptr) {
            return;
        }

        fullscreenWindow = topLevel;
        preFullscreenWindowState = topLevel->windowState();
        hiddenFullscreenSiblings.clear();
        QWidget* pathWidget = owner;
        while (QWidget* parent = pathWidget->parentWidget()) {
            const auto siblings = parent->findChildren<QWidget*>(QString(), Qt::FindDirectChildrenOnly);
            for (QWidget* sibling : siblings) {
                if (sibling != pathWidget && sibling->isVisible() && !sibling->isWindow()) {
                    hiddenFullscreenSiblings.append(sibling);
                    sibling->hide();
                }
            }
            pathWidget = parent;
            if (parent == topLevel) {
                break;
            }
        }
        htmlFullscreen = true;
        topLevel->showFullScreen();
        QTimer::singleShot(0, owner, [guard = QPointer<SystemWebViewWidget>(owner)] {
            if (!guard.isNull() && guard->d->available && !gtk_widget_has_focus(guard->d->webView)) {
                gtk_widget_grab_focus(guard->d->webView);
            }
        });
    }

    void leaveFullscreen() {
        if (!htmlFullscreen) {
            return;
        }
        htmlFullscreen = false;
        if (!fullscreenWindow.isNull()) {
            fullscreenWindow->setWindowState(preFullscreenWindowState);
        }
        for (const QPointer<QWidget>& sibling : std::as_const(hiddenFullscreenSiblings)) {
            if (!sibling.isNull()) {
                sibling->show();
            }
        }
        hiddenFullscreenSiblings.clear();
        fullscreenWindow.clear();
        if (owner != nullptr && available && !gtk_widget_has_focus(webView)) {
            gtk_widget_grab_focus(webView);
        }
    }
};

SystemWebViewWidget::SystemWebViewWidget(QWidget* parent) : QWidget(parent), d(new Impl) {
    d->owner = this;
    setFocusPolicy(Qt::StrongFocus);
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
    d->webContext = webkit_web_context_new_ephemeral();
    d->websiteDataManager = webkit_web_context_get_website_data_manager(d->webContext);
    if (!webkit_web_context_is_ephemeral(d->webContext)
        || !webkit_website_data_manager_is_ephemeral(d->websiteDataManager)) {
        qCritical() << "WebKitGTK failed to create an ephemeral browsing context.";
        g_object_unref(d->webContext);
        d->webContext = nullptr;
        d->websiteDataManager = nullptr;
        gtk_widget_destroy(d->plug);
        d->plug = nullptr;
        setEnabled(false);
        return;
    }
    d->webView = webkit_web_view_new_with_context(d->webContext);
    WebKitSettings* settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(d->webView));
    webkit_settings_set_enable_fullscreen(settings, TRUE);
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
        "permission-request",
        G_CALLBACK(+[](WebKitWebView*, WebKitPermissionRequest* request, gpointer) -> gboolean {
            if (request == nullptr || g_strcmp0(G_OBJECT_TYPE_NAME(request), "WebKitPermissionRequest") != 0) {
                return FALSE;
            }
            webkit_permission_request_allow(request);
            return TRUE;
        }),
        this);
    g_signal_connect(
        d->webView,
        "enter-fullscreen",
        G_CALLBACK(+[](WebKitWebView*, gpointer data) -> gboolean {
            static_cast<SystemWebViewWidget*>(data)->d->enterFullscreen();
            return TRUE;
        }),
        this);
    g_signal_connect(
        d->webView,
        "leave-fullscreen",
        G_CALLBACK(+[](WebKitWebView*, gpointer data) -> gboolean {
            static_cast<SystemWebViewWidget*>(data)->d->leaveFullscreen();
            return TRUE;
        }),
        this);
    g_signal_connect(
        d->webView,
        "create",
        G_CALLBACK(+[](WebKitWebView* webView, WebKitNavigationAction* navigationAction, gpointer data) -> GtkWidget* {
            auto* self = static_cast<SystemWebViewWidget*>(data);
            WebKitURIRequest* request = webkit_navigation_action_get_request(navigationAction);
            const char* uri = request != nullptr ? webkit_uri_request_get_uri(request) : nullptr;
            const QUrl destination = uri != nullptr ? QUrl(QString::fromUtf8(uri)) : QUrl();
            if (!isSupportedPopupUrl(destination)) {
                qWarning() << "Ignoring unsupported popup URL:" << destination;
                return nullptr;
            }

            self->d->httpErrorPending = false;
            self->d->internalErrorPageLoading = false;
            self->d->internalErrorPageCommitted = false;
            self->d->internalErrorUrl = QUrl();
            webkit_web_view_load_request(webView, request);
            return nullptr;
        }),
        this);
    g_signal_connect(
        d->webView,
        "decide-policy",
        G_CALLBACK(+[](WebKitWebView*, WebKitPolicyDecision* decision, WebKitPolicyDecisionType type,
                       gpointer data) -> gboolean {
            if (type != WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
                return FALSE;
            }

            auto* self = static_cast<SystemWebViewWidget*>(data);
            auto* responseDecision = WEBKIT_RESPONSE_POLICY_DECISION(decision);
            if (!webkit_response_policy_decision_is_main_frame_main_resource(responseDecision)) {
                return FALSE;
            }

            WebKitURIResponse* response = webkit_response_policy_decision_get_response(responseDecision);
            if (response == nullptr) {
                return FALSE;
            }
            SoupMessageHeaders* headers = webkit_uri_response_get_http_headers(response);
            const char* disposition = headers != nullptr ? soup_message_headers_get_one(headers, "Content-Disposition")
                                                         : nullptr;
            const bool isAttachment = disposition != nullptr
                && QString::fromUtf8(disposition).contains(QStringLiteral("attachment"), Qt::CaseInsensitive);
            const bool isDownload = isAttachment
                || !webkit_response_policy_decision_is_mime_type_supported(responseDecision);
            const guint status = webkit_uri_response_get_status_code(response);
            if (isDownload) {
                self->d->intentionalDownloadPending = true;
                webkit_policy_decision_download(decision);
                return TRUE;
            }
            if (status < 400) {
                return FALSE;
            }
            if (self->d->httpErrorPending || self->d->internalErrorPageLoading) {
                webkit_policy_decision_ignore(decision);
                return TRUE;
            }

            const char* responseUri = webkit_uri_response_get_uri(response);
            const QUrl url = responseUri != nullptr ? QUrl(QString::fromUtf8(responseUri)) : self->d->currentUrl;
            self->d->httpErrorPending = true;
            self->d->internalErrorUrl = url;
            self->d->loadFailed = true;
            if (self->d->currentUrl != url) {
                self->d->currentUrl = url;
                emit self->urlChanged(url);
            }
            if (self->d->navigationDisplayUrl != url) {
                self->d->navigationDisplayUrl = url;
                emit self->navigationDisplayUrlChanged(url);
            }
            if (self->d->currentProgress != 0) {
                self->d->currentProgress = 0;
                emit self->loadProgress(0);
            }
            emit self->loadFinished(false);

            webkit_policy_decision_ignore(decision);
            const QPointer<SystemWebViewWidget> guard(self);
            QTimer::singleShot(0, self, [guard, url, status] {
                if (!guard.isNull() && guard->d->httpErrorPending && guard->d->internalErrorUrl == url) {
                    guard->renderErrorPage(
                        url, QStringLiteral("The server returned an HTTP error response."), static_cast<int>(status));
                }
            });
            return TRUE;
        }),
        this);
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
                self->d->intentionalDownloadPending = false;
                if (!self->d->httpErrorPending && !self->d->internalErrorPageLoading) {
                    self->d->loadFailed = false;
                }
                self->d->updateProgress();
            } else if (event == WEBKIT_LOAD_COMMITTED) {
                if (self->d->internalErrorPageLoading) {
                    self->d->internalErrorPageCommitted = true;
                }
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
                if (self->d->internalErrorPageLoading && self->d->internalErrorPageCommitted) {
                    self->d->internalErrorPageLoading = false;
                    self->d->internalErrorPageCommitted = false;
                }
            }
        }),
        this);
    g_signal_connect(
        d->webView,
        "load-failed",
        G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent, const char*, GError* error, gpointer data) -> gboolean {
            auto* self = static_cast<SystemWebViewWidget*>(data);
            if (self->d->httpErrorPending || self->d->internalErrorPageLoading) {
                return TRUE;
            }
            const bool interruptedByDownload = error != nullptr && error->domain == WEBKIT_POLICY_ERROR
                && error->code == WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE
                && self->d->intentionalDownloadPending;
            if (interruptedByDownload) {
                self->d->intentionalDownloadPending = false;
                self->d->loadFailed = true;
                self->d->currentProgress = -1;
                return TRUE;
            }
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
    d->leaveFullscreen();
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
    if (d->webContext != nullptr) {
        g_object_unref(d->webContext);
        d->webContext = nullptr;
        d->websiteDataManager = nullptr;
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
    d->httpErrorPending = false;
    d->internalErrorPageLoading = false;
    d->internalErrorPageCommitted = false;
    d->internalErrorUrl = QUrl();
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
        d->container->setFocus(event->reason());
    }
    if (d->available && !gtk_widget_has_focus(d->webView)) {
        gtk_widget_grab_focus(d->webView);
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
        d->httpErrorPending = false;
        d->internalErrorPageLoading = false;
        d->internalErrorPageCommitted = false;
        webkit_web_view_go_back(d->nativeWebView());
    }
}
void SystemWebViewWidget::forward() {
    if (d->available && webkit_web_view_can_go_forward(d->nativeWebView())) {
        d->httpErrorPending = false;
        d->internalErrorPageLoading = false;
        d->internalErrorPageCommitted = false;
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
        if (!d->internalErrorUrl.isEmpty() && (d->internalErrorPageLoading || d->loadFailed)) {
            setUrl(d->internalErrorUrl);
            return;
        }
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
bool SystemWebViewWidget::setProxy(const QString& host, int port) {
    if (!hasExplicitProxySupport() || QThread::currentThread() != thread() || port < 1 || port > 65535) {
        return false;
    }

    const QString trimmedHost = host.trimmed();
    if (trimmedHost.isEmpty() || trimmedHost.contains('/') || trimmedHost.contains('@') || trimmedHost.contains('?')
        || trimmedHost.contains('#')) {
        return false;
    }
    for (const QChar character : trimmedHost) {
        if (character.isSpace() || character.category() == QChar::Other_Control) {
            return false;
        }
    }

    QUrl proxyUrl;
    proxyUrl.setScheme(QStringLiteral("http"));
    proxyUrl.setHost(trimmedHost);
    proxyUrl.setPort(port);
    if (!proxyUrl.isValid() || proxyUrl.host().isEmpty()) {
        return false;
    }

    const QByteArray encodedProxy = proxyUrl.toEncoded(QUrl::FullyEncoded);
    WebKitNetworkProxySettings* settings = webkit_network_proxy_settings_new(encodedProxy.constData(), nullptr);
    if (settings == nullptr) {
        return false;
    }
    webkit_website_data_manager_set_network_proxy_settings(
        d->websiteDataManager, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, settings);
    webkit_network_proxy_settings_free(settings);
    return true;
}
void SystemWebViewWidget::clearProxy() {
    if (!hasExplicitProxySupport()) {
        return;
    }
    if (QThread::currentThread() != thread()) {
        const QPointer<SystemWebViewWidget> guard(this);
        QMetaObject::invokeMethod(
            this,
            [guard] {
                if (!guard.isNull()) {
                    guard->clearProxy();
                }
            },
            Qt::QueuedConnection);
        return;
    }
    webkit_website_data_manager_set_network_proxy_settings(
        d->websiteDataManager, WEBKIT_NETWORK_PROXY_MODE_DEFAULT, nullptr);
}
bool SystemWebViewWidget::hasExplicitProxySupport() const {
#if WEBKIT_CHECK_VERSION(2, 32, 0)
    return d->available && d->websiteDataManager != nullptr;
#else
    return false;
#endif
}
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
void SystemWebViewWidget::renderErrorPage(const QUrl& url, const QString& reason, int httpStatus) {
    if (!d->available || d->webView == nullptr) {
        return;
    }

    const QString title = QStringLiteral("Page could not be loaded");
    const QString reasonText = reason.isEmpty() ? QStringLiteral("The page could not be loaded successfully.") : reason;
    const QString statusText = httpStatus > 0 ? QStringLiteral("HTTP %1").arg(httpStatus) : QString();
    const QString html = QStringLiteral(
                             "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
                             "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
                             "<title>%1</title><style>"
                             ":root{color-scheme:light dark}html,body{height:100%}"
                             "body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:0;"
                             "background:#fff;color:#000}.card{max-width:720px;margin:8vh auto;padding:28px;"
                             "border-radius:16px;background:#fff;color:#000;box-shadow:0 6px 24px #0000002e}"
                             "code{overflow-wrap:anywhere;background:#eee;color:#000;padding:2px 6px;border-radius:6px}"
                             "@media(prefers-color-scheme:dark){body{background:#000;color:#fff}.card{background:#111;"
                             "color:#eee;box-shadow:0 6px 24px #ffffff0d}code{background:#222;color:#fff}}"
                             "</style></head><body><main class=\"card\"><h1>%1</h1><p>URL: <code>%2</code></p>"
                             "<p>%3 <small>%4</small></p></main></body></html>")
                             .arg(title.toHtmlEscaped(),
                                  url.toString().toHtmlEscaped(),
                                  reasonText.toHtmlEscaped(),
                                  statusText.toHtmlEscaped());

    d->httpErrorPending = false;
    d->internalErrorPageLoading = true;
    d->internalErrorPageCommitted = false;
    d->internalErrorUrl = url;
    d->loadFailed = true;
    const QByteArray htmlUtf8 = html.toUtf8();
    const QByteArray baseUri = url.toEncoded();
    webkit_web_view_load_html(d->nativeWebView(), htmlUtf8.constData(), baseUri.constData());
}
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
    quint64 token = ++captureToken;
    if (token == 0) {
        token = ++captureToken;
    }
    if (QThread::currentThread() == thread()) {
        return _captureVisiblePage_onGui(filePath, token);
    }

    const QPointer<SystemWebViewWidget> guard(this);
    QMetaObject::invokeMethod(
        this,
        [guard, filePath, token] {
            if (!guard.isNull()) {
                guard->_captureVisiblePage_onGui(filePath, token);
            }
        },
        Qt::QueuedConnection);
    return token;
}
quint64 SystemWebViewWidget::_captureVisiblePage_onGui(const QString& requestedPath, quint64 token) {
    const QString outputPath = requestedPath.trimmed();
    auto fail = [this, token, &requestedPath](const QString& error) {
        emit captureFinished(token, false, requestedPath, error);
        return token;
    };

    if (!d->available || d->webView == nullptr) {
        return fail(QStringLiteral("WebView is not available"));
    }
    if (outputPath.isEmpty()) {
        return fail(QStringLiteral("Empty output path"));
    }

    const QFileInfo outputInfo(outputPath);
    if (outputInfo.fileName().isEmpty() || outputInfo.isDir()) {
        return fail(QStringLiteral("Output path does not name a writable file"));
    }
    QDir parentDirectory = outputInfo.absoluteDir();
    if (!parentDirectory.exists() && !QDir().mkpath(parentDirectory.absolutePath())) {
        return fail(QStringLiteral("Cannot create capture directory: %1").arg(parentDirectory.absolutePath()));
    }
    const QFileInfo parentInfo(parentDirectory.absolutePath());
    if (!parentInfo.isDir() || !parentInfo.isWritable()) {
        return fail(QStringLiteral("Capture directory is not writable: %1").arg(parentDirectory.absolutePath()));
    }
    if (!gtk_widget_get_realized(d->webView)) {
        return fail(QStringLiteral("WebView is not realized"));
    }
    GtkAllocation allocation;
    gtk_widget_get_allocation(d->webView, &allocation);
    if (allocation.width <= 0 || allocation.height <= 0) {
        return fail(QStringLiteral("WebView has no visible viewport"));
    }

    auto* request = new CaptureRequest{QPointer<SystemWebViewWidget>(this), token, outputPath};
    webkit_web_view_get_snapshot(
        d->nativeWebView(),
        WEBKIT_SNAPSHOT_REGION_VISIBLE,
        WEBKIT_SNAPSHOT_OPTIONS_NONE,
        nullptr,
        snapshotFinished,
        request);
    return token;
}
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
