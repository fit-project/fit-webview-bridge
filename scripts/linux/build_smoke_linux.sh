#!/usr/bin/env bash
set -euo pipefail

# Build + smoke import for each configured Python version.
# Example:
#   PY_VERSIONS="3.11 3.12 3.13" ./scripts/linux/build_smoke_linux.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PY_VERSIONS="${PY_VERSIONS:-3.11 3.12 3.13}"
QT_VERSION="${QT_VERSION:-6.9.0}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CLEAN_BUILD="${CLEAN_BUILD:-1}"

host_machine="$(uname -m)"
case "$host_machine" in
  aarch64|arm64)
    qt_sdk_dirname="gcc_arm64"
    ;;
  x86_64|amd64)
    qt_sdk_dirname="gcc_64"
    ;;
  *)
    echo "Unsupported Linux architecture: ${host_machine}" >&2
    exit 1
    ;;
esac

QT6_DIR="${QT6_DIR:-$ROOT_DIR/Qt/$QT_VERSION/$qt_sdk_dirname/lib/cmake/Qt6}"

missing_tools=()
for tool in cmake ninja pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done
if ((${#missing_tools[@]} > 0)); then
  printf 'Missing commands: %s\n' "${missing_tools[*]}" >&2
  exit 1
fi

if ! pkg-config --exists webkit2gtk-4.1 gtk+-3.0; then
  echo "WebKitGTK 4.1 and GTK3 development packages are required." >&2
  echo "Run ./scripts/linux/bootstrap_linux.sh after installing system prerequisites." >&2
  exit 1
fi

if [[ ! -f "$QT6_DIR/Qt6Config.cmake" ]]; then
  echo "Qt6_DIR not found: $QT6_DIR" >&2
  echo "Run ./scripts/linux/bootstrap_linux.sh first or set QT6_DIR." >&2
  exit 1
fi

echo "== Linux build + smoke import =="
echo "Architecture: ${host_machine} (${qt_sdk_dirname})"
echo "Qt6_DIR: ${QT6_DIR}"
echo "Build type: ${CMAKE_BUILD_TYPE}"
echo

for pyv in $PY_VERSIONS; do
  py_tag="${pyv/./}"
  venv_dir="$ROOT_DIR/.venv${py_tag}"
  python_exe="$venv_dir/bin/python"
  shiboken_exe="$venv_dir/bin/shiboken6"
  build_dir="$ROOT_DIR/build-linux-py${py_tag}"

  if [[ ! -x "$python_exe" ]]; then
    echo "Missing virtual environment: ${venv_dir}. Run bootstrap first." >&2
    exit 1
  fi
  if [[ ! -x "$shiboken_exe" ]]; then
    echo "shiboken6 executable not found in ${venv_dir}." >&2
    echo "Run ./scripts/linux/bootstrap_linux.sh to repair the environment." >&2
    exit 1
  fi

  actual_minor="$($python_exe -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$actual_minor" != "$pyv" ]]; then
    echo "${venv_dir} uses Python ${actual_minor}; expected ${pyv}." >&2
    exit 1
  fi

  echo "--> Python ${pyv}, build dir: ${build_dir#$ROOT_DIR/}"
  if [[ "$CLEAN_BUILD" == "1" && -d "$build_dir" ]]; then
    rm -rf "$build_dir"
  fi

  cmake \
    -S "$ROOT_DIR" \
    -B "$build_dir" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
    -DBUILD_BINDINGS=ON \
    -DQt6_DIR="$QT6_DIR" \
    -DPython3_EXECUTABLE="$python_exe" \
    -DSHIBOKEN6_GEN="$shiboken_exe"

  cmake --build "$build_dir" --parallel

  PYTHONPATH="$ROOT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    "$python_exe" -c \
      "from fit_webview_bridge import systemwebview; print('systemwebview import OK (py${pyv}):', systemwebview.__file__)"
  echo
done

echo "All Linux builds and smoke imports passed."

