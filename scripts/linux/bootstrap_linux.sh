#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the local Linux toolchain for Python 3.11/3.12/3.13 and Qt.
# Python runtimes are managed by pyenv; the system Python is never modified.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

readonly PYTHON_MINORS=(3.11 3.12 3.13)
readonly PYSIDE_VERSION="6.9.0"
readonly QT_VERSION="6.9.0"
readonly QT_DEST="$ROOT_DIR/Qt"

host_machine="$(uname -m)"
case "$host_machine" in
  aarch64|arm64)
    host_arch="arm64"
    aqt_host="linux_arm64"
    qt_arch="linux_gcc_arm64"
    qt_sdk_dirname="gcc_arm64"
    ;;
  x86_64|amd64)
    host_arch="x86_64"
    aqt_host="linux"
    qt_arch="linux_gcc_64"
    qt_sdk_dirname="gcc_64"
    ;;
  *)
    echo "Error: unsupported Linux architecture reported by uname -m: ${host_machine}" >&2
    exit 1
    ;;
esac

missing_tools=()
for tool in cmake ninja pkg-config pyenv aqt; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done

missing_modules=()
if command -v pkg-config >/dev/null 2>&1; then
  pkg-config --exists webkit2gtk-4.1 || missing_modules+=("webkit2gtk-4.1")
  pkg-config --exists gtk+-3.0 || missing_modules+=("GTK3 (pkg-config module gtk+-3.0)")
fi

if ((${#missing_tools[@]} > 0 || ${#missing_modules[@]} > 0)); then
  echo "Error: required Linux development prerequisites are missing." >&2
  if ((${#missing_tools[@]} > 0)); then
    printf '  Missing commands: %s\n' "${missing_tools[*]}" >&2
  fi
  if ((${#missing_modules[@]} > 0)); then
    printf '  Missing native libraries: %s\n' "${missing_modules[*]}" >&2
  fi
  echo "Install them using your system/toolchain setup, then rerun this script." >&2
  echo "This bootstrap intentionally does not install apt packages or modify system Python." >&2
  exit 1
fi

webkit_version="$(pkg-config --modversion webkit2gtk-4.1)"

latest_patch_version() {
  local minor="$1"
  local version

  version="$(pyenv versions --bare | sed 's:/*$::' | awk -v prefix="${minor}." 'index($0, prefix) == 1 && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print }' | sort -V | tail -n 1)"
  if [[ -n "$version" ]]; then
    printf '%s\n' "$version"
    return
  fi

  version="$(pyenv install --list | sed 's/^[[:space:]]*//' | awk -v prefix="${minor}." 'index($0, prefix) == 1 && $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print }' | sort -V | tail -n 1)"
  if [[ -z "$version" ]]; then
    echo "Error: pyenv has no installable release for Python ${minor}." >&2
    return 1
  fi

  echo "--> Installing Python ${version} with pyenv" >&2
  pyenv install "$version" >&2
  printf '%s\n' "$version"
}

echo "== Bootstrap Linux development environments =="
echo "Architecture: ${host_arch} (${host_machine})"
echo "PySide6/Shiboken6: ${PYSIDE_VERSION}"
echo "Qt: ${QT_VERSION} (${aqt_host}, ${qt_arch})"
echo

declare -a selected_pythons=()
declare -a venv_results=()

for minor in "${PYTHON_MINORS[@]}"; do
  python_version="$(latest_patch_version "$minor")"
  python_bin="$(pyenv prefix "$python_version")/bin/python"
  venv_dir="$ROOT_DIR/.venv${minor/./}"

  if [[ -d "$venv_dir" ]]; then
    if [[ ! -x "$venv_dir/bin/python" ]]; then
      echo "Error: ${venv_dir} exists but is not a usable virtual environment." >&2
      exit 1
    fi
    venv_minor="$($venv_dir/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if [[ "$venv_minor" != "$minor" ]]; then
      echo "Error: ${venv_dir} uses Python ${venv_minor}; expected ${minor}." >&2
      echo "Remove or rename that environment, then rerun this script." >&2
      exit 1
    fi
    venv_action="reused"
  else
    "$python_bin" -m venv "$venv_dir"
    venv_action="created"
  fi

  echo "--> ${venv_action^} .venv${minor/./} with Python ${python_version}"
  "$venv_dir/bin/python" -m pip install --upgrade pip
  "$venv_dir/bin/python" -m pip install \
    "pyside6==${PYSIDE_VERSION}" \
    "shiboken6==${PYSIDE_VERSION}" \
    "shiboken6-generator==${PYSIDE_VERSION}"

  selected_pythons+=("${minor}=${python_bin} (${python_version})")
  venv_results+=(".venv${minor/./}=${venv_action}")
done

qt_dir="$QT_DEST/$QT_VERSION/$qt_sdk_dirname"
qt_config="$qt_dir/lib/cmake/Qt6/Qt6Config.cmake"

if [[ -f "$qt_config" ]]; then
  qt_action="reused"
  echo "== Qt already present at ${qt_dir}; skipping aqt install =="
else
  qt_action="installed"
  echo "== Installing Qt via aqtinstall =="
  aqt install-qt "$aqt_host" desktop "$QT_VERSION" "$qt_arch" -O "$QT_DEST"

  if [[ ! -f "$qt_config" ]]; then
    echo "Error: Qt installation completed but Qt6Config.cmake was not found at:" >&2
    echo "  ${qt_config}" >&2
    exit 1
  fi
fi

echo
echo "== Bootstrap summary =="
echo "Architecture: ${host_arch} (${host_machine})"
printf 'Python: %s\n' "${selected_pythons[@]}"
printf 'Virtual environment: %s\n' "${venv_results[@]}"
echo "PySide6/Shiboken6: ${PYSIDE_VERSION}"
echo "Qt: ${QT_VERSION} (${qt_action})"
echo "Qt directory: ${qt_dir}"
echo "WebKitGTK: ${webkit_version}"
