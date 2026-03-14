from __future__ import annotations

import pytest


@pytest.mark.contract
def test_module_exports_expected_types(systemwebview_module) -> None:
    assert getattr(systemwebview_module, "WKWebViewWidget", None) is not None
    assert getattr(systemwebview_module, "DownloadInfo", None) is not None


@pytest.mark.contract
def test_widget_declares_expected_public_methods(widget_class) -> None:
    expected_methods = [
        "url",
        "setUrl",
        "back",
        "forward",
        "stop",
        "reload",
        "clearWebsiteData",
        "evaluateJavaScript",
        "evaluateJavaScriptWithResult",
        "setDownloadDirectory",
        "downloadDirectory",
        "setUserAgent",
        "userAgent",
        "resetUserAgent",
        "setApplicationNameForUserAgent",
        "captureVisiblePage",
    ]
    for method_name in expected_methods:
        assert callable(getattr(widget_class, method_name, None)), method_name


@pytest.mark.contract
def test_widget_exposes_expected_signals(widget_class) -> None:
    expected_signals = [
        "loadFinished",
        "urlChanged",
        "navigationDisplayUrlChanged",
        "titleChanged",
        "loadProgress",
        "canGoBackChanged",
        "canGoForwardChanged",
        "downloadStarted",
        "downloadProgress",
        "downloadFinished",
        "downloadFailed",
        "javaScriptResult",
        "captureFinished",
    ]

    for signal_name in expected_signals:
        signal = getattr(widget_class, signal_name, None)
        assert signal is not None, signal_name
