import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

from PySide6.QtCore import QTimer, QUrl
from PySide6.QtGui import QImageReader
from PySide6.QtWidgets import QApplication, QHBoxLayout, QLineEdit, QMainWindow, QPushButton, QVBoxLayout, QWidget

from fit_webview_bridge import systemwebview


DOWNLOAD_PAYLOAD = b"FIT WebView Bridge Linux download smoke\n"


class DownloadHandler(BaseHTTPRequestHandler):
    direct_requests = []

    def do_GET(self) -> None:
        if self.path == "/popup-source":
            payload = (
                b"<!doctype html><html><head><title>Popup source</title></head><body>"
                b'<a id="popup-link" href="/popup-target" target="_blank">Open target</a>'
                b'<button id="popup-js" onclick="window.open(\'/popup-js\', \'_blank\')">Open JS</button>'
                b'<a id="popup-download" href="/popup-download" target="_blank">Download</a>'
                b'<a id="popup-error" href="/http-404?from=popup" target="_blank">Error</a>'
                b"</body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/popup-target":
            payload = b"<!doctype html><html><head><title>Popup target</title></head><body>POPUP TARGET</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/popup-js":
            payload = b"<!doctype html><html><head><title>Popup JavaScript</title></head><body>POPUP JS</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/popup-download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="popup-download.txt"')
            self.send_header("Content-Length", str(len(DOWNLOAD_PAYLOAD)))
            self.end_headers()
            self.wfile.write(DOWNLOAD_PAYLOAD)
            return
        if self.path.startswith("/http-ok"):
            payload = b"<!doctype html><html><head><title>HTTP smoke OK</title></head><body>HTTP OK</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/http-redirect":
            self.send_response(302)
            self.send_header("Location", "/http-ok?redirected")
            self.end_headers()
            return
        if self.path.startswith("/http-404"):
            payload = b"<!doctype html><title>REMOTE ERROR BODY</title><p>REMOTE 404 MUST NOT BE SHOWN</p>"
            self.send_response(404, "Not Found <remote>")
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/http-500":
            payload = b"<!doctype html><title>REMOTE ERROR BODY</title><p>REMOTE 500 MUST NOT BE SHOWN</p>"
            self.send_response(500)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/http-403":
            payload = b"<!doctype html><title>REMOTE ERROR BODY</title><p>REMOTE 403 MUST NOT BE SHOWN</p>"
            self.send_response(403)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/proxy-page"):
            self.__class__.direct_requests.append(self.path)
            payload = b"<!doctype html><html><head><title>Direct origin</title></head><body>direct</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path != "/download":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="smoke-download.txt"')
        self.send_header("Content-Length", str(len(DOWNLOAD_PAYLOAD)))
        self.end_headers()
        self.wfile.write(DOWNLOAD_PAYLOAD)

    def log_message(self, _format: str, *_args) -> None:
        pass


class ProxyHandler(BaseHTTPRequestHandler):
    requests = []

    def do_GET(self) -> None:
        self.__class__.requests.append((self.server.proxy_name, self.path, self.headers.get("Host", "")))
        payload = (
            b"<!doctype html><html><head><title>Proxy routed</title></head>"
            b"<body><script>localStorage.setItem('fitProxyPreserved','yes')</script>proxied</body></html>"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args) -> None:
        pass


def data_url(title: str, body: str) -> QUrl:
    html = f"<!doctype html><html><head><title>{title}</title></head><body><h1>{body}</h1></body></html>"
    return QUrl(f"data:text/html;charset=utf-8,{quote(html)}")


def main() -> int:
    automated = "--automated" in sys.argv
    qt_args = [argument for argument in sys.argv if argument != "--automated"]
    app = QApplication(qt_args)
    download_temp = tempfile.TemporaryDirectory(prefix="fit-webview-download-smoke-") if automated else None
    download_server = ThreadingHTTPServer(("127.0.0.1", 0), DownloadHandler) if automated else None
    first_proxy = ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler) if automated else None
    second_proxy = ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler) if automated else None
    if download_server is not None:
        first_proxy.proxy_name = "first"
        second_proxy.proxy_name = "second"
        threading.Thread(target=download_server.serve_forever, daemon=True).start()
        threading.Thread(target=first_proxy.serve_forever, daemon=True).start()
        threading.Thread(target=second_proxy.serve_forever, daemon=True).start()
    window = QMainWindow()
    window.setWindowTitle("FIT WebView Bridge — Linux WebKitGTK navigation smoke test")

    central = QWidget()
    layout = QVBoxLayout(central)
    controls = QHBoxLayout()
    back_button = QPushButton("Back")
    forward_button = QPushButton("Forward")
    reload_button = QPushButton("Reload")
    stop_button = QPushButton("Stop")
    address = QLineEdit()
    controls.addWidget(back_button)
    controls.addWidget(forward_button)
    controls.addWidget(reload_button)
    controls.addWidget(stop_button)
    controls.addWidget(address, 1)

    web_view = systemwebview.SystemWebViewWidget()
    layout.addLayout(controls)
    layout.addWidget(web_view, 1)
    window.setCentralWidget(central)

    back_button.clicked.connect(web_view.back)
    forward_button.clicked.connect(web_view.forward)
    reload_button.clicked.connect(web_view.reload)
    stop_button.clicked.connect(web_view.stop)
    address.returnPressed.connect(lambda: web_view.setUrl(QUrl.fromUserInput(address.text())))

    observed = {
        "urls": [],
        "titles": [],
        "progress": [],
        "finished": [],
        "back_states": [],
        "forward_states": [],
        "stop_cancelled_load": False,
        "javascript": {},
        "javascript_tokens": [],
        "unexpected_javascript_tokens": [],
        "default_user_agent": "",
        "custom_user_agent_property": False,
        "data_clear_invoked": False,
        "download_directory": False,
        "download_started": [],
        "download_progress": [],
        "download_finished": [],
        "download_failed": [],
        "proxy_supported": False,
        "proxy_invalid_rejected": False,
        "proxy_configured": False,
        "proxy_replaced": False,
        "proxy_request": False,
        "proxy_cleared": False,
        "proxy_storage_preserved": False,
        "capture_tokens": [],
        "capture_results": {},
        "capture_completions": [],
        "navigation_display_urls": [],
        "http_results": {},
        "http_failures": {},
        "http_successes_after_failure": 0,
        "popup_results": {},
        "popup_error_failures": 0,
        "popup_error_successes": 0,
    }

    def on_url_changed(url: QUrl) -> None:
        observed["urls"].append(url.toString())
        address.setText(url.toString())
        print(f"urlChanged: {url.toString()}", flush=True)

    def on_title_changed(title: str) -> None:
        observed["titles"].append(title)
        window.setWindowTitle(title or "FIT WebView Bridge")
        print(f"titleChanged: {title}", flush=True)

    def on_progress_changed(percent: int) -> None:
        observed["progress"].append(percent)
        print(f"loadProgress: {percent}", flush=True)

    def on_back_changed(available: bool) -> None:
        observed["back_states"].append(available)
        back_button.setEnabled(available)
        print(f"canGoBackChanged: {available}", flush=True)

    def on_forward_changed(available: bool) -> None:
        observed["forward_states"].append(available)
        forward_button.setEnabled(available)
        print(f"canGoForwardChanged: {available}", flush=True)

    web_view.urlChanged.connect(on_url_changed)
    def on_navigation_display_url_changed(url: QUrl) -> None:
        observed["navigation_display_urls"].append(url.toString())
        print(f"navigationDisplayUrlChanged: {url.toString()}", flush=True)

    web_view.navigationDisplayUrlChanged.connect(on_navigation_display_url_changed)
    web_view.titleChanged.connect(on_title_changed)
    web_view.loadProgress.connect(on_progress_changed)
    web_view.canGoBackChanged.connect(on_back_changed)
    web_view.canGoForwardChanged.connect(on_forward_changed)

    first_url = data_url("Linux smoke page one", "Page one")
    second_url = data_url("Linux smoke page two", "Page two")
    phase = {"value": "first"}

    def finish_automated_smoke() -> None:
        web_view.stop()
        checks = {
            "Back": observed["urls"].count(first_url.toString()) >= 2,
            "Forward": observed["urls"].count(second_url.toString()) >= 2,
            "Reload": observed["finished"].count(True) >= 5,
            "Stop active load": observed["stop_cancelled_load"],
            "titles": all(title in observed["titles"] for title in ("Linux smoke page one", "Linux smoke page two")),
            "URL signals": first_url.toString() in observed["urls"] and second_url.toString() in observed["urls"],
            "progress": 100 in observed["progress"] and len(set(observed["progress"])) > 1,
            "loadFinished": True in observed["finished"],
            "load failure": False in observed["finished"],
            "back state": True in observed["back_states"],
            "forward state": True in observed["forward_states"],
            "JavaScript number": observed["javascript"].get("number", (None, "")) == (42.0, ""),
            "JavaScript string": observed["javascript"].get("string", (None, "")) == ("linux-js", ""),
            "JavaScript boolean": observed["javascript"].get("boolean", (None, "")) == (True, ""),
            "JavaScript null": observed["javascript"].get("null", (False, "")) == (None, ""),
            "JavaScript fire-and-forget": observed["javascript"].get("fire", (None, "")) == (42.0, ""),
            "JavaScript error": bool(observed["javascript"].get("error", (None, ""))[1]),
            "unique JavaScript tokens": len(observed["javascript_tokens"])
            == len(set(observed["javascript_tokens"])),
            "no fire-and-forget result": not observed["unexpected_javascript_tokens"],
            "custom user agent": observed["javascript"].get("custom_ua", (None, ""))[0]
            == "FIT-WebView-Smoke/1.0",
            "userAgent property contract": observed["custom_user_agent_property"],
            "reset user agent": observed["javascript"].get("reset_ua", (None, ""))[0]
            == observed["default_user_agent"],
            "application name user agent": "FITWebViewSmoke"
            in (observed["javascript"].get("app_ua", ("", ""))[0] or ""),
            "data/cache clear invoked": observed["data_clear_invoked"],
            "download directory": observed["download_directory"],
            "downloadStarted": len(observed["download_started"]) >= 3,
            "downloadProgress": any(done == len(DOWNLOAD_PAYLOAD) and total == len(DOWNLOAD_PAYLOAD)
                                    for done, total in observed["download_progress"]),
            "downloadFinished": len(observed["download_finished"]) >= 2,
            "download contents": all(item[3] == DOWNLOAD_PAYLOAD for item in observed["download_finished"]),
            "download filenames": [item[0] for item in observed["download_finished"][:2]]
            == ["smoke-download (1).txt", "smoke-download (2).txt"],
            "download source URL": all(item[2].endswith("/download") for item in observed["download_finished"][:2]),
            "existing file preserved": (Path(download_temp.name) / "smoke-download.txt").read_bytes()
            == b"pre-existing\n",
            "download failure": bool(observed["download_failed"] and observed["download_failed"][-1][1]),
            "proxy support": observed["proxy_supported"],
            "invalid proxies rejected": observed["proxy_invalid_rejected"],
            "proxy configured": observed["proxy_configured"],
            "proxy replaced": observed["proxy_replaced"],
            "HTTP request through proxy": observed["proxy_request"],
            "clearProxy bypassed explicit proxy": observed["proxy_cleared"],
            "clearProxy preserved storage": observed["proxy_storage_preserved"],
            "capture tokens": len(observed["capture_tokens"]) == 3
            and all(observed["capture_tokens"])
            and len(set(observed["capture_tokens"])) == 3,
            "capture completion tokens": set(observed["capture_completions"])
            == set(observed["capture_tokens"]),
            "single capture completion": len(observed["capture_completions"])
            == len(set(observed["capture_completions"])),
            "PNG capture": observed["capture_results"].get("png", {}).get("valid", False),
            "JPEG capture": observed["capture_results"].get("jpeg", {}).get("valid", False),
            "visible viewport capture": observed["capture_results"].get("png", {}).get("visible", False)
            and observed["capture_results"].get("jpeg", {}).get("visible", False),
            "capture failure": observed["capture_results"].get("invalid", {}).get("failed", False),
            "HTTP 200": observed["http_results"].get("200", False),
            "HTTP redirect": observed["http_results"].get("redirect", False),
            "HTTP 404 error page": observed["http_results"].get("404", False),
            "HTTP 500 error page": observed["http_results"].get("500", False),
            "HTTP 403 error page": observed["http_results"].get("403", False),
            "HTTP single failure signals": all(observed["http_failures"].get(code) == 1 for code in ("404", "500", "403")),
            "HTTP no false success": observed["http_successes_after_failure"] == 0,
            "HTTP meaningful URLs": observed["http_results"].get("urls", False),
            "HTTP escaped error content": observed["http_results"].get("escaped", False),
            "HTTP recovery": observed["http_results"].get("recovery", False),
            "popup source": observed["popup_results"].get("source", False),
            "target blank same view": observed["popup_results"].get("target", False)
            and "Popup target" in observed["titles"],
            "popup Back": observed["popup_results"].get("back", False),
            "popup Forward": observed["popup_results"].get("forward", False),
            "window.open same view": observed["popup_results"].get("javascript", False)
            and "Popup JavaScript" in observed["titles"],
            "popup download": observed["popup_results"].get("download", False),
            "popup HTTP error": observed["popup_results"].get("error", False),
            "popup single error failure": observed["popup_error_failures"] == 1,
            "popup no false error success": observed["popup_error_successes"] == 0,
            "no secondary popup WebView": observed["popup_results"].get("same_view", False),
        }
        for name, passed in checks.items():
            print(f"CHECK {name}: {'PASS' if passed else 'FAIL'}", flush=True)
        app.exit(0 if all(checks.values()) else 1)

    def download_url() -> QUrl:
        port = download_server.server_address[1]
        return QUrl(f"http://127.0.0.1:{port}/download")

    def trigger_download() -> None:
        web_view.setUrl(download_url())

    def start_download_smoke() -> None:
        phase["value"] = "download"
        directory = Path(download_temp.name)
        (directory / "smoke-download.txt").write_bytes(b"pre-existing\n")
        web_view.setDownloadDirectory(str(directory))
        observed["download_directory"] = web_view.downloadDirectory() == str(directory)
        trigger_download()

    def on_download_started(name: str, path: str) -> None:
        observed["download_started"].append((name, path))
        print(f"downloadStarted: name={name!r}, path={path!r}", flush=True)

    def on_download_progress(received: int, total: int) -> None:
        observed["download_progress"].append((received, total))
        print(f"downloadProgress: {received}/{total}", flush=True)

    def on_download_finished(info) -> None:
        file_name = info.downloadFileName()
        directory = info.downloadDirectory()
        source_url = info.downloadUrl().toString()
        contents = (Path(directory) / file_name).read_bytes()
        observed["download_finished"].append((file_name, directory, source_url, contents))
        print(f"downloadFinished: file={file_name!r}, directory={directory!r}, url={source_url!r}", flush=True)
        if len(observed["download_finished"]) == 1:
            QTimer.singleShot(100, trigger_download)
        elif len(observed["download_finished"]) == 2:
            invalid_directory = Path(download_temp.name) / "not-a-directory"
            invalid_directory.write_text("file, not directory", encoding="utf-8")
            web_view.setDownloadDirectory(str(invalid_directory))
            phase["value"] = "download_failure"
            QTimer.singleShot(100, trigger_download)
        elif phase["value"] == "popup_download":
            observed["popup_results"]["download"] = (
                file_name == "popup-download.txt"
                and contents == DOWNLOAD_PAYLOAD
                and source_url.endswith("/popup-download")
            )
            web_view.setDownloadDirectory(str(Path(download_temp.name)))
            phase["value"] = "popup_error"
            QTimer.singleShot(200, lambda: web_view.evaluateJavaScript("document.getElementById('popup-error').click()"))

    def on_download_failed(path: str, error: str) -> None:
        observed["download_failed"].append((path, error))
        print(f"downloadFailed: path={path!r}, error={error!r}", flush=True)
        if phase["value"] == "download_failure":
            QTimer.singleShot(250, start_capture_smoke)

    web_view.downloadStarted.connect(on_download_started)
    web_view.downloadProgress.connect(on_download_progress)
    web_view.downloadFinished.connect(on_download_finished)
    web_view.downloadFailed.connect(on_download_failed)

    capture_directory = Path(download_temp.name) / "captures" if automated else None
    capture_paths = {
        "png": capture_directory / "nested" / "visible.PNG" if automated else None,
        "jpeg": capture_directory / "nested" / "visible.JpEg" if automated else None,
        "invalid": capture_directory / "invalid-target" if automated else None,
    }

    def start_capture_smoke() -> None:
        phase["value"] = "capture_load"
        tall_html = (
            "<!doctype html><html><head><title>Capture viewport</title></head>"
            "<body style='margin:0;background:#234;color:white'>"
            "<div style='height:4000px;padding:24px'>VISIBLE CAPTURE MARKER</div></body></html>"
        )
        web_view.setUrl(QUrl(f"data:text/html;charset=utf-8,{quote(tall_html)}"))

    def request_captures() -> None:
        capture_paths["invalid"].mkdir(parents=True)
        for label in ("png", "jpeg", "invalid"):
            token = web_view.captureVisiblePage(str(capture_paths[label]))
            observed["capture_tokens"].append(token)
            print(f"captureVisiblePage: label={label}, token={token}, path={capture_paths[label]}", flush=True)

    def on_capture_finished(token: int, success: bool, file_path: str, error: str) -> None:
        observed["capture_completions"].append(token)
        path = Path(file_path)
        label = next((name for name, expected in capture_paths.items() if expected == path), "unknown")
        print(
            f"captureFinished: token={token}, label={label}, success={success}, path={file_path!r}, error={error!r}",
            flush=True,
        )
        if success:
            reader = QImageReader(str(path))
            image_format = bytes(reader.format()).lower()
            size = reader.size()
            data = path.read_bytes()
            expected_format = b"png" if label == "png" else b"jpeg"
            valid_magic = data.startswith(b"\x89PNG\r\n\x1a\n") if label == "png" else data.startswith(b"\xff\xd8")
            expected_height = web_view.height()
            visible = 100 < size.height() < 4000 and abs(size.height() - expected_height) <= 20
            observed["capture_results"][label] = {
                "valid": path.is_file()
                and path.stat().st_size > 0
                and image_format == expected_format
                and valid_magic,
                "visible": visible,
                "size": (size.width(), size.height()),
            }
        else:
            observed["capture_results"][label] = {
                "failed": label == "invalid" and bool(error) and file_path == str(capture_paths["invalid"])
            }
        if len(observed["capture_completions"]) == 3:
            QTimer.singleShot(250, start_http_error_smoke)

    web_view.captureFinished.connect(on_capture_finished)

    javascript_requests = {}

    def http_url(path: str) -> QUrl:
        return QUrl(f"http://127.0.0.1:{download_server.server_address[1]}{path}")

    def start_http_error_smoke() -> None:
        phase["value"] = "http_200"
        web_view.setUrl(http_url("/http-ok"))

    def start_popup_smoke() -> None:
        phase["value"] = "popup_source"
        web_view.setUrl(http_url("/popup-source"))

    def request_http_error_page(code: str) -> None:
        phase["value"] = f"http_{code}"
        path = "/http-404?unsafe=%3Cfit-unsafe%3E&quote=%22value%22" if code == "404" else f"/http-{code}"
        web_view.setUrl(http_url(path))

    def inspect_http_error_page(code: str) -> None:
        script = "document.title+'\\n'+document.body.textContent+'\\n'+document.body.innerHTML+'\\n'+location.href"
        evaluate(f"http_error_{code}", script)

    def proxy_page_url(query: str) -> QUrl:
        port = download_server.server_address[1]
        return QUrl(f"http://127.0.0.1:{port}/proxy-page?{query}")

    def start_proxy_smoke() -> None:
        phase["value"] = "proxy"
        ProxyHandler.requests.clear()
        DownloadHandler.direct_requests.clear()
        observed["proxy_supported"] = web_view.hasExplicitProxySupport()
        observed["proxy_invalid_rejected"] = not any(
            (
                web_view.setProxy("", 8080),
                web_view.setProxy("127.0.0.1", 0),
                web_view.setProxy("127.0.0.1", 65536),
                web_view.setProxy("http://malformed", 8080),
            )
        )
        observed["proxy_configured"] = web_view.setProxy("127.0.0.1", first_proxy.server_address[1])
        observed["proxy_replaced"] = web_view.setProxy("127.0.0.1", second_proxy.server_address[1])
        web_view.setUrl(proxy_page_url("through-proxy"))

    def evaluate(label: str, script: str) -> int:
        token = web_view.evaluateJavaScriptWithResult(script)
        javascript_requests[token] = label
        observed["javascript_tokens"].append(token)
        print(f"evaluateJavaScriptWithResult: {label}, token={token}", flush=True)
        return token

    def start_javascript_smoke() -> None:
        phase["value"] = "javascript"
        evaluate("default_ua", "navigator.userAgent")

    def on_javascript_result(result, token: int, error: str) -> None:
        label = javascript_requests.pop(token, None)
        print(f"javaScriptResult: token={token}, label={label}, result={result!r}, error={error!r}", flush=True)
        if label is None:
            observed["unexpected_javascript_tokens"].append(token)
            return
        observed["javascript"][label] = (result, error)

        if label == "default_ua":
            observed["default_user_agent"] = result
            web_view.setUserAgent("FIT-WebView-Smoke/1.0")
            observed["custom_user_agent_property"] = web_view.userAgent() == "FIT-WebView-Smoke/1.0"
            evaluate("custom_ua", "navigator.userAgent")
        elif label == "custom_ua":
            web_view.resetUserAgent()
            evaluate("reset_ua", "navigator.userAgent")
        elif label == "reset_ua":
            web_view.setApplicationNameForUserAgent("FITWebViewSmoke")
            evaluate("app_ua", "navigator.userAgent")
        elif label == "app_ua":
            web_view.evaluateJavaScript("window.__fitFireAndForget = 41")
            evaluate("number", "6 * 7")
            evaluate("string", "'linux-js'")
            evaluate("boolean", "true")
            evaluate("null", "null")
            evaluate("error", "throw new Error('expected Linux smoke error')")
            QTimer.singleShot(100, lambda: evaluate("fire", "window.__fitFireAndForget + 1"))
            web_view.clearCacheData()
            web_view.clearWebsiteData()
            observed["data_clear_invoked"] = True
        elif label == "proxy_storage":
            observed["proxy_storage_preserved"] = result == "yes" and not error
            QTimer.singleShot(100, start_download_smoke)
        elif label and label.startswith("http_error_"):
            code = label.rsplit("_", 1)[1]
            text = result or ""
            parts = text.split("\n", 3)
            title, body_text, body_html, location = parts if len(parts) == 4 else ("", "", "", "")
            expected_url = http_url(
                "/http-404?unsafe=%3Cfit-unsafe%3E&quote=%22value%22" if code == "404" else f"/http-{code}"
            ).toString()
            correct_page = (
                title == "Page could not be loaded"
                and f"HTTP {code}" in body_text
                and expected_url in body_text
                and "REMOTE ERROR BODY" not in text
            )
            observed["http_results"][code] = correct_page
            if code == "404":
                observed["http_results"]["escaped"] = (
                    "<fit-unsafe>" not in body_html and "&amp;" in body_html
                )
            observed["http_results"]["urls"] = observed["http_results"].get("urls", True) and (
                web_view.url().toString() == expected_url
                and observed["navigation_display_urls"][-1] == expected_url
                and location == expected_url
            )
            next_code = {"404": "500", "500": "403"}.get(code)
            if next_code:
                QTimer.singleShot(200, lambda value=next_code: request_http_error_page(value))
            else:
                phase["value"] = "http_recovery"
                QTimer.singleShot(200, lambda: web_view.setUrl(http_url("/http-ok?recovery")))
        elif label == "popup_error_page":
            text = result or ""
            expected_url = http_url("/http-404?from=popup").toString()
            observed["popup_results"]["error"] = (
                "Page could not be loaded" in text
                and "HTTP 404" in text
                and expected_url in text
                and web_view.url().toString() == expected_url
            )
            phase["value"] = "done"
            QTimer.singleShot(300, finish_automated_smoke)
        required = {"number", "string", "boolean", "null", "error", "fire"}
        if required.issubset(observed["javascript"]) and phase["value"] == "javascript":
            QTimer.singleShot(250, start_proxy_smoke)

    web_view.javaScriptResult.connect(on_javascript_result)

    def on_load_finished(ok: bool) -> None:
        observed["finished"].append(ok)
        print(f"loadFinished: {ok}", flush=True)
        if not automated:
            return
        if not ok:
            if phase["value"] == "popup_error":
                observed["popup_error_failures"] += 1
                QTimer.singleShot(
                    350,
                    lambda: evaluate(
                        "popup_error_page",
                        "document.title+'\\n'+document.body.textContent+'\\n'+location.href",
                    ),
                )
                return
            if phase["value"] in ("http_404", "http_500", "http_403"):
                code = phase["value"].split("_")[1]
                observed["http_failures"][code] = observed["http_failures"].get(code, 0) + 1
                QTimer.singleShot(350, lambda value=code: inspect_http_error_page(value))
                return
            if phase["value"] == "failure":
                QTimer.singleShot(100, start_javascript_smoke)
            elif phase["value"] in ("download", "download_failure", "popup_download"):
                return
            else:
                app.exit(1)
            return

        current_phase = phase["value"]
        if current_phase == "http_200":
            observed["http_results"]["200"] = web_view.url().toString() == http_url("/http-ok").toString()
            phase["value"] = "http_redirect"
            QTimer.singleShot(150, lambda: web_view.setUrl(http_url("/http-redirect")))
        elif current_phase == "http_redirect":
            observed["http_results"]["redirect"] = (
                web_view.url().toString() == http_url("/http-ok?redirected").toString()
            )
            QTimer.singleShot(150, lambda: request_http_error_page("404"))
        elif current_phase == "http_recovery":
            observed["http_results"]["recovery"] = web_view.url().toString() == http_url("/http-ok?recovery").toString()
            QTimer.singleShot(200, start_popup_smoke)
        elif current_phase in ("http_404", "http_500", "http_403"):
            observed["http_successes_after_failure"] += 1
        elif current_phase == "popup_source":
            observed["popup_results"]["source"] = web_view.url().toString() == http_url("/popup-source").toString()
            phase["value"] = "popup_blank"
            QTimer.singleShot(150, lambda: web_view.evaluateJavaScript("document.getElementById('popup-link').click()"))
        elif current_phase == "popup_blank":
            observed["popup_results"]["target"] = web_view.url().toString() == http_url("/popup-target").toString()
            observed["popup_results"]["same_view"] = observed["popup_results"]["target"]
            phase["value"] = "popup_back"
            QTimer.singleShot(150, web_view.back)
        elif current_phase == "popup_back":
            observed["popup_results"]["back"] = web_view.url().toString() == http_url("/popup-source").toString()
            phase["value"] = "popup_forward"
            QTimer.singleShot(150, web_view.forward)
        elif current_phase == "popup_forward":
            observed["popup_results"]["forward"] = web_view.url().toString() == http_url("/popup-target").toString()
            phase["value"] = "popup_return_source"
            QTimer.singleShot(150, web_view.back)
        elif current_phase == "popup_return_source":
            phase["value"] = "popup_javascript"
            QTimer.singleShot(150, lambda: web_view.evaluateJavaScript("window.open('/popup-js', '_blank')"))
        elif current_phase == "popup_javascript":
            observed["popup_results"]["javascript"] = web_view.url().toString() == http_url("/popup-js").toString()
            phase["value"] = "popup_javascript_back"
            QTimer.singleShot(150, web_view.back)
        elif current_phase == "popup_javascript_back":
            web_view.setDownloadDirectory(str(Path(download_temp.name)))
            phase["value"] = "popup_download"
            QTimer.singleShot(
                150, lambda: web_view.evaluateJavaScript("document.getElementById('popup-download').click()")
            )
        elif current_phase == "popup_error":
            observed["popup_error_successes"] += 1
        elif current_phase == "proxy":
            observed["proxy_request"] = (
                len(ProxyHandler.requests) == 1
                and ProxyHandler.requests[0][0] == "second"
                and ProxyHandler.requests[0][1].startswith("http://127.0.0.1:")
                and not DownloadHandler.direct_requests
            )
            web_view.clearProxy()
            phase["value"] = "proxy_cleared"
            QTimer.singleShot(100, lambda: web_view.setUrl(proxy_page_url("after-clear")))
        elif current_phase == "proxy_cleared":
            observed["proxy_cleared"] = (
                len(ProxyHandler.requests) == 1
                and any(path.startswith("/proxy-page?after-clear") for path in DownloadHandler.direct_requests)
            )
            evaluate("proxy_storage", "localStorage.getItem('fitProxyPreserved')")
        elif current_phase == "capture_load":
            phase["value"] = "capture"
            QTimer.singleShot(250, request_captures)
        elif current_phase == "first":
            phase["value"] = "second"
            QTimer.singleShot(100, lambda: web_view.setUrl(second_url))
        elif current_phase == "second":
            phase["value"] = "back"
            QTimer.singleShot(100, web_view.back)
        elif current_phase == "back":
            phase["value"] = "forward"
            QTimer.singleShot(100, web_view.forward)
        elif current_phase == "forward":
            phase["value"] = "reload"
            QTimer.singleShot(100, web_view.reload)
        elif current_phase == "reload":
            phase["value"] = "stop"

            def start_and_stop_load() -> None:
                web_view.reload()
                web_view.stop()
                observed["stop_cancelled_load"] = True
                phase["value"] = "failure"
                QTimer.singleShot(
                    250,
                    lambda: web_view.setUrl(
                        QUrl("file:///tmp/fit-webview-bridge-does-not-exist/navigation-smoke.html")
                    ),
                )

            QTimer.singleShot(100, start_and_stop_load)

    web_view.loadFinished.connect(on_load_finished)

    back_button.setEnabled(False)
    forward_button.setEnabled(False)
    window.resize(1024, 720)
    window.show()
    QTimer.singleShot(1500, lambda: window.resize(1200, 800))

    if automated:
        QTimer.singleShot(30_000, lambda: app.exit(2))
        web_view.setUrl(first_url)
    else:
        initial_url = QUrl("https://www.google.com")
        address.setText(initial_url.toString())
        web_view.setUrl(initial_url)

    result = app.exec()
    if download_server is not None:
        for server in (download_server, first_proxy, second_proxy):
            server.shutdown()
            server.server_close()
    if download_temp is not None:
        download_temp.cleanup()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
