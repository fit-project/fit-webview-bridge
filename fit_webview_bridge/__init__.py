import builtins as _builtins
import importlib
import sys as _sys

_wkm = importlib.import_module(__name__ + ".wkwebview")
_sys.modules.setdefault("wkwebview", _wkm)
setattr(_wkm, "wkwebview", _wkm)
setattr(_builtins, "wkwebview", _wkm)

from .wkwebview import WKWebViewWidget as SystemWebView
