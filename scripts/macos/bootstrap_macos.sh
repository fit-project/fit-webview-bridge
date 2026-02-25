#!/usr/bin/env bash
set -euo pipefail

# Bootstraps local macOS toolchain for Python 3.11/3.12/3.13 and Qt.
# Override defaults with env vars, e.g.:
#   PYSIDE_VERSION=6.9.3 QT_VERSION=6.9.0 ./scripts/macos/bootstrap_macos.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PY_VERSIONS="${PY_VERSIONS:-3.11 3.12 3.13}"
PYSIDE_VERSION="${PYSIDE_VERSION:-6.9.0}"
QT_VERSION="${QT_VERSION:-6.9.0}"
if [[ -z "${QT_DEST:-}" ]]; then
  if [[ -d "$ROOT_DIR/Qt" ]]; then
    QT_DEST="$ROOT_DIR/Qt"
  elif [[ -d "$ROOT_DIR/scripts/Qt" ]]; then
    # Legacy location created by older script path logic.
    QT_DEST="$ROOT_DIR/scripts/Qt"
  else
    QT_DEST="$ROOT_DIR/Qt"
  fi
fi
QT_ARCH="${QT_ARCH:-clang_64}"

echo "== Bootstrap environments =="
echo "Python versions: $PY_VERSIONS"
echo "PySide/Shiboken: $PYSIDE_VERSION"
echo "Qt version: $QT_VERSION"
echo

first_venv=""
for pyv in $PY_VERSIONS; do
  venv_dir=".venv${pyv/./}"
  py_bin="python${pyv}"
  echo "--> Preparing ${venv_dir} (${py_bin})"
  "${py_bin}" -m venv "${venv_dir}"
  source "${venv_dir}/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install \
    "pyside6==${PYSIDE_VERSION}" \
    "shiboken6==${PYSIDE_VERSION}" \
    "shiboken6-generator==${PYSIDE_VERSION}"
  deactivate
  if [[ -z "$first_venv" ]]; then
    first_venv="${venv_dir}"
  fi
done

qt_dir="${QT_DEST}/${QT_VERSION}/macos"
if [[ -d "$qt_dir" ]]; then
  echo "== Qt already present at: ${qt_dir}"
  echo "Skipping aqt install."
  exit 0
fi

echo "== Installing Qt via aqtinstall =="
source "${first_venv}/bin/activate"
python -m pip install -U aqtinstall
aqt install-qt mac desktop "${QT_VERSION}" "${QT_ARCH}" -O "${QT_DEST}"
deactivate

echo
echo "Done. Qt installed under: ${qt_dir}"
