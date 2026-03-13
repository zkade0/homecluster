#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_DIR="${REPO_ROOT}/nixos"
FLAKE_REF="path:${FLAKE_DIR}"
ACTION="${ACTION:-switch}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
USE_SUDO_NIX="${USE_SUDO_NIX:-auto}"
REMOTE_SUDO_MODE="${REMOTE_SUDO_MODE:-auto}"

if [[ ! "${ACTION}" =~ ^(switch|boot|test|build)$ ]]; then
  echo "Invalid ACTION=${ACTION}. Use switch|boot|test|build." >&2
  exit 1
fi

# Keep deterministic order for bootstrap safety.
ALL_HOSTS=("k8s-0" "k8s-1" "k8s-2")

declare -A HOST_IP_DEFAULT=(
  [k8s-0]="${HOST_IP_K8S0:-192.168.8.5}"
  [k8s-1]="${HOST_IP_K8S1:-192.168.8.6}"
  [k8s-2]="${HOST_IP_K8S2:-192.168.8.7}"
)

declare -A HOST_USER_DEFAULT=(
  [k8s-0]="${HOST_USER_K8S0:-root}"
  [k8s-1]="${HOST_USER_K8S1:-root}"
  [k8s-2]="${HOST_USER_K8S2:-root}"
)

usage() {
  cat <<USAGE
Usage:
  $0 all
  $0 k8s-0
  $0 k8s-1,k8s-2

Env:
  ACTION=switch|boot|test|build    (default: switch)
  SSH_KEY_FILE=/path/to/private_key
  USE_SUDO_NIX=auto|1|0            (default: auto)
  REMOTE_SUDO_MODE=auto|nopasswd|ask (default: auto)
USAGE
}

check_remote_sudo_noninteractive() {
  local target="$1"
  local -a ssh_args=()

  if [[ -n "${SSH_KEY_FILE}" ]]; then
    ssh_args+=(
      -i "${SSH_KEY_FILE}"
      -o IdentitiesOnly=yes
      -o PreferredAuthentications=publickey
      -o PasswordAuthentication=no
      -o BatchMode=yes
      -o StrictHostKeyChecking=accept-new
    )
  fi

  if ssh "${ssh_args[@]}" "${target}" "sudo -n true" >/dev/null 2>&1; then
    return
  fi

  cat >&2 <<EOF
Remote sudo check failed for ${target}.
The remote user needs passwordless sudo for automated deployment.

Fix on the node, then retry:
  echo '<user> ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/90-nixos-deploy >/dev/null
  sudo chmod 440 /etc/sudoers.d/90-nixos-deploy
EOF
  exit 1
}

remote_sudo_supports_nopasswd() {
  local target="$1"
  local -a ssh_args=()

  if [[ -n "${SSH_KEY_FILE}" ]]; then
    ssh_args+=(
      -i "${SSH_KEY_FILE}"
      -o IdentitiesOnly=yes
      -o PreferredAuthentications=publickey
      -o PasswordAuthentication=no
      -o BatchMode=yes
      -o StrictHostKeyChecking=accept-new
    )
  fi

  ssh "${ssh_args[@]}" "${target}" "sudo -n true" >/dev/null 2>&1
}

run_rebuild() {
  if [[ -n "${SSH_KEY_FILE}" ]]; then
    export NIX_SSHOPTS="${NIX_SSHOPTS:-} -i ${SSH_KEY_FILE} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o BatchMode=yes"
  fi

  if command -v nixos-rebuild >/dev/null 2>&1; then
    nixos-rebuild "$@"
    return
  fi

  if command -v nix >/dev/null 2>&1; then
    local -a nix_cmd=(
      nix
      --extra-experimental-features "nix-command flakes"
      run
      nixpkgs#nixos-rebuild
      --
      "$@"
    )

    if [[ "${USE_SUDO_NIX}" == "1" ]]; then
      sudo --preserve-env=NIX_SSHOPTS "${nix_cmd[@]}"
      return
    fi

    if [[ "${USE_SUDO_NIX}" == "0" ]]; then
      "${nix_cmd[@]}"
      return
    fi

    local errlog rc
    errlog="$(mktemp)"
    set +e
    "${nix_cmd[@]}" 2> >(tee "${errlog}" >&2)
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      rm -f "${errlog}"
      return
    fi

    if command -v sudo >/dev/null 2>&1 && grep -q 'creating directory "/nix/store": Permission denied' "${errlog}"; then
      echo "nix run lacked /nix/store permissions, retrying with sudo..." >&2
      sudo --preserve-env=NIX_SSHOPTS "${nix_cmd[@]}"
      rm -f "${errlog}"
      return
    fi

    rm -f "${errlog}"
    return "${rc}"
  fi

  echo "Neither nixos-rebuild nor nix is available on this machine." >&2
  exit 1
}

expand_targets() {
  local raw="$1"

  if [[ "${raw}" == "all" ]]; then
    printf "%s\n" "${ALL_HOSTS[@]}"
    return
  fi

  tr ',' '\n' <<<"${raw}"
}

resolve_host_field() {
  local host="$1"
  local field="$2"
  local fallback="$3"
  local value=""

  if command -v nix >/dev/null 2>&1; then
    set +e
    value="$(nix --extra-experimental-features "nix-command flakes" eval --raw "${FLAKE_REF}#homelab.hosts.${host}.${field}" 2>/dev/null)"
    set -e
  fi

  if [[ -z "${value}" ]]; then
    value="${fallback}"
  fi

  echo "${value}"
}

deploy_host() {
  local host="$1"
  local ip user
  ip="$(resolve_host_field "${host}" ip "${HOST_IP_DEFAULT[${host}]:-}")"
  user="$(resolve_host_field "${host}" user "${HOST_USER_DEFAULT[${host}]:-}")"

  if [[ -z "${ip}" || -z "${user}" ]]; then
    echo "Unknown host: ${host}" >&2
    exit 1
  fi

  local target="${user}@${ip}"

  echo "==> Deploying ${host} to ${target} (ACTION=${ACTION})"

  local args=(
    "${ACTION}"
    --flake "${FLAKE_REF}#${host}"
    --target-host "${target}"
    --build-host "${target}"
    --no-reexec
  )

  if [[ "${user}" != "root" ]]; then
    case "${REMOTE_SUDO_MODE}" in
      nopasswd)
        check_remote_sudo_noninteractive "${target}"
        args+=(--sudo)
        ;;
      ask)
        args+=(--sudo --ask-sudo-password)
        ;;
      auto)
        if remote_sudo_supports_nopasswd "${target}"; then
          args+=(--sudo)
        else
          echo "Remote sudo for ${target} requires a password; using --ask-sudo-password." >&2
          args+=(--sudo --ask-sudo-password)
        fi
        ;;
      *)
        echo "Invalid REMOTE_SUDO_MODE=${REMOTE_SUDO_MODE}. Use auto|nopasswd|ask." >&2
        exit 1
        ;;
    esac
  fi

  run_rebuild "${args[@]}"
}

main() {
  if [[ "${1:-}" == "" ]]; then
    usage
    exit 1
  fi

  while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    deploy_host "${host}"
  done < <(expand_targets "$1")
}

main "$@"
