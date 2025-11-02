#pragma once
#include <QObject>
#include <QString>
#include <QUrl>

class DownloadInfo : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString downloadFileName READ downloadFileName CONSTANT)
    Q_PROPERTY(QString downloadDirectory READ downloadDirectory CONSTANT)
    Q_PROPERTY(QUrl    downloadUrl      READ downloadUrl      CONSTANT)
public:
    explicit DownloadInfo(const QString& fileName,
                          const QString& directory,
                          const QUrl& url,
                          QObject* parent=nullptr)
        : QObject(parent), m_fileName(fileName), m_directory(directory), m_url(url) {}

    QString downloadFileName() const { return m_fileName; }
    QString downloadDirectory() const { return m_directory; }
    QUrl    downloadUrl()      const { return m_url; }

private:
    QString m_fileName;
    QString m_directory;
    QUrl    m_url;
};
