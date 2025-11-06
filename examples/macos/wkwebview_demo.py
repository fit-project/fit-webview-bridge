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


from PySide6.QtCore import QStandardPaths
from PySide6.QtWidgets import QFileDialog, QMessageBox


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
        self.btnShot = QPushButton("📸 Screenshot")

        self.address = QLineEdit()  # ← barra indirizzi
        self.address.setPlaceholderText("Digita un URL o una ricerca…")
        self.btnGo = QPushButton("Go")

        bar.addWidget(self.btnBack)
        bar.addWidget(self.btnFwd)
        bar.addWidget(self.btnHome)
        bar.addWidget(self.address, 1)  # ← occupa spazio elastico
        bar.addWidget(self.btnGo)
        bar.addWidget(self.btnShot)
        root.addLayout(bar)

        # --- webview ---
        self.view = WKWebViewWidget()
        root.addWidget(self.view)

        # handler screenshot
        self.btnShot.clicked.connect(self.take_screenshot)

        # collega il segnale di fine cattura (una volta sola è ok: filtriamo con token)
        self.view.captureFinished.connect(self.on_capture_finished)

        # token dell’ultima richiesta (per distinguere se fai più scatti)
        self._last_capture_token = None

        # segnali base
        self.view.titleChanged.connect(self.setWindowTitle)
        self.view.loadProgress.connect(lambda p: print("progress:", p))
        self.view.setUserAgent(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        )

        def on_load_finished():
            print("on_load_finished")
            tok = self.view.evaluateJavaScriptWithResult(
                "(() => ({ y: window.scrollY,"
                "         h: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight),"
                "         vh: window.innerHeight }))()"
            )

            def on_js(result, token, error):
                print(f"result: {result}")
                if token != tok:
                    return
                if error:
                    print("JS error:", error)
                    return
                # result è dict serializzato in JSON (se hai scelto la serializzazione)
                # oppure primitive QVariant: gestiscilo e continua il flow di screenshot

            self.view.javaScriptResult.connect(on_js)

        self.view.loadFinished.connect(on_load_finished)

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

    def take_screenshot(self):
        # cartella suggerita: Pictures/ o Desktop se non disponibile
        pics = (
            QStandardPaths.writableLocation(QStandardPaths.PicturesLocation)
            or QStandardPaths.writableLocation(QStandardPaths.DesktopLocation)
            or ""
        )
        # suggerisci PNG di default (puoi mettere .jpg per JPEG)
        suggested = os.path.join(pics, "snapshot.png") if pics else "snapshot.png"

        path, _ = QFileDialog.getSaveFileName(
            self,
            "Salva screenshot visibile",
            suggested,
            "PNG (*.png);;JPEG (*.jpg *.jpeg)",
        )
        if not path:
            return

        # CHIAMATA CHIAVE: ritorna un token per riconoscere l’operazione
        self._last_capture_token = self.view.captureVisiblePage(path)
        print(
            f"[screenshot] richiesto → token={self._last_capture_token}, path='{path}'"
        )

    def on_capture_finished(self, token, ok, filePath, error):
        # ignora screenshot vecchi se ne stai facendo un altro
        if self._last_capture_token is not None and token != self._last_capture_token:
            return

        if ok:
            print(f"[screenshot] OK  → token={token}, file='{filePath}'")
            QMessageBox.information(
                self, "Screenshot salvato", f"File salvato:\n{filePath}"
            )
        else:
            print(
                f"[screenshot] FAIL → token={token}, err='{error}', path='{filePath}'"
            )
            QMessageBox.critical(
                self,
                "Errore screenshot",
                error or "Impossibile salvare lo screenshot",
            )

        # opzionale: azzera il token
        self._last_capture_token = None


if __name__ == "__main__":
    app = QApplication([])
    m = Main()
    m.resize(1200, 800)
    m.show()
    app.exec()
