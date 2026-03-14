from __future__ import annotations

import os
import sys
from pathlib import Path
import importlib

import pytest
from PySide6 import QtWidgets


def _add_local_build_paths() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo_root))

    for pattern in ("systemwebview*.so", "systemwebview*.pyd", "_systemwebview*.so", "_systemwebview*.pyd"):
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
def systemwebview_module():
    try:
        import systemwebview as module  # type: ignore
    except Exception:
        try:
            module = importlib.import_module("fit_webview_bridge.systemwebview")
        except Exception as exc:
            pytest.skip(f"systemwebview binding not available: {exc}")
    return module


@pytest.fixture(scope="session")
def widget_class(systemwebview_module):
    cls = getattr(systemwebview_module, "SystemWebViewWidget", None)
    if cls is None:
        pytest.skip("SystemWebViewWidget class not available in binding")
    return cls
