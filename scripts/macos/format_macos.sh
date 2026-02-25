#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

FORMAT_FIX=1 SKIP_TIDY=1 ENABLE_CODEQL=0 ./scripts/macos/check_quality.sh
