import json
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication, QHBoxLayout, QWidget

from fit_webview_bridge import systemwebview


COOKIE_NAME = "fit_ephemeral_cookie"
STORAGE_KEY = "fitEphemeralStorage"
STATE_VALUE = "widget-a"
DOWNLOAD_PAYLOAD = b"FIT WebView Bridge ephemeral download smoke\n"


class SmokeHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/state":
            payload = b"<!doctype html><html><head><title>Ephemeral state</title></head><body>state</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        elif self.path == "/download":
            payload = DOWNLOAD_PAYLOAD
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="ephemeral-download.txt"')
        else:
            self.send_error(404)
            return
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args) -> None:
        pass


def main() -> int:
    app = QApplication(sys.argv)
    server = ThreadingHTTPServer(("127.0.0.1", 0), SmokeHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    download_temp = tempfile.TemporaryDirectory(prefix="fit-webview-ephemeral-smoke-")
    origin = f"http://127.0.0.1:{server.server_address[1]}"
    state_url = QUrl(f"{origin}/state")
    download_url = QUrl(f"{origin}/download")

    host = QWidget()
    layout = QHBoxLayout(host)
    views = {}
    phase = {"value": "a_initial"}
    requests = {}
    results = {
        "same_widget_cookie": False,
        "same_widget_local_storage": False,
        "simultaneous_cookie_isolation": False,
        "simultaneous_local_storage_isolation": False,
        "clear_website_cookie": False,
        "clear_website_local_storage": False,
        "clear_cache_callable": False,
        "destroyed_widget_cookie_isolation": False,
        "destroyed_widget_local_storage_isolation": False,
        "download_contents": False,
        "download_persisted": False,
    }
    downloaded_path = {"value": None}

    def add_view(name: str):
        view = systemwebview.SystemWebViewWidget()
        views[name] = view
        layout.addWidget(view)
        view.loadFinished.connect(lambda ok, view_name=name: on_load_finished(view_name, ok))
        view.javaScriptResult.connect(
            lambda result, token, error, view_name=name: on_javascript_result(view_name, result, token, error)
        )
        return view

    def remove_view(name: str) -> None:
        view = views.pop(name)
        layout.removeWidget(view)
        view.deleteLater()

    def evaluate(name: str, label: str, script: str) -> None:
        token = views[name].evaluateJavaScriptWithResult(script)
        requests[(name, token)] = label

    def inspect_state(name: str, label: str) -> None:
        evaluate(
            name,
            label,
            f"JSON.stringify({{cookie: document.cookie, storage: localStorage.getItem('{STORAGE_KEY}')}})",
        )

    def set_state(name: str, label: str) -> None:
        evaluate(
            name,
            label,
            f"document.cookie='{COOKIE_NAME}={STATE_VALUE}; SameSite=Lax';"
            f"localStorage.setItem('{STORAGE_KEY}', '{STATE_VALUE}'); true",
        )

    def state_values(result):
        value = json.loads(result)
        return value.get("cookie", ""), value.get("storage")

    def finish() -> None:
        path = downloaded_path["value"]
        results["download_persisted"] = path is not None and path.is_file() and path.read_bytes() == DOWNLOAD_PAYLOAD
        for label, passed in results.items():
            print(f"CHECK {label.replace('_', ' ')}: {'PASS' if passed else 'FAIL'}", flush=True)
        app.exit(0 if all(results.values()) else 1)

    def on_download_finished(info) -> None:
        path = Path(info.downloadDirectory()) / info.downloadFileName()
        downloaded_path["value"] = path
        results["download_contents"] = path.is_file() and path.read_bytes() == DOWNLOAD_PAYLOAD
        remove_view("a")
        phase["value"] = "c_initial"
        QTimer.singleShot(300, lambda: add_view("c").setUrl(state_url))

    def on_javascript_result(name: str, result, token: int, error: str) -> None:
        label = requests.pop((name, token), None)
        if label is None or error:
            print(f"Unexpected JavaScript result: view={name}, label={label}, error={error!r}", flush=True)
            app.exit(1)
            return
        if label == "a_set":
            phase["value"] = "a_reload"
            views["a"].reload()
        elif label == "a_same_widget":
            cookie, storage = state_values(result)
            results["same_widget_cookie"] = f"{COOKIE_NAME}={STATE_VALUE}" in cookie
            results["same_widget_local_storage"] = storage == STATE_VALUE
            phase["value"] = "b_initial"
            add_view("b").setUrl(state_url)
        elif label == "b_isolation":
            cookie, storage = state_values(result)
            results["simultaneous_cookie_isolation"] = COOKIE_NAME not in cookie
            results["simultaneous_local_storage_isolation"] = storage is None
            remove_view("b")
            views["a"].clearCacheData()
            results["clear_cache_callable"] = True
            views["a"].clearWebsiteData()
            phase["value"] = "a_after_clear"
            QTimer.singleShot(750, views["a"].reload)
        elif label == "a_cleared":
            cookie, storage = state_values(result)
            results["clear_website_cookie"] = COOKIE_NAME not in cookie
            results["clear_website_local_storage"] = storage is None
            set_state("a", "a_reset")
        elif label == "a_reset":
            views["a"].setDownloadDirectory(download_temp.name)
            views["a"].downloadFinished.connect(on_download_finished)
            phase["value"] = "download"
            views["a"].setUrl(download_url)
        elif label == "c_isolation":
            cookie, storage = state_values(result)
            results["destroyed_widget_cookie_isolation"] = COOKIE_NAME not in cookie
            results["destroyed_widget_local_storage_isolation"] = storage is None
            remove_view("c")
            QTimer.singleShot(300, finish)

    def on_load_finished(name: str, ok: bool) -> None:
        if not ok:
            print(f"Unexpected navigation failure: view={name}, phase={phase['value']}", flush=True)
            app.exit(1)
            return
        current = phase["value"]
        if current == "a_initial" and name == "a":
            set_state("a", "a_set")
        elif current == "a_reload" and name == "a":
            inspect_state("a", "a_same_widget")
        elif current == "b_initial" and name == "b":
            inspect_state("b", "b_isolation")
        elif current == "a_after_clear" and name == "a":
            inspect_state("a", "a_cleared")
        elif current == "c_initial" and name == "c":
            inspect_state("c", "c_isolation")

    add_view("a")
    host.resize(1000, 600)
    host.show()
    QTimer.singleShot(30_000, lambda: app.exit(2))
    views["a"].setUrl(state_url)
    result = app.exec()

    server.shutdown()
    server.server_close()
    download_temp.cleanup()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
