import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication, QLabel, QLineEdit, QPushButton, QVBoxLayout, QWidget

from fit_webview_bridge import systemwebview


PAGE = b"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Focus and input smoke</title>
  <style>
    body { font: 16px sans-serif; padding: 12px; }
    input, textarea, [contenteditable], button { display: block; margin: 8px 0; min-width: 320px; }
    [contenteditable] { border: 1px solid #777; min-height: 45px; padding: 4px; }
    #selectable { user-select: text; }
  </style>
</head>
<body>
  <input id="text" placeholder="Text input">
  <input id="search" type="search" placeholder="Search input">
  <textarea id="textarea" placeholder="Textarea"></textarea>
  <div id="editable" contenteditable="true">Editable text</div>
  <p id="selectable">FIT selectable clipboard text</p>
  <button id="first-button">First button</button>
  <button id="last-button">Last button</button>
  <script>
    window.fitEvents = [];
    for (const name of ['focusin', 'focusout', 'keydown', 'keyup', 'input', 'contextmenu']) {
      document.addEventListener(name, event => {
        window.fitEvents.push({type: name, target: event.target.id || event.target.tagName,
                              key: event.key || ''});
      }, true);
    }
    window.fitState = () => JSON.stringify({
      active: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : '',
      text: document.getElementById('text').value,
      search: document.getElementById('search').value,
      textarea: document.getElementById('textarea').value,
      editable: document.getElementById('editable').textContent,
      events: window.fitEvents.slice(-20)
    });
  </script>
</body>
</html>
"""


class PageHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/focus-input":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, _format: str, *_args) -> None:
        pass


def main() -> int:
    app = QApplication(sys.argv)
    server = ThreadingHTTPServer(("127.0.0.1", 0), PageHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    window = QWidget()
    window.setWindowTitle("FIT WebView Bridge — X11 focus/input smoke")
    layout = QVBoxLayout(window)
    instructions = QLabel(
        "Manual X11 checks: Tab from Qt-before into WebKit; type in every editable field; "
        "use Shift+Tab; test Ctrl+A/C/V/X; Tab beyond the final HTML button into Qt-after; "
        "right-click editable/static text, close the native menu, then type again."
    )
    instructions.setWordWrap(True)
    before = QLineEdit()
    before.setObjectName("qt-before")
    before.setPlaceholderText("Qt widget before WebKit")
    web_view = systemwebview.SystemWebViewWidget()
    after = QLineEdit()
    after.setObjectName("qt-after")
    after.setPlaceholderText("Qt widget after WebKit")
    status = QLabel("Waiting for the local page...")
    status.setWordWrap(True)
    inspect_button = QPushButton("Print current focus/input state")
    quit_button = QPushButton("Quit")

    for widget in (instructions, before, web_view, after, status, inspect_button, quit_button):
        layout.addWidget(widget)
    layout.setStretchFactor(web_view, 1)

    pending = set()

    def inspect() -> None:
        token = int(web_view.evaluateJavaScriptWithResult("window.fitState ? window.fitState() : ''"))
        pending.add(token)

    def on_result(result, token: int, error: str) -> None:
        if int(token) not in pending:
            return
        pending.remove(int(token))
        qt_focus = QApplication.focusWidget()
        qt_name = qt_focus.objectName() if qt_focus is not None else "<none>"
        message = f"Qt focus={qt_name or type(qt_focus).__name__}; Web state={result}; error={error!r}"
        status.setText(message)
        print(message, flush=True)

    def on_loaded(ok: bool) -> None:
        print(f"loadFinished: {ok}", flush=True)
        if ok:
            before.setFocus()
            QTimer.singleShot(100, inspect)

    QApplication.instance().focusChanged.connect(
        lambda old, now: print(
            "Qt focusChanged:",
            old.objectName() if old is not None else "<none>",
            "->",
            now.objectName() if now is not None else "<none>",
            flush=True,
        )
    )
    web_view.javaScriptResult.connect(on_result)
    web_view.loadFinished.connect(on_loaded)
    inspect_button.clicked.connect(inspect)
    quit_button.clicked.connect(app.quit)

    window.resize(1000, 760)
    window.show()
    web_view.setUrl(QUrl(f"http://127.0.0.1:{server.server_address[1]}/focus-input"))
    result = app.exec()

    server.shutdown()
    server.server_close()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
