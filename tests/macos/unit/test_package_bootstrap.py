from __future__ import annotations

import sys
import types

import pytest


@pytest.mark.unit
def test_package_init_exports_systemwebview_entrypoint() -> None:
    package_name = "fit_webview_bridge"
    module_name = f"{package_name}.systemwebview"

    for mod_name in [package_name, module_name, "systemwebview"]:
        sys.modules.pop(mod_name, None)

    fake_mod = types.ModuleType(module_name)
    fake_widget = type("FakeWKWebViewWidget", (), {})
    fake_mod.WKWebViewWidget = fake_widget

    sys.modules[module_name] = fake_mod

    imported = __import__(package_name, fromlist=["*"])

    assert imported.SystemWebView is fake_widget
