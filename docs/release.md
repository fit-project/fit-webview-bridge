# Release and distribution

FIT WebView Bridge release wheels are distributed through the FIT Project
static Python package index:

<https://fit-project.github.io/fit-python-index/simple/>

PyPI is not a publication target for this project. It remains an upstream
source for runtime dependencies such as PySide6 and Shiboken6.

## Distribution architecture

Normal development changes use the platform CI workflows:

```text
pull request / normal development
        ↓
ci-macos.yml + ci-linux.yml
```

A manual release rehearsal builds and validates the complete payload without
publishing it:

```text
workflow_dispatch
        ↓
release.yml
        ↓
six validated wheels
        ↓
fit-python-index-dry-run artifact
        ↓
STOP
```

A production release starts only from a pushed `v*` tag:

```text
tag vX.Y.Z
        ↓
release.yml
        ↓
six validated wheels
        ↓
fit-project/fit-python-index
        ↓
existing GitHub Pages site
        ↓
Poetry / pip
```

The workflow never creates or pushes a release tag. The maintainer must first
set the intended version in `pyproject.toml`, merge that source state, and tag
the exact release commit. The normalized tag version must match the normalized
project version. For example, source version `1.0.0-rc4` and tag `v1.0.0rc4`
are equivalent under PEP 440. A mismatch fails before wheel builds begin, and
the workflow never rewrites `pyproject.toml`.

## Supported release-wheel matrix

| Platform | Architecture | Python | Runtime baseline |
| --- | --- | --- | --- |
| macOS | ARM64 | CPython 3.11, 3.12, 3.13 | Apple Silicon / WKWebView |
| Linux | x86_64 | CPython 3.11, 3.12, 3.13 | Ubuntu 24.04, X11/xcb, WebKitGTK 4.1 and GTK 3 |

The release must contain exactly these six wheels:

```text
fit_webview_bridge-<VERSION>-cp311-cp311-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp312-cp312-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp313-cp313-linux_x86_64.whl
fit_webview_bridge-<VERSION>-cp311-cp311-macosx_*_arm64.whl
fit_webview_bridge-<VERSION>-cp312-cp312-macosx_*_arm64.whl
fit_webview_bridge-<VERSION>-cp313-cp313-macosx_*_arm64.whl
```

The macOS job uses an Apple Silicon `macos-14` runner, installs the Qt 6.9.0
SDK, and uses cibuildwheel to build CPython 3.11 through 3.13 ARM64 wheels. The
Linux job uses Ubuntu 24.04 x86_64, installs Qt and the X11/WebKitGTK build and
runtime dependencies, and builds each supported CPython wheel through the
validated Linux release script.

The Linux wheels intentionally retain the native `linux_x86_64` platform tag.
They are not repaired into manylinux wheels and do not bundle WebKitGTK, GTK,
or other operating-system libraries. Windows, Intel macOS, ARM64 Linux, source
distributions, and native Wayland wheels are not part of this release path.

## Validation and rehearsal artifact

Each platform job validates wheel count, Python and platform tags, metadata,
runtime requirements, native extension contents, linkage, build-path leakage,
and clean consumer installation. The aggregate job then requires one Linux and
one macOS wheel for each of CPython 3.11, 3.12, and 3.13, all for the project
version.

The aggregate job generates this replacement-only rehearsal tree in temporary
storage:

```text
simple/
├── index.html
└── fit-webview-bridge/
    ├── index.html
    └── <six wheel files>
```

Every package-page link contains a SHA-256 fragment calculated from the wheel.
The workflow validates the tree and performs a CPython 3.11 Linux installation
through a local HTTP server. Only `workflow_dispatch` uploads the tree as the
`fit-python-index-dry-run` artifact. Manual dispatch can never run the
publication job.

## Production index publication

After all build and aggregate validation succeeds for a tag push, the
`publish-index` job:

1. revalidates the tag and the downloaded six-wheel payload;
2. checks out the default branch of `fit-project/fit-python-index` using the
   `FIT_PYTHON_INDEX_TOKEN` repository secret;
3. preserves every historical wheel and adds only missing new wheel files;
4. regenerates `simple/fit-webview-bridge/index.html` from every wheel present;
5. preserves existing root-index package entries and adds
   `fit-webview-bridge/` only when missing;
6. validates links, hashes, deterministic ordering, the new six-wheel matrix,
   and historical-file preservation;
7. installs the new CPython 3.11 Linux wheel through a local HTTP server backed
   by the cumulative checkout; and
8. commits and pushes the index update to its checked-out default branch.

Published filenames are immutable. A missing filename is added, an existing
filename with the same SHA-256 is accepted as an idempotent rerun, and an
existing filename with different bytes fails publication. The package page is
regenerated from all wheel files, so older partial test releases may remain
without being subjected to the new release's six-wheel completeness rule.

Publication jobs share a non-cancelling concurrency group. This serializes
cross-repository updates so two releases cannot race. If a rerun finds all six
wheels and both index pages already current, it succeeds without creating a
meaningless commit. Otherwise, the workflow commits as `FIT Release Bot` with:

```text
release: add fit-webview-bridge <NORMALIZED_VERSION>
```

The publisher only updates repository contents. The index repository's
existing GitHub Pages configuration continues to serve the Simple API; this
workflow does not introduce a second Pages deployment mechanism.

## Performing a release

From an up-to-date local `main` checkout, update and commit the project version,
then run the normal review and CI process. Once that version commit is on
`origin/main`, create and push the matching tag:

```bash
git switch main
git pull --ff-only origin main
git status --short
git tag -a vX.Y.Z -m "Release X.Y.Z"
git push origin vX.Y.Z
```

Replace `X.Y.Z` with the PEP 440-compatible release version represented by
`pyproject.toml`. For a source prerelease such as `1.0.0-rc4`, the normalized
tag may be `v1.0.0rc4`. Verify that `git status --short` is empty and that
`HEAD` is the intended release commit before tagging.

The tag starts all six wheel builds. Publication runs only after every platform
and aggregate check passes, updates the cumulative index without replacing
history, and lets the index repository's existing GitHub Pages configuration
publish the new files. Consumers continue to use:

```text
https://fit-project.github.io/fit-python-index/simple/
```
