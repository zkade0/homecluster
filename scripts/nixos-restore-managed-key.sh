#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_SECRET_FILE="${SOPS_SECRET_FILE:-${REPO_ROOT}/secrets/ssh/nixos-bootstrap.sops.yaml}"
OUT_KEY_FILE="${OUT_KEY_FILE:-${HOME}/.ssh/homelab-nixos-admin}"
OUT_PUB_FILE="${OUT_PUB_FILE:-${REPO_ROOT}/nixos/keys/homelab-admin.pub}"

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

main() {
  require_cmd sops

  if [[ ! -f "${SOPS_SECRET_FILE}" ]]; then
    echo "SOPS secret file not found: ${SOPS_SECRET_FILE}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${OUT_KEY_FILE}")"
  mkdir -p "$(dirname "${OUT_PUB_FILE}")"

  sops -d --extract '["stringData"]["managed_private_key"]' "${SOPS_SECRET_FILE}" > "${OUT_KEY_FILE}"
  sops -d --extract '["stringData"]["managed_public_key"]' "${SOPS_SECRET_FILE}" > "${OUT_PUB_FILE}"

  chmod 600 "${OUT_KEY_FILE}"
  chmod 644 "${OUT_PUB_FILE}"

  echo "Restored managed private key: ${OUT_KEY_FILE}"
  echo "Restored managed public key:  ${OUT_PUB_FILE}"
}

main "$@"
