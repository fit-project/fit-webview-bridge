#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${PYTHON_EXE:?PYTHON_EXE is required}"
: "${PYTHON_VERSION:?PYTHON_VERSION is required}"
: "${PY_TAG:?PY_TAG is required}"
: "${Qt6_DIR:?Qt6_DIR is required}"
: "${QT_ROOT:?QT_ROOT is required}"
: "${WHEELHOUSE:?WHEELHOUSE is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

actual_minor="$("${PYTHON_EXE}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
test "${actual_minor}" = "${PYTHON_VERSION}"

build_dir="${RUNNER_TEMP}/build-linux-ci-py${PY_TAG}-x86_64"
dist_dir="${RUNNER_TEMP}/dist-py${PY_TAG}"
extract_dir="${RUNNER_TEMP}/wheel-extract-py${PY_TAG}"
clean_root="${RUNNER_TEMP}/clean-wheel-py${PY_TAG}"
shiboken_exe="$(dirname "${PYTHON_EXE}")/shiboken6"

rm -rf "${build_dir}" "${dist_dir}" "${extract_dir}" "${clean_root}"
mkdir -p "${dist_dir}" "${extract_dir}" "${clean_root}" "${WHEELHOUSE}"

cmake -S "${ROOT_DIR}" -B "${build_dir}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_BINDINGS=ON \
  -DQt6_DIR="${Qt6_DIR}" -DPython3_EXECUTABLE="${PYTHON_EXE}" \
  -DSHIBOKEN6_GEN="${shiboken_exe}"
cmake --build "${build_dir}" --parallel

PYTHONPATH="${ROOT_DIR}" "${PYTHON_EXE}" -c \
  "from fit_webview_bridge import systemwebview; print('developer import OK:', systemwebview.__file__)"

export CMAKE_ARGS="-DQt6_DIR=${Qt6_DIR} -DPython3_EXECUTABLE=${PYTHON_EXE} -DSHIBOKEN6_GEN=${shiboken_exe}"
"${PYTHON_EXE}" -m build --wheel --no-isolation --outdir "${dist_dir}" "${ROOT_DIR}"

mapfile -t wheels < <(find "${dist_dir}" -maxdepth 1 -type f -name '*.whl' -print)
test "${#wheels[@]}" -eq 1
wheel="${wheels[0]}"
[[ "$(basename "${wheel}")" == *-cp${PY_TAG}-cp${PY_TAG}-linux_x86_64.whl ]]

export WHEEL_PATH="${wheel}"
"${PYTHON_EXE}" - <<'PY'
import os
import zipfile

with zipfile.ZipFile(os.environ["WHEEL_PATH"]) as archive:
    names = archive.namelist()
    print(*names, sep="\n")
    extensions = [name for name in names if name.startswith("fit_webview_bridge/systemwebview") and name.endswith(".so")]
    assert names.count("fit_webview_bridge/__init__.py") == 1
    assert len(extensions) == 1, extensions
    assert extensions[0].endswith(f"cpython-{os.environ['PY_TAG']}-x86_64-linux-gnu.so"), extensions[0]
    assert any(name.endswith(".dist-info/METADATA") for name in names)
    forbidden = ("/build/", "Qt/", ".libs/", "libwebkit", "libgtk", "libjavascriptcore")
    assert not any(token in name for name in names for token in forbidden), names
    assert len([name for name in names if name.endswith(".so")]) == 1
PY

"${PYTHON_EXE}" -m zipfile -e "${wheel}" "${extract_dir}"
mapfile -t packaged_extensions < <(find "${extract_dir}/fit_webview_bridge" -maxdepth 1 -type f -name 'systemwebview*.so' -print)
test "${#packaged_extensions[@]}" -eq 1
packaged_so="${packaged_extensions[0]}"
readelf -d "${packaged_so}"
objdump -p "${packaged_so}" | grep -E 'NEEDED|RPATH|RUNPATH'
runpath="$(readelf -d "${packaged_so}" | grep -E 'RPATH|RUNPATH')"
runpath_value="$(sed -n 's/.*Library runpath: \[\(.*\)\].*/\1/p' <<<"${runpath}")"
test "${runpath_value}" = '$ORIGIN:$ORIGIN/../PySide6/Qt/lib:$ORIGIN/../PySide6:$ORIGIN/../shiboken6'
"${PYTHON_EXE}" -m auditwheel show "${wheel}"

clean_venv="${clean_root}/venv"
"${PYTHON_EXE}" -m venv "${clean_venv}"
cd "${clean_root}"
env -u PYTHONPATH "${clean_venv}/bin/python" -m pip install "${wheel}"
env -u PYTHONPATH "${clean_venv}/bin/python" -I - <<'PY'
import pathlib
import sys
import fit_webview_bridge
from fit_webview_bridge import SystemWebView, systemwebview

prefix = pathlib.Path(sys.prefix).resolve()
for module in (fit_webview_bridge, systemwebview):
    path = pathlib.Path(module.__file__).resolve()
    print(path)
    assert path.is_relative_to(prefix)
print("isolated import OK")
PY
env -u PYTHONPATH "${clean_venv}/bin/python" - <<'PY'
from importlib.metadata import distributions
names = {dist.metadata["Name"].lower() for dist in distributions()}
forbidden = {"cmake", "ninja", "scikit-build-core", "shiboken6-generator"}
assert names.isdisjoint(forbidden), names & forbidden
PY

site_packages="$(env -u PYTHONPATH "${clean_venv}/bin/python" -c 'import sysconfig; print(sysconfig.get_path("platlib"))')"
mapfile -t installed_extensions < <(find "${site_packages}/fit_webview_bridge" -maxdepth 1 -type f -name 'systemwebview*.so' -print)
test "${#installed_extensions[@]}" -eq 1
installed_so="${installed_extensions[0]}"
readelf -d "${installed_so}"
ldd_output="$(ldd "${installed_so}")"
printf '%s\n' "${ldd_output}"
! grep -q 'not found' <<<"${ldd_output}"
grep -E "libQt6(Core|Gui|Widgets).*${clean_venv}.*/PySide6/Qt/lib" <<<"${ldd_output}"
grep -E "libpyside6.*${clean_venv}.*/PySide6" <<<"${ldd_output}"
grep -E "libshiboken6.*${clean_venv}.*/shiboken6" <<<"${ldd_output}"
grep -E 'libwebkit2gtk-4\.1\.so.* => /(usr/)?lib/' <<<"${ldd_output}"
grep -E 'libgtk-3\.so.* => /(usr/)?lib/' <<<"${ldd_output}"
if grep -Fq "${ROOT_DIR}" <<<"${ldd_output}" || grep -Fq "${QT_ROOT}" <<<"${ldd_output}"; then
  echo "Installed extension resolved a build-tree dependency" >&2
  exit 1
fi

smoke_script="${clean_root}/wheel_xvfb_smoke.py"
cat > "${smoke_script}" <<'PY'
from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication
from fit_webview_bridge import SystemWebView

app = QApplication([])
view = SystemWebView()
result = {"finished": None}
def finish(ok):
    result["finished"] = bool(ok)
    print(f"loadFinished={bool(ok)}")
    QTimer.singleShot(100, app.quit)
view.loadFinished.connect(finish)
view.resize(640, 480)
view.show()
view.setUrl(QUrl("data:text/html,<title>Wheel smoke</title><h1>Installed wheel OK</h1>"))
QTimer.singleShot(10_000, app.quit)
app.exec()
view.close()
if result["finished"] is not True:
    raise SystemExit("installed-wheel Xvfb smoke did not finish successfully")
print("installed-wheel Xvfb smoke OK")
PY
env -u PYTHONPATH QT_QPA_PLATFORM=xcb GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
  xvfb-run -a "${clean_venv}/bin/python" -I "${smoke_script}"

cp "${wheel}" "${WHEELHOUSE}/"
echo "Validated $(basename "${wheel}")"

