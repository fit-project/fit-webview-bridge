import sys
from urllib.parse import quote

from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication, QHBoxLayout, QLineEdit, QMainWindow, QPushButton, QVBoxLayout, QWidget

from fit_webview_bridge import systemwebview


def data_url(title: str, body: str) -> QUrl:
    html = f"<!doctype html><html><head><title>{title}</title></head><body><h1>{body}</h1></body></html>"
    return QUrl(f"data:text/html;charset=utf-8,{quote(html)}")


def main() -> int:
    automated = "--automated" in sys.argv
    qt_args = [argument for argument in sys.argv if argument != "--automated"]
    app = QApplication(qt_args)
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
    web_view.navigationDisplayUrlChanged.connect(
        lambda url: print(f"navigationDisplayUrlChanged: {url.toString()}", flush=True)
    )
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
        }
        for name, passed in checks.items():
            print(f"CHECK {name}: {'PASS' if passed else 'FAIL'}", flush=True)
        app.exit(0 if all(checks.values()) else 1)

    javascript_requests = {}

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
        required = {"number", "string", "boolean", "null", "error", "fire"}
        if required.issubset(observed["javascript"]) and phase["value"] == "javascript":
            phase["value"] = "done"
            QTimer.singleShot(250, finish_automated_smoke)

    web_view.javaScriptResult.connect(on_javascript_result)

    def on_load_finished(ok: bool) -> None:
        observed["finished"].append(ok)
        print(f"loadFinished: {ok}", flush=True)
        if not automated:
            return
        if not ok:
            if phase["value"] == "failure":
                QTimer.singleShot(100, start_javascript_smoke)
            else:
                app.exit(1)
            return

        current_phase = phase["value"]
        if current_phase == "first":
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

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
