#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_REF="path:${REPO_ROOT}/nixos"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
VOLUME_NAME="${VOLUME_NAME:-homelab}"
BRICK_DIR="${BRICK_DIR:-/srv/brick/vol1}"

ALL_HOSTS=("k8s-0" "k8s-1" "k8s-2")

declare -A HOST_IP
declare -A HOST_USER

usage() {
  cat <<USAGE
Usage:
  $0

Env:
  SSH_KEY_FILE=/path/to/private_key
  VOLUME_NAME=homelab
  BRICK_DIR=/srv/brick/vol1
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

load_host_meta() {
  local host="$1"
  local json
  json="$(nix --extra-experimental-features "nix-command flakes" eval --json "${FLAKE_REF}#homelab.hosts.${host}")"
  HOST_IP["${host}"]="$(jq -r '.ip' <<<"${json}")"
  HOST_USER["${host}"]="$(jq -r '.user // "root"' <<<"${json}")"
}

host_target() {
  local host="$1"
  echo "${HOST_USER[${host}]}@${HOST_IP[${host}]}"
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

  echo "Ensuring brick path exists on all nodes"
  for host in "${ALL_HOSTS[@]}"; do
    ssh_cmd "$(host_target "${host}")" "mkdir -p '${BRICK_DIR}'"
  done

  local bootstrap_host bootstrap_target
  bootstrap_host="k8s-0"
  bootstrap_target="$(host_target "${bootstrap_host}")"

  echo "Probing Gluster peers from ${bootstrap_host}"
  for host in "${ALL_HOSTS[@]}"; do
    if [[ "${host}" == "${bootstrap_host}" ]]; then
      continue
    fi
    ssh_cmd "${bootstrap_target}" "gluster peer probe '${HOST_IP[${host}]}' >/dev/null 2>&1 || true"
  done

  # Let peer state settle.
  sleep 4

  local brick_list=()
  for host in "${ALL_HOSTS[@]}"; do
    brick_list+=("${HOST_IP[${host}]}:${BRICK_DIR}")
  done

  echo "Creating replicated volume '${VOLUME_NAME}' (replica 3) if needed"
  if ! ssh_cmd "${bootstrap_target}" "gluster volume info '${VOLUME_NAME}' >/dev/null 2>&1"; then
    ssh_cmd "${bootstrap_target}" \
      "gluster volume create '${VOLUME_NAME}' replica 3 transport tcp ${brick_list[*]} force"
  fi

  ssh_cmd "${bootstrap_target}" "gluster volume start '${VOLUME_NAME}' >/dev/null 2>&1 || true"
  ssh_cmd "${bootstrap_target}" "gluster volume set '${VOLUME_NAME}' cluster.quorum-type auto >/dev/null 2>&1 || true"
  ssh_cmd "${bootstrap_target}" "gluster volume set '${VOLUME_NAME}' cluster.server-quorum-type server >/dev/null 2>&1 || true"
  ssh_cmd "${bootstrap_target}" "gluster volume set '${VOLUME_NAME}' cluster.self-heal-daemon on >/dev/null 2>&1 || true"

  echo "Mounting shared volume on all nodes"
  for host in "${ALL_HOSTS[@]}"; do
    ssh_cmd "$(host_target "${host}")" \
      "set -euo pipefail; \
       if mountpoint -q /mnt/homelab-data; then ls /mnt/homelab-data >/dev/null 2>&1 || umount -l /mnt/homelab-data || true; fi; \
       mkdir -p /mnt/homelab-data; \
       timeout 20 ls /mnt/homelab-data >/dev/null; \
       mkdir -p /mnt/homelab-data/portainer /mnt/homelab-data/romm /mnt/homelab-data/technitium/config"
  done

  echo
  echo "Gluster status:"
  ssh_cmd "${bootstrap_target}" "gluster pool list && gluster volume info '${VOLUME_NAME}'"
}

main "$@"
