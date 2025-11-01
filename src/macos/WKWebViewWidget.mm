#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include "WKWebViewWidget.h"

#include <QtWidgets>
#include <QString>
#include <QUrl>
#include <QDir>

@class WKNavDelegate;
@class FitUrlMsgHandler;

// =======================
// Impl
// =======================
struct WKWebViewWidget::Impl {
    WKWebView*               wk        = nil;
    WKNavDelegate*           delegate  = nil;
    WKUserContentController* ucc       = nil;
    FitUrlMsgHandler*        msg       = nil;
    QString                  downloadDir; // es. ~/Downloads
};

// =======================
// Helpers forward
// =======================
static NSURL* toNSURL(QUrl u);

// =======================
// SPA message handler
// =======================
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

// =======================
// Navigation + Download delegate
// =======================
@interface WKNavDelegate : NSObject <WKNavigationDelegate, WKDownloadDelegate>
@property(nonatomic, assign) WKWebViewWidget* owner;
// stato download (nel delegate, non toccare i privati del widget)
@property(nonatomic, strong) NSMapTable<WKDownload*, NSString*>* downloadPaths;
@end

@implementation WKNavDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _downloadPaths = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

#pragma mark - Navigazione

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

#pragma mark - Decide download vs render

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    if (navigationResponse.canShowMIMEType) {
        decisionHandler(WKNavigationResponsePolicyAllow);
    } else {
        // API moderna: "Download" (non BecomeDownload)
        decisionHandler(WKNavigationResponsePolicyDownload);
    }
}

#pragma mark - Diventare download

- (void)webView:(WKWebView *)webView
navigationAction:(WKNavigationAction *)navigationAction
didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    if (self.owner) {
        emit self.owner->downloadStarted(QString(), QString());
    }
    // Progress via NSProgress (best effort): alcuni siti non lo popolano
    [download.progress addObserver:self
                        forKeyPath:@"fractionCompleted"
                           options:NSKeyValueObservingOptionNew
                           context:NULL];
}

- (void)webView:(WKWebView *)webView
navigationResponse:(WKNavigationResponse *)navigationResponse
didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;

    NSString* suggested = navigationResponse.response.suggestedFilename ?: @"download";
    if (self.owner) {
        QString destDir = self.owner->downloadDirectory();
        QString destPath = destDir + "/" + QString::fromUtf8(suggested.UTF8String);
        emit self.owner->downloadStarted(QString::fromUtf8(suggested.UTF8String),
                                         destPath);
    }
    [download.progress addObserver:self
                        forKeyPath:@"fractionCompleted"
                           options:NSKeyValueObservingOptionNew
                           context:NULL];
}

#pragma mark - Scegli destinazione

static NSString* uniquePath(NSString* baseDir, NSString* filename) {
    NSString* fname = filename ?: @"download";
    NSString* path = [baseDir stringByAppendingPathComponent:fname];
    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return path;

    NSString* name = [fname stringByDeletingPathExtension];
    NSString* ext  = [fname pathExtension];
    for (NSUInteger i = 1; i < 10000; ++i) {
        NSString* cand = ext.length
            ? [NSString stringWithFormat:@"%@ (%lu).%@", name, (unsigned long)i, ext]
            : [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)i];
        NSString* candPath = [baseDir stringByAppendingPathComponent:cand];
        if (![fm fileExistsAtPath:candPath]) return candPath;
    }
    return path;
}

- (void)download:(WKDownload *)download
decideDestinationUsingResponse:(NSURLResponse *)response
suggestedFilename:(NSString *)suggestedFilename
completionHandler:(void (^)(NSURL * _Nullable destination))completionHandler
{
    if (!self.owner) { completionHandler(nil); return; }

    QString qdir = self.owner->downloadDirectory();
    NSString* dir = [NSString stringWithUTF8String:qdir.toUtf8().constData()];
    if (!dir.length) {
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    NSString* finalPath = uniquePath(dir, suggestedFilename ?: @"download");
    [self.downloadPaths setObject:finalPath forKey:download];

    emit self.owner->downloadStarted(
        QString::fromUtf8((suggestedFilename ?: @"download").UTF8String),
        QString::fromUtf8(finalPath.UTF8String)
    );

    completionHandler([NSURL fileURLWithPath:finalPath]);
}

#pragma mark - Progress / Fine / Errore

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)obj
                        change:(NSDictionary *)change context:(void *)ctx
{
    if (![keyPath isEqualToString:@"fractionCompleted"]) {
        [super observeValueForKeyPath:keyPath ofObject:obj change:change context:ctx];
        return;
    }
    if (!self.owner) return;

    NSProgress* prog = (NSProgress*)obj;
    int64_t total = prog.totalUnitCount;     // può essere -1 (sconosciuto)
    int64_t done  = prog.completedUnitCount;
    emit self.owner->downloadProgress(done, total >= 0 ? total : -1);
}

- (void)downloadDidFinish:(WKDownload *)download {
    if (!self.owner) return;

    @try { [download.progress removeObserver:self forKeyPath:@"fractionCompleted"]; } @catch (...) {}

    NSString* finalPath = [self.downloadPaths objectForKey:download];
    if (finalPath) {
        emit self.owner->downloadFinished(QString::fromUtf8(finalPath.UTF8String));
        [self.downloadPaths removeObjectForKey:download];
    } else {
        emit self.owner->downloadFinished(QString());
    }
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    if (!self.owner) return;

    @try { [download.progress removeObserver:self forKeyPath:@"fractionCompleted"]; } @catch (...) {}

   NSString* finalPath = [self.downloadPaths objectForKey:download];
    QString qpath = finalPath ? QString::fromUtf8(finalPath.UTF8String) : QString();
    emit self.owner->downloadFailed(qpath, QString::fromUtf8(error.localizedDescription.UTF8String));
    if (finalPath) [self.downloadPaths removeObjectForKey:download];
}

@end

// =======================
// QUrl -> NSURL (normalizza e forza https)
// =======================
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

// =======================
// WKWebViewWidget
// =======================
WKWebViewWidget::WKWebViewWidget(QWidget* parent)
    : QWidget(parent), d(new Impl) {
    setAttribute(Qt::WA_NativeWindow, true);
    (void)winId();

    d->downloadDir = QDir::homePath() + "/Downloads";

    NSView* nsParent = (__bridge NSView*)reinterpret_cast<void*>(winId());
    WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
    if ([cfg respondsToSelector:@selector(defaultWebpagePreferences)]) {
        cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
    }

    // SPA: intercetta pushState/replaceState/popstate/click
    d->ucc = [WKUserContentController new];
    d->msg = [FitUrlMsgHandler new];
    d->msg.owner = this;
    [d->ucc addScriptMessageHandler:d->msg name:@"fitUrlChanged"];

    NSString* js =
        @"(function(){"
        @"  function emit(){ try{ window.webkit.messageHandlers.fitUrlChanged.postMessage(location.href); }catch(e){} }"
        @"  var _ps = history.pushState; history.pushState = function(){ _ps.apply(this, arguments); emit(); };"
        @"  var _rs = history.replaceState; history.replaceState = function(){ _rs.apply(this, arguments); emit(); };"
        @"  window.addEventListener('popstate', emit, true);"
        @"  document.addEventListener('click', function(ev){"
        @"    var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;"
        @"    if (!a) return; if (a.target === '_blank' || a.hasAttribute('download')) return;"
        @"    setTimeout(emit, 0);"
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

// =======================
// Download directory API
// =======================
QString WKWebViewWidget::downloadDirectory() const {
    return d ? d->downloadDir : QString();
}

void WKWebViewWidget::setDownloadDirectory(const QString& dirPath) {
    if (!d) return;
    QString p = QDir::fromNativeSeparators(dirPath);
    if (p.endsWith('/')) p.chop(1);
    if (p.isEmpty()) return;
    QDir().mkpath(p);
    d->downloadDir = p;
}