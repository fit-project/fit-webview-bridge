#include "fit_webview_bridge/SystemWebViewWidget.h"

#include <QApplication>
#include <QDebug>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QtMath>
#include <QMouseEvent>
#include <QResizeEvent>
#include <QShowEvent>
#include <QTimer>
#include <QVBoxLayout>
#include <QVariant>
#include <QWindow>

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

} // namespace

struct SystemWebViewWidget::Impl {
    SystemWebViewWidget* owner = nullptr;
    GtkWidget* plug = nullptr;
    GtkWidget* webView = nullptr;
    QWindow* foreignWindow = nullptr;
    QWidget* container = nullptr;
    QTimer* glibPump = nullptr;
    QUrl currentUrl;
    QString currentTitle;
    int currentProgress = -1;
    bool loadFailed = false;
    bool canGoBack = false;
    bool canGoForward = false;
    bool available = false;

    WebKitWebView* nativeWebView() const { return WEBKIT_WEB_VIEW(webView); }

    void updateUrl() {
        const char* uri = webkit_web_view_get_uri(nativeWebView());
        const QUrl url = uri != nullptr ? QUrl(QString::fromUtf8(uri)) : QUrl();
        if (currentUrl == url) {
            return;
        }
        currentUrl = url;
        emit owner->urlChanged(url);
        emit owner->navigationDisplayUrlChanged(url);
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
            } else if (event == WEBKIT_LOAD_FINISHED) {
                self->d->updateUrl();
                self->d->updateTitle();
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
void SystemWebViewWidget::clearWebsiteData() { warnUnsupported("clearWebsiteData()"); }
void SystemWebViewWidget::clearCacheData() { warnUnsupported("clearCacheData()"); }
bool SystemWebViewWidget::setProxy(const QString&, int) { warnUnsupported("setProxy()"); return false; }
void SystemWebViewWidget::clearProxy() { warnUnsupported("clearProxy()"); }
bool SystemWebViewWidget::hasExplicitProxySupport() const { return false; }
void SystemWebViewWidget::evaluateJavaScript(const QString&) { warnUnsupported("evaluateJavaScript()"); }
quint64 SystemWebViewWidget::evaluateJavaScriptWithResult(const QString&) {
    warnUnsupported("evaluateJavaScriptWithResult()");
    emit javaScriptResult(QVariant(), 0, QString::fromLatin1(unsupportedMessage));
    return 0;
}
void SystemWebViewWidget::setDownloadDirectory(const QString&) { warnUnsupported("setDownloadDirectory()"); }
QString SystemWebViewWidget::downloadDirectory() const { return {}; }
void SystemWebViewWidget::renderErrorPage(const QUrl&, const QString&, int) { warnUnsupported("renderErrorPage()"); }
void SystemWebViewWidget::setUserAgent(const QString&) { warnUnsupported("setUserAgent()"); }
QString SystemWebViewWidget::userAgent() const { return {}; }
void SystemWebViewWidget::resetUserAgent() { warnUnsupported("resetUserAgent()"); }
void SystemWebViewWidget::setApplicationNameForUserAgent(const QString&) {
    warnUnsupported("setApplicationNameForUserAgent()");
}
quint64 SystemWebViewWidget::captureVisiblePage(const QString& filePath) {
    warnUnsupported("captureVisiblePage()");
    emit captureFinished(0, false, filePath, QString::fromLatin1(unsupportedMessage));
    return 0;
}
quint64 SystemWebViewWidget::_captureVisiblePage_onGui(const QString&, quint64) { return 0; }
void SystemWebViewWidget::applyUserAgent() {}
