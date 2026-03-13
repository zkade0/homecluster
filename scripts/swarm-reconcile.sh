#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
FLAKE_REF="path:${FLAKE_DIR}"

STACKS_DIR="${STACKS_DIR:-${REPO_ROOT}/swarm/stacks}"
STACK_FILE="${STACK_FILE:-}"
STACKS="${STACKS:-}"
EXCLUDE_STACKS="${EXCLUDE_STACKS:-homelab}"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/swarm/env/cluster.env}"
ENV_LOCAL_FILE="${ENV_LOCAL_FILE:-${ENV_FILE}.local}"
SOPS_SECRET_FILE="${SOPS_SECRET_FILE:-${REPO_ROOT}/swarm/secrets/cluster-secrets.sops.yaml}"

MANAGER_HOST="${MANAGER_HOST:-k8s-0}"
MANAGER_SSH="${MANAGER_SSH:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

SYNC_SECRETS="${SYNC_SECRETS:-1}"
FORCE_REPLACE="${FORCE_REPLACE:-0}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
DRY_RUN="${DRY_RUN:-0}"

STATE_DIR="${STATE_DIR:-${REPO_ROOT}/dist/swarm-reconcile}"
RENDER_DIR=""
LAST_GOOD_DIR=""

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-swarm-reconcile}"

declare -a STACK_FILES=()
declare -a STACK_NAMES=()
declare -a DEPLOYED_STACKS=()
declare -a ROLLED_BACK_STACKS=()
declare -a FAILED_STACKS=()
declare -a SKIPPED_STACKS=()

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/swarm-reconcile.sh

Env:
  STACK_FILE=swarm/stacks/romm.yaml       # deploy exactly one file
  STACKS=romm,monitoring                  # deploy selected stacks by name/path
  STACKS_DIR=./swarm/stacks               # discovery root (default)
  EXCLUDE_STACKS=homelab                  # excluded from auto-discovery

  ENV_FILE=./swarm/env/cluster.env
  ENV_LOCAL_FILE=./swarm/env/cluster.env.local
  SOPS_SECRET_FILE=./swarm/secrets/cluster-secrets.sops.yaml

  MANAGER_HOST=k8s-0
  MANAGER_SSH=root@192.168.8.5            # overrides MANAGER_HOST lookup
  SSH_KEY_FILE=~/.ssh/homelab-nixos-admin

  SYNC_SECRETS=1                           # run swarm-sync-secrets.sh first
  FORCE_REPLACE=0                          # passed to swarm-sync-secrets.sh
  DEPLOY_TIMEOUT=180                       # per-stack health-check timeout (s)
  POLL_INTERVAL=5                          # health-check poll interval (s)
  DRY_RUN=0                                # print actions without deploying

  DISCORD_WEBHOOK_URL=...                  # optional notifications
  DISCORD_USERNAME=swarm-reconcile
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

err() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

normalize_path() {
  local path="$1"

  if [[ "${path}" == "~/"* ]]; then
    printf '%s\n' "${HOME}/${path#~/}"
    return 0
  fi

  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
    return 0
  fi

  printf '%s\n' "${REPO_ROOT}/${path}"
}

contains_csv_value() {
  local csv="$1"
  local needle="$2"
  local item

  IFS=',' read -r -a __items <<<"${csv}"
  for item in "${__items[@]}"; do
    item="$(trim "${item}")"
    [[ -z "${item}" ]] && continue
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

derive_stack_name() {
  local stack_file="$1"
  local filename
  filename="$(basename "${stack_file}")"

  case "${filename}" in
    stack.yaml|stack.yml|compose.yaml|compose.yml)
      basename "$(dirname "${stack_file}")"
      ;;
    *)
      echo "${filename%.*}"
      ;;
  esac
}

resolve_stack_token_to_file() {
  local token="$1"

  if [[ "${token}" == */* ]] || [[ "${token}" == *.yaml ]] || [[ "${token}" == *.yml ]]; then
    if [[ -f "${token}" ]]; then
      realpath "${token}"
      return 0
    fi
    if [[ -f "${REPO_ROOT}/${token}" ]]; then
      realpath "${REPO_ROOT}/${token}"
      return 0
    fi
    return 1
  fi

  local candidates=(
    "${STACKS_DIR}/${token}.yaml"
    "${STACKS_DIR}/${token}.yml"
    "${STACKS_DIR}/${token}/stack.yaml"
    "${STACKS_DIR}/${token}/stack.yml"
    "${STACKS_DIR}/${token}/compose.yaml"
    "${STACKS_DIR}/${token}/compose.yml"
  )

  local path
  for path in "${candidates[@]}"; do
    if [[ -f "${path}" ]]; then
      realpath "${path}"
      return 0
    fi
  done

  return 1
}

append_stack() {
  local stack_file="$1"
  local stack_name="$2"
  local idx

  for idx in "${!STACK_FILES[@]}"; do
    if [[ "${STACK_FILES[idx]}" == "${stack_file}" ]] || [[ "${STACK_NAMES[idx]}" == "${stack_name}" ]]; then
      warn "Skipping duplicate stack selection: ${stack_name} (${stack_file})"
      SKIPPED_STACKS+=("${stack_name}")
      return 0
    fi
  done

  STACK_FILES+=("${stack_file}")
  STACK_NAMES+=("${stack_name}")
}

discover_stacks() {
  local path token stack_name

  if [[ -n "${STACK_FILE}" ]]; then
    path="$(resolve_stack_token_to_file "${STACK_FILE}")" || {
      err "STACK_FILE not found: ${STACK_FILE}"
      return 1
    }
    stack_name="$(derive_stack_name "${path}")"
    append_stack "${path}" "${stack_name}"
    return 0
  fi

  if [[ -n "${STACKS}" ]]; then
    IFS=',' read -r -a __tokens <<<"${STACKS}"
    for token in "${__tokens[@]}"; do
      token="$(trim "${token}")"
      [[ -z "${token}" ]] && continue
      path="$(resolve_stack_token_to_file "${token}")" || {
        err "Stack token could not be resolved: ${token}"
        return 1
      }
      stack_name="$(derive_stack_name "${path}")"
      append_stack "${path}" "${stack_name}"
    done
    return 0
  fi

  while IFS= read -r path; do
    stack_name="$(derive_stack_name "${path}")"
    if contains_csv_value "${EXCLUDE_STACKS}" "${stack_name}"; then
      SKIPPED_STACKS+=("${stack_name}")
      continue
    fi
    append_stack "${path}" "${stack_name}"
  done < <(find "${STACKS_DIR}" -maxdepth 2 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

  if [[ "${#STACK_FILES[@]}" -eq 0 ]]; then
    err "No stack files discovered in ${STACKS_DIR}"
    return 1
  fi
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    err "Env file not found: ${ENV_FILE}"
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${ENV_LOCAL_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_LOCAL_FILE}"
  fi
  set +a
}

send_discord_notification() {
  local status="$1"
  local message="$2"

  if [[ -z "${DISCORD_WEBHOOK_URL}" ]]; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; cannot send Discord notification"
    return 0
  fi

  local color
  if [[ "${status}" == "success" ]]; then
    color=5763719
  else
    color=15548997
  fi

  local payload
  if command -v jq >/dev/null 2>&1; then
    payload="$(jq -cn \
      --arg username "${DISCORD_USERNAME}" \
      --arg title "Swarm reconcile: ${status}" \
      --arg description "${message}" \
      --argjson color "${color}" \
      '{username: $username, embeds: [{title: $title, description: $description, color: $color}] }')"
  else
    payload=$(cat <<EOF
{"username":"${DISCORD_USERNAME}","content":"Swarm reconcile (${status})\n${message}"}
EOF
)
  fi

  curl -sS -X POST "${DISCORD_WEBHOOK_URL}" \
    -H 'Content-Type: application/json' \
    -d "${payload}" >/dev/null || warn "Discord notification failed"
}

wait_for_stack_healthy() {
  local target="$1"
  local stack_name="$2"
  local timeout="$3"
  local poll_interval="$4"
  local start_ts now_ts elapsed lines svc replicas running desired healthy

  start_ts="$(date +%s)"
  while true; do
    lines="$(ssh_cmd "${target}" "docker stack services '${stack_name}' --format '{{.Name}} {{.Replicas}}'" 2>/dev/null || true)"
    healthy=1

    if [[ -z "${lines}" ]]; then
      healthy=0
    else
      while IFS=' ' read -r svc replicas; do
        [[ -z "${svc}" ]] && continue
        if [[ "${replicas}" != */* ]]; then
          healthy=0
          continue
        fi
        IFS='/' read -r running desired <<<"${replicas}"
        if [[ -z "${running}" || -z "${desired}" ]]; then
          healthy=0
          continue
        fi
        if [[ "${running}" != "${desired}" ]]; then
          healthy=0
        fi
      done <<<"${lines}"
    fi

    if [[ "${healthy}" -eq 1 ]]; then
      return 0
    fi

    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))
    if (( elapsed >= timeout )); then
      err "Stack ${stack_name} did not reach healthy state within ${timeout}s"
      if [[ -n "${lines}" ]]; then
        err "Last replica status:"
        while IFS= read -r line; do
          err "  ${line}"
        done <<<"${lines}"
      fi
      ssh_cmd "${target}" "docker service ps ${stack_name}_* --no-trunc --filter desired-state=running" >/dev/null 2>&1 || true
      return 1
    fi

    sleep "${poll_interval}"
  done
}

render_stack() {
  local stack_file="$1"
  local stack_name="$2"
  local output_file="$3"

  export STACK_NAME="${stack_name}"
  envsubst < "${stack_file}" > "${output_file}"
}

deploy_rendered_stack() {
  local target="$1"
  local stack_name="$2"
  local rendered_file="$3"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] deploy ${stack_name} from ${rendered_file}"
    return 0
  fi

  ssh_cmd "${target}" "docker stack deploy --prune --with-registry-auth -c - '${stack_name}'" < "${rendered_file}"
}

rollback_stack() {
  local target="$1"
  local stack_name="$2"
  local rollback_file="$3"

  if [[ ! -f "${rollback_file}" ]]; then
    warn "No rollback file found for ${stack_name}: ${rollback_file}"
    return 1
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] rollback ${stack_name} from ${rollback_file}"
    return 0
  fi

  warn "Rolling back ${stack_name} using ${rollback_file}"
  if ! ssh_cmd "${target}" "docker stack deploy --prune --with-registry-auth -c - '${stack_name}'" < "${rollback_file}"; then
    err "Rollback deploy command failed for ${stack_name}"
    return 1
  fi

  if ! wait_for_stack_healthy "${target}" "${stack_name}" "${DEPLOY_TIMEOUT}" "${POLL_INTERVAL}"; then
    err "Rollback did not converge for ${stack_name}"
    return 1
  fi

  return 0
}

deploy_one_stack() {
  local target="$1"
  local stack_name="$2"
  local stack_file="$3"
  local rendered_file="${RENDER_DIR}/${stack_name}.yaml"
  local rollback_file="${LAST_GOOD_DIR}/${stack_name}.yaml"

  log "Rendering ${stack_name} from ${stack_file}"
  render_stack "${stack_file}" "${stack_name}" "${rendered_file}"

  log "Deploying ${stack_name} to ${target}"
  if ! deploy_rendered_stack "${target}" "${stack_name}" "${rendered_file}"; then
    err "Deploy command failed for ${stack_name}"
    if rollback_stack "${target}" "${stack_name}" "${rollback_file}"; then
      ROLLED_BACK_STACKS+=("${stack_name}")
    fi
    FAILED_STACKS+=("${stack_name}")
    return 1
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    DEPLOYED_STACKS+=("${stack_name}")
    return 0
  fi

  if ! wait_for_stack_healthy "${target}" "${stack_name}" "${DEPLOY_TIMEOUT}" "${POLL_INTERVAL}"; then
    err "Health check failed for ${stack_name}"
    if rollback_stack "${target}" "${stack_name}" "${rollback_file}"; then
      ROLLED_BACK_STACKS+=("${stack_name}")
    fi
    FAILED_STACKS+=("${stack_name}")
    return 1
  fi

  if [[ "${DRY_RUN}" != "1" ]]; then
    cp "${rendered_file}" "${rollback_file}"
  fi

  DEPLOYED_STACKS+=("${stack_name}")
  return 0
}

sync_secrets_if_enabled() {
  local target="$1"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] skip secret sync"
    return 0
  fi

  if [[ "${SYNC_SECRETS}" != "1" ]]; then
    return 0
  fi

  log "Syncing SOPS secrets to ${target}"
  MANAGER_SSH="${target}" \
  SSH_KEY_FILE="${SSH_KEY_FILE}" \
  FORCE_REPLACE="${FORCE_REPLACE}" \
  SOPS_SECRET_FILE="${SOPS_SECRET_FILE}" \
  "${REPO_ROOT}/scripts/swarm-sync-secrets.sh"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd nix
  require_cmd ssh
  require_cmd envsubst
  require_cmd realpath

  if [[ -n "${SSH_KEY_FILE}" ]]; then
    SSH_KEY_FILE="$(normalize_path "${SSH_KEY_FILE}")"
  fi
  STACKS_DIR="$(normalize_path "${STACKS_DIR}")"
  ENV_FILE="$(normalize_path "${ENV_FILE}")"
  ENV_LOCAL_FILE="$(normalize_path "${ENV_LOCAL_FILE}")"
  SOPS_SECRET_FILE="$(normalize_path "${SOPS_SECRET_FILE}")"
  STATE_DIR="$(normalize_path "${STATE_DIR}")"
  RENDER_DIR="${STATE_DIR}/rendered"
  LAST_GOOD_DIR="${STATE_DIR}/last-good"

  mkdir -p "${RENDER_DIR}" "${LAST_GOOD_DIR}"

  load_env
  discover_stacks

  local target
  target="$(resolve_target)"
  log "Swarm reconcile target: ${target}"

  sync_secrets_if_enabled "${target}"

  local i
  for i in "${!STACK_FILES[@]}"; do
    if ! deploy_one_stack "${target}" "${STACK_NAMES[i]}" "${STACK_FILES[i]}"; then
      warn "Stack ${STACK_NAMES[i]} failed reconcile"
    fi
  done

  local summary
  summary="$(cat <<EOF
Target: ${target}
Deployed: ${#DEPLOYED_STACKS[@]} (${DEPLOYED_STACKS[*]:-none})
RolledBack: ${#ROLLED_BACK_STACKS[@]} (${ROLLED_BACK_STACKS[*]:-none})
Failed: ${#FAILED_STACKS[@]} (${FAILED_STACKS[*]:-none})
Skipped: ${#SKIPPED_STACKS[@]} (${SKIPPED_STACKS[*]:-none})
EOF
)"

  if [[ "${#FAILED_STACKS[@]}" -gt 0 ]]; then
    err "Swarm reconcile finished with failures"
    err "${summary}"
    send_discord_notification "failed" "${summary}"
    exit 1
  fi

  log "Swarm reconcile finished successfully"
  log "${summary}"
  send_discord_notification "success" "${summary}"
}

main "$@"
