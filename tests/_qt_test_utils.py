from __future__ import annotations

import time
from collections.abc import Callable

from PySide6 import QtCore


def wait_for(
    predicate: Callable[[], bool],
    timeout_ms: int = 8000,
    poll_ms: int = 20,
) -> bool:
    app = QtCore.QCoreApplication.instance()
    if app is None:
        raise RuntimeError("QCoreApplication is not initialized")

    deadline = time.monotonic() + (timeout_ms / 1000.0)
    while time.monotonic() < deadline:
        app.processEvents(QtCore.QEventLoop.AllEvents, poll_ms)
        if predicate():
            return True
        time.sleep(poll_ms / 1000.0)
    app.processEvents(QtCore.QEventLoop.AllEvents, poll_ms)
    return predicate()
