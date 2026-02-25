#!/usr/bin/env bash
set -euo pipefail

# Build + smoke import for each configured Python version.
# Example:
#   PY_VERSIONS="3.11 3.12 3.13" PYSIDE_VERSION=6.9.0 ./scripts/macos/build_smoke_macos.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PY_VERSIONS="${PY_VERSIONS:-3.11 3.12 3.13}"
QT_VERSION="${QT_VERSION:-6.9.0}"
if [[ -z "${QT6_DIR:-}" ]]; then
  default_qt6_dir="$ROOT_DIR/Qt/${QT_VERSION}/macos/lib/cmake/Qt6"
  legacy_qt6_dir="$ROOT_DIR/scripts/Qt/${QT_VERSION}/macos/lib/cmake/Qt6"
  if [[ -d "$default_qt6_dir" ]]; then
    QT6_DIR="$default_qt6_dir"
  elif [[ -d "$legacy_qt6_dir" ]]; then
    # Legacy location created by older script path logic.
    QT6_DIR="$legacy_qt6_dir"
  else
    QT6_DIR="$default_qt6_dir"
  fi
fi
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
CMAKE_OSX_ARCHITECTURES="${CMAKE_OSX_ARCHITECTURES:-arm64}"
FITWVB_VENDORIZE="${FITWVB_VENDORIZE:-OFF}"
CLEAN_BUILD="${CLEAN_BUILD:-1}"
if command -v xcrun >/dev/null 2>&1; then
  MACOS_SDKROOT="${MACOS_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
else
  MACOS_SDKROOT="${MACOS_SDKROOT:-}"
fi

if [[ ! -d "$QT6_DIR" ]]; then
  echo "Qt6_DIR not found: $QT6_DIR" >&2
  echo "Run ./scripts/macos/bootstrap_macos.sh first or set QT6_DIR." >&2
  exit 1
fi

echo "== Build + smoke =="
echo "Qt6_DIR: $QT6_DIR"
echo "Build type: $CMAKE_BUILD_TYPE"
echo "Arch: $CMAKE_OSX_ARCHITECTURES"
echo

for pyv in $PY_VERSIONS; do
  venv_dir=".venv${pyv/./}"
  if [[ ! -x "${venv_dir}/bin/python" ]]; then
    echo "Missing venv: ${venv_dir}. Run bootstrap first." >&2
    exit 1
  fi

  build_dir="build-py${pyv/./}"
  echo "--> Python ${pyv} (${venv_dir}), build dir: ${build_dir}"
  if [[ "${CLEAN_BUILD}" == "1" ]]; then
    rm -rf "${build_dir}"
  fi
  source "${venv_dir}/bin/activate"

  python_exe="$(python -c 'import sys; print(sys.executable)')"
  shiboken_exe="${ROOT_DIR}/${venv_dir}/bin/shiboken6"
  if [[ ! -x "${shiboken_exe}" ]]; then
    shiboken_exe="$(python -c 'import shutil; print(shutil.which("shiboken6") or "")')"
  fi
  if [[ -z "${shiboken_exe}" || ! -x "${shiboken_exe}" ]]; then
    echo "shiboken6 executable not found in ${venv_dir}. Install/repair PySide6 in this venv." >&2
    exit 1
  fi
  echo "Using shiboken: ${shiboken_exe}"

  cmake_cmd=(
    cmake -S . \
      -B "${build_dir}" \
      -G Ninja \
      -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
      -DCMAKE_OSX_ARCHITECTURES="${CMAKE_OSX_ARCHITECTURES}" \
      -DFITWVB_VENDORIZE="${FITWVB_VENDORIZE}" \
      -DQt6_DIR="${QT6_DIR}" \
      -DPython3_EXECUTABLE="${python_exe}" \
      -DSHIBOKEN6_GEN="${shiboken_exe}"
  )
  if [[ -n "${MACOS_SDKROOT}" ]]; then
    cmake_cmd+=("-DCMAKE_OSX_SYSROOT=${MACOS_SDKROOT}")
  fi
  env \
    -u CPATH \
    -u CPLUS_INCLUDE_PATH \
    -u C_INCLUDE_PATH \
    -u OBJC_INCLUDE_PATH \
    PATH="${ROOT_DIR}/${venv_dir}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    CC=/usr/bin/clang \
    CXX=/usr/bin/clang++ \
    "${cmake_cmd[@]}"

  env \
    -u CPATH \
    -u CPLUS_INCLUDE_PATH \
    -u C_INCLUDE_PATH \
    -u OBJC_INCLUDE_PATH \
    CC=/usr/bin/clang \
    CXX=/usr/bin/clang++ \
    cmake --build "${build_dir}" --parallel

  PYTHONPATH="${ROOT_DIR}/${build_dir}:${PYTHONPATH:-}" \
    python -c "import wkwebview; print('wkwebview import OK (py${pyv})')"

  deactivate
  echo
done

echo "All builds and smoke imports passed."
