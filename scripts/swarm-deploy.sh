#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
FLAKE_REF="path:${FLAKE_DIR}"

STACK_FILE="${STACK_FILE:-${REPO_ROOT}/swarm/stacks/homelab.yaml}"
STACK_NAME="${STACK_NAME:-homelab}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/swarm/env/cluster.env}"
ENV_LOCAL_FILE="${ENV_LOCAL_FILE:-${ENV_FILE}.local}"
DOMAIN_FILE="${DOMAIN_FILE:-${REPO_ROOT}/swarm/env/domain.txt}"
MANAGER_HOST="${MANAGER_HOST:-k8s-0}"
MANAGER_SSH="${MANAGER_SSH:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
SYNC_SECRETS="${SYNC_SECRETS:-1}"
TLS_PREFLIGHT="${TLS_PREFLIGHT:-1}"

usage() {
  cat <<USAGE
Usage:
  $0

Env:
  STACK_FILE=./swarm/stacks/homelab.yaml
  STACK_NAME=homelab
  ENV_FILE=./swarm/env/cluster.env
  DOMAIN_FILE=./swarm/env/domain.txt
  MANAGER_HOST=k8s-0
  MANAGER_SSH=root@192.168.8.5     # overrides MANAGER_HOST lookup
  SSH_KEY_FILE=/path/to/private_key
  SYNC_SECRETS=1
  TLS_PREFLIGHT=1
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

read_domain_file() {
  local domain_file="$1"
  awk 'NF && $1 !~ /^#/ {print $1; exit}' "${domain_file}" | tr -d '\r'
}

load_domain() {
  local domain_from_file=""

  if [[ -f "${DOMAIN_FILE}" ]]; then
    domain_from_file="$(read_domain_file "${DOMAIN_FILE}")"
    if [[ -z "${domain_from_file}" ]]; then
      echo "DOMAIN_FILE is empty: ${DOMAIN_FILE}" >&2
      exit 1
    fi
    export BASE_DOMAIN="${domain_from_file}"
  fi

  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    echo "BASE_DOMAIN is not set. Set DOMAIN_FILE (${DOMAIN_FILE}) or BASE_DOMAIN in env." >&2
    exit 1
  fi
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

check_traefik_tls_readiness() {
  local target="$1"

  if [[ "${TLS_PREFLIGHT}" != "1" ]]; then
    return 0
  fi

  if [[ "${STACK_NAME}" == "traefik" ]]; then
    return 0
  fi

  if ! ssh_cmd "${target}" "docker service inspect traefik_traefik >/dev/null 2>&1"; then
    echo "WARNING: traefik_traefik not found; skipping TLS preflight." >&2
    return 0
  fi

  local args_json
  args_json="$(ssh_cmd "${target}" "docker service inspect traefik_traefik --format '{{json .Spec.TaskTemplate.ContainerSpec.Args}}'")"

  if [[ "${args_json}" != *"--certificatesresolvers.le.acme.storage="* ]] || \
     [[ "${args_json}" != *"--entrypoints.websecure.http.tls.certresolver=le"* ]]; then
    echo "ERROR: Traefik TLS preflight failed." >&2
    echo "traefik_traefik is missing ACME/certresolver flags, so browsers may show certificate warnings." >&2
    echo "Deploy/fix swarm/stacks/traefik.yaml first, or set TLS_PREFLIGHT=0 to bypass intentionally." >&2
    exit 1
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd nix
  require_cmd ssh
  require_cmd envsubst

  if [[ ! -f "${STACK_FILE}" ]]; then
    echo "Stack file not found: ${STACK_FILE}" >&2
    exit 1
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Env file not found: ${ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${ENV_LOCAL_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_LOCAL_FILE}"
  fi
  set +a
  load_domain
  export STACK_NAME

  local target
  target="$(resolve_target)"
  echo "Deploying stack ${STACK_NAME} to ${target}"

  check_traefik_tls_readiness "${target}"

  if [[ "${SYNC_SECRETS}" == "1" ]]; then
    MANAGER_SSH="${target}" SSH_KEY_FILE="${SSH_KEY_FILE}" "${REPO_ROOT}/scripts/swarm-sync-secrets.sh"
  fi

  envsubst < "${STACK_FILE}" | ssh_cmd "${target}" \
    "docker stack deploy --prune --with-registry-auth -c - '${STACK_NAME}'"

  echo
  echo "Services:"
  ssh_cmd "${target}" "docker service ls"
}

main "$@"
