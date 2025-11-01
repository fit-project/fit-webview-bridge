import os, sys
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path[:0] = [os.path.join(ROOT, "build"),
                os.path.join(ROOT, "build", "bindings", "shiboken_out")]


from PySide6.QtWidgets import QApplication, QMainWindow, QWidget, QVBoxLayout
from fit_webview_bridge import SystemWebView
# tentativo 1: pacchetto generato da shiboken (wkwebview)
try:
    import wkwebview
    WKWebViewWidget = wkwebview.WKWebViewWidget  # accesso via attributo
except Exception:
    # tentativo 2: modulo nativo diretto
    from _wkwebview import WKWebViewWidget


class Main(QMainWindow):
    def __init__(self):
        super().__init__()
        central = QWidget(self)
        lay = QVBoxLayout(central)
        self.view = WKWebViewWidget()
        lay.addWidget(self.view)
        self.setCentralWidget(central)

        # segnali utili
        self.view.titleChanged.connect(self.setWindowTitle)
        self.view.loadProgress.connect(lambda p: print("progress:", p))

        self.view.load("https://www.facebook.com/reel/574839388710756/")

app = QApplication([])
m = Main()
m.resize(1200, 800)
m.show()
app.exec()
