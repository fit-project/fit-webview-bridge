import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path[:0] = [
    os.path.join(ROOT, "build"),
    os.path.join(ROOT, "build", "bindings", "shiboken_out"),
]

from PySide6.QtCore import QUrl
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLineEdit,
    QMainWindow,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

# tentativo 1: pacchetto generato da shiboken (wkwebview)
try:
    import wkwebview

    WKWebViewWidget = wkwebview.WKWebViewWidget
except Exception:
    # tentativo 2: modulo nativo diretto
    from _wkwebview import WKWebViewWidget


HOME_URL = "https://github.com/fit-project"


class Main(QMainWindow):
    def __init__(self):
        super().__init__()

        central = QWidget(self)
        root = QVBoxLayout(central)
        self.setCentralWidget(central)

        # --- toolbar: back/forward/home + address bar + go ---
        bar = QHBoxLayout()
        self.btnBack = QPushButton("◀︎ Back")
        self.btnFwd = QPushButton("Forward ▶︎")
        self.btnHome = QPushButton("🏠 Home")

        self.address = QLineEdit()  # ← barra indirizzi
        self.address.setPlaceholderText("Digita un URL o una ricerca…")
        self.btnGo = QPushButton("Go")

        bar.addWidget(self.btnBack)
        bar.addWidget(self.btnFwd)
        bar.addWidget(self.btnHome)
        bar.addWidget(self.address, 1)  # ← occupa spazio elastico
        bar.addWidget(self.btnGo)
        root.addLayout(bar)

        # --- webview ---
        self.view = WKWebViewWidget()
        root.addWidget(self.view)

        # segnali base
        self.view.titleChanged.connect(self.setWindowTitle)
        self.view.loadProgress.connect(lambda p: print("progress:", p))

        # abilita/disabilita i bottoni in base alla navigazione
        self.btnBack.setEnabled(False)
        self.btnFwd.setEnabled(False)
        self.view.canGoBackChanged.connect(self.btnBack.setEnabled)
        self.view.canGoForwardChanged.connect(self.btnFwd.setEnabled)

        # azioni bottoni
        self.btnBack.clicked.connect(self.view.back)
        self.btnFwd.clicked.connect(self.view.forward)
        self.btnHome.clicked.connect(lambda: self.view.setUrl(QUrl(HOME_URL)))

        # --- address bar: invio / bottone Go ---
        def navigate_from_address():
            text = (self.address.text() or "").strip()
            if not text:
                return
            url = QUrl.fromUserInput(text)  # gestisce http/https, domini, file, ecc.
            self.view.setUrl(url)

        self.address.returnPressed.connect(navigate_from_address)
        self.btnGo.clicked.connect(navigate_from_address)

        # mantieni sincronizzata la barra con la URL corrente
        self.view.urlChanged.connect(lambda u: self.address.setText(u.toString()))

        # --- eventi download: print semplici ---
        self.view.downloadStarted.connect(
            lambda name, path: print(f"[download] started: name='{name}' path='{path}'")
        )
        self.view.downloadProgress.connect(
            lambda done, total: print(
                f"[download] progress: {done}/{total if total >= 0 else '?'}"
            )
        )
        self.view.downloadFailed.connect(
            lambda path, err: print(f"[download] FAILED: path='{path}' err='{err}'")
        )

        def on_finished(info):
            try:
                fname = info.fileName() if hasattr(info, "fileName") else None
                directory = info.directory() if hasattr(info, "directory") else None
                url = info.url().toString() if hasattr(info, "url") else None
                if fname or directory or url:
                    print(
                        f"[download] finished: file='{fname}' dir='{directory}' url='{url}'"
                    )
                else:
                    print(f"[download] finished: {info}")
            except Exception as e:
                print(f"[download] finished (inspect error: {e}): {info}")

        self.view.downloadFinished.connect(on_finished)

        # carica home e imposta barra
        self.view.setUrl(QUrl(HOME_URL))
        self.address.setText(HOME_URL)


if __name__ == "__main__":
    app = QApplication([])
    m = Main()
    m.resize(1200, 800)
    m.show()
    app.exec()
