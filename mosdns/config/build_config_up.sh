#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${ROOT_DIR}/config_up"
OUTPUT_ZIP="${ROOT_DIR}/config_up.zip"
MANIFEST="${SOURCE_DIR}/manifest.json"

SCHEMA=2
PACKAGE_ID="main-config-schema-2"

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

managed_json="$(printf '%s\n' "${managed_files[@]}" | jq -R . | jq -s .)"
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
    delete_files: [],
    sha256: $sha256
  }' >"${MANIFEST}"

tmp_zip="$(mktemp "${ROOT_DIR}/.config_up.XXXXXX.zip")"
trap 'rm -f "${tmp_zip}"' EXIT
rm -f "${tmp_zip}"
(
  cd "${SOURCE_DIR}"
  zip -X -q "${tmp_zip}" "manifest.json" "${managed_files[@]}"
)
mv "${tmp_zip}" "${OUTPUT_ZIP}"
trap - EXIT

echo "built ${OUTPUT_ZIP} (schema=${SCHEMA}, package_id=${PACKAGE_ID})"
