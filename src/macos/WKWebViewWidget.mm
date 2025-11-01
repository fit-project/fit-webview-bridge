#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include "WKWebViewWidget.h"

#include <QtWidgets>
#include <QString>
#include <QUrl>

@class WKNavDelegate;
@class FitUrlMsgHandler;

struct WKWebViewWidget::Impl {
    WKWebView*        wk        = nil;
    WKNavDelegate*    delegate  = nil;
    WKUserContentController* ucc = nil;
    FitUrlMsgHandler* msg       = nil;
};

@interface WKNavDelegate : NSObject <WKNavigationDelegate>
@property(nonatomic, assign) WKWebViewWidget* owner;
@end

@implementation WKNavDelegate
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (!self.owner) return;
    if (webView.URL)
        emit self.owner->urlChanged(QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String)));
    emit self.owner->loadProgress(5);
    emit self.owner->canGoBackChanged(webView.canGoBack);
    emit self.owner->canGoForwardChanged(webView.canGoForward);
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    if (!self.owner) return;
    if (webView.URL)
        emit self.owner->urlChanged(QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String)));
    emit self.owner->loadProgress(50);
    emit self.owner->canGoBackChanged(webView.canGoBack);
    emit self.owner->canGoForwardChanged(webView.canGoForward);
}
- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    if (!self.owner) return;
    if (webView.URL)
        emit self.owner->urlChanged(QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String)));
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (!self.owner) return;
    emit self.owner->loadFinished(true);
    if (webView.URL)
        emit self.owner->urlChanged(QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String)));
    if (webView.title)
        emit self.owner->titleChanged(QString::fromUtf8(webView.title.UTF8String));
    emit self.owner->loadProgress(100);
    emit self.owner->canGoBackChanged(webView.canGoBack);
    emit self.owner->canGoForwardChanged(webView.canGoForward);
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (!self.owner) return;
    emit self.owner->loadFinished(false);
    emit self.owner->loadProgress(0);
    emit self.owner->canGoBackChanged(webView.canGoBack);
    emit self.owner->canGoForwardChanged(webView.canGoForward);
}
@end

// Handler per messaggi JS (SPA: pushState/replaceState/popstate/click)
@interface FitUrlMsgHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, assign) WKWebViewWidget* owner;
@end

@implementation FitUrlMsgHandler
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (!self.owner) return;
    if (![message.name isEqualToString:@"fitUrlChanged"]) return;
    if (![message.body isKindOfClass:[NSString class]]) return;
    QString s = QString::fromUtf8([(NSString*)message.body UTF8String]);
    emit self.owner->urlChanged(QUrl::fromEncoded(s.toUtf8()));
}
@end

// Conversione QUrl -> NSURL con forzatura http->https e normalizzazione user-input
static NSURL* toNSURL(QUrl u) {
    if (!u.isValid()) return nil;

    if (u.scheme().isEmpty())
        u = QUrl::fromUserInput(u.toString());

    // Forza sempre http -> https (nessuna eccezione)
    if (u.scheme() == "http")
        u.setScheme("https");

    if (u.isLocalFile())
        return [NSURL fileURLWithPath:[NSString stringWithUTF8String:u.toLocalFile().toUtf8().constData()]];

    const QByteArray enc = u.toString(QUrl::FullyEncoded).toUtf8();
    return [NSURL URLWithString:[NSString stringWithUTF8String:enc.constData()]];
}

WKWebViewWidget::WKWebViewWidget(QWidget* parent)
    : QWidget(parent), d(new Impl) {
    setAttribute(Qt::WA_NativeWindow, true);
    (void)winId();

    NSView* nsParent = (__bridge NSView*)reinterpret_cast<void*>(winId());
    WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
    if ([cfg respondsToSelector:@selector(defaultWebpagePreferences)]) {
        cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
    }

    // UserContentController + script per intercettare navigazioni SPA
    d->ucc = [WKUserContentController new];
    d->msg = [FitUrlMsgHandler new];
    d->msg.owner = this;
    [d->ucc addScriptMessageHandler:d->msg name:@"fitUrlChanged"];

    NSString* js =
        @"(function(){"
        @"  function emit(){"
        @"    try{ window.webkit.messageHandlers.fitUrlChanged.postMessage(location.href); }catch(e){}"
        @"  }"
        @"  var _ps = history.pushState;"
        @"  history.pushState = function(){ _ps.apply(this, arguments); emit(); };"
        @"  var _rs = history.replaceState;"
        @"  history.replaceState = function(){ _rs.apply(this, arguments); emit(); };"
        @"  window.addEventListener('popstate', emit, true);"
        @"  document.addEventListener('click', function(ev){"
        @"    var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;"
        @"    if (!a) return;"
        @"    if (a.target === '_blank' || a.hasAttribute('download')) return;"
        @"    setTimeout(emit, 0);"  // lascia tempo alla SPA di aggiornare l’URL
        @"  }, true);"
        @"})();";

    WKUserScript* us = [[WKUserScript alloc]
        initWithSource:js
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];

    [d->ucc addUserScript:us];
    cfg.userContentController = d->ucc;

    d->wk = [[WKWebView alloc] initWithFrame:nsParent.bounds configuration:cfg];
    d->wk.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [nsParent addSubview:d->wk];

    d->delegate = [WKNavDelegate new];
    d->delegate.owner = this;
    [d->wk setNavigationDelegate:d->delegate];
}

WKWebViewWidget::~WKWebViewWidget() {
    if (!d) return;
    if (d->ucc && d->msg) {
        @try { [d->ucc removeScriptMessageHandlerForName:@"fitUrlChanged"]; } @catch (...) {}
    }
    d->msg = nil;

    if (d->wk) { [d->wk removeFromSuperview]; d->wk = nil; }
    d->delegate = nil;
    d->ucc = nil;

    delete d; d = nullptr;
}

void WKWebViewWidget::showEvent(QShowEvent* e) { QWidget::showEvent(e); }
void WKWebViewWidget::resizeEvent(QResizeEvent* e) { QWidget::resizeEvent(e); }

QUrl WKWebViewWidget::url() const {
    if (!(d && d->wk)) return QUrl();
    NSURL* nsurl = d->wk.URL;
    if (!nsurl) return QUrl();
    const char* utf8 = nsurl.absoluteString.UTF8String;
    if (!utf8) return QUrl();
    return QUrl::fromEncoded(QByteArray(utf8));
}

void WKWebViewWidget::setUrl(const QUrl& u) {
    if (!(d && d->wk)) return;
    NSURL* nsurl = toNSURL(u);
    if (!nsurl) return;
    [d->wk loadRequest:[NSURLRequest requestWithURL:nsurl]];
}

void WKWebViewWidget::back()    { if (d && d->wk && d->wk.canGoBack)    [d->wk goBack]; }
void WKWebViewWidget::forward() { if (d && d->wk && d->wk.canGoForward) [d->wk goForward]; }
void WKWebViewWidget::stop()    { if (d && d->wk) [d->wk stopLoading:nil]; }
void WKWebViewWidget::reload()  { if (d && d->wk) [d->wk reload]; }
void WKWebViewWidget::evaluateJavaScript(const QString& script) {
    if (!d || !d->wk) return;
    NSString* s = [NSString stringWithUTF8String:script.toUtf8().constData()];
    [d->wk evaluateJavaScript:s completionHandler:^(id result, NSError* error){
        Q_UNUSED(result); Q_UNUSED(error);
    }];
}
