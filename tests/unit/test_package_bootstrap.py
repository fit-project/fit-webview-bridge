from __future__ import annotations

import builtins
import sys
import types

import pytest


@pytest.mark.unit
def test_package_init_bootstraps_wkwebview_aliases(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    package_name = "fit_webview_bridge"
    wk_module_name = f"{package_name}.wkwebview"

    for mod_name in [package_name, wk_module_name, "wkwebview"]:
        sys.modules.pop(mod_name, None)
    if hasattr(builtins, "wkwebview"):
        monkeypatch.delattr(builtins, "wkwebview", raising=False)

    fake_mod = types.ModuleType(wk_module_name)
    fake_widget = type("FakeWKWebViewWidget", (), {})
    fake_mod.WKWebViewWidget = fake_widget

    sys.modules[wk_module_name] = fake_mod

    imported = __import__(package_name, fromlist=["*"])

    assert imported.SystemWebView is fake_widget
    assert sys.modules["wkwebview"] is fake_mod
    assert getattr(fake_mod, "wkwebview") is fake_mod
    assert getattr(builtins, "wkwebview") is fake_mod
