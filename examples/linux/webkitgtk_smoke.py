import sys

from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication, QMainWindow

import systemwebview


def main() -> int:
    app = QApplication(sys.argv)
    window = QMainWindow()
    window.setWindowTitle("FIT WebView Bridge — Linux WebKitGTK smoke test")

    web_view = systemwebview.SystemWebViewWidget()
    window.setCentralWidget(web_view)
    window.resize(1024, 720)
    web_view.setUrl(QUrl("https://www.google.com"))
    window.show()

    # Exercise geometry propagation after the native view has been embedded.
    QTimer.singleShot(1500, lambda: window.resize(1200, 800))
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
