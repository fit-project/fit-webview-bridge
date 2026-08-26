import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PySide6.QtCore import QTimer, QUrl, Qt
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QVBoxLayout, QWidget

from fit_webview_bridge import systemwebview


PAGE = b"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Fullscreen smoke</title>
  <style>
    html, body { margin: 0; height: 100%; font: 18px sans-serif; }
    #target { box-sizing: border-box; min-height: 100%; padding: 32px; color: white;
              background: linear-gradient(135deg, #17365d, #287a78); }
    #target:fullscreen { width: 100%; height: 100%; }
    button, input { display: block; margin: 18px 0; padding: 10px; font-size: 18px; }
  </style>
</head>
<body>
  <section id="target">
    <h1>FIT WebView Bridge DOM fullscreen target</h1>
    <button id="enter" onclick="document.getElementById('target').requestFullscreen().then(() => document.getElementById('editor').focus())">Enter fullscreen</button>
    <input id="editor" placeholder="Type here while fullscreen">
    <p>Press Escape to leave fullscreen.</p>
  </section>
  <script>
    window.fitFullscreenEvents = [];
    document.addEventListener('fullscreenchange', () => {
      window.fitFullscreenEvents.push({type: 'change', element: document.fullscreenElement?.id || null});
    });
    document.addEventListener('fullscreenerror', () => {
      window.fitFullscreenEvents.push({type: 'error', element: document.fullscreenElement?.id || null});
    });
    window.fitFullscreenState = () => JSON.stringify({
      available: typeof document.getElementById('target').requestFullscreen === 'function',
      element: document.fullscreenElement?.id || null,
      editor: document.getElementById('editor').value,
      events: window.fitFullscreenEvents
    });
  </script>
</body>
</html>
"""


class PageHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/fullscreen":
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
    window.setWindowTitle("FIT WebView Bridge — X11 fullscreen smoke")
    layout = QVBoxLayout(window)
    chrome_above = QLabel(
        "Cycle 1: click the HTML Enter fullscreen button, type in the HTML input, then press Escape."
    )
    chrome_above.setWordWrap(True)
    web_view = systemwebview.SystemWebViewWidget()
    chrome_below = QLabel("Qt chrome below WebKit — this must disappear during DOM fullscreen.")
    quit_button = QPushButton("Quit after both fullscreen cycles")
    quit_button.setEnabled(False)
    for widget in (chrome_above, web_view, chrome_below, quit_button):
        layout.addWidget(widget)
    layout.setStretchFactor(web_view, 1)

    pending = set()
    entered = {"value": False}
    cycle = {"value": 1}
    checks = {
        "fullscreen_api": False,
        "first_dom_enter": False,
        "first_qt_enter": False,
        "first_chrome_hidden": False,
        "first_geometry": False,
        "first_dom_leave": False,
        "first_normal_restore": False,
        "second_dom_enter": False,
        "second_qt_enter": False,
        "second_chrome_hidden": False,
        "second_geometry": False,
        "second_dom_leave": False,
        "second_maximized_restore": False,
        "fullscreen_keyboard": False,
        "two_fullscreen_changes": False,
    }
    checks_printed = {"value": False}

    def inspect() -> None:
        if not web_view.isVisible() or pending:
            return
        token = int(web_view.evaluateJavaScriptWithResult("window.fitFullscreenState()"))
        pending.add(token)

    def on_result(result, token: int, error: str) -> None:
        if int(token) not in pending:
            return
        pending.remove(int(token))
        if error or not result:
            print(f"Fullscreen state error: {error!r}", flush=True)
            return
        state = json.loads(result)
        checks["fullscreen_api"] = bool(state["available"])
        dom_fullscreen = state["element"] == "target"
        qt_fullscreen = window.isFullScreen()
        current_cycle = cycle["value"]
        prefix = "first" if current_cycle == 1 else "second"

        if dom_fullscreen:
            if not entered["value"]:
                print(f"Cycle {current_cycle}: DOM entered, Qt fullscreen={qt_fullscreen}", flush=True)
            checks[f"{prefix}_dom_enter"] = True
            checks[f"{prefix}_qt_enter"] = qt_fullscreen
            checks[f"{prefix}_chrome_hidden"] = not chrome_above.isVisible() and not chrome_below.isVisible()
            checks[f"{prefix}_geometry"] = web_view.width() > 0 and web_view.height() > 0
            checks["fullscreen_keyboard"] = checks["fullscreen_keyboard"] or bool(state["editor"])
            entered["value"] = True
        elif entered["value"]:
            print(f"Cycle {current_cycle}: DOM left, Qt state={window.windowState()}", flush=True)
            checks[f"{prefix}_dom_leave"] = True
            if current_cycle == 1:
                checks["first_normal_restore"] = window.windowState() == Qt.WindowNoState
                cycle["value"] = 2
                entered["value"] = False
                chrome_above.setText(
                    "Cycle 2 (maximized restore): enter HTML fullscreen again, optionally open the native context "
                    "menu, press Escape, and verify the Qt window returns maximized."
                )
                QTimer.singleShot(300, window.showMaximized)
            else:
                checks["second_maximized_restore"] = bool(window.windowState() & Qt.WindowMaximized)
                checks["two_fullscreen_changes"] = sum(
                    event["type"] == "change" for event in state["events"]
                ) >= 4
                entered["value"] = False
                quit_button.setEnabled(True)
                print("Both fullscreen cycles completed; inspect the checks and click Quit.", flush=True)

    def print_checks() -> None:
        if checks_printed["value"]:
            return
        checks_printed["value"] = True
        for name, passed in checks.items():
            print(f"CHECK {name.replace('_', ' ')}: {'PASS' if passed else 'FAIL'}", flush=True)

    def finish() -> None:
        print_checks()
        app.quit()

    def on_loaded(ok: bool) -> None:
        print(f"loadFinished: {ok}", flush=True)
        if ok:
            QTimer.singleShot(100, inspect)

    web_view.javaScriptResult.connect(on_result)
    web_view.loadFinished.connect(on_loaded)
    quit_button.clicked.connect(finish)
    app.aboutToQuit.connect(print_checks)
    poll = QTimer(window)
    poll.setInterval(250)
    poll.timeout.connect(inspect)
    poll.start()

    window.resize(1000, 720)
    window.show()
    web_view.setUrl(QUrl(f"http://127.0.0.1:{server.server_address[1]}/fullscreen"))
    result = app.exec()

    server.shutdown()
    server.server_close()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
