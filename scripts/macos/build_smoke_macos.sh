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
  source "${venv_dir}/bin/activate"

  python_exe="$(python -c 'import sys; print(sys.executable)')"
  cmake -S . \
    -B "${build_dir}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
    -DCMAKE_OSX_ARCHITECTURES="${CMAKE_OSX_ARCHITECTURES}" \
    -DFITWVB_VENDORIZE="${FITWVB_VENDORIZE}" \
    -DQt6_DIR="${QT6_DIR}" \
    -DPython3_EXECUTABLE="${python_exe}"

  cmake --build "${build_dir}" --parallel

  PYTHONPATH="${ROOT_DIR}/${build_dir}:${PYTHONPATH:-}" \
    python -c "import wkwebview; print('wkwebview import OK (py${pyv})')"

  deactivate
  echo
done

echo "All builds and smoke imports passed."
