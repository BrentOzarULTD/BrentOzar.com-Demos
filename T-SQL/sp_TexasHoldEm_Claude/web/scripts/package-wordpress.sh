#!/usr/bin/env bash
set -euo pipefail

if ! command -v zip >/dev/null 2>&1; then
    echo "Missing required command: zip" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
web_dir="$(cd "${script_dir}/.." && pwd)"
artifact_dir="${web_dir}/artifacts"

artifact="${artifact_dir}/texas-holdem-viewer.zip"

mkdir -p "${artifact_dir}"
cd "${web_dir}/wordpress"

# zip only adds and updates entries, so a rebuild after deleting or renaming a
# plugin file would keep shipping the old one. Start from nothing every time.
rm -f "${artifact}"
zip -qr "${artifact}" texas-holdem-viewer -x '*.DS_Store'

echo "Created ${artifact}"
