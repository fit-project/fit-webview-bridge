from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtCore import QUrl

from tests._qt_test_utils import wait_for


def _write_page(path: Path, title: str, body: str) -> None:
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
    widget.resize(900, 700)
    widget.show()
    qapp.processEvents()
    yield widget
    widget.close()
    widget.deleteLater()
    qapp.processEvents()


@pytest.mark.integration
def test_load_local_file_emits_finished_and_title(
    shown_widget, tmp_path: Path
) -> None:
    page = tmp_path / "integration_page.html"
    _write_page(page, "Integration Title", "<h1 id='msg'>ready</h1>")
    url = QUrl.fromLocalFile(str(page))

    load_events: list[bool] = []
    shown_widget.loadFinished.connect(lambda ok: load_events.append(bool(ok)))

    shown_widget.setUrl(url)

    assert wait_for(lambda: len(load_events) > 0, timeout_ms=10000)
    assert load_events[-1] is True
    assert shown_widget.url().toLocalFile() == str(page)


@pytest.mark.integration
def test_evaluate_javascript_with_result_returns_expected_value(
    shown_widget, tmp_path: Path
) -> None:
    page = tmp_path / "js_page.html"
    _write_page(page, "JS Page", "<script>window.answer = 6 * 7;</script>")
    load_events: list[bool] = []
    shown_widget.loadFinished.connect(lambda ok: load_events.append(bool(ok)))
    shown_widget.setUrl(QUrl.fromLocalFile(str(page)))
    assert wait_for(lambda: len(load_events) > 0 and load_events[-1], timeout_ms=10000)

    results: list[tuple] = []
    shown_widget.javaScriptResult.connect(
        lambda result, token, error: results.append((result, int(token), str(error)))
    )
    token = int(shown_widget.evaluateJavaScriptWithResult("6 * 7"))

    assert wait_for(
        lambda: any(received_token == token for _, received_token, _ in results),
        timeout_ms=10000,
    )
    result, _, error = next(item for item in results if item[1] == token)
    assert float(result) == 42.0
    assert error == ""


@pytest.mark.integration
def test_capture_visible_page_writes_image_file(
    shown_widget, tmp_path: Path
) -> None:
    page = tmp_path / "capture_page.html"
    _write_page(page, "Capture Page", "<div style='height:1200px'>capture</div>")
    load_events: list[bool] = []
    shown_widget.loadFinished.connect(lambda ok: load_events.append(bool(ok)))
    shown_widget.setUrl(QUrl.fromLocalFile(str(page)))
    assert wait_for(lambda: len(load_events) > 0 and load_events[-1], timeout_ms=10000)

    out_file = tmp_path / "capture.png"
    captures: list[tuple] = []
    shown_widget.captureFinished.connect(
        lambda token, ok, file_path, error: captures.append(
            (int(token), bool(ok), str(file_path), str(error))
        )
    )

    token = int(shown_widget.captureVisiblePage(str(out_file)))
    assert wait_for(
        lambda: any(received_token == token for received_token, _, _, _ in captures),
        timeout_ms=12000,
    )

    _, ok, file_path, error = next(item for item in captures if item[0] == token)
    assert ok is True, error
    assert Path(file_path) == out_file
    assert out_file.exists()
    assert out_file.stat().st_size > 0
