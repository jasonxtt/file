#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${ROOT_DIR}/config_up"
ALL_DIR="${ROOT_DIR}/config_all"
OUTPUT_ZIP="${ROOT_DIR}/config_up.zip"
ALL_ZIP="${ROOT_DIR}/config_all.zip"
MANIFEST="${SOURCE_DIR}/manifest.json"

SCHEMA=2
PACKAGE_ID="main-config-schema-2"

# Keep SCHEMA/PACKAGE_ID in sync with the mosdns binary:
# coremain/config_update.go requiredConfigSchema/requiredConfigPackageID.
# Binary-only releases should leave these values unchanged. Structural config
# releases must bump both values so existing installs re-apply config_up.zip.

# Files listed here are structure files maintained by the incremental updater.
# The script writes them into manifest.managed_files, recalculates sha256, copies
# them into config_all, and includes them in config_up.zip.
managed_files=(
  "config_custom.yaml"
  "sub_config/adguard.yaml"
  "sub_config/cache.yaml"
  "sub_config/domain_output.yaml"
  "sub_config/for_singbox.yaml"
  "sub_config/forward_1.yaml"
  "sub_config/forward_local.yaml"
  "sub_config/forward_nocn.yaml"
  "sub_config/forward_nocn_ecs.yaml"
  "sub_config/process_ot.yaml"
  "sub_config/process_v4.yaml"
  "sub_config/process_v6.yaml"
  "sub_config/requery.yaml"
  "sub_config/rule_set.yaml"
  "sub_config/switch.yaml"
  "sub_config/webinfo.yaml"
)

# Existing installs delete only files listed here. The binary intentionally
# accepts deletions for sub_config/*.yaml only. A deleted file must not also be
# listed in managed_files.
deleted_files=(
)

managed_json="$(printf '%s\n' "${managed_files[@]}" | jq -R . | jq -s .)"
if [[ ${#deleted_files[@]} -gt 0 ]]; then
  deleted_json="$(printf '%s\n' "${deleted_files[@]}" | jq -R . | jq -s .)"
else
  deleted_json='[]'
fi
hashes='{}'
for rel in "${managed_files[@]}"; do
  file="${SOURCE_DIR}/${rel}"
  if [[ ! -f "${file}" ]]; then
    echo "missing managed file: ${rel}" >&2
    exit 1
  fi
  digest="$(shasum -a 256 "${file}" | awk '{print $1}')"
  hashes="$(jq --arg path "${rel}" --arg digest "${digest}" '. + {($path): $digest}' <<<"${hashes}")"
done

jq -n \
  --arg channel "main" \
  --arg package_id "${PACKAGE_ID}" \
  --argjson format 1 \
  --argjson config_schema "${SCHEMA}" \
  --argjson managed_files "${managed_json}" \
  --argjson deleted_files "${deleted_json}" \
  --argjson sha256 "${hashes}" \
  '{
    format: $format,
    channel: $channel,
    package_id: $package_id,
    config_schema: $config_schema,
    managed_files: $managed_files,
    create_if_missing: {
      "rule/switch16.txt": "B"
    },
    delete_files: $deleted_files,
    sha256: $sha256
  }' >"${MANIFEST}"

# Keep the full fresh-install package aligned with the incremental package.
# Edit config_up first, run this script, then publish both generated zip files.
for rel in "${managed_files[@]}"; do
  mkdir -p "$(dirname "${ALL_DIR}/${rel}")"
  cp "${SOURCE_DIR}/${rel}" "${ALL_DIR}/${rel}"
done

if [[ ${#deleted_files[@]} -gt 0 ]]; then
  for rel in "${deleted_files[@]}"; do
    rm -f "${ALL_DIR}/${rel}"
  done
fi

tmp_zip="$(mktemp "${ROOT_DIR}/.config_up.XXXXXX.zip")"
tmp_all_zip="$(mktemp "${ROOT_DIR}/.config_all.XXXXXX.zip")"
trap 'rm -f "${tmp_zip}" "${tmp_all_zip}"' EXIT
rm -f "${tmp_zip}"
(
  cd "${SOURCE_DIR}"
  zip -X -q "${tmp_zip}" "manifest.json" "${managed_files[@]}"
)
mv "${tmp_zip}" "${OUTPUT_ZIP}"

# Rebuild config_all.zip from the whole config_all tree after syncing managed
# files. .DS_Store is excluded so macOS Finder metadata does not leak into
# release packages.
rm -f "${tmp_all_zip}"
(
  cd "${ALL_DIR}"
  find . -name .DS_Store -prune -o -type f -print \
    | sed 's#^\./##' \
    | LC_ALL=C sort \
    | zip -X -q "${tmp_all_zip}" -@
)
mv "${tmp_all_zip}" "${ALL_ZIP}"
trap - EXIT

echo "built ${OUTPUT_ZIP} (schema=${SCHEMA}, package_id=${PACKAGE_ID})"
echo "synced ${ALL_DIR} and built ${ALL_ZIP}"
