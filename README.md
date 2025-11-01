# FIT WebView Bridge

### Description

**FIT WebView Bridge** is a cross‑platform Qt widget (C++/Objective‑C++) with **PySide6** bindings that wraps the OS‑native web engines:
- **Windows →** Edge WebView2
- **macOS →** WKWebView
- **Linux →** WebKitGTK (with **GStreamer** for codecs)

It exposes a **unified Python API** for browser control and enables **forensic viewing/capture** of content, including media requiring proprietary codecs (e.g., **H.264/AAC**), **without** custom QtWebEngine builds or codec redistribution burdens (system codecs are used). All **controls** (UI and app logic) are **delegated to the PySide window**.


### Why this project
QtWebEngine (Chromium) **does not enable proprietary codecs** by default, and redistributing them requires **licensing**. Alternatives (building QtWebEngine with codecs or using QtWebView/QML) have portability/control limitations. The chosen path is to **leverage native engines**, achieving codec compatibility and **full control** via a Python API.

### Repository layout
```
fit-webview-bridge/
├─ CMakeLists.txt
├─ cmake/                   # Find*.cmake, toolchains, helpers
├─ include/fitwvb/          # Public headers (API)
├─ src/
│  ├─ core/                 # Facade / common interfaces
│  ├─ win/                  # Edge WebView2 backend (C++)
│  ├─ macos/                # WKWebView backend (Obj-C++)
│  └─ linux/                # WebKitGTK backend (C++)
├─ bindings/pyside6/        # Shiboken6: typesystem & config
├─ tests/                   # Unit / integration
└─ examples/                # Minimal PySide6 demo app
```

### Interface (methods/slots + signals)
**Methods / slots**
- `load(url)`
- `back()`
- `forward()`
- `reload()`
- `stop()`
- `setHtml(html, baseUrl)`
- `evalJs(script, callback)`

**Signals**
- `urlChanged(QUrl)`
- `titleChanged(QString)`
- `loadProgress(int)`
- `loadFinished(bool)`
- `consoleMessage(QString)`

> Note: the API is **uniform** across OSes; implementations delegate to the native engine.

### Prerequisites
**Common**
- **CMake** (>= 3.24 recommended)
- **Ninja** (generator)
- **Python** 3.9+
- **PySide6** and **Shiboken6** (for Python bindings)
- Platform build toolchain

**Windows**
- **MSVC** (Visual Studio 2022 or Build Tools) and Windows SDK
- **Microsoft Edge WebView2 Runtime**
- **WebView2 SDK** (NuGet/vcpkg)

**macOS**
- **Xcode** + Command Line Tools
- **Objective‑C++** enabled (.mm)
- Frameworks: `WebKit`, `Cocoa`

**Linux**
- **GCC/Clang**, `pkg-config`
- **WebKitGTK** dev packages (e.g., `webkit2gtk-4.1` or distro equivalent)
- **GStreamer** (base + required plugins for codecs)

### Build (indicative)
```bash
git clone https://github.com/fit-project/fit-webview-bridge.git
cd fit-webview-bridge
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PYSIDE6_BINDINGS=ON
cmake --build build
# (optional) ctest --test-dir build
```

### Examples
PySide6 samples in `examples/` demonstrate URL loading, JS injection, and signal handling.

### Codec & licensing notes
The project **does not** redistribute proprietary codecs: it leverages codecs **already provided by the OS**. End‑user usage must comply with the relevant licenses/formats.

### Project status
Initial/alpha (API subject to change).

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
