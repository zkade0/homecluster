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

sync_required_secret() {
  local target="$1"
  local key="$2"
  local name="$3"
  local value

  value="$(extract_secret "${key}")"
  if [[ -z "${value}" ]]; then
    echo "Required secret ${key} is empty in ${SOPS_SECRET_FILE}" >&2
    exit 1
  fi

  create_or_replace_secret "${target}" "${name}" "${value}"
}

sync_optional_secret() {
  local target="$1"
  local key="$2"
  local name="$3"
  local value

  value="$(extract_secret_optional "${key}")"
  if [[ -z "${value}" ]]; then
    echo "Secret ${key} not found in ${SOPS_SECRET_FILE}, skipping ${name}."
    return 0
  fi

  create_or_replace_secret "${target}" "${name}" "${value}"
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

  sync_required_secret "${target}" "ACME_EMAIL" "homelab_acme_email"
  sync_required_secret "${target}" "CLOUDFLARE_API_TOKEN" "homelab_cloudflare_api_token"
  sync_required_secret "${target}" "VAULTWARDEN_ADMIN_TOKEN" "homelab_vaultwarden_admin_token"
  sync_required_secret "${target}" "GRAFANA_ADMIN_PASSWORD" "homelab_grafana_admin_password"
  sync_required_secret "${target}" "PIHOLE_WEB_PASSWORD" "homelab_pihole_web_password"
  sync_required_secret "${target}" "AUTHENTIK_SECRET_KEY" "homelab_authentik_secret_key"
  sync_required_secret "${target}" "AUTHENTIK_BOOTSTRAP_PASSWORD" "homelab_authentik_bootstrap_password"
  sync_required_secret "${target}" "AUTHENTIK_BOOTSTRAP_TOKEN" "homelab_authentik_bootstrap_token"
  sync_required_secret "${target}" "AUTHENTIK_POSTGRES_PASSWORD" "homelab_authentik_postgres_password"
  sync_required_secret "${target}" "ROMM_DB_PASSWORD" "homelab_romm_db_password"

  sync_optional_secret "${target}" "RESTIC_PASSWORD" "homelab_restic_password"
  sync_optional_secret "${target}" "TECHNITIUM_ADMIN_PASSWORD" "homelab_technitium_admin_password"
  sync_optional_secret "${target}" "TECHNITIUM_API_TOKEN" "homelab_technitium_api_token"
  sync_optional_secret "${target}" "PAPERLESS_SECRET_KEY" "homelab_paperless_secret_key"
  sync_optional_secret "${target}" "SPEEDTEST_TRACKER_APP_KEY" "homelab_speedtest_tracker_app_key"
  sync_optional_secret "${target}" "DISPATCH_AUTH_SECRET" "homelab_dispatch_auth_secret"
  sync_optional_secret "${target}" "N8N_BASIC_AUTH_USER" "homelab_n8n_basic_auth_user"
  sync_optional_secret "${target}" "N8N_BASIC_AUTH_PASSWORD" "homelab_n8n_basic_auth_password"
  sync_optional_secret "${target}" "N8N_ENCRYPTION_KEY" "homelab_n8n_encryption_key"
  sync_optional_secret "${target}" "DASH_BASIC_AUTH" "homelab_dash_basic_auth"
  sync_optional_secret "${target}" "NEXTCLOUD_DB_PASSWORD" "homelab_nextcloud_db_password"
  sync_optional_secret "${target}" "NEXTCLOUD_ADMIN_PASSWORD" "homelab_nextcloud_admin_password"
  sync_optional_secret "${target}" "ROMM_DB_ROOT_PASSWORD" "homelab_romm_db_root_password"
  sync_optional_secret "${target}" "ROMM_AUTH_SECRET_KEY" "homelab_romm_auth_secret_key"
  sync_optional_secret "${target}" "SCREENSCRAPER_USER" "homelab_romm_screenscraper_user"
  sync_optional_secret "${target}" "SCREENSCRAPER_PASSWORD" "homelab_romm_screenscraper_password"
  sync_optional_secret "${target}" "RETROACHIEVEMENTS_API_KEY" "homelab_romm_retroachievements_api_key"
  sync_optional_secret "${target}" "STEAMGRIDDB_API_KEY" "homelab_romm_steamgriddb_api_key"

  echo "Secret sync complete."
}

main "$@"
