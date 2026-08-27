# Release and distribution

FIT WebView Bridge release wheels are distributed through the FIT Project
static Python package index:

<https://fit-project.github.io/fit-python-index/simple/>

PyPI remains the source for upstream runtime dependencies, including PySide6
and Shiboken6.

## Distribution architecture

The intended release flow is:

```text
fit-webview-bridge tag
        ↓
release workflow
        ↓
macOS ARM64 wheels + Linux x86_64 wheels
        ↓
FIT Python Index
        ↓
Poetry/pip
```

Automatic tag triggering and publication to the FIT Python Index are pending a
later milestone. For now, `.github/workflows/release.yml` runs only through
`workflow_dispatch`. It builds and validates the release payload, generates the
static Simple Index tree, and uploads that tree as the
`fit-python-index-dry-run` artifact. It does not publish packages, create a
GitHub Release, or change the live FIT Python Index.

## Supported release-wheel matrix

| Platform | Architecture | Python | Runtime baseline |
| --- | --- | --- | --- |
| macOS | ARM64 | CPython 3.11, 3.12, 3.13 | Apple Silicon / WKWebView |
| Linux | x86_64 | CPython 3.11, 3.12, 3.13 | Ubuntu 24.04, X11/xcb, WebKitGTK 4.1 and GTK 3 |

The Linux wheels intentionally retain the native `linux_x86_64` platform tag.
They are not repaired into manylinux wheels and do not bundle WebKitGTK, GTK,
or other operating-system libraries. Qt, PySide6, and Shiboken6 are resolved
from the consumer environment through the declared Python dependencies.

Windows and native Wayland support remain unsupported and open contribution
areas. ARM64 Linux is not part of the release-wheel matrix.

## Dry-run payload

The release workflow builds the following six files from the version declared
in `pyproject.toml`:

```text
fit_webview_bridge-<VERSION>-cp311-cp311-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp312-cp312-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp313-cp313-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp311-cp311-macosx_*_arm64.whl
fit_webview_bridge-<VERSION>-cp312-cp312-macosx_*_arm64.whl
fit_webview_bridge-<VERSION>-cp313-cp313-macosx_*_arm64.whl
```

The combined artifact has this publication-ready layout:

```text
simple/
├── index.html
└── fit-webview-bridge/
    ├── index.html
    └── <six wheel files>
```

Every package-page link contains the wheel's calculated SHA-256 digest as its
URL fragment. The workflow validates the tree and performs a CPython 3.11 Linux
install against a local HTTP server before uploading the artifact.

## Next publication milestone

After the dry-run artifact has been manually accepted, the next milestone is
to add a `v*` tag trigger and a least-privilege publication job that writes the
validated `site/` payload to `fit-project/fit-python-index`. That change must
define the cross-repository authentication and GitHub Pages update mechanism;
neither is present in the dry-run workflow.
