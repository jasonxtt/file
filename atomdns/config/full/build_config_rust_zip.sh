#!/usr/bin/env bash
# Builds config_rust.zip, the fresh-install package of atomdns: everything in config_rust/ plus the
# WebUI unpacked from a release's atomdns-webui.tar.gz into ui/main/ (served at /). The WebUI is
# not kept in config_rust/ itself; it comes from the atomdns release of the same version.
#   ./build_config_rust_zip.sh <atomdns-webui.tar.gz> [output.zip]
# The default output is config_rust.zip next to this script.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${ROOT_DIR}/config_rust"
WEBUI="${1:?usage: build_config_rust_zip.sh <atomdns-webui.tar.gz> [output.zip]}"
OUTPUT_ZIP="${2:-${ROOT_DIR}/config_rust.zip}"
OUTPUT_ZIP="$(cd "$(dirname "${OUTPUT_ZIP}")" && pwd)/$(basename "${OUTPUT_ZIP}")"

if [[ -e "${SOURCE_DIR}/ui/main" ]]; then
  echo "config_rust/ui/main must not exist (the WebUI comes from atomdns-webui.tar.gz)" >&2
  exit 1
fi
# List once: `tar | grep -q` under pipefail fails when grep exits early and tar gets SIGPIPE.
WEBUI_ENTRIES="$(tar -tzf "${WEBUI}")"
for required in index.html ui-manifest.json; do
  if ! grep -qx "${required}" <<<"${WEBUI_ENTRIES}"; then
    echo "${WEBUI} has no top-level ${required}" >&2
    exit 1
  fi
done

stage="$(mktemp -d)"
tmp_zip="$(mktemp "${ROOT_DIR}/.config_rust.XXXXXX.zip")"
trap 'rm -rf "${stage}" "${tmp_zip}"' EXIT
rm -f "${tmp_zip}"

# COPYFILE_DISABLE: no macOS AppleDouble (._*) files.
COPYFILE_DISABLE=1 tar -C "${SOURCE_DIR}" --exclude '.DS_Store' -cf - . | tar -C "${stage}" -xf -
mkdir -p "${stage}/ui/main"
tar -xzf "${WEBUI}" -C "${stage}/ui/main"
(
  cd "${stage}"
  zip -X -r -q "${tmp_zip}" . -x '.DS_Store' '*/.DS_Store'
)
mv "${tmp_zip}" "${OUTPUT_ZIP}"
trap 'rm -rf "${stage}"' EXIT

echo "built ${OUTPUT_ZIP} (WebUI $(tar -xzOf "${WEBUI}" ui-manifest.json | jq -r '.ui_version'))"
echo "sha256: $(shasum -a 256 "${OUTPUT_ZIP}" | awk '{print $1}')"
