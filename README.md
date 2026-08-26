# FIT WebView Bridge

## Description

**FIT WebView Bridge** provides a Qt widget with **PySide6** bindings for embedding native system web engines.

Goals:

- use OS-native web engines and system codecs instead of custom QtWebEngine proprietary-codec builds
- expose a common, Python-usable widget API for navigation, downloads, JavaScript evaluation, and capture

The planned platform backends are:

- **macOS →** WKWebView
- **Linux →** WebKitGTK
- **Windows →** Edge WebView2

## Why this project

QtWebEngine (Chromium) does not enable proprietary codecs by default. This module uses native web engines to keep codec compatibility and retain application control through a Qt/PySide API.

## Implementation status

- **macOS:** implemented and currently supported (`src/macos`, `bindings/pyside6/macos`)
- **Linux:** working X11/WebKitGTK proof of concept; backend still in development
- **Windows:** planned; not yet supported

## Repository layout

```text
fit-webview-bridge/
├─ CMakeLists.txt
├─ include/fit_webview_bridge/  # Platform-neutral public C++ API
├─ src/
│  └─ macos/                    # WKWebView backend (Objective-C++)
├─ bindings/pyside6/            # Shiboken typesystem and platform binding builds
│  └─ macos/
├─ fit_webview_bridge/          # Python package entrypoint
├─ examples/macos/              # macOS demo app
├─ scripts/                     # Platform development scripts
│  ├─ linux/
│  └─ macos/
├─ docs/                        # Platform build and development guides
└─ tests/                       # Pytest suites
```

## API (`SystemWebViewWidget`)

**Methods / invokables**

- `url()`
- `setUrl(QUrl)`
- `back()`
- `forward()`
- `stop()`
- `reload()`
- `clearWebsiteData()`
- `clearCacheData()`
- `setProxy(QString host, int port) -> bool` (macOS 14+ WKWebView explicit HTTP CONNECT proxy)
- `clearProxy()`
- `hasExplicitProxySupport() -> bool`
- `evaluateJavaScript(QString)`
- `evaluateJavaScriptWithResult(QString) -> token`
- `setDownloadDirectory(QString)`
- `downloadDirectory()`
- `setUserAgent(QString)`
- `userAgent()`
- `resetUserAgent()`
- `setApplicationNameForUserAgent(QString)`
- `captureVisiblePage(QString) -> token`

On the macOS backend, `setProxy()` uses `WKWebsiteDataStore.proxyConfigurations` on macOS 14+ and should be called immediately after creating `SystemWebViewWidget`, before the first `setUrl()`. `clearProxy()` only removes the explicit proxy configuration; it does not clear cookies, storage, or cache.

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

## Development / Build

Detailed build, test, and quality-check instructions are maintained in platform-specific guides. The currently supported development workflow is documented in the [macOS build and development guide](docs/build-macos.md).

## Platform documentation

- [macOS build and development guide](docs/build-macos.md)
- [Linux build and smoke-test guide](docs/build-linux.md)
- Windows build guide — planned

## Examples

The PySide6 samples in `examples/macos/` and `examples/linux/` demonstrate the
native platform backends. The Linux smoke test currently requires an X11
session and Qt's `xcb` platform plugin.

## Codec and licensing notes

The project **does not** redistribute proprietary codecs: it leverages codecs **already provided by the OS**. End-user usage must comply with the relevant licenses and formats.

## Project status

Active development. The current supported public implementation in this repository is macOS; Linux is in development and Windows is planned.

## Fit Web — Project rationale and options for proprietary codecs

**Fit Web** is the FIT project's *scraper* module designed to **forensically acquire and preserve web content**: <https://github.com/fit-project/fit-web>.

Like the other modules, **Fit Web** is based on **PySide** (Qt for Python). It currently uses **QtWebEngine**, which is a **Chromium** wrapper.

### The problem

By default, Chromium **does not enable proprietary audio/video codecs**, notably **H.264** and **AAC**.

### Options considered

#### 1) Build QtWebEngine with proprietary codecs

Enable the `-webengine-proprietary-codecs` option.  
Documentation: <https://doc.qt.io/qt-6/qtwebengine-overview.html>

**Drawbacks**

- Must be done for **all supported operating systems**.
- The build requires **very powerful machines** (e.g., difficulties on a MacBook Air M2 with 16 GB RAM).
- **Licensing**: distributing H.264 and AAC **requires a license**.

#### 2) Use QtWebView

QtWebView relies on **the OS's native web APIs**; for proprietary-codec content it uses **the system's codecs**.

**Pros**: no custom builds, no direct license handling.

**Cons**: the UI layer is **QML**, geared toward lightweight (often mobile) UIs, so it **doesn't provide full browser control** compared to QtWebEngine.

Documentation: <https://doc.qt.io/qt-6/qtwebview-index.html>

#### 3) Implement a native Qt widget (C/C++) per OS

Develop a Qt widget (usable from **PySide6**) that embeds the system's web engine:

- **Windows →** Edge WebView2
- **macOS →** WKWebView
- **Linux →** WebKitGTK (with **GStreamer** for codecs)

**Advantages**

- **No redistribution licensing**: leverage the codecs already provided by the OS.
- A **common API** can be exposed to PySide6.
- **More control** than QtWebView, without QML's limitations.

**Disadvantages**

- **Medium-to-high complexity** to implement.
- Requires **C++** and, on macOS, **Objective-C++**.
- Requires **custom CMake** to include libraries and linking.
