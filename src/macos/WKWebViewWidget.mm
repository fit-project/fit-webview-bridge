#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

#include "WKWebViewWidget.h"
#include "DownloadInfo.h"


static inline void fit_emit_downloadStarted(WKWebViewWidget* owner,
                                            const QString& name,
                                            const QString& path) {
    if (!owner) return;
    QMetaObject::invokeMethod(owner, [owner, name, path]{
        emit owner->downloadStarted(name, path);
    }, Qt::QueuedConnection);
}

static inline void fit_emit_downloadFailed(WKWebViewWidget* owner,
                                           const QString& path,
                                           const QString& err) {
    if (!owner) return;
    QMetaObject::invokeMethod(owner, [owner, path, err]{
        emit owner->downloadFailed(path, err);
    }, Qt::QueuedConnection);
}

static inline void fit_emit_downloadFinished(WKWebViewWidget* owner,
                                             const QString& fileName,
                                             const QString& dir,
                                             const QUrl& src) {
    if (!owner) return;
    QMetaObject::invokeMethod(owner, [owner, fileName, dir, src]{
        auto *info = new DownloadInfo(fileName, dir, src, owner);
        emit owner->downloadFinished(info);
    }, Qt::QueuedConnection);
}


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
@property(nonatomic, assign) WKWebView* webView;

- (void)_fitShowContextMenuFromPayload:(NSDictionary*)payload;
- (void)_fitOpenLink:(NSMenuItem*)item;
- (void)_fitCopyURL:(NSMenuItem*)item;
@end


static inline NSString* FITURLStr(NSURL *u) { return u ? u.absoluteString : @"(nil)"; }

static NSString* FIT_CurrentLang(void) {
    NSString *lang = NSLocale.preferredLanguages.firstObject ?: @"en";
    // normalizza es. "it-IT" -> "it"
    NSRange dash = [lang rangeOfString:@"-"];
    return (dash.location != NSNotFound) ? [lang substringToIndex:dash.location] : lang;
}

static NSString* FIT_T(NSString* key) {
    static NSDictionary *en, *it;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        en = @{
            @"menu.openLink":     @"Open link",
            @"menu.copyLink":     @"Copy link address",
            @"menu.openImage":    @"Open image",
            @"menu.copyImageURL": @"Copy image URL",
            @"menu.downloadImage":@"Download image…",
            @"error.title":    @"Can’t load this page",
            @"error.reason":   @"The site may not exist or be temporarily unreachable.",
            @"error.retry":    @"Retry",
            @"error.close":    @"Close",
        };
        it = @{
            @"menu.openLink":     @"Apri link",
            @"menu.copyLink":     @"Copia indirizzo link",
            @"menu.openImage":    @"Apri immagine",
            @"menu.copyImageURL": @"Copia URL immagine",
            @"menu.downloadImage":@"Scarica immagine…",
            @"error.title":    @"Impossibile caricare la pagina",
            @"error.reason":   @"Il sito potrebbe essere inesistente o momentaneamente non raggiungibile.",
            @"error.retry":    @"Riprova",
            @"error.close":    @"Chiudi",
        };
    });
    NSString *lang = FIT_CurrentLang();
    NSDictionary *tbl = [lang isEqualToString:@"it"] ? it : en;
    return tbl[key] ?: en[key] ?: key;
}

@implementation FitUrlMsgHandler

// Helpers per sanity-check su tipi da payload
static inline NSString* FITStringOrNil(id obj) {
    return [obj isKindOfClass:NSString.class] ? (NSString*)obj : nil;
}
static inline NSNumber* FITNumberOrNil(id obj) {
    return [obj isKindOfClass:NSNumber.class] ? (NSNumber*)obj : nil;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (!self.owner) return;

    if ([message.name isEqualToString:@"fitUrlChanged"]) {
        if (![message.body isKindOfClass:[NSString class]]) return;
        QString s = QString::fromUtf8([(NSString*)message.body UTF8String]);
        emit self.owner->urlChanged(QUrl::fromEncoded(s.toUtf8()));
        return;
    }

    if ([message.name isEqualToString:@"fitContextMenu"]) {
        if (![message.body isKindOfClass:[NSDictionary class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _fitShowContextMenuFromPayload:(NSDictionary*)message.body];
        });
        return;
    }
}

- (void)_fitShowContextMenuFromPayload:(NSDictionary*)payload
{
    WKWebView* wv = self.webView;
    if (!wv || !wv.window) return;

    NSString *linkStr = FITStringOrNil(payload[@"link"]);
    NSString *imgStr  = FITStringOrNil(payload[@"image"]);
    NSURL *linkURL = (linkStr.length ? [NSURL URLWithString:linkStr] : nil);
    NSURL *imgURL  = (imgStr.length  ? [NSURL URLWithString:imgStr]  : nil);
    if (!linkURL && !imgURL) return;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    if (linkURL) {
        NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:FIT_T(@"menu.openLink")
                                              action:@selector(_fitOpenLink:)
                                       keyEquivalent:@""];
        open.target = self; open.representedObject = @{@"url": linkURL};
        [menu addItem:open];

        NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:FIT_T(@"menu.copyLink")
                                              action:@selector(_fitCopyURL:)
                                       keyEquivalent:@""];
        copy.target = self; copy.representedObject = @{@"url": linkURL};
        [menu addItem:copy];
    }

    if (imgURL) {
        NSMenuItem *openImg = [[NSMenuItem alloc] initWithTitle:FIT_T(@"menu.openImage")
                                                 action:@selector(_fitOpenLink:)
                                          keyEquivalent:@""];
        openImg.target = self; openImg.representedObject = @{@"url": imgURL};
        [menu addItem:openImg];

        NSMenuItem *copyImg = [[NSMenuItem alloc] initWithTitle:FIT_T(@"menu.copyImageURL")
                                                 action:@selector(_fitCopyURL:)
                                          keyEquivalent:@""];
        copyImg.target = self; copyImg.representedObject = @{@"url": imgURL};
        [menu addItem:copyImg];

        NSMenuItem *dlImg = [[NSMenuItem alloc] initWithTitle:FIT_T(@"menu.downloadImage")
                                               action:@selector(_fitDownloadImage:)
                                        keyEquivalent:@""];
        dlImg.target = self;
        dlImg.representedObject = @{@"url": imgURL};
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:dlImg];
    }

    NSPoint mouseOnScreen = [NSEvent mouseLocation];
    NSPoint inWindow = [wv.window convertPointFromScreen:mouseOnScreen];
    NSPoint inView = [wv convertPoint:inWindow fromView:nil];

    [menu popUpMenuPositioningItem:nil atLocation:inView inView:wv];
}

- (void)_fitOpenLink:(NSMenuItem*)item {
    NSURL *url = ((NSDictionary*)item.representedObject)[@"url"];
    if (!url || !self.webView) return;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)_fitCopyURL:(NSMenuItem*)item {
    NSURL *url = ((NSDictionary*)item.representedObject)[@"url"];
    if (!url) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:url.absoluteString forType:NSPasteboardTypeString];
}

// Utility: crea nome unico in una cartella
static NSString* fit_uniquePath(NSString* baseDir, NSString* filename) {
    NSString* fname = filename.length ? filename : @"download";
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

// Scarica un URL (usato dall’azione immagine)
- (void)_fitDownloadURL:(NSURL *)url suggestedName:(NSString *)suggestedName {
    if (!url || !self.owner) return;

    // cartella destinazione da Qt
    QString qdir = self.owner->downloadDirectory();
    NSString *destDir = [NSString stringWithUTF8String:qdir.toUtf8().constData()];
    if (!destDir.length) destDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    // nome iniziale
    NSString *fname = suggestedName.length ? suggestedName : (url.lastPathComponent.length ? url.lastPathComponent : @"download");
    NSString *tmpTarget = fit_uniquePath(destDir, fname);

    // segnala start (nome provvisorio)
    fit_emit_downloadStarted(self.owner,
                             QString::fromUtf8([tmpTarget lastPathComponent].UTF8String),
                             QString::fromUtf8(tmpTarget.UTF8String));

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDownloadTask *task =
    [session downloadTaskWithURL:url
               completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
    {
        if (error) {
            fit_emit_downloadFailed(self.owner,
                QString::fromUtf8(tmpTarget.UTF8String),
                QString::fromUtf8(error.localizedDescription.UTF8String));
            return;
        }

        // usa il suggerimento del server se c’è
        NSString *serverName = response.suggestedFilename.length ? response.suggestedFilename : [tmpTarget lastPathComponent];
        NSString *finalPath  = fit_uniquePath(destDir, serverName);

        NSError *mvErr = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:finalPath]
                                                error:&mvErr];
        if (mvErr) {
            fit_emit_downloadFailed(self.owner,
                QString::fromUtf8(finalPath.UTF8String),
                QString::fromUtf8(mvErr.localizedDescription.UTF8String));
            return;
        }

        QUrl qsrc = QUrl::fromEncoded(QByteArray(url.absoluteString.UTF8String));
        fit_emit_downloadFinished(self.owner,
            QString::fromUtf8([finalPath lastPathComponent].UTF8String),
            QString::fromUtf8([finalPath stringByDeletingLastPathComponent].UTF8String),
            qsrc);
    }];
    [task resume];
}

- (void)_fitDownloadImage:(NSMenuItem*)item {
    NSURL *url = ((NSDictionary*)item.representedObject)[@"url"];
    [self _fitDownloadURL:url suggestedName:nil];
}
@end


// ===== WKNavDelegate =====
@interface WKNavDelegate : NSObject <WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate>
@property(nonatomic, assign) WKWebViewWidget* owner;
// mappe per download
@property(nonatomic, strong) NSMapTable<WKDownload*, NSString*>* downloadPaths;   // weak key -> strong value
@property(nonatomic, strong) NSMapTable<NSProgress*, WKDownload*>* progressToDownload; // weak->weak
@property(nonatomic, strong) NSHashTable<NSProgress*>* completedProgresses;      // weak set
@property(nonatomic, strong) NSMapTable<WKDownload*, NSNumber*>* expectedTotals; // weak->strong
@property(nonatomic, strong) NSMapTable<WKDownload*, NSURL*>*     sourceURLs;      // weak->strong
@property(nonatomic, strong) NSMapTable<WKDownload*, NSString*>*  suggestedNames;  // weak->strong
@property(nonatomic, strong) NSURL* pendingPopupParentURL;
@property(nonatomic, strong) NSURL* pendingPopupChildURL;
@property(nonatomic, assign) WKWebView* webView;
@end

@implementation WKNavDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _downloadPaths = [NSMapTable weakToStrongObjectsMapTable];
        _progressToDownload = [NSMapTable weakToWeakObjectsMapTable];
        _completedProgresses = [NSHashTable weakObjectsHashTable];
        _expectedTotals = [NSMapTable weakToStrongObjectsMapTable];
        _sourceURLs     = [NSMapTable weakToStrongObjectsMapTable];
        _suggestedNames = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

#pragma mark - Navigazione
// 1a) Navigation: intercetta click con targetFrame == nil (tipico di _blank)
- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    decisionHandler(WKNavigationActionPolicyAllow);
}


// 1b) UI: invocato quando la pagina chiede esplicitamente una nuova webview
- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
 forNavigationAction:(WKNavigationAction *)navigationAction
          windowFeatures:(WKWindowFeatures *)windowFeatures
{
    if (navigationAction.targetFrame == nil || !navigationAction.targetFrame.isMainFrame) {
        NSURL *parent = webView.URL;
        NSURL *child  = navigationAction.request.URL;

        // salva coppia padre/figlio per il “ritorno” post-download
        self.pendingPopupParentURL = parent;
        self.pendingPopupChildURL  = child;

        if (child) {
            [webView loadRequest:navigationAction.request];   // apri nella stessa webview
        }
    }

    return nil; // restituisci nil per NON creare una nuova finestra
}


- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error
{
    if (!self.owner) return;
    emit self.owner->loadFinished(false);
    emit self.owner->loadProgress(0);
    emit self.owner->canGoBackChanged(webView.canGoBack);
    emit self.owner->canGoForwardChanged(webView.canGoForward);

    QUrl qurl = webView.URL
        ? QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String))
        : QUrl();
    self.owner->renderErrorPage(qurl,
        QString::fromUtf8(error.localizedDescription.UTF8String),
        /*httpStatus*/ 0);
}



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
    // Mostra pagina d'errore interna
    QUrl qurl = webView.URL
    ? QUrl::fromEncoded(QByteArray(webView.URL.absoluteString.UTF8String))
    : QUrl();
    self.owner->renderErrorPage(qurl,
    QString::fromUtf8(error.localizedDescription.UTF8String),
    /*httpStatus*/ 0);
}

#pragma mark - Decide download vs render

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
    NSURLResponse *resp = navigationResponse.response;
    NSURL *url = resp.URL;

    BOOL isAttachment = NO;
    if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSString *cd = http.allHeaderFields[@"Content-Disposition"];
        if (cd && [[cd lowercaseString] containsString:@"attachment"]) {
            isAttachment = YES;
        }
        // 🔎 Se è main frame e status HTTP >= 400, mostra pagina d'errore custom
       if (navigationResponse.isForMainFrame && http.statusCode >= 400 && self.owner) {
           QUrl qurl = QUrl::fromEncoded(QByteArray(url.absoluteString.UTF8String));
           self.owner->renderErrorPage(qurl,
               QStringLiteral(""),             // reason generica localizzata dal template
                (int)http.statusCode);
            decisionHandler(WKNavigationResponsePolicyCancel);
           return;
       }
    }

    if (isAttachment) {
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }

    if (navigationResponse.canShowMIMEType) {
        decisionHandler(WKNavigationResponsePolicyAllow);
    } else {
        decisionHandler(WKNavigationResponsePolicyDownload);
    }
}

#pragma mark - Diventare download

- (void)webView:(WKWebView *)webView
navigationAction:(WKNavigationAction *)navigationAction
didBecomeDownload:(WKDownload *)download
{
    download.delegate = self;

    // URL sorgente (request dell’azione)
    if (navigationAction.request.URL) {
        [self.sourceURLs setObject:navigationAction.request.URL forKey:download];
    }

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

    if (navigationResponse.response.URL) {
        [self.sourceURLs setObject:navigationResponse.response.URL forKey:download];
    }

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

    // Leggi il Content-Length se disponibile e salvalo
    long long expected = response.expectedContentLength; // -1 se sconosciuto
    if (expected >= 0) {
        [self.expectedTotals setObject:@(expected) forKey:download];
        if (self.owner) {
            // progress iniziale (0 di total)
            emit self.owner->downloadProgress(0, expected);
        }
    }

    if (suggestedFilename) {
    [self.suggestedNames setObject:suggestedFilename forKey:download];
    } else if (![self.suggestedNames objectForKey:download]) {
        [self.suggestedNames setObject:@"download" forKey:download];
    }

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

    // Calcolo grezzo fuori dal main
    int64_t total = prog.totalUnitCount;     // -1 se sconosciuto
    int64_t done  = prog.completedUnitCount;

    // Dispatch su main, ma **ricontrolla** lo stato "completed" dentro al blocco
   // DOPO (compatibile MRC)
    __unsafe_unretained WKNavDelegate* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WKNavDelegate* strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.owner) return;

        // blocca update tardivi dopo finished/failed
        if ([strongSelf.completedProgresses containsObject:prog]) return;

        WKDownload* dl = [strongSelf.progressToDownload objectForKey:prog];
        NSNumber* exp = dl ? [strongSelf.expectedTotals objectForKey:dl] : nil;

        int64_t totalEff = (total >= 0 ? total : (exp ? exp.longLongValue : -1));
        emit strongSelf.owner->downloadProgress(done, totalEff);
    });


}

- (void)downloadDidFinish:(WKDownload *)download {
    if (!self.owner) return;

    // 1) stop KVO
    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        [download.progress removeObserver:self forKeyPath:@"completedUnitCount"];
        [download.progress removeObserver:self forKeyPath:@"totalUnitCount"];
    } @catch (...) {}

    // 2) marca come completato per filtrare update tardivi
    [self.completedProgresses addObject:download.progress];

    // 3) raccogli dati
    NSString* finalPath = [self.downloadPaths objectForKey:download];
    NSString* fname = [self.suggestedNames objectForKey:download];
    if (!fname && finalPath) fname = [finalPath lastPathComponent];
    NSString* dir = finalPath ? [finalPath stringByDeletingLastPathComponent] : nil;
    NSURL* src = [self.sourceURLs objectForKey:download];

    // 4) crea DownloadInfo* e emetti
    QString qFileName = fname ? QString::fromUtf8(fname.UTF8String) : QString();
    QString qDir      = dir   ? QString::fromUtf8(dir.UTF8String)   : QString();
    QUrl    qUrl      = src   ? QUrl::fromEncoded(QByteArray(src.absoluteString.UTF8String))
                              : QUrl();

    DownloadInfo* info = new DownloadInfo(qFileName, qDir, qUrl, self.owner);
    emit self.owner->downloadFinished(info);

    

    WKWebView *webView = self.webView;
    NSURL *srcURL = [self.sourceURLs objectForKey:download];

    if (webView && self.pendingPopupChildURL && srcURL &&
        [srcURL isEqual:self.pendingPopupChildURL]) {

        WKBackForwardList *bf = webView.backForwardList;
        NSURL *current = webView.URL;
        NSURL *backURL = bf.backItem.URL;

        // CASI:
        // A) Sei sul FIGLIO → torna indietro alla PARENT
        if (current && [current isEqual:self.pendingPopupChildURL]) {
            [webView goBack];
        }
        // B) Sei già sulla PARENT → non fare nulla
        else if (current && [current isEqual:self.pendingPopupParentURL]) {
            // niente
        }
        // C) Non sei sul child, ma l’item precedente è la PARENT → goBack
        else if (backURL && [backURL isEqual:self.pendingPopupParentURL]) {
            [webView goBack];
        }
        // D) Fallback: carica esplicitamente la PARENT
        else if (self.pendingPopupParentURL) {
            [webView loadRequest:[NSURLRequest requestWithURL:self.pendingPopupParentURL]];
        } else {
            //Niente
        }

        // pulizia stato
        self.pendingPopupChildURL = nil;
        self.pendingPopupParentURL = nil;
    }
    // 5) cleanup mappe
    if (finalPath) [self.downloadPaths removeObjectForKey:download];
    [self.progressToDownload removeObjectForKey:download.progress];
    [self.expectedTotals removeObjectForKey:download];
    [self.sourceURLs removeObjectForKey:download];
    [self.suggestedNames removeObjectForKey:download];
}


- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    if (!self.owner) return;

    // stop KVO
    @try {
        [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        [download.progress removeObserver:self forKeyPath:@"completedUnitCount"];
        [download.progress removeObserver:self forKeyPath:@"totalUnitCount"];
    } @catch (...) {}
    [self.completedProgresses addObject:download.progress];

    // path (se già deciso)
    NSString* finalPath = [self.downloadPaths objectForKey:download];
    emit self.owner->downloadFailed(
        finalPath ? QString::fromUtf8(finalPath.UTF8String) : QString(),
        QString::fromUtf8(error.localizedDescription.UTF8String)
    );

    // 🔙 Se il download proviene dal "figlio", torna alla "pagina padre"
    WKWebView *webView = self.webView;
    NSURL *src = [self.sourceURLs objectForKey:download];
    if (webView && self.pendingPopupChildURL && src && [src isEqual:self.pendingPopupChildURL]) {
        if (webView.canGoBack) {
            [webView goBack];
        } else if (self.pendingPopupParentURL) {
            [webView loadRequest:[NSURLRequest requestWithURL:self.pendingPopupParentURL]];
        }
        // ripulisci lo stato
        self.pendingPopupChildURL = nil;
        self.pendingPopupParentURL = nil;
    }

    // cleanup mappe
    if (finalPath) [self.downloadPaths removeObjectForKey:download];
    [self.progressToDownload removeObjectForKey:download.progress];
    [self.expectedTotals removeObjectForKey:download];
    [self.sourceURLs removeObjectForKey:download];
    [self.suggestedNames removeObjectForKey:download];
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

    // ✅ Consenti window.open() senza creare una nuova finestra UI
    @try {
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    } @catch (...) {}

    // --- Fullscreen HTML5 (via KVC tollerante) ---
    @try {
        [cfg.preferences setValue:@YES forKey:@"fullScreenEnabled"];
    } @catch (NSException *e) {
        // ignore if not available
    }

    // --- AirPlay & PiP via selector per compatibilità SDK ---
    if ([cfg respondsToSelector:@selector(setAllowsAirPlayForMediaPlayback:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(cfg, @selector(setAllowsAirPlayForMediaPlayback:), YES);
    }
    if ([cfg respondsToSelector:@selector(setAllowsPictureInPictureMediaPlayback:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(cfg, @selector(setAllowsPictureInPictureMediaPlayback:), YES);
    }

    // SPA: intercetta pushState/replaceState/popstate/click
    d->ucc = [WKUserContentController new];
    d->msg = [FitUrlMsgHandler new];
    d->msg.owner = this;
    [d->ucc addScriptMessageHandler:d->msg name:@"fitUrlChanged"];
    [d->ucc addScriptMessageHandler:d->msg name:@"fitContextMenu"];

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
        @"})();"
        @"(function(){"
        @"  document.addEventListener('contextmenu', function(ev){"
        @"    var el = ev.target;"
        @"    var a = el && el.closest ? el.closest('a[href]') : null;"
        @"    var img = el && el.closest ? el.closest('img[src]') : null;"
        @"    if (!a && !img) return;"   // lascia il menu nativo altrove
        @"    ev.preventDefault();"
        @"    try {"
        @"      window.webkit.messageHandlers.fitContextMenu.postMessage({"
        @"        x: ev.clientX, y: ev.clientY,"
        @"        link: a ? a.href : null,"
        @"        image: img ? img.src : null"
        @"      });"
        @"    } catch(e){}"
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
    [d->msg setWebView:d->wk];
    [nsParent addSubview:d->wk];

    d->delegate = [WKNavDelegate new];
    d->delegate.owner = this;
    d->delegate.webView = d->wk;
    [d->wk setNavigationDelegate:d->delegate];
    [d->wk setUIDelegate:d->delegate];
}

WKWebViewWidget::~WKWebViewWidget() {
    if (!d) return;

    if (d->ucc && d->msg) {
        @try { [d->ucc removeScriptMessageHandlerForName:@"fitUrlChanged"]; } @catch (...) {}
        @try { [d->ucc removeScriptMessageHandlerForName:@"fitContextMenu"]; } @catch (...) {}
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

void WKWebViewWidget::renderErrorPage(const QUrl& url,
                                      const QString& reason,
                                      int httpStatus)
{
    if (!(d && d->wk)) return;

    // Template HTML minimale, con testo bilingue (IT/EN tramite FIT_T).
    // Segnaposti: {url}, {reason}, {status}, {title}, {retry}, {close}
   QString html = QString::fromUtf8(
        R"FWB(<!doctype html><html lang="it"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>{title}</title>
        <style>
        :root { color-scheme: light dark; }
        html,body{height:100%}
        body{
            font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;
            margin:0;background:#fff;color:#000
        }
        @media (prefers-color-scheme: dark){
            body{background:#000;color:#fff}
        }
        .card{
            max-width:720px;margin:8vh auto;padding:28px;border-radius:16px;
            background:#fff;color:#000;box-shadow:0 6px 24px rgba(0,0,0,.18)
        }
        @media (prefers-color-scheme: dark){
            .card{background:#111;color:#eee;box-shadow:0 6px 24px rgba(255,255,255,.05)}
        }
        h1{font-size:22px;margin:0 0 6px}
        p{line-height:1.5}
        code{
            background:#eee;color:#000;padding:2px 6px;border-radius:6px
        }
        @media (prefers-color-scheme: dark){
            code{background:#222;color:#fff}
        }
        .actions{margin-top:18px;display:flex;gap:10px;flex-wrap:wrap}
        button,a{
            padding:10px 14px;border-radius:10px;border:1px solid currentColor;
            cursor:pointer;text-decoration:none;background:transparent;color:inherit
        }
        button.primary{
            background:#000;color:#fff;border-color:#000
        }
        @media (prefers-color-scheme: dark){
            button.primary{background:#fff;color:#000;border-color:#fff}
        }
        small{opacity:.7}
        </style>
        <div class="card">
        <h1>{title}</h1>
        <p>URL: <code>{url}</code></p>
        <p>{reason} <small>{status}</small></p>
        <div class="actions">
            <button class="primary" onclick="location.reload()">{retry}</button>
            <a class="ghost" href="about:blank">{close}</a>
        </div>
        </div>)FWB"
    );



    // Localizza con FIT_T
    QString title = QString::fromUtf8([FIT_T(@"error.title") UTF8String]);
    QString reasonText = reason.isEmpty()
        ? QString::fromUtf8([FIT_T(@"error.reason") UTF8String])
        : reason;
    QString retry = QString::fromUtf8([FIT_T(@"error.retry") UTF8String]);
    QString close = QString::fromUtf8([FIT_T(@"error.close") UTF8String]);

    html.replace("{title}",  title);
    html.replace("{url}",    url.toString());
    html.replace("{reason}", reasonText);
    html.replace("{status}", httpStatus > 0 ? QString("HTTP %1").arg(httpStatus) : QString());
    html.replace("{retry}",  retry);
    html.replace("{close}",  close);

    // Carica l'HTML direttamente nella webview
    [d->wk loadHTMLString:[NSString stringWithUTF8String:html.toUtf8().constData()]
                  baseURL:[NSURL URLWithString:@"about:blank"]];
}