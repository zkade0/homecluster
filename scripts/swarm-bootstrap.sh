#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
FLAKE_REF="path:${FLAKE_DIR}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
FORCE_REJOIN="${FORCE_REJOIN:-0}"

ALL_HOSTS=("k8s-0" "k8s-1" "k8s-2")

declare -A HOST_IP
declare -A HOST_USER
declare -A HOST_ROLE
declare -A HOST_ADVERTISE
declare -A HOST_MANAGER
declare -A HOST_TAGS_JSON

usage() {
  cat <<USAGE
Usage:
  $0

Env:
  SSH_KEY_FILE=/path/to/private_key
  FORCE_REJOIN=1   # force leave+rejoin for nodes that are already active
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

resolve_host_json() {
  local host="$1"
  nix --extra-experimental-features "nix-command flakes" eval --json "${FLAKE_REF}#homelab.hosts.${host}"
}

load_host_meta() {
  local host="$1"
  local json
  json="$(resolve_host_json "${host}")"

  HOST_IP["${host}"]="$(jq -r '.ip' <<<"${json}")"
  HOST_USER["${host}"]="$(jq -r '.user // "root"' <<<"${json}")"
  HOST_ROLE["${host}"]="$(jq -r '.swarmRole // "manager"' <<<"${json}")"
  HOST_ADVERTISE["${host}"]="$(jq -r '.swarmAdvertiseAddr // .ip' <<<"${json}")"
  HOST_MANAGER["${host}"]="$(jq -r '.swarmManagerAddress // ""' <<<"${json}")"
  HOST_TAGS_JSON["${host}"]="$(jq -c '.tags // []' <<<"${json}")"
}

host_target() {
  local host="$1"
  echo "${HOST_USER[${host}]}@${HOST_IP[${host}]}"
}

remote_swarm_state() {
  local host="$1"
  local target
  target="$(host_target "${host}")"
  ssh_cmd "${target}" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true"
}

remote_swarm_cluster_id() {
  local host="$1"
  local target
  target="$(host_target "${host}")"
  ssh_cmd "${target}" "docker info --format '{{ if .Swarm.Cluster }}{{ .Swarm.Cluster.ID }}{{ end }}' 2>/dev/null || true"
}

bootstrap_host() {
  local host
  for host in "${ALL_HOSTS[@]}"; do
    if [[ "${HOST_ROLE[${host}]}" == "manager" && -z "${HOST_MANAGER[${host}]}" ]]; then
      echo "${host}"
      return
    fi
  done

  echo "No bootstrap manager found in nixos/hosts.nix (manager with swarmManagerAddress = null)." >&2
  exit 1
}

normalize_tag() {
  local tag="$1"
  printf "%s" "${tag}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-'
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_cmd nix
  require_cmd jq
  require_cmd ssh

  local host
  for host in "${ALL_HOSTS[@]}"; do
    load_host_meta "${host}"
  done

  local init_host
  init_host="$(bootstrap_host)"
  local init_target
  init_target="$(host_target "${init_host}")"

  echo "Using bootstrap manager ${init_host} (${init_target})"

  local init_state
  init_state="$(remote_swarm_state "${init_host}")"
  if [[ "${init_state}" != "active" ]]; then
    echo "Initializing swarm on ${init_host}"
    ssh_cmd "${init_target}" \
      "docker swarm init --advertise-addr '${HOST_ADVERTISE[${init_host}]}' >/dev/null 2>&1 || true"
  fi

  local manager_token worker_token
  local init_cluster_id
  manager_token="$(ssh_cmd "${init_target}" "docker swarm join-token -q manager")"
  worker_token="$(ssh_cmd "${init_target}" "docker swarm join-token -q worker")"
  init_cluster_id="$(remote_swarm_cluster_id "${init_host}")"

  for host in "${ALL_HOSTS[@]}"; do
    if [[ "${host}" == "${init_host}" ]]; then
      continue
    fi

    local state token join_target target node_cluster_id
    target="$(host_target "${host}")"
    state="$(remote_swarm_state "${host}")"
    node_cluster_id="$(remote_swarm_cluster_id "${host}")"
    join_target="${HOST_MANAGER[${host}]}"
    if [[ -z "${join_target}" ]]; then
      join_target="${HOST_ADVERTISE[${init_host}]}"
    fi

    if [[ "${state}" == "active" ]]; then
      if [[ "${node_cluster_id}" == "${init_cluster_id}" ]]; then
        if [[ "${FORCE_REJOIN}" != "1" ]]; then
          echo "Skipping ${host}: already active in target swarm"
          continue
        fi
      elif [[ "${FORCE_REJOIN}" != "1" ]]; then
        echo "Node ${host} is active in a different swarm. Re-run with FORCE_REJOIN=1." >&2
        exit 1
      fi
    fi

    if [[ "${FORCE_REJOIN}" == "1" ]]; then
      echo "Forcing rejoin on ${host}"
      ssh_cmd "${target}" "docker swarm leave --force >/dev/null 2>&1 || true"
    fi

    if [[ "${HOST_ROLE[${host}]}" == "manager" ]]; then
      token="${manager_token}"
    else
      token="${worker_token}"
    fi

    echo "Joining ${host} as ${HOST_ROLE[${host}]}"
    ssh_cmd "${target}" \
      "docker swarm join --token '${token}' '${join_target}:2377' --advertise-addr '${HOST_ADVERTISE[${host}]}'"
  done

  echo "Applying homelab node labels"
  for host in "${ALL_HOSTS[@]}"; do
    ssh_cmd "${init_target}" \
      "docker node update --label-add homelab.role='${HOST_ROLE[${host}]}' '${host}' >/dev/null"
    ssh_cmd "${init_target}" \
      "docker node update --label-add homelab.hostname='${host}' '${host}' >/dev/null"

    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      local norm
      norm="$(normalize_tag "${tag}")"
      ssh_cmd "${init_target}" \
        "docker node update --label-add homelab.tag.${norm}=true '${host}' >/dev/null"
    done < <(jq -r '.[]' <<<"${HOST_TAGS_JSON[${host}]}")
  done

  echo
  echo "Swarm bootstrap complete. Current nodes:"
  ssh_cmd "${init_target}" "docker node ls"
}

main "$@"
