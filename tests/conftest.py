from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
from PySide6 import QtWidgets


def _add_local_build_paths() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo_root))

    for pattern in ("wkwebview*.so", "wkwebview*.pyd", "_wkwebview*.so", "_wkwebview*.pyd"):
        for candidate in repo_root.rglob(pattern):
            parent = str(candidate.parent)
            if parent not in sys.path:
                sys.path.insert(0, parent)


_add_local_build_paths()


@pytest.fixture(scope="session")
def qapp() -> QtWidgets.QApplication:
    if os.environ.get("FIT_WV_RUN_GUI_TESTS") != "1":
        pytest.skip(
            "GUI tests are disabled. Set FIT_WV_RUN_GUI_TESTS=1 to run integration/e2e suites."
        )
    app = QtWidgets.QApplication.instance()
    if app is None:
        app = QtWidgets.QApplication([])
    return app


@pytest.fixture(scope="session")
def wkwebview_module():
    try:
        import wkwebview as module  # type: ignore
    except Exception:
        try:
            import fit_webview_bridge as pkg
        except Exception as exc:
            pytest.skip(f"wkwebview binding not available: {exc}")
        module = getattr(pkg, "wkwebview", None)
        if module is None:
            pytest.skip("wkwebview binding not available via fit_webview_bridge")
    return module


@pytest.fixture(scope="session")
def widget_class(wkwebview_module):
    cls = getattr(wkwebview_module, "WKWebViewWidget", None)
    if cls is None:
        pytest.skip("WKWebViewWidget class not available in binding")
    return cls
