#pragma once
#include <QWidget>
#include <QObject>
#include <QUrl>

#include "DownloadInfo.h"

class QString; class QShowEvent; class QResizeEvent;

class WKWebViewWidget : public QWidget {
    Q_OBJECT
    Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)

public:
    explicit WKWebViewWidget(QWidget* parent = nullptr);
    ~WKWebViewWidget() override;

    Q_INVOKABLE QUrl url() const;
    Q_INVOKABLE void setUrl(const QUrl& url);

    Q_INVOKABLE void back();
    Q_INVOKABLE void forward();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void reload();
    Q_INVOKABLE void evaluateJavaScript(const QString& script);

    Q_INVOKABLE void setDownloadDirectory(const QString& dirPath);
    Q_INVOKABLE QString downloadDirectory() const;
    void renderErrorPage(const QUrl& url, const QString& reason, int httpStatus);

signals:
    void loadFinished(bool ok);
    void urlChanged(const QUrl& url);
    void titleChanged(const QString& title);
    void loadProgress(int percent);
    void canGoBackChanged(bool);
    void canGoForwardChanged(bool);
    


    void downloadStarted(const QString& suggestedFilename, const QString& destinationPath);
    void downloadProgress(qint64 bytesReceived, qint64 totalBytes);
    void downloadFinished(DownloadInfo* info);
    void downloadFailed(const QString& filePath, const QString& error);

protected:
    void showEvent(QShowEvent*) override;
    void resizeEvent(QResizeEvent*) override;

private:
    struct Impl; Impl* d = nullptr;
};
