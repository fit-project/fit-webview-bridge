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

`Could NOT find WrapVulkanHeaders` is a non-fatal Qt diagnostic for this build.
