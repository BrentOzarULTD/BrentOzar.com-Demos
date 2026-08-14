#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
web_dir="$(cd "${script_dir}/.." && pwd)"
artifact_dir="${web_dir}/artifacts"

mkdir -p "${artifact_dir}"
cd "${web_dir}/wordpress"
zip -qr "${artifact_dir}/texas-holdem-viewer.zip" texas-holdem-viewer -x '*.DS_Store'

echo "Created ${artifact_dir}/texas-holdem-viewer.zip"
