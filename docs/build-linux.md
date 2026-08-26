# Linux build and smoke test

The Linux proof of concept embeds WebKitGTK in a Qt widget through X11. A real
X11 session and Qt's `xcb` platform plugin are therefore required; headless and
Wayland-native embedding are not currently supported.

## Ubuntu dependencies

Install the WebKitGTK/GTK development packages and the runtime libraries used
by Qt's `xcb` platform plugin:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake ninja-build pkg-config \
  libgtk-3-dev libwebkit2gtk-4.1-dev \
  libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
  libxcb-render-util0 libxcb-xkb1 libxkbcommon-x11-0
```

The repository bootstrap expects `pyenv` and `aqt` to already be available. It
creates Python 3.11, 3.12, and 3.13 virtual environments and installs Qt 6.9.0:

```bash
./scripts/linux/bootstrap_linux.sh
```

## Configure and build

To build and smoke-import the bindings for all supported Python versions, run:

```bash
./scripts/linux/build_smoke_linux.sh
```

Build directories are recreated by default. Use `CLEAN_BUILD=0` to reuse them,
or select versions with `PY_VERSIONS`, for example:

```bash
CLEAN_BUILD=0 PY_VERSIONS="3.11 3.13" ./scripts/linux/build_smoke_linux.sh
```

For a manual single-version build, the following example builds the Python
3.11 binding on ARM64:

```bash
cmake -S . -B build-linux-py311 -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DBUILD_BINDINGS=ON \
  -DQt6_DIR="$PWD/Qt/6.9.0/gcc_arm64/lib/cmake/Qt6" \
  -DPython3_EXECUTABLE="$PWD/.venv311/bin/python" \
  -DSHIBOKEN6_GEN="$PWD/.venv311/bin/shiboken6"

cmake --build build-linux-py311
```

On x86-64, replace `gcc_arm64` with `gcc_64`. To build for another bootstrapped
Python version, use the matching virtual environment and a separate build
directory, for example `.venv313` and `build-linux-py313`.

## Run the smoke test

Use the same Python version used by CMake. The extension is emitted into the
`fit_webview_bridge` package in the source tree, so add the repository root—not
the CMake build directory—to `PYTHONPATH`:

```bash
PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
QT_QPA_PLATFORM=xcb \
./.venv311/bin/python examples/linux/webkitgtk_smoke.py
```

For the self-checking smoke workflow, including navigation, JavaScript,
User-Agent, data clearing, downloads, proxy configuration, and visible-page
capture, plus custom HTTP error pages, run:

```bash
PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
QT_QPA_PLATFORM=xcb \
./.venv311/bin/python examples/linux/webkitgtk_smoke.py --automated
```

The focused session-isolation smoke test uses only a local HTTP server:

```bash
PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
QT_QPA_PLATFORM=xcb \
./.venv311/bin/python examples/linux/webkitgtk_ephemeral_smoke.py
```

The X11 focus/input smoke is intentionally manual because Qt synthetic input
does not reliably reproduce keyboard and mouse events delivered directly to a
foreign GTK X11 window:

```bash
PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
QT_QPA_PLATFORM=xcb \
./.venv311/bin/python examples/linux/webkitgtk_focus_input_smoke.py
```

The Linux bridge gives both `SystemWebViewWidget` and its foreign-window
container a strong Qt focus policy. Entering the wrapper explicitly focuses the
native WebKitGTK widget. The bridge does not synthesize key events, forward
WebKit editing commands, or install process-global X11 hooks. Attempting to
mirror a native GTK click back into Qt with `QWidget::setFocus()` steals X11
keyboard focus from the foreign window, so Qt's logical `focusWidget()` may be
empty while WebKitGTK owns native keyboard focus. Use the manual smoke test to
verify native printable-key and editing-shortcut behavior in the target X11
environment.

Use the smoke page to verify text input, textarea, contenteditable, clipboard
shortcuts, internal Tab/Shift+Tab traversal, native context-menu focus recovery,
and both Qt/WebKit Tab boundaries. Those interaction results remain
manual/window-manager-specific; they are not asserted by the automated smoke
suite.

`Could NOT find WrapVulkanHeaders` is a non-fatal Qt diagnostic for this build.

## Linux API notes

Each Linux `SystemWebViewWidget` owns a dedicated ephemeral WebKit context and
website data manager. Cookies, local storage, databases, caches, and other
website data are session-scoped: they remain available during the lifetime of
that widget/context, but are not intended to survive its destruction. Separate
widgets do not share browsing state.

Files explicitly saved through the download API remain ordinary persistent
filesystem files and are not part of WebKit's ephemeral website storage.
`clearWebsiteData()` and `clearCacheData()` remain available to clear state
during a live widget session.

JavaScript evaluation uses JavaScriptCoreGTK and maps null/undefined, boolean,
number, and string results to their QVariant equivalents. Objects and arrays
are returned as compact JSON text, matching the macOS public representation. A
result that cannot be serialized, such as a cyclic object graph, is reported
through the existing JavaScript error string.

As on macOS, `userAgent()` returns the configured full override, or an empty
string when no override is active; it does not return WebKit's effective
default value. `setApplicationNameForUserAgent()` uses WebKitGTK's native
application-details API. WebKitGTK appends both the supplied name and its
default engine version, whereas WKWebView controls the application-name suffix
through its configuration object.

`clearWebsiteData()` requests removal of every data type supported by the
installed WebKitGTK, including caches, storage, databases, cookies, HSTS/ITP,
service-worker registrations, and DOM cache data. `clearCacheData()` is limited
to WebKitGTK's memory and disk cache types. Both operations are asynchronous.

Downloads require an explicit directory configured with
`setDownloadDirectory()`. The Linux backend does not silently fall back to a
system directory. Existing files are preserved by adding ` (N)` before the
extension. Download progress reports cumulative received bytes and the response
Content-Length, or `-1` when WebKitGTK does not provide a total size.
When a main-frame response is intentionally converted into a download, it does
not emit `loadFinished(false)` or a misleading `loadFinished(true)` for a page
navigation.

Explicit proxy configuration uses a dedicated WebKit context and website data
manager for each `SystemWebViewWidget`, so changing one widget does not alter
unrelated views. `setProxy()` installs an HTTP proxy URI as WebKitGTK's custom
default proxy for both HTTP and HTTPS requests; HTTPS is expected to use CONNECT
according to the WebKitGTK network stack, but the automated smoke test currently
validates HTTP only. Unlike the macOS API, the Linux configuration was verified
to work after prior navigation and does not need to be set immediately after
widget construction. Repeated calls replace the previous configuration.

`clearProxy()` restores WebKitGTK's default/system proxy mode for that widget's
data manager. It does not clear cookies, storage, website data, or cache; the
automated smoke test verifies preservation of local storage across the reset.

`captureVisiblePage()` asynchronously captures only the currently visible
WebKitGTK viewport. A `.jpg` or `.jpeg` suffix selects JPEG output; every other
suffix uses PNG. Missing parent directories are created automatically, and the
result is reported through `captureFinished()` with the token returned by the
method. Full-page capture and capture while the native view is unrealized are
not supported in this milestone.

For main-frame HTTP responses with status 400 or greater, the Linux backend
replaces the remote response body with a deterministic internal error page. It
shows the original URL and status code, while `url()` and
`navigationDisplayUrlChanged()` continue to expose that original URL. Dynamic
text is HTML-escaped and the internal page has no external resources.
`loadFinished(false)` is emitted once for the failed response; loading the
internal page does not emit a later `loadFinished(true)`. Redirects, successful
responses, attachments, and unsupported MIME types intended for download are
not classified as HTTP error pages.

New-window requests such as `target="_blank"` and `window.open()` are handled
inside the existing `SystemWebViewWidget`. The Linux backend rejects creation
of a secondary WebKitGTK view and loads the supplied request in the current
view, preserving its normal navigation history, download handling, and custom
HTTP error-page behavior. The automated smoke test verifies Back/Forward,
popup-initiated downloads, and popup-initiated HTTP 404 responses.

Popup destinations are accepted for HTTP, HTTPS, file, data, about, and blob
URLs. Empty destinations and schemes such as `mailto`, `tel`, and `javascript`
are ignored; the backend does not launch external applications for them.

WebKitGTK's native URI property tracks same-document History API changes. The
automated smoke test verifies `pushState()`, `replaceState()`, hash navigation,
and Back/popstate updates for `url()`, `urlChanged()`, and
`navigationDisplayUrlChanged()` without JavaScript injection.
