#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include "WKWebViewWidget.h"

#include <QtWidgets>
#include <QString>
#include <QUrl>

@class WKNavDelegate;

struct WKWebViewWidget::Impl {
    WKWebView*     wk       = nil;
    WKNavDelegate* delegate = nil;
};

@interface WKNavDelegate : NSObject <WKNavigationDelegate>
@property(nonatomic, assign) WKWebViewWidget* owner;
@end

@implementation WKNavDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (!self.owner) return;
    emit self.owner->loadFinished(true);
    if (webView.URL) emit self.owner->urlChanged(QUrl(QString::fromUtf8(webView.URL.absoluteString.UTF8String)));
    if (webView.title) emit self.owner->titleChanged(QString::fromUtf8(webView.title.UTF8String));
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
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (self.owner) emit self.owner->loadProgress(5);
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    if (self.owner) emit self.owner->loadProgress(50);
}
@end

static NSURL* toNSURL(QString u) {
    u = u.trimmed();
    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "https://" + u;
    return [NSURL URLWithString:[NSString stringWithUTF8String:u.toUtf8().constData()]];
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
    d->wk = [[WKWebView alloc] initWithFrame:nsParent.bounds configuration:cfg];
    d->wk.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [nsParent addSubview:d->wk];

    d->delegate = [WKNavDelegate new];
    d->delegate.owner = this;
    [d->wk setNavigationDelegate:d->delegate];

    load(QStringLiteral("https://example.org"));
}

WKWebViewWidget::~WKWebViewWidget() {
    if (!d) return;
    if (d->wk) { [d->wk removeFromSuperview]; d->wk = nil; }
    d->delegate = nil;
    delete d; d = nullptr;
}

void WKWebViewWidget::showEvent(QShowEvent* e) { QWidget::showEvent(e); /* opzionale */ }
void WKWebViewWidget::resizeEvent(QResizeEvent* e) { QWidget::resizeEvent(e); /* opzionale */ }

void WKWebViewWidget::load(const QString& url) {
    if (d && d->wk) [d->wk loadRequest:[NSURLRequest requestWithURL:toNSURL(url)]];
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
