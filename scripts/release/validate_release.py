#!/usr/bin/env python3
"""Validate release wheels and build the dry-run PEP 503 repository tree."""

from __future__ import annotations

import argparse
import hashlib
import html
import shutil
import tomllib
import zipfile
from dataclasses import dataclass
from email.parser import Parser
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


PACKAGE_NAME = "fit-webview-bridge"
WHEEL_DISTRIBUTION = "fit_webview_bridge"
PYTHON_TAGS = ("cp311", "cp312", "cp313")
RUNTIME_REQUIREMENTS = {
    "pyside6": "==6.9.0",
    "shiboken6": "==6.9.0",
}


@dataclass(frozen=True)
class WheelInfo:
    path: Path
    version: Version
    python_tag: str
    platform: str


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        href = dict(attrs).get("href")
        if href is not None:
            self.hrefs.append(href)


def fail(message: str) -> None:
    raise SystemExit(message)


def project_version(project_file: Path) -> Version:
    with project_file.open("rb") as handle:
        data = tomllib.load(handle)
    try:
        raw_version = data["project"]["version"]
    except KeyError as error:
        fail(f"Missing project.version in {project_file}: {error}")
    version = Version(raw_version)
    print(f"Resolved project version: {raw_version} (normalized: {version})")
    return version


def classify_platform(platform_tag: str) -> str:
    if platform_tag == "linux_x86_64":
        return "linux"
    if platform_tag.startswith("macosx_") and platform_tag.endswith("_arm64"):
        return "macos"
    fail(f"Unexpected wheel platform: {platform_tag}")


def parse_wheel_filename(path: Path) -> WheelInfo:
    parts = path.name.removesuffix(".whl").split("-")
    if len(parts) != 5 or path.suffix != ".whl":
        fail(f"Unexpected wheel filename shape: {path.name}")

    distribution, raw_version, python_tag, abi_tag, platform_tag = parts
    if distribution != WHEEL_DISTRIBUTION:
        fail(f"Unexpected wheel distribution in {path.name}: {distribution}")
    if python_tag not in PYTHON_TAGS or abi_tag != python_tag:
        fail(f"Unexpected Python/ABI tags in {path.name}: {python_tag}-{abi_tag}")
    classify_platform(platform_tag)
    return WheelInfo(path, Version(raw_version), python_tag, platform_tag)


def validate_metadata(info: WheelInfo, archive: zipfile.ZipFile) -> None:
    names = archive.namelist()
    if len(names) != len(set(names)):
        fail(f"Duplicate archive members in {info.path.name}")

    metadata_files = [name for name in names if name.endswith(".dist-info/METADATA")]
    if len(metadata_files) != 1:
        fail(f"Expected one METADATA file in {info.path.name}: {metadata_files}")

    metadata = Parser().parsestr(archive.read(metadata_files[0]).decode("utf-8"))
    if canonicalize_name(metadata["Name"]) != PACKAGE_NAME:
        fail(f"Unexpected project name in {info.path.name}: {metadata['Name']}")
    if Version(metadata["Version"]) != info.version:
        fail(
            f"Filename/METADATA version mismatch in {info.path.name}: "
            f"{info.version} != {metadata['Version']}"
        )

    requirements: dict[str, Requirement] = {}
    for raw_requirement in metadata.get_all("Requires-Dist", []):
        requirement = Requirement(raw_requirement)
        name = canonicalize_name(requirement.name)
        if name in requirements:
            fail(f"Duplicate runtime requirement {name} in {info.path.name}")
        requirements[name] = requirement

    if set(requirements) != set(RUNTIME_REQUIREMENTS):
        fail(
            f"Unexpected runtime requirements in {info.path.name}: "
            f"{sorted(requirements)}"
        )
    for name, specifier in RUNTIME_REQUIREMENTS.items():
        requirement = requirements[name]
        if (
            str(requirement.specifier) != specifier
            or requirement.extras
            or requirement.marker is not None
            or requirement.url is not None
        ):
            fail(f"Unexpected runtime requirement in {info.path.name}: {requirement}")


def validate_contents(
    info: WheelInfo, archive: zipfile.ZipFile, forbidden_paths: list[str]
) -> None:
    names = archive.namelist()
    if names.count("fit_webview_bridge/__init__.py") != 1:
        fail(f"Expected one package __init__.py in {info.path.name}")

    native_modules = [
        name
        for name in names
        if name.startswith("fit_webview_bridge/systemwebview") and name.endswith(".so")
    ]
    if len(native_modules) != 1:
        fail(f"Expected one native extension in {info.path.name}: {native_modules}")
    if len([name for name in names if name.endswith(".so")]) != 1:
        fail(f"Unexpected additional native extension in {info.path.name}")

    python_digits = info.python_tag.removeprefix("cp")
    if classify_platform(info.platform) == "linux":
        expected_suffix = f"cpython-{python_digits}-x86_64-linux-gnu.so"
    else:
        expected_suffix = f"cpython-{python_digits}-darwin.so"
    if not native_modules[0].endswith(expected_suffix):
        fail(
            f"Unexpected native extension suffix in {info.path.name}: "
            f"{native_modules[0]}"
        )

    forbidden_members = (
        "/build/",
        ".libs/",
        "libwebkit",
        "libgtk",
        "libjavascriptcore",
    )
    for name in names:
        if any(token in name.lower() for token in forbidden_members):
            fail(f"Forbidden bundled content in {info.path.name}: {name}")

    payloads = [archive.read(name) for name in names if not name.endswith("/")]
    for forbidden_path in ["/home/", *forbidden_paths]:
        normalized = forbidden_path.strip().rstrip("/")
        if normalized and any(normalized.encode() in payload for payload in payloads):
            fail(f"Build/source path leaked into {info.path.name}: {normalized}")


def validate_wheel_set(
    wheel_dir: Path,
    expected_platform: str,
    expected_version: Version,
    forbidden_paths: list[str],
    allow_index: bool = False,
) -> list[WheelInfo]:
    if not wheel_dir.is_dir():
        fail(f"Wheel directory does not exist: {wheel_dir}")

    all_files = sorted(path for path in wheel_dir.rglob("*") if path.is_file())
    non_wheels = [path for path in all_files if path.suffix != ".whl"]
    allowed_non_wheels = {wheel_dir / "index.html"} if allow_index else set()
    if set(non_wheels) != allowed_non_wheels:
        fail(f"Unexpected non-wheel files in {wheel_dir}: {non_wheels}")

    wheel_files = [path for path in all_files if path.suffix == ".whl"]

    expected_count = 6 if expected_platform == "all" else 3
    if len(wheel_files) != expected_count:
        fail(
            f"Expected {expected_count} wheels in {wheel_dir}, found {len(wheel_files)}"
        )
    if len({path.name for path in wheel_files}) != len(wheel_files):
        fail(f"Duplicate wheel filenames in {wheel_dir}")

    wheels = [parse_wheel_filename(path) for path in wheel_files]
    for info in wheels:
        if info.version != expected_version:
            fail(
                f"Wheel version does not match pyproject.toml in {info.path.name}: "
                f"{info.version} != {expected_version}"
            )
        with zipfile.ZipFile(info.path) as archive:
            validate_metadata(info, archive)
            validate_contents(info, archive, forbidden_paths)

    by_platform: dict[str, list[WheelInfo]] = {"linux": [], "macos": []}
    for info in wheels:
        by_platform[classify_platform(info.platform)].append(info)

    expected_platforms = (
        ("linux", "macos") if expected_platform == "all" else (expected_platform,)
    )
    unexpected_platforms = set(by_platform) - set(expected_platforms)
    if any(by_platform[name] for name in unexpected_platforms):
        fail(f"Unexpected platforms in wheel set: {sorted(unexpected_platforms)}")

    for platform in expected_platforms:
        platform_wheels = by_platform[platform]
        tags = [info.python_tag for info in platform_wheels]
        if len(platform_wheels) != 3 or sorted(tags) != sorted(PYTHON_TAGS):
            fail(f"Expected cp311/cp312/cp313 exactly once for {platform}: {tags}")

    versions = {info.version for info in wheels}
    if versions != {expected_version}:
        fail(f"Wheel versions are not identical: {sorted(map(str, versions))}")

    print(f"Validated {len(wheels)} {expected_platform} wheel(s):")
    for info in sorted(wheels, key=lambda item: item.path.name):
        print(f"  {info.path.name}")
    return wheels


def render_index(links: list[tuple[str, str]]) -> str:
    lines = ["<!DOCTYPE html>", "<html>", "  <body>"]
    for href, label in links:
        lines.append(
            f'    <a href="{html.escape(href, quote=True)}">{html.escape(label)}</a>'
        )
    lines.extend(["  </body>", "</html>", ""])
    return "\n".join(lines)


def generate_index(wheel_dir: Path, site_dir: Path, project_file: Path) -> None:
    version = project_version(project_file)
    wheels = validate_wheel_set(wheel_dir, "all", version, [])
    if site_dir.exists():
        fail(f"Refusing to overwrite existing site directory: {site_dir}")

    simple_dir = site_dir / "simple"
    package_dir = simple_dir / PACKAGE_NAME
    package_dir.mkdir(parents=True)

    links: list[tuple[str, str]] = []
    for info in sorted(wheels, key=lambda item: item.path.name):
        destination = package_dir / info.path.name
        shutil.copy2(info.path, destination)
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        links.append((f"{destination.name}#sha256={digest}", destination.name))

    (simple_dir / "index.html").write_text(
        render_index([(f"{PACKAGE_NAME}/", PACKAGE_NAME)]), encoding="utf-8"
    )
    (package_dir / "index.html").write_text(render_index(links), encoding="utf-8")
    print(f"Generated dry-run Simple Index under {site_dir}")


def parse_links(index_file: Path) -> list[str]:
    parser = LinkParser()
    parser.feed(index_file.read_text(encoding="utf-8"))
    return parser.hrefs


def validate_index(site_dir: Path, project_file: Path) -> None:
    simple_dir = site_dir / "simple"
    package_dir = simple_dir / PACKAGE_NAME
    root_index = simple_dir / "index.html"
    package_index = package_dir / "index.html"

    if parse_links(root_index) != [f"{PACKAGE_NAME}/"]:
        fail(f"Root Simple Index must link only to {PACKAGE_NAME}/")

    hrefs = parse_links(package_index)
    if len(hrefs) != 6 or len(set(hrefs)) != 6:
        fail(f"Expected six unique package links, found {len(hrefs)}")
    if hrefs != sorted(hrefs):
        fail("Package index links are not sorted deterministically")

    linked_wheels: set[Path] = set()
    for href in hrefs:
        parsed = urlsplit(href)
        filename = unquote(parsed.path)
        if parsed.scheme or parsed.netloc or parsed.query:
            fail(f"Wheel href must be a local relative URL: {href}")
        if Path(filename).name != filename or not filename.endswith(".whl"):
            fail(f"Unexpected wheel href path: {href}")
        wheel = package_dir / filename
        if not wheel.is_file():
            fail(f"Wheel href does not resolve to a local file: {href}")

        expected_fragment = f"sha256={hashlib.sha256(wheel.read_bytes()).hexdigest()}"
        if parsed.fragment != expected_fragment:
            fail(f"SHA-256 mismatch for {filename}")
        linked_wheels.add(wheel)

    version = project_version(project_file)
    validate_wheel_set(package_dir, "all", version, [], allow_index=True)

    expected_files = {root_index, package_index, *linked_wheels}
    actual_files = {path for path in site_dir.rglob("*") if path.is_file()}
    if actual_files != expected_files:
        fail(
            "Generated site contains missing or unrelated files: "
            f"expected={sorted(map(str, expected_files))}, "
            f"actual={sorted(map(str, actual_files))}"
        )
    if any(path.name.endswith((".tar.gz", ".zip")) for path in actual_files):
        fail("Source distribution found in generated site")
    print(
        "Validated generated Simple Index: six local wheels and six matching SHA-256 fragments"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    wheels = subparsers.add_parser("wheels", help="validate a release wheel set")
    wheels.add_argument("--wheel-dir", type=Path, required=True)
    wheels.add_argument("--project-file", type=Path, required=True)
    wheels.add_argument("--platform", choices=("linux", "macos", "all"), required=True)
    wheels.add_argument("--forbid-path", action="append", default=[])

    generate = subparsers.add_parser(
        "generate-index", help="generate the dry-run Simple Index"
    )
    generate.add_argument("--wheel-dir", type=Path, required=True)
    generate.add_argument("--site-dir", type=Path, required=True)
    generate.add_argument("--project-file", type=Path, required=True)

    index = subparsers.add_parser(
        "validate-index", help="validate the generated Simple Index"
    )
    index.add_argument("--site-dir", type=Path, required=True)
    index.add_argument("--project-file", type=Path, required=True)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.command == "wheels":
        version = project_version(args.project_file)
        validate_wheel_set(args.wheel_dir, args.platform, version, args.forbid_path)
    elif args.command == "generate-index":
        generate_index(args.wheel_dir, args.site_dir, args.project_file)
    elif args.command == "validate-index":
        validate_index(args.site_dir, args.project_file)
    else:
        fail(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
