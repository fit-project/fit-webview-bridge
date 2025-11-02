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

// ===== WKNavDelegate =====
@interface WKNavDelegate : NSObject <WKNavigationDelegate, WKDownloadDelegate>
@property(nonatomic, assign) WKWebViewWidget* owner;
// mappe per download
@property(nonatomic, strong) NSMapTable<WKDownload*, NSString*>* downloadPaths;   // weak key -> strong value
@property(nonatomic, strong) NSMapTable<NSProgress*, WKDownload*>* progressToDownload; // weak->weak
@property(nonatomic, strong) NSHashTable<NSProgress*>* completedProgresses;      // weak set
@end

@implementation WKNavDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _downloadPaths = [NSMapTable weakToStrongObjectsMapTable];
        _progressToDownload = [NSMapTable weakToWeakObjectsMapTable];
        _completedProgresses = [NSHashTable weakObjectsHashTable];
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
        decisionHandler(WKNavigationResponsePolicyDownload); // API moderna
    }
}

#pragma mark - Diventare download

- (void)webView:(WKWebView *)webView
navigationAction:(WKNavigationAction *)navigationAction
didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;
    if (self.owner) emit self.owner->downloadStarted(QString(), QString());

    // KVO su NSProgress (3 keyPath, con INITIAL)
    [download.progress addObserver:self forKeyPath:@"fractionCompleted"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];
    [download.progress addObserver:self forKeyPath:@"completedUnitCount"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];
    [download.progress addObserver:self forKeyPath:@"totalUnitCount"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];

    [self.progressToDownload setObject:download forKey:download.progress];
}

- (void)webView:(WKWebView *)webView
navigationResponse:(WKNavigationResponse *)navigationResponse
didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;

    NSString* suggested = navigationResponse.response.suggestedFilename ?: @"download";
    if (self.owner) {
        QString dir = self.owner->downloadDirectory();
        QString path = dir + "/" + QString::fromUtf8(suggested.UTF8String);
        emit self.owner->downloadStarted(QString::fromUtf8(suggested.UTF8String), path);
    }

    [download.progress addObserver:self forKeyPath:@"fractionCompleted"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];
    [download.progress addObserver:self forKeyPath:@"completedUnitCount"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];
    [download.progress addObserver:self forKeyPath:@"totalUnitCount"
                           options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                           context:NULL];

    [self.progressToDownload setObject:download forKey:download.progress];
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
    if (!dir.length) dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];

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
    if (![obj isKindOfClass:[NSProgress class]] || !self.owner) {
        [super observeValueForKeyPath:keyPath ofObject:obj change:change context:ctx];
        return;
    }
    NSProgress* prog = (NSProgress*)obj;

    // ignora aggiornamenti dopo il completamento
    if ([self.completedProgresses containsObject:prog]) return;

    int64_t total = prog.totalUnitCount;     // -1 se sconosciuto
    int64_t done  = prog.completedUnitCount;

    dispatch_async(dispatch_get_main_queue(), ^{
        emit self.owner->downloadProgress(done, (total >= 0 ? total : -1));
    });
}

- (void)downloadDidFinish:(WKDownload *)download {
    if (!self.owner) return;

    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        [download.progress removeObserver:self forKeyPath:@"completedUnitCount"];
        [download.progress removeObserver:self forKeyPath:@"totalUnitCount"];
    } @catch (...) {}

    [self.completedProgresses addObject:download.progress];

    NSString* finalPath = [self.downloadPaths objectForKey:download];
    emit self.owner->downloadFinished(finalPath ? QString::fromUtf8(finalPath.UTF8String) : QString());
    if (finalPath) [self.downloadPaths removeObjectForKey:download];
    [self.progressToDownload removeObjectForKey:download.progress];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    if (!self.owner) return;

    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        [download.progress removeObserver:self forKeyPath:@"completedUnitCount"];
        [download.progress removeObserver:self forKeyPath:@"totalUnitCount"];
    } @catch (...) {}

    [self.completedProgresses addObject:download.progress];

    NSString* finalPath = [self.downloadPaths objectForKey:download];
    emit self.owner->downloadFailed(
        finalPath ? QString::fromUtf8(finalPath.UTF8String) : QString(),
        QString::fromUtf8(error.localizedDescription.UTF8String)
    );
    if (finalPath) [self.downloadPaths removeObjectForKey:download];
    [self.progressToDownload removeObjectForKey:download.progress];
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