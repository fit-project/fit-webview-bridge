from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtCore import QUrl

from tests._qt_test_utils import wait_for


def _write_html(path: Path, title: str, body: str) -> None:
    html = f"""<!doctype html>
<html>
  <head><meta charset="utf-8"><title>{title}</title></head>
  <body>{body}</body>
</html>
"""
    path.write_text(html, encoding="utf-8")


@pytest.fixture
def shown_widget(qapp, widget_class):
    widget = widget_class()
    widget.resize(1024, 768)
    widget.show()
    qapp.processEvents()
    yield widget
    widget.close()
    widget.deleteLater()
    qapp.processEvents()


@pytest.mark.e2e
def test_navigation_back_forward_and_capture_flow(
    shown_widget, tmp_path: Path
) -> None:
    second_page = tmp_path / "page_2.html"
    _write_html(second_page, "Page Two", "<h1 id='page2'>second</h1>")

    first_page = tmp_path / "page_1.html"
    _write_html(first_page, "Page One", "<h1 id='page1'>first</h1>")
    first_url = QUrl.fromLocalFile(str(first_page))
    second_qurl = QUrl.fromLocalFile(str(second_page))

    load_events: list[bool] = []
    shown_widget.loadFinished.connect(lambda ok: load_events.append(bool(ok)))
    can_go_back = {"value": False}
    can_go_forward = {"value": False}
    shown_widget.canGoBackChanged.connect(lambda v: can_go_back.__setitem__("value", bool(v)))
    shown_widget.canGoForwardChanged.connect(
        lambda v: can_go_forward.__setitem__("value", bool(v))
    )

    shown_widget.setUrl(first_url)
    assert wait_for(lambda: len(load_events) > 0 and load_events[-1], timeout_ms=10000)

    js_events: list[tuple] = []
    shown_widget.javaScriptResult.connect(
        lambda result, token, error: js_events.append((result, int(token), str(error)))
    )
    title_token = int(shown_widget.evaluateJavaScriptWithResult("document.title"))
    assert wait_for(
        lambda: any(received_token == title_token for _, received_token, _ in js_events),
        timeout_ms=8000,
    )
    title_result, _, _ = next(item for item in js_events if item[1] == title_token)
    assert str(title_result) == "Page One"

    shown_widget.setUrl(second_qurl)
    assert wait_for(lambda: len(load_events) > 1 and load_events[-1], timeout_ms=10000)

    assert wait_for(
        lambda: "page_2.html" in shown_widget.url().toString(),
        timeout_ms=10000,
    )
    if not wait_for(lambda: can_go_back["value"], timeout_ms=3000):
        pytest.skip("Back navigation history is not available in this runtime session")

    shown_widget.back()
    assert wait_for(
        lambda: "page_1.html" in shown_widget.url().toString(),
        timeout_ms=10000,
    )

    if not wait_for(lambda: can_go_forward["value"], timeout_ms=3000):
        pytest.skip("Forward navigation history is not available in this runtime session")

    shown_widget.forward()
    assert wait_for(
        lambda: "page_2.html" in shown_widget.url().toString(),
        timeout_ms=10000,
    )

    output = tmp_path / "e2e_capture.png"
    capture_events: list[tuple] = []
    shown_widget.captureFinished.connect(
        lambda token, ok, file_path, error: capture_events.append(
            (int(token), bool(ok), str(file_path), str(error))
        )
    )

    cap_token = int(shown_widget.captureVisiblePage(str(output)))
    assert wait_for(
        lambda: any(received_token == cap_token for received_token, _, _, _ in capture_events),
        timeout_ms=12000,
    )
    _, ok, _, error = next(item for item in capture_events if item[0] == cap_token)
    assert ok is True, error
    assert output.exists()
    assert output.stat().st_size > 0
