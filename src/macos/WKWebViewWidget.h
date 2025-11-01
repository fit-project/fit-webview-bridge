#pragma once
#include <QWidget>
#include <QObject>
#include <QUrl>

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

signals:
    void loadFinished(bool ok);
    void urlChanged(const QUrl& url);
    void titleChanged(const QString& title);
    void loadProgress(int percent);
    void canGoBackChanged(bool);
    void canGoForwardChanged(bool);

protected:
    void showEvent(QShowEvent*) override;
    void resizeEvent(QResizeEvent*) override;

private:
    struct Impl; Impl* d = nullptr;
};
