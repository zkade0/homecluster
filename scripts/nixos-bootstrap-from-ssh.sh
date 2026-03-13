#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_FILE="${REPO_ROOT}/nixos/hosts.nix"
DEPLOY_SCRIPT="${REPO_ROOT}/scripts/nixos-deploy.sh"
MANAGED_PUBKEY_FILE="${REPO_ROOT}/nixos/keys/homelab-admin.pub"
SOPS_SECRET_FILE="${REPO_ROOT}/secrets/ssh/nixos-bootstrap.sops.yaml"

K8S0_SSH="${K8S0_SSH:-}"
K8S1_SSH="${K8S1_SSH:-}"
K8S2_SSH="${K8S2_SSH:-}"
NEW_IP_K8S0="${NEW_IP_K8S0:-192.168.8.5}"
NEW_IP_K8S1="${NEW_IP_K8S1:-192.168.8.6}"
NEW_IP_K8S2="${NEW_IP_K8S2:-192.168.8.7}"

GATEWAY="${GATEWAY:-192.168.8.1}"
NAMESERVERS_CSV="${NAMESERVERS:-1.1.1.1}"
SWARM_ROLE_K8S0="${SWARM_ROLE_K8S0:-manager}"
SWARM_ROLE_K8S1="${SWARM_ROLE_K8S1:-manager}"
SWARM_ROLE_K8S2="${SWARM_ROLE_K8S2:-manager}"
SWARM_MANAGER_ADDRESS="${SWARM_MANAGER_ADDRESS:-${NEW_IP_K8S0}}"
OS_DISK="${OS_DISK:-/dev/nvme0n1}"
DATA_DISK="${DATA_DISK:-/dev/sda}"
SSD_CACHE_GB="${SSD_CACHE_GB:-75}"
DEPLOY="${DEPLOY:-1}"
FINAL_DEPLOY_USER="${FINAL_DEPLOY_USER:-root}"
INITIAL_DEPLOY_USER="${INITIAL_DEPLOY_USER:-auto}"

BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-}"
BOOTSTRAP_PASSWORD_FILE="${BOOTSTRAP_PASSWORD_FILE:-}"
ROTATE_ROOT_PASSWORD="${ROTATE_ROOT_PASSWORD:-1}"
NEW_ROOT_PASSWORD="${NEW_ROOT_PASSWORD:-}"
STORE_SECRETS="${STORE_SECRETS:-1}"
MANAGED_KEY_FILE="${MANAGED_KEY_FILE:-${HOME}/.ssh/homelab-nixos-admin}"

SSH_OPTIONS="${SSH_OPTIONS:--o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"

AUTH_MODE="key"
BOOTSTRAP_PASSWORD_VALUE=""
SSH_OPTS_ARR=()

usage() {
  cat <<USAGE
Usage (env vars):
  K8S0_SSH=kaden@192.168.8.50 \\
  K8S1_SSH=kaden@192.168.8.56 \\
  K8S2_SSH=kaden@192.168.8.226 \\
  NEW_IP_K8S0=192.168.8.5 \\
  NEW_IP_K8S1=192.168.8.6 \\
  NEW_IP_K8S2=192.168.8.7 \\
  BOOTSTRAP_PASSWORD=password \\
  ./scripts/nixos-bootstrap-from-ssh.sh

Optional env:
  GATEWAY=192.168.8.1
  NAMESERVERS=1.1.1.1,1.0.0.1
  NEW_IP_K8S0=192.168.8.5
  NEW_IP_K8S1=192.168.8.6
  NEW_IP_K8S2=192.168.8.7
  FINAL_DEPLOY_USER=root             (stored in nixos/hosts.nix)
  INITIAL_DEPLOY_USER=auto           (auto uses each current SSH user for first deploy)
  SWARM_ROLE_K8S0=manager            (manager|worker)
  SWARM_ROLE_K8S1=manager            (manager|worker)
  SWARM_ROLE_K8S2=manager            (manager|worker)
  SWARM_MANAGER_ADDRESS=192.168.8.5
  OS_DISK=/dev/nvme0n1
  DATA_DISK=/dev/sda
  SSD_CACHE_GB=75
  DEPLOY=1|0                        (default: 1)

Auth/bootstrap:
  BOOTSTRAP_PASSWORD=<password>     one-time node password auth
  BOOTSTRAP_PASSWORD_FILE=<path>    read bootstrap password from file
  ROTATE_ROOT_PASSWORD=1|0          set random/new root password after key install (default: 1)
  NEW_ROOT_PASSWORD=<value>         override generated password for rotation
  MANAGED_KEY_FILE=~/.ssh/homelab-nixos-admin

Secret handling:
  STORE_SECRETS=1|0                 write encrypted bootstrap secret bundle (default: 1)
  SOPS_SECRET_FILE=secrets/ssh/nixos-bootstrap.sops.yaml

Other:
  SSH_OPTIONS="-o ..."
USAGE
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

validate_swarm_role() {
  local role="$1"
  local node="$2"
  if [[ "${role}" != "manager" && "${role}" != "worker" ]]; then
    echo "Invalid ${node} role: ${role}. Use manager or worker." >&2
    exit 1
  fi
}

normalize_target() {
  local raw="$1"
  if [[ "${raw}" == *"@"* ]]; then
    echo "${raw}"
  else
    echo "root@${raw}"
  fi
}

target_user() {
  local target="$1"
  echo "${target%%@*}"
}

target_host() {
  local target="$1"
  echo "${target#*@}"
}

nix_list_from_csv() {
  local csv="$1"
  local out=""
  IFS=',' read -r -a items <<<"${csv}"
  for item in "${items[@]}"; do
    local trimmed
    trimmed="$(echo "${item}" | awk '{$1=$1;print}')"
    [[ -z "${trimmed}" ]] && continue
    out+=" \"${trimmed}\""
  done
  echo "[${out} ]"
}

setup_auth_mode() {
  read -r -a SSH_OPTS_ARR <<<"${SSH_OPTIONS}"

  if [[ -n "${BOOTSTRAP_PASSWORD_FILE}" ]]; then
    if [[ ! -f "${BOOTSTRAP_PASSWORD_FILE}" ]]; then
      echo "BOOTSTRAP_PASSWORD_FILE not found: ${BOOTSTRAP_PASSWORD_FILE}" >&2
      exit 1
    fi
    BOOTSTRAP_PASSWORD_VALUE="$(<"${BOOTSTRAP_PASSWORD_FILE}")"
  elif [[ -n "${BOOTSTRAP_PASSWORD}" ]]; then
    BOOTSTRAP_PASSWORD_VALUE="${BOOTSTRAP_PASSWORD}"
  fi

  if [[ -n "${BOOTSTRAP_PASSWORD_VALUE}" ]]; then
    AUTH_MODE="password"
    require_cmd sshpass
  else
    AUTH_MODE="key"
  fi
}

ssh_exec() {
  local target="$1"
  shift

  if [[ "${AUTH_MODE}" == "password" ]]; then
    sshpass -p "${BOOTSTRAP_PASSWORD_VALUE}" \
      ssh "${SSH_OPTS_ARR[@]}" \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${target}" "$@"
    return
  fi

  ssh "${SSH_OPTS_ARR[@]}" -i "${MANAGED_KEY_FILE}" -o IdentitiesOnly=yes "${target}" "$@"
}

ssh_exec_root() {
  local target="$1"
  shift
  local cmd="$*"
  local user
  local quoted_cmd

  user="$(target_user "${target}")"
  if [[ "${user}" == "root" ]]; then
    ssh_exec "${target}" "${cmd}"
    return
  fi

  if [[ -z "${BOOTSTRAP_PASSWORD_VALUE}" ]]; then
    echo "Root command on ${target} needs BOOTSTRAP_PASSWORD or BOOTSTRAP_PASSWORD_FILE." >&2
    exit 1
  fi

  quoted_cmd="$(printf "%q" "${cmd}")"

  if [[ "${AUTH_MODE}" == "password" ]]; then
    printf '%s\n' "${BOOTSTRAP_PASSWORD_VALUE}" | \
      sshpass -p "${BOOTSTRAP_PASSWORD_VALUE}" \
      ssh "${SSH_OPTS_ARR[@]}" \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${target}" "sudo -S -p '' bash -lc ${quoted_cmd}"
    return
  fi

  printf '%s\n' "${BOOTSTRAP_PASSWORD_VALUE}" | \
    ssh "${SSH_OPTS_ARR[@]}" -i "${MANAGED_KEY_FILE}" -o IdentitiesOnly=yes \
    "${target}" "sudo -S -p '' bash -lc ${quoted_cmd}"
}

scp_from() {
  local src="$1"
  local dst="$2"

  if [[ "${AUTH_MODE}" == "password" ]]; then
    sshpass -p "${BOOTSTRAP_PASSWORD_VALUE}" \
      scp "${SSH_OPTS_ARR[@]}" \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "${src}" "${dst}"
    return
  fi

  scp "${SSH_OPTS_ARR[@]}" -i "${MANAGED_KEY_FILE}" -o IdentitiesOnly=yes "${src}" "${dst}"
}

ensure_sops_ready() {
  require_cmd sops
  if grep -q "age1replacewithyourrealrecipient" "${REPO_ROOT}/.sops.yaml"; then
    echo "Set a real age recipient in .sops.yaml before running secure bootstrap." >&2
    echo "Generate with: age-keygen -o age.agekey" >&2
    exit 1
  fi
}

ensure_managed_key() {
  require_cmd ssh-keygen

  mkdir -p "$(dirname "${MANAGED_KEY_FILE}")"
  mkdir -p "$(dirname "${MANAGED_PUBKEY_FILE}")"
  mkdir -p "$(dirname "${SOPS_SECRET_FILE}")"

  if [[ ! -s "${MANAGED_KEY_FILE}" || ! -s "${MANAGED_KEY_FILE}.pub" ]]; then
    echo "Generating managed SSH key: ${MANAGED_KEY_FILE}"
    ssh-keygen -t ed25519 -N "" -f "${MANAGED_KEY_FILE}" -C "homelab-nixos-admin"
  fi

  chmod 600 "${MANAGED_KEY_FILE}"
  cp "${MANAGED_KEY_FILE}.pub" "${MANAGED_PUBKEY_FILE}"
}

install_managed_key_on_node() {
  local target="$1"
  local login_user
  local pub

  login_user="$(target_user "${target}")"
  pub="$(<"${MANAGED_KEY_FILE}.pub")"

  ssh_exec "${target}" "set -euo pipefail
user_home=\$(getent passwd '${login_user}' | cut -d: -f6)
if [ -z \"\$user_home\" ]; then
  echo 'Could not determine home directory for ${login_user}' >&2
  exit 1
fi
install -m 700 -d \"\$user_home/.ssh\"
touch \"\$user_home/.ssh/authorized_keys\"
chmod 600 \"\$user_home/.ssh/authorized_keys\"
grep -qxF '${pub}' \"\$user_home/.ssh/authorized_keys\" || echo '${pub}' >> \"\$user_home/.ssh/authorized_keys\""

  if [[ "${login_user}" != "root" ]]; then
    ssh_exec_root "${target}" "set -euo pipefail
install -m 700 -d /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF '${pub}' /root/.ssh/authorized_keys || echo '${pub}' >> /root/.ssh/authorized_keys"
  fi
}

rotate_root_password_on_node() {
  local target="$1"
  local new_pw="$2"

  ssh_exec_root "${target}" "echo 'root:${new_pw}' | chpasswd"
}

discover_interface() {
  local target="$1"
  local iface

  iface="$(ssh_exec "${target}" "ip -4 route show default | awk 'NR==1 {print \$5}'")"
  if [[ -n "${iface}" ]]; then
    echo "${iface}"
    return
  fi

  iface="$(ssh_exec "${target}" "ip -o link show | awk -F': ' '\$2 != \"lo\" {print \$2; exit}'")"
  if [[ -z "${iface}" ]]; then
    echo "Could not determine network interface on ${target}" >&2
    exit 1
  fi

  echo "${iface}"
}

copy_hardware_config() {
  local target="$1"
  local node="$2"

  scp_from "${target}:/etc/nixos/hardware-configuration.nix" "${REPO_ROOT}/nixos/hosts/${node}/hardware-configuration.nix"
}

collect_disk_info() {
  local target="$1"
  local node="$2"

  {
    echo "## ${node} (${target})"
    echo
    echo "Assumptions:"
    echo "- OS disk: ${OS_DISK}"
    echo "- Data disk for stateful services: ${DATA_DISK}"
    echo "- Requested SSD cache size: ${SSD_CACHE_GB}GB"
    echo
    ssh_exec "${target}" "lsblk -e7 -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT,FSTYPE,MODEL"
    echo
    ssh_exec "${target}" "set -euo pipefail
for d in '${OS_DISK}' '${DATA_DISK}'; do
  echo \"Device: \$d\"
  if [ ! -e \"\$d\" ]; then
    echo \"  missing\"
    continue
  fi
  real=\$(readlink -f \"\$d\")
  echo \"  resolved: \$real\"
  echo \"  by-id links:\"
  found=0
  for link in /dev/disk/by-id/*; do
    if [ \"\$(readlink -f \"\$link\")\" = \"\$real\" ]; then
      echo \"    \$link\"
      found=1
    fi
  done
  if [ \"\$found\" -eq 0 ]; then
    echo \"    (none found)\"
  fi
done"
    echo
  } >> "${REPO_ROOT}/docs/NODE-DISK-INVENTORY.md"
}

save_bootstrap_secrets() {
  local initial_password="$1"
  local rotated_password="$2"
  local tmp
  tmp="$(mktemp)"

  {
    echo "stringData:"
    echo "  generated_at: \"$(date -Iseconds)\""
    echo "  bootstrap_initial_password: \"${initial_password}\""
    echo "  root_password_after_rotation: \"${rotated_password}\""
    echo "  managed_private_key: |"
    sed 's/^/    /' "${MANAGED_KEY_FILE}"
    echo "  managed_public_key: |"
    sed 's/^/    /' "${MANAGED_KEY_FILE}.pub"
  } > "${tmp}"

  sops -e --input-type yaml --output-type yaml "${tmp}" > "${SOPS_SECRET_FILE}"
  rm -f "${tmp}"
}

main() {
  if [[ -z "${K8S0_SSH}" || -z "${K8S1_SSH}" || -z "${K8S2_SSH}" ]]; then
    usage
    exit 1
  fi

  require_cmd ssh
  require_cmd scp
  require_cmd awk
  require_cmd sed

  setup_auth_mode
  ensure_managed_key

  validate_swarm_role "${SWARM_ROLE_K8S0}" "SWARM_ROLE_K8S0"
  validate_swarm_role "${SWARM_ROLE_K8S1}" "SWARM_ROLE_K8S1"
  validate_swarm_role "${SWARM_ROLE_K8S2}" "SWARM_ROLE_K8S2"
  if [[ "${SWARM_ROLE_K8S0}" != "manager" ]]; then
    echo "SWARM_ROLE_K8S0 must stay manager because k8s-0 is the bootstrap manager." >&2
    exit 1
  fi

  if [[ "${STORE_SECRETS}" == "1" ]]; then
    ensure_sops_ready
  fi

  local t0 t1 t2
  t0="$(normalize_target "${K8S0_SSH}")"
  t1="$(normalize_target "${K8S1_SSH}")"
  t2="$(normalize_target "${K8S2_SSH}")"

  local u0 u1 u2
  local ip0_cur ip1_cur ip2_cur
  u0="$(target_user "${t0}")"
  u1="$(target_user "${t1}")"
  u2="$(target_user "${t2}")"
  ip0_cur="$(target_host "${t0}")"
  ip1_cur="$(target_host "${t1}")"
  ip2_cur="$(target_host "${t2}")"

  echo "Checking SSH reachability..."
  ssh_exec "${t0}" "echo ok >/dev/null"
  ssh_exec "${t1}" "echo ok >/dev/null"
  ssh_exec "${t2}" "echo ok >/dev/null"

  echo "Installing managed SSH key on all nodes..."
  install_managed_key_on_node "${t0}"
  install_managed_key_on_node "${t1}"
  install_managed_key_on_node "${t2}"

  # After keys are installed, switch remaining operations to key auth.
  AUTH_MODE="key"

  echo "Discovering primary interfaces..."
  local if0 if1 if2
  if0="$(discover_interface "${t0}")"
  if1="$(discover_interface "${t1}")"
  if2="$(discover_interface "${t2}")"

  if [[ "${ROTATE_ROOT_PASSWORD}" == "1" ]]; then
    if [[ -z "${NEW_ROOT_PASSWORD}" ]]; then
      require_cmd openssl
      NEW_ROOT_PASSWORD="$(openssl rand -hex 24)"
    fi

    echo "Rotating root password on all nodes..."
    rotate_root_password_on_node "${t0}" "${NEW_ROOT_PASSWORD}"
    rotate_root_password_on_node "${t1}" "${NEW_ROOT_PASSWORD}"
    rotate_root_password_on_node "${t2}" "${NEW_ROOT_PASSWORD}"
  fi

  echo "Copying hardware configs..."
  copy_hardware_config "${t0}" "k8s-0"
  copy_hardware_config "${t1}" "k8s-1"
  copy_hardware_config "${t2}" "k8s-2"

  echo "Collecting disk inventory -> docs/NODE-DISK-INVENTORY.md"
  {
    echo "# Node Disk Inventory"
    echo
    echo "Generated: $(date -Iseconds)"
    echo
  } > "${REPO_ROOT}/docs/NODE-DISK-INVENTORY.md"
  collect_disk_info "${t0}" "k8s-0"
  collect_disk_info "${t1}" "k8s-1"
  collect_disk_info "${t2}" "k8s-2"

  local ns_list
  ns_list="$(nix_list_from_csv "${NAMESERVERS_CSV}")"

  echo "Writing ${HOSTS_FILE}"
  cp "${HOSTS_FILE}" "${HOSTS_FILE}.bak.$(date +%s)"
  cat > "${HOSTS_FILE}" <<EOF_HOSTS
{
  k8s-0 = {
    ip = "${NEW_IP_K8S0}";
    user = "${FINAL_DEPLOY_USER}";
    interface = "${if0}";
    gateway = "${GATEWAY}";
    nameservers = ${ns_list};
    swarmRole = "${SWARM_ROLE_K8S0}";
    swarmAdvertiseAddr = "${NEW_IP_K8S0}";
    swarmManagerAddress = null;
    osDisk = "${OS_DISK}";
    dataDisk = "${DATA_DISK}";
    ssdCacheGB = ${SSD_CACHE_GB};
    tags = [ "${SWARM_ROLE_K8S0}" "bootstrap" ];
  };

  k8s-1 = {
    ip = "${NEW_IP_K8S1}";
    user = "${FINAL_DEPLOY_USER}";
    interface = "${if1}";
    gateway = "${GATEWAY}";
    nameservers = ${ns_list};
    swarmRole = "${SWARM_ROLE_K8S1}";
    swarmAdvertiseAddr = "${NEW_IP_K8S1}";
    swarmManagerAddress = "${SWARM_MANAGER_ADDRESS}";
    osDisk = "${OS_DISK}";
    dataDisk = "${DATA_DISK}";
    ssdCacheGB = ${SSD_CACHE_GB};
    tags = [ "${SWARM_ROLE_K8S1}" ];
  };

  k8s-2 = {
    ip = "${NEW_IP_K8S2}";
    user = "${FINAL_DEPLOY_USER}";
    interface = "${if2}";
    gateway = "${GATEWAY}";
    nameservers = ${ns_list};
    swarmRole = "${SWARM_ROLE_K8S2}";
    swarmAdvertiseAddr = "${NEW_IP_K8S2}";
    swarmManagerAddress = "${SWARM_MANAGER_ADDRESS}";
    osDisk = "${OS_DISK}";
    dataDisk = "${DATA_DISK}";
    ssdCacheGB = ${SSD_CACHE_GB};
    tags = [ "${SWARM_ROLE_K8S2}" ];
  };
}
EOF_HOSTS

  if [[ "${STORE_SECRETS}" == "1" ]]; then
    echo "Writing encrypted bootstrap secrets: ${SOPS_SECRET_FILE}"
    save_bootstrap_secrets "${BOOTSTRAP_PASSWORD_VALUE}" "${NEW_ROOT_PASSWORD}"
  fi

  cat <<SUMMARY

Bootstrap inputs resolved:
  current ssh k8s-0: ${u0}@${ip0_cur} iface=${if0}
  current ssh k8s-1: ${u1}@${ip1_cur} iface=${if1}
  current ssh k8s-2: ${u2}@${ip2_cur} iface=${if2}
  new node ip k8s-0: ${NEW_IP_K8S0}
  new node ip k8s-1: ${NEW_IP_K8S1}
  new node ip k8s-2: ${NEW_IP_K8S2}
  post-bootstrap deploy user: ${FINAL_DEPLOY_USER}
  gateway: ${GATEWAY}
  nameservers: ${NAMESERVERS_CSV}
  swarm bootstrap manager: ${SWARM_MANAGER_ADDRESS}
  swarm roles: k8s-0=${SWARM_ROLE_K8S0}, k8s-1=${SWARM_ROLE_K8S1}, k8s-2=${SWARM_ROLE_K8S2}
  os disk: ${OS_DISK}
  data disk: ${DATA_DISK}
  ssd cache target: ${SSD_CACHE_GB}GB
  managed key: ${MANAGED_KEY_FILE}
  managed pubkey in repo: ${MANAGED_PUBKEY_FILE}

Node disk inventory captured at:
  docs/NODE-DISK-INVENTORY.md
SUMMARY

  if [[ "${DEPLOY}" == "1" ]]; then
    local init_u0 init_u1 init_u2
    if [[ "${INITIAL_DEPLOY_USER}" == "auto" ]]; then
      init_u0="${u0}"
      init_u1="${u1}"
      init_u2="${u2}"
    else
      init_u0="${INITIAL_DEPLOY_USER}"
      init_u1="${INITIAL_DEPLOY_USER}"
      init_u2="${INITIAL_DEPLOY_USER}"
    fi

    echo "Deploying NixOS configs (bootstrap then remaining nodes)..."
    HOST_IP_K8S0="${ip0_cur}" HOST_IP_K8S1="${ip1_cur}" HOST_IP_K8S2="${ip2_cur}" \
    HOST_USER_K8S0="${init_u0}" HOST_USER_K8S1="${init_u1}" HOST_USER_K8S2="${init_u2}" \
    SSH_KEY_FILE="${MANAGED_KEY_FILE}" "${DEPLOY_SCRIPT}" k8s-0

    HOST_IP_K8S0="${ip0_cur}" HOST_IP_K8S1="${ip1_cur}" HOST_IP_K8S2="${ip2_cur}" \
    HOST_USER_K8S0="${init_u0}" HOST_USER_K8S1="${init_u1}" HOST_USER_K8S2="${init_u2}" \
    SSH_KEY_FILE="${MANAGED_KEY_FILE}" "${DEPLOY_SCRIPT}" k8s-1,k8s-2

    echo "Deployment complete."
  else
    echo "DEPLOY=0 set, skipping deployment."
    echo "Run: SSH_KEY_FILE=${MANAGED_KEY_FILE} make nixos-deploy-k8s0 && SSH_KEY_FILE=${MANAGED_KEY_FILE} make nixos-deploy-rest"
  fi
}

main "$@"
