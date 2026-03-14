# FIT WebView Bridge

## Description

**FIT WebView Bridge** currently provides a native **macOS** Qt widget (`WKWebView`) with **PySide6** bindings.

Goal:
- use the OS-native web engine and system codecs (no custom QtWebEngine codec builds)
- expose a Python-usable widget API for navigation, downloads, JS evaluation, and capture

Current implementation scope:
- macOS backend only (`src/macos`, `bindings/pyside6/macos`)

Roadmap:
- planned backend expansion to Windows (WebView2) and Linux (WebKitGTK)

## Why this project
QtWebEngine (Chromium) does not enable proprietary codecs by default. This module uses native web engines to keep codec compatibility and retain application control through a Qt/PySide API.

## Repository layout (current)
```
fit-webview-bridge/
├─ CMakeLists.txt
├─ src/
│  └─ macos/                # WKWebView backend (Objective-C++)
├─ bindings/pyside6/
│  └─ macos/                # Shiboken typesystem and binding build
├─ fit_webview_bridge/      # Python package entrypoint
├─ examples/macos/          # Demo app
├─ scripts/macos/           # Local bootstrap/build scripts
└─ tests/                   # Pytest suites
```

## API (SystemWebViewWidget)
**Methods / invokables**
- `url()`
- `setUrl(QUrl)`
- `back()`
- `forward()`
- `stop()`
- `reload()`
- `clearWebsiteData()`
- `evaluateJavaScript(QString)`
- `evaluateJavaScriptWithResult(QString) -> token`
- `setDownloadDirectory(QString)`
- `downloadDirectory()`
- `setUserAgent(QString)`
- `userAgent()`
- `resetUserAgent()`
- `setApplicationNameForUserAgent(QString)`
- `captureVisiblePage(QString) -> token`

**Signals**
- `urlChanged(QUrl)`
- `navigationDisplayUrlChanged(QUrl)`
- `titleChanged(QString)`
- `loadProgress(int)`
- `loadFinished(bool)`
- `canGoBackChanged(bool)`
- `canGoForwardChanged(bool)`
- `downloadStarted(QString, QString)`
- `downloadProgress(qint64, qint64)`
- `downloadFinished(DownloadInfo*)`
- `downloadFailed(QString, QString)`
- `javaScriptResult(QVariant, quint64, QString)`
- `captureFinished(quint64, bool, QString, QString)`

## Prerequisites (macOS)
- **CMake** >= 3.24
- **Ninja** (generator)
- **Python** >= 3.11,<3.14
- **Xcode** + Command Line Tools
- **PySide6 / Shiboken6** compatible with your target Python
- Qt 6.9.x SDK (installed locally, e.g. via `aqtinstall`)

## Build (macOS)
```bash
git clone https://github.com/fit-project/fit-webview-bridge.git
cd fit-webview-bridge
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_BINDINGS=ON \
  -DQt6_DIR="$PWD/Qt/6.9.0/macos/lib/cmake/Qt6" \
  -DPython3_EXECUTABLE="$(python3 -c 'import sys; print(sys.executable)')"
cmake --build build

# smoke import
PYTHONPATH="$PWD/build:$PYTHONPATH" python3 -c "import systemwebview; print('systemwebview import OK')"
```

## Local checks (same as CI)

Run these commands before opening a PR, so failures are caught locally first.

### What each tool does
- `cmake` + `ninja`: configures and builds the native module and PySide6 binding.
- `pytest`: runs automated tests (`unit`, `contract`, `integration` and `e2e` suites).
- `clang-format`: checks code formatting/style consistency for C++/Objective-C++ sources.
- `clang-tidy`: performs static analysis for bug-prone patterns and quality issues.
- `CodeQL` (optional): performs deeper security/quality static analysis and produces a SARIF report.

### 1) Bootstrap local toolchain (macOS)
This prepares Python virtualenvs (`3.11`, `3.12`, `3.13`) and installs Qt via `aqtinstall`.

```bash
./scripts/macos/bootstrap_macos.sh
```

### 2) Build + smoke import (all supported Python versions)
This compiles the module for each configured Python version and validates import of `systemwebview`.

```bash
./scripts/macos/build_smoke_macos.sh
```

By default, the script performs a clean build per Python version (`CLEAN_BUILD=1`) to avoid stale CMake cache/toolchain mismatches.
To reuse existing build directories:

```bash
CLEAN_BUILD=0 ./scripts/macos/build_smoke_macos.sh
```

Single entrypoint (bootstrap + build/smoke):

```bash
./scripts/macos/ci_local_macos.sh
```

### 3) Test suite
After a successful build, run:

```bash

#Base setup
source .venv311/bin/activate
python -m pip install -U pip
pip install pytest

# unit tests
pytest -m unit -q tests/macos

# contract tests
pytest -m contract -q tests/macos

# integration tests
FIT_WV_RUN_GUI_TESTS=1 pytest -m integration -q tests/macos

# end-to-end smoke tests
FIT_WV_RUN_GUI_TESTS=1 pytest -m e2e -q tests/macos
```

Note: `integration` and `e2e` require a GUI-capable macOS session and are gated by `FIT_WV_RUN_GUI_TESTS=1`.

### 4) Native quality and security checks (macOS)
Install native analysis tools (one-time):

```bash
brew install llvm
export PATH="/opt/homebrew/opt/llvm/bin:$PATH"
```

Formatting rules are pinned in the repository via `.clang-format`.

Run all native checks:

```bash
./scripts/macos/check_quality.sh
```

Note: native quality checks run with `BUILD_BINDINGS=OFF` to avoid coupling static analysis to Shiboken generation.

If `clang-format` reports many violations, auto-format first:

```bash
./scripts/macos/format_macos.sh
```

`format_macos.sh` runs only the formatting stage (`clang-format`) and skips `clang-tidy`.

Equivalent one-liner:

```bash
FORMAT_FIX=1 SKIP_TIDY=1 ./scripts/macos/check_quality.sh
```

Use a custom `clang-tidy` check subset:

```bash
CLANG_TIDY_CHECKS='-*,clang-analyzer-*,bugprone-*' ./scripts/macos/check_quality.sh
```

If your shell exports LLVM paths globally and `clang-tidy` configure fails due toolchain mismatch, run with a clean include env:

```bash
env -u CPATH -u CPLUS_INCLUDE_PATH -u C_INCLUDE_PATH -u OBJC_INCLUDE_PATH \
  ./scripts/macos/check_quality.sh
```

If `clang-tidy` cannot find macOS framework headers (for example `Cocoa/Cocoa.h`), set the SDK root explicitly:

```bash
MACOS_SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" ./scripts/macos/check_quality.sh
```

If `build_smoke_macos.sh` fails during Shiboken generation with errors like
`Libc++ only supports Clang 19 and later` or missing `__builtin_ctzg/__builtin_clzg`,
you are hitting a mixed toolchain environment (typically Homebrew LLVM headers with AppleClang).
Use the default clean run and venv toolchain selection:

```bash
CLEAN_BUILD=1 ./scripts/macos/build_smoke_macos.sh
```

Enable local CodeQL scan (optional):

```bash
ENABLE_CODEQL=1 ./scripts/macos/check_quality.sh
```

By default, the CodeQL build runs with `BUILD_BINDINGS=OFF` (native backend only) to avoid Shiboken/toolchain coupling.
If you explicitly want bindings in the CodeQL build, override:

```bash
ENABLE_CODEQL=1 CODEQL_BUILD_BINDINGS=ON ./scripts/macos/check_quality.sh
```

Note: with Homebrew CodeQL, query packs may be downloaded on first run (`--download`), so network access is required.

If `codeql` is not installed/in `PATH`, the script reports:

```text
CodeQL CLI not found in PATH but ENABLE_CODEQL=1 was requested.
```

Install CodeQL CLI on macOS (Homebrew):

```bash
brew install codeql
codeql version
```

## Examples
PySide6 samples in `examples/` demonstrate URL loading, JS injection, and signal handling.

## Codec & licensing notes
The project **does not** redistribute proprietary codecs: it leverages codecs **already provided by the OS**. End‑user usage must comply with the relevant licenses/formats.

## Project status
Active development. Current public scope in this repository is macOS.

# Fit Web — Project rationale and options for proprietary codecs

**Fit Web** is the FIT project's *scraper* module designed to **forensically acquire and preserve web content**: <https://github.com/fit-project/fit-web>.

Like the other modules, **Fit Web** is based on **PySide** (Qt for Python). It currently uses **QtWebEngine**, which is a **Chromium** wrapper.

## The problem
By default, Chromium **does not enable proprietary audio/video codecs**, notably **H.264** and **AAC**.

## Options considered

### 1) Build QtWebEngine with proprietary codecs
Enable the `-webengine-proprietary-codecs` option.  
Documentation: <https://doc.qt.io/qt-6/qtwebengine-overview.html>

**Drawbacks**
- Must be done for **all supported operating systems**.
- The build requires **very powerful machines** (e.g., difficulties on a MacBook Air M2 with 16 GB RAM).
- **Licensing**: distributing H.264 and AAC **requires a license**.

### 2) Use QtWebView
QtWebView relies on **the OS’s native web APIs**; for proprietary‑codec content it uses **the system’s codecs**.  
**Pros**: no custom builds, no direct license handling.  
**Cons**: the UI layer is **QML**, geared toward lightweight (often mobile) UIs, so it **doesn’t provide full browser control** compared to QtWebEngine.

Documentation: <https://doc.qt.io/qt-6/qtwebview-index.html>

### 3) Implement a native Qt widget (C/C++) per OS
Develop a Qt widget (usable from **PySide6**) that embeds the system’s web engine:

- **Windows →** Edge WebView2
- **macOS →** WKWebView
- **Linux →** WebKitGTK (with **GStreamer** for codecs)

**Advantages**
- **No redistribution licensing**: leverage the codecs already provided by the OS.
- A **common API** can be exposed to PySide6.
- **More control** than QtWebView, without QML’s limitations.

**Disadvantages**
- **Medium‑to‑high complexity** to implement.
- Requires **C++** and, on macOS, **Objective‑C++**.
- Requires **custom CMake** to include libraries and linking.

---
