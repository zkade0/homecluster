#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
FLAKE_REF="path:${FLAKE_DIR}"

SOPS_SECRET_FILE="${SOPS_SECRET_FILE:-${REPO_ROOT}/swarm/secrets/cluster-secrets.sops.yaml}"
MANAGER_HOST="${MANAGER_HOST:-k8s-0}"
MANAGER_SSH="${MANAGER_SSH:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
FORCE_REPLACE="${FORCE_REPLACE:-0}"

usage() {
  cat <<USAGE
Usage:
  $0

Env:
  SOPS_SECRET_FILE=./swarm/secrets/cluster-secrets.sops.yaml
  MANAGER_HOST=k8s-0
  MANAGER_SSH=root@192.168.8.5     # overrides MANAGER_HOST lookup
  SSH_KEY_FILE=/path/to/private_key
  FORCE_REPLACE=1                  # remove+recreate existing secrets
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

ssh_cmd() {
  local target="$1"
  shift

  local -a args=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
  )

  if [[ -n "${SSH_KEY_FILE}" ]]; then
    args+=(
      -i "${SSH_KEY_FILE}"
      -o IdentitiesOnly=yes
      -o PreferredAuthentications=publickey
      -o PasswordAuthentication=no
    )
  fi

  ssh "${args[@]}" "${target}" "$@"
}

resolve_target() {
  if [[ -n "${MANAGER_SSH}" ]]; then
    echo "${MANAGER_SSH}"
    return
  fi

  local ip user
  ip="$(nix --extra-experimental-features "nix-command flakes" eval --raw "${FLAKE_REF}#homelab.hosts.${MANAGER_HOST}.ip")"
  user="$(nix --extra-experimental-features "nix-command flakes" eval --raw "${FLAKE_REF}#homelab.hosts.${MANAGER_HOST}.user")"
  echo "${user}@${ip}"
}

extract_secret() {
  local key="$1"
  sops -d --extract "[\"stringData\"][\"${key}\"]" "${SOPS_SECRET_FILE}"
}

extract_secret_optional() {
  local key="$1"
  sops -d --extract "[\"stringData\"][\"${key}\"]" "${SOPS_SECRET_FILE}" 2>/dev/null || true
}

create_or_replace_secret() {
  local target="$1"
  local name="$2"
  local value="$3"

  if ssh_cmd "${target}" "docker secret inspect '${name}' >/dev/null 2>&1"; then
    if [[ "${FORCE_REPLACE}" != "1" ]]; then
      echo "Secret ${name} already exists, skipping (FORCE_REPLACE=0)."
      return
    fi

    echo "Replacing secret ${name}"
    ssh_cmd "${target}" "docker secret rm '${name}' >/dev/null"
  else
    echo "Creating secret ${name}"
  fi

  printf "%s" "${value}" | ssh_cmd "${target}" "docker secret create '${name}' - >/dev/null"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd nix
  require_cmd sops
  require_cmd ssh

  if [[ ! -f "${SOPS_SECRET_FILE}" ]]; then
    echo "SOPS secret file not found: ${SOPS_SECRET_FILE}" >&2
    exit 1
  fi

  local target
  target="$(resolve_target)"
  echo "Syncing Docker Swarm secrets to ${target}"

  create_or_replace_secret "${target}" "homelab_acme_email" "$(extract_secret "ACME_EMAIL")"
  create_or_replace_secret "${target}" "homelab_cloudflare_api_token" "$(extract_secret "CLOUDFLARE_API_TOKEN")"
  create_or_replace_secret "${target}" "homelab_vaultwarden_admin_token" "$(extract_secret "VAULTWARDEN_ADMIN_TOKEN")"
  create_or_replace_secret "${target}" "homelab_pihole_web_password" "$(extract_secret "PIHOLE_WEB_PASSWORD")"
  create_or_replace_secret "${target}" "homelab_authentik_secret_key" "$(extract_secret "AUTHENTIK_SECRET_KEY")"
  create_or_replace_secret "${target}" "homelab_authentik_bootstrap_password" "$(extract_secret "AUTHENTIK_BOOTSTRAP_PASSWORD")"
  create_or_replace_secret "${target}" "homelab_authentik_bootstrap_token" "$(extract_secret "AUTHENTIK_BOOTSTRAP_TOKEN")"
  create_or_replace_secret "${target}" "homelab_authentik_postgres_password" "$(extract_secret "AUTHENTIK_POSTGRES_PASSWORD")"
  create_or_replace_secret "${target}" "homelab_romm_db_password" "$(extract_secret "ROMM_DB_PASSWORD")"

  local restic_password
  restic_password="$(extract_secret_optional "RESTIC_PASSWORD")"

  if [[ -n "${restic_password}" ]]; then
    create_or_replace_secret "${target}" "homelab_restic_password" "${restic_password}"
  else
    echo "Secret RESTIC_PASSWORD not found in ${SOPS_SECRET_FILE}, skipping homelab_restic_password."
  fi

  echo "Secret sync complete."
}

main "$@"
