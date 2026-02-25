#!/usr/bin/env bash
set -euo pipefail

# Native quality/security checks for macOS backend.
#
# Default:
#   1) clang-format dry-run check
#   2) clang-tidy on Objective-C++ sources (subset rules)
#
# Optional:
#   3) CodeQL local scan (ENABLE_CODEQL=1)
#
# Examples:
#   ./scripts/macos/check_quality.sh
#   CLANG_TIDY_CHECKS='-*,clang-analyzer-*,bugprone-*' ./scripts/macos/check_quality.sh
#   ENABLE_CODEQL=1 ./scripts/macos/check_quality.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="${BUILD_DIR:-build-quality}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Debug}"
CLANG_TIDY_CHECKS="${CLANG_TIDY_CHECKS:--*,clang-analyzer-*,bugprone-*,performance-*}"
ENABLE_CODEQL="${ENABLE_CODEQL:-0}"
CODEQL_DB="${CODEQL_DB:-.codeql-db}"
CODEQL_OUTPUT="${CODEQL_OUTPUT:-codeql.sarif}"
CODEQL_BUILD_DIR="${CODEQL_BUILD_DIR:-${BUILD_DIR}-codeql}"
CODEQL_BUILD_BINDINGS="${CODEQL_BUILD_BINDINGS:-OFF}"
FORMAT_FIX="${FORMAT_FIX:-0}"
SKIP_TIDY="${SKIP_TIDY:-0}"
if command -v xcrun >/dev/null 2>&1; then
  MACOS_SDKROOT="${MACOS_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
else
  MACOS_SDKROOT="${MACOS_SDKROOT:-}"
fi

# Reuse existing build env vars if set by caller/scripts.
QT_VERSION="${QT_VERSION:-6.9.0}"
if [[ -z "${QT6_DIR:-}" ]]; then
  default_qt6_dir="$ROOT_DIR/Qt/${QT_VERSION}/macos/lib/cmake/Qt6"
  legacy_qt6_dir="$ROOT_DIR/scripts/Qt/${QT_VERSION}/macos/lib/cmake/Qt6"
  if [[ -d "$default_qt6_dir" ]]; then
    QT6_DIR="$default_qt6_dir"
  elif [[ -d "$legacy_qt6_dir" ]]; then
    QT6_DIR="$legacy_qt6_dir"
  else
    QT6_DIR="$default_qt6_dir"
  fi
fi

if [[ -z "${Python3_EXECUTABLE:-}" ]]; then
  Python3_EXECUTABLE="$(python3 -c 'import sys; print(sys.executable)')"
fi

resolve_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi
  if command -v xcrun >/dev/null 2>&1; then
    local xcr_path
    xcr_path="$(xcrun --find "$tool" 2>/dev/null || true)"
    if [[ -n "$xcr_path" ]]; then
      echo "$xcr_path"
      return 0
    fi
  fi
  local brew_llvm="/opt/homebrew/opt/llvm/bin/${tool}"
  if [[ -x "$brew_llvm" ]]; then
    echo "$brew_llvm"
    return 0
  fi
  return 1
}

echo "== Native quality checks (macOS) =="
echo "Root: ${ROOT_DIR}"
echo "Build dir: ${BUILD_DIR}"
echo "Qt6_DIR: ${QT6_DIR}"
echo "Python3_EXECUTABLE: ${Python3_EXECUTABLE}"
echo "FORMAT_FIX: ${FORMAT_FIX}"
echo "SKIP_TIDY: ${SKIP_TIDY}"
echo "MACOS_SDKROOT: ${MACOS_SDKROOT}"
echo

if ! CLANG_FORMAT_BIN="$(resolve_tool clang-format)"; then
  echo "clang-format not found." >&2
  echo "Install with: brew install llvm" >&2
  echo "Then export PATH=\"/opt/homebrew/opt/llvm/bin:\$PATH\"" >&2
  exit 1
fi
if ! CLANG_TIDY_BIN="$(resolve_tool clang-tidy)"; then
  echo "clang-tidy not found." >&2
  echo "Install with: brew install llvm" >&2
  echo "Then export PATH=\"/opt/homebrew/opt/llvm/bin:\$PATH\"" >&2
  exit 1
fi

echo "[1/3] clang-format dry-run check"
format_files=()
while IFS= read -r file; do
  format_files+=("$file")
done < <(find src/macos -type f \( -name '*.h' -o -name '*.mm' \) | sort)

if [[ "${#format_files[@]}" -eq 0 ]]; then
  echo "No C++/Objective-C++ files found under src/macos" >&2
  exit 1
fi

if [[ "${FORMAT_FIX}" == "1" ]]; then
  echo "Applying clang-format in-place (FORMAT_FIX=1)"
  "${CLANG_FORMAT_BIN}" -i "${format_files[@]}"
fi
"${CLANG_FORMAT_BIN}" --dry-run --Werror "${format_files[@]}"
echo "clang-format: OK"
echo

echo "[2/3] configure + clang-tidy"
if [[ "${SKIP_TIDY}" == "1" ]]; then
  echo "clang-tidy skipped (SKIP_TIDY=1)."
  exit 0
fi

if [[ ! -d "$QT6_DIR" ]]; then
  echo "Qt6_DIR not found: ${QT6_DIR}" >&2
  echo "Run ./scripts/macos/bootstrap_macos.sh first or set QT6_DIR." >&2
  exit 1
fi

env \
  -u CPATH \
  -u CPLUS_INCLUDE_PATH \
  -u C_INCLUDE_PATH \
  -u OBJC_INCLUDE_PATH \
  CC=/usr/bin/clang \
  CXX=/usr/bin/clang++ \
  cmake -S . -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DBUILD_BINDINGS=OFF \
  -DQt6_DIR="${QT6_DIR}" \
  -DPython3_EXECUTABLE="${Python3_EXECUTABLE}"
cmake --build "${BUILD_DIR}" --parallel

tidy_files=()
while IFS= read -r file; do
  tidy_files+=("$file")
done < <(find src/macos -type f -name '*.mm' | sort)

if [[ "${#tidy_files[@]}" -eq 0 ]]; then
  echo "No Objective-C++ implementation files found for clang-tidy." >&2
  exit 1
fi

for f in "${tidy_files[@]}"; do
  echo "clang-tidy: ${f}"
  tidy_cmd=(
    "${CLANG_TIDY_BIN}" "${f}" -p "${BUILD_DIR}" -checks="${CLANG_TIDY_CHECKS}"
  )
  if [[ -n "${MACOS_SDKROOT}" ]]; then
    tidy_cmd+=("--extra-arg=-isysroot" "--extra-arg=${MACOS_SDKROOT}")
  fi
  "${tidy_cmd[@]}"
done
echo "clang-tidy: OK"
echo

echo "[3/3] CodeQL (optional)"
if [[ "${ENABLE_CODEQL}" != "1" ]]; then
  echo "CodeQL skipped (set ENABLE_CODEQL=1 to run)."
  exit 0
fi

if ! command -v codeql >/dev/null 2>&1; then
  echo "CodeQL CLI not found in PATH but ENABLE_CODEQL=1 was requested." >&2
  exit 1
fi

rm -rf "${CODEQL_DB}" "${CODEQL_BUILD_DIR}"
CODEQL_BUILD_SCRIPT="${ROOT_DIR}/.codeql-build.sh"
cat > "${CODEQL_BUILD_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
env \
  -u CPATH \
  -u CPLUS_INCLUDE_PATH \
  -u C_INCLUDE_PATH \
  -u OBJC_INCLUDE_PATH \
  CC=/usr/bin/clang \
  CXX=/usr/bin/clang++ \
  cmake -S . -B "${CODEQL_BUILD_DIR}" -G Ninja \
  -DBUILD_BINDINGS="${CODEQL_BUILD_BINDINGS}" \
  -DQt6_DIR="${QT6_DIR}" \
  -DPython3_EXECUTABLE="${Python3_EXECUTABLE}"
cmake --build "${CODEQL_BUILD_DIR}" --parallel
EOF
chmod +x "${CODEQL_BUILD_SCRIPT}"
trap 'rm -f "${CODEQL_BUILD_SCRIPT}"' EXIT

codeql database create "${CODEQL_DB}" \
  --language=cpp \
  --command="${CODEQL_BUILD_SCRIPT}"
codeql database analyze "${CODEQL_DB}" \
  codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls \
  --download \
  --format=sarif-latest \
  --output="${CODEQL_OUTPUT}"

echo "CodeQL: OK (${CODEQL_OUTPUT})"
