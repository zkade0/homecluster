SHELL := /bin/bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  swarm-bootstrap     Initialize/join Docker Swarm nodes"
	@echo "  gluster-bootstrap   Create replica-3 Gluster volume on /dev/sda"
	@echo "  swarm-sync-secrets  Sync SOPS secrets into Docker Swarm"
	@echo "  swarm-deploy        Deploy homelab stack to Swarm"
	@echo "  swarm-deploy-portainer Deploy Portainer stack to Swarm"
	@echo "  swarm-deploy-traefik Deploy Traefik ingress stack to Swarm"
	@echo "  swarm-deploy-romm   Deploy RomM stack to Swarm"
	@echo "  swarm-deploy-speedtest Deploy LibreSpeed Rust stack to Swarm"
	@echo "  swarm-deploy-uptime-kuma Deploy Uptime Kuma stack to Swarm"
	@echo "  swarm-deploy-backups Deploy Restic backup stack to Swarm"
	@echo "  swarm-deploy-paperless Deploy Paperless-ngx stack to Swarm"
	@echo "  swarm-deploy-local-dns Deploy Technitium DNS stack to Swarm (compat target)"
	@echo "  swarm-deploy-technitium-dns Deploy Technitium DNS stack to Swarm"
	@echo "  swarm-deploy-monitoring Deploy Prometheus + Grafana monitoring stack"
	@echo "  swarm-reconcile     Flux-like manual reconcile for Swarm stacks (deploy+verify+rollback)"
	@echo "  swarm-onboard-from-compose Convert compose -> swarm stack, upsert DNS, and reconcile deploy"
	@echo "  swarm-deploy-apps   Deploy Portainer + RomM as separate stacks"
	@echo "  nixos-build         Build one NixOS host config (HOST=k8s-0|k8s-1|k8s-2)"
	@echo "  nixos-bootstrap     Password bootstrap -> managed SSH key -> deploy"
	@echo "  nixos-deploy        Deploy one NixOS host (HOST=...)"
	@echo "  nixos-deploy-k8s0   Deploy bootstrap node only"
	@echo "  nixos-deploy-rest   Deploy remaining nodes (k8s-1/2)"
	@echo "  nixos-deploy-all    Deploy all NixOS hosts"
	@echo "  nixos-restore-key   Restore managed deploy key from SOPS secret"
	@echo "  validate-stack      Validate Swarm stack file rendering"

.PHONY: swarm-bootstrap
swarm-bootstrap:
	SSH_KEY_FILE="$(SSH_KEY_FILE)" FORCE_REJOIN="$(FORCE_REJOIN)" ./scripts/swarm-bootstrap.sh

.PHONY: swarm-sync-secrets
swarm-sync-secrets:
	SOPS_SECRET_FILE="$(SOPS_SECRET_FILE)" MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" \
	SSH_KEY_FILE="$(SSH_KEY_FILE)" FORCE_REPLACE="$(FORCE_REPLACE)" ./scripts/swarm-sync-secrets.sh

.PHONY: gluster-bootstrap
gluster-bootstrap:
	SSH_KEY_FILE="$(SSH_KEY_FILE)" VOLUME_NAME="$(or $(VOLUME_NAME),homelab)" BRICK_DIR="$(or $(BRICK_DIR),/srv/brick/vol1)" ./scripts/gluster-bootstrap.sh

.PHONY: swarm-deploy
swarm-deploy:
	STACK_FILE="$(STACK_FILE)" STACK_NAME="$(or $(STACK_NAME),homelab)" ENV_FILE="$(ENV_FILE)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS="$(or $(SYNC_SECRETS),1)" ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-portainer
swarm-deploy-portainer:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/portainer.yaml)" STACK_NAME="$(or $(STACK_NAME),portainer)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-traefik
swarm-deploy-traefik:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/traefik.yaml)" STACK_NAME="$(or $(STACK_NAME),traefik)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-romm
swarm-deploy-romm:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/romm.yaml)" STACK_NAME="$(or $(STACK_NAME),romm)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-speedtest
swarm-deploy-speedtest:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/speedtest.yaml)" STACK_NAME="$(or $(STACK_NAME),speedtest)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-uptime-kuma
swarm-deploy-uptime-kuma:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/uptime-kuma.yaml)" STACK_NAME="$(or $(STACK_NAME),uptime-kuma)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-backups
swarm-deploy-backups:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/backups.yaml)" STACK_NAME="$(or $(STACK_NAME),backups)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS="$(or $(SYNC_SECRETS),1)" ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-paperless
swarm-deploy-paperless:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/paperless.yaml)" STACK_NAME="$(or $(STACK_NAME),paperless)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-technitium-dns
swarm-deploy-technitium-dns:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/local-dns.yaml)" STACK_NAME="$(or $(STACK_NAME),local-dns)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-deploy-local-dns
swarm-deploy-local-dns: swarm-deploy-technitium-dns

.PHONY: swarm-deploy-monitoring
swarm-deploy-monitoring:
	STACK_FILE="$(or $(STACK_FILE),swarm/stacks/monitoring.yaml)" STACK_NAME="$(or $(STACK_NAME),monitoring)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS=0 ./scripts/swarm-deploy.sh

.PHONY: swarm-reconcile
swarm-reconcile:
	@STACK_FILE="$(STACK_FILE)" STACKS="$(STACKS)" STACKS_DIR="$(or $(STACKS_DIR),swarm/stacks)" EXCLUDE_STACKS="$(EXCLUDE_STACKS)" \
	ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" ENV_LOCAL_FILE="$(or $(ENV_LOCAL_FILE),swarm/env/cluster.env.local)" \
	SOPS_SECRET_FILE="$(or $(SOPS_SECRET_FILE),swarm/secrets/cluster-secrets.sops.yaml)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" \
	SYNC_SECRETS="$(or $(SYNC_SECRETS),1)" FORCE_REPLACE="$(or $(FORCE_REPLACE),0)" \
	DEPLOY_TIMEOUT="$(or $(DEPLOY_TIMEOUT),180)" POLL_INTERVAL="$(or $(POLL_INTERVAL),5)" DRY_RUN="$(or $(DRY_RUN),0)" \
	DISCORD_WEBHOOK_URL="$(DISCORD_WEBHOOK_URL)" DISCORD_USERNAME="$(or $(DISCORD_USERNAME),swarm-reconcile)" \
	./scripts/swarm-reconcile.sh

.PHONY: swarm-onboard-from-compose
swarm-onboard-from-compose:
	@COMPOSE_FILE="$(COMPOSE_FILE)" STACK_NAME="$(STACK_NAME)" STACK_FILE="$(STACK_FILE)" \
	ROUTE_SERVICE="$(ROUTE_SERVICE)" SERVICE_PORT="$(SERVICE_PORT)" APP_HOST="$(APP_HOST)" \
	TRAEFIK_VIP="$(or $(TRAEFIK_VIP),192.168.8.11)" \
	ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" ENV_LOCAL_FILE="$(or $(ENV_LOCAL_FILE),swarm/env/cluster.env.local)" \
	DOMAIN_FILE="$(or $(DOMAIN_FILE),swarm/env/domain.txt)" SOPS_SECRET_FILE="$(or $(SOPS_SECRET_FILE),swarm/secrets/cluster-secrets.sops.yaml)" \
	DNS_UPSERT="$(or $(DNS_UPSERT),1)" DNS_TTL="$(or $(DNS_TTL),300)" DNS_RESOLVER_IP="$(or $(DNS_RESOLVER_IP),192.168.8.10)" \
	TECHNITIUM_API_BASE="$(TECHNITIUM_API_BASE)" TECHNITIUM_ZONE="$(TECHNITIUM_ZONE)" \
	TECHNITIUM_API_TOKEN="$(TECHNITIUM_API_TOKEN)" TECHNITIUM_API_TOKEN_FILE="$(TECHNITIUM_API_TOKEN_FILE)" TECHNITIUM_INSECURE_TLS="$(or $(TECHNITIUM_INSECURE_TLS),1)" \
	PREFLIGHT="$(or $(PREFLIGHT),1)" PREFLIGHT_STRICT="$(or $(PREFLIGHT_STRICT),1)" PREFLIGHT_ONLY="$(or $(PREFLIGHT_ONLY),0)" \
	DEPLOY="$(or $(DEPLOY),1)" DRY_RUN="$(or $(DRY_RUN),0)" SYNC_SECRETS="$(or $(SYNC_SECRETS),0)" FORCE_REPLACE="$(or $(FORCE_REPLACE),0)" \
	MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" SSH_KEY_FILE="$(SSH_KEY_FILE)" ENSURE_BIND_DIRS="$(or $(ENSURE_BIND_DIRS),1)" ENSURE_BIND_DIRS_SCOPE="$(or $(ENSURE_BIND_DIRS_SCOPE),manager)" \
	./scripts/swarm-onboard-from-compose.sh

.PHONY: swarm-deploy-apps
swarm-deploy-apps:
	$(MAKE) swarm-deploy-portainer SSH_KEY_FILE="$(SSH_KEY_FILE)" MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)"
	$(MAKE) swarm-deploy-romm SSH_KEY_FILE="$(SSH_KEY_FILE)" MANAGER_HOST="$(or $(MANAGER_HOST),k8s-0)" MANAGER_SSH="$(MANAGER_SSH)" ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)"

.PHONY: nixos-build
nixos-build:
	@test -n "$(HOST)" || (echo "HOST is required (k8s-0|k8s-1|k8s-2)" && exit 1)
	nix build ./nixos#nixosConfigurations.$(HOST).config.system.build.toplevel

.PHONY: nixos-bootstrap
nixos-bootstrap:
	@test -n "$(K8S0_SSH)" || (echo "K8S0_SSH is required (e.g. kaden@192.168.8.50)" && exit 1)
	@test -n "$(K8S1_SSH)" || (echo "K8S1_SSH is required (e.g. kaden@192.168.8.56)" && exit 1)
	@test -n "$(K8S2_SSH)" || (echo "K8S2_SSH is required (e.g. kaden@192.168.8.226)" && exit 1)
	K8S0_SSH="$(K8S0_SSH)" K8S1_SSH="$(K8S1_SSH)" K8S2_SSH="$(K8S2_SSH)" \
	NEW_IP_K8S0="$(or $(NEW_IP_K8S0),192.168.8.5)" \
	NEW_IP_K8S1="$(or $(NEW_IP_K8S1),192.168.8.6)" \
	NEW_IP_K8S2="$(or $(NEW_IP_K8S2),192.168.8.7)" \
	GATEWAY="$(or $(GATEWAY),192.168.8.1)" NAMESERVERS="$(or $(NAMESERVERS),1.1.1.1)" \
	SWARM_ROLE_K8S0="$(or $(SWARM_ROLE_K8S0),manager)" \
	SWARM_ROLE_K8S1="$(or $(SWARM_ROLE_K8S1),manager)" \
	SWARM_ROLE_K8S2="$(or $(SWARM_ROLE_K8S2),manager)" \
	SWARM_MANAGER_ADDRESS="$(or $(SWARM_MANAGER_ADDRESS),$(or $(NEW_IP_K8S0),192.168.8.5))" \
	OS_DISK="$(or $(OS_DISK),/dev/nvme0n1)" DATA_DISK="$(or $(DATA_DISK),/dev/sda)" \
	SSD_CACHE_GB="$(or $(SSD_CACHE_GB),75)" DEPLOY="$(or $(DEPLOY),1)" \
	BOOTSTRAP_PASSWORD="$(BOOTSTRAP_PASSWORD)" BOOTSTRAP_PASSWORD_FILE="$(BOOTSTRAP_PASSWORD_FILE)" \
	ROTATE_ROOT_PASSWORD="$(or $(ROTATE_ROOT_PASSWORD),1)" NEW_ROOT_PASSWORD="$(NEW_ROOT_PASSWORD)" \
	STORE_SECRETS="$(or $(STORE_SECRETS),1)" MANAGED_KEY_FILE="$(MANAGED_KEY_FILE)" \
	FINAL_DEPLOY_USER="$(or $(FINAL_DEPLOY_USER),root)" \
	INITIAL_DEPLOY_USER="$(or $(INITIAL_DEPLOY_USER),auto)" \
	USE_SUDO_NIX="$(or $(USE_SUDO_NIX),auto)" \
	REMOTE_SUDO_MODE="$(or $(REMOTE_SUDO_MODE),auto)" \
	./scripts/nixos-bootstrap-from-ssh.sh

.PHONY: nixos-deploy
nixos-deploy:
	@test -n "$(HOST)" || (echo "HOST is required (k8s-0|k8s-1|k8s-2)" && exit 1)
	SSH_KEY_FILE="$(SSH_KEY_FILE)" USE_SUDO_NIX="$(or $(USE_SUDO_NIX),auto)" REMOTE_SUDO_MODE="$(or $(REMOTE_SUDO_MODE),auto)" ./scripts/nixos-deploy.sh "$(HOST)"

.PHONY: nixos-deploy-k8s0
nixos-deploy-k8s0:
	SSH_KEY_FILE="$(SSH_KEY_FILE)" USE_SUDO_NIX="$(or $(USE_SUDO_NIX),auto)" REMOTE_SUDO_MODE="$(or $(REMOTE_SUDO_MODE),auto)" ./scripts/nixos-deploy.sh k8s-0

.PHONY: nixos-deploy-rest
nixos-deploy-rest:
	SSH_KEY_FILE="$(SSH_KEY_FILE)" USE_SUDO_NIX="$(or $(USE_SUDO_NIX),auto)" REMOTE_SUDO_MODE="$(or $(REMOTE_SUDO_MODE),auto)" ./scripts/nixos-deploy.sh k8s-1,k8s-2

.PHONY: nixos-deploy-all
nixos-deploy-all:
	SSH_KEY_FILE="$(SSH_KEY_FILE)" USE_SUDO_NIX="$(or $(USE_SUDO_NIX),auto)" REMOTE_SUDO_MODE="$(or $(REMOTE_SUDO_MODE),auto)" ./scripts/nixos-deploy.sh all

.PHONY: nixos-restore-key
nixos-restore-key:
	SOPS_SECRET_FILE="$(SOPS_SECRET_FILE)" OUT_KEY_FILE="$(OUT_KEY_FILE)" OUT_PUB_FILE="$(OUT_PUB_FILE)" \
	./scripts/nixos-restore-managed-key.sh

.PHONY: validate-stack
validate-stack:
	@command -v docker >/dev/null || (echo "docker is not installed" && exit 1)
	@ENV_FILE="$(or $(ENV_FILE),swarm/env/cluster.env)" ; \
	ENV_LOCAL_FILE="$(or $(ENV_LOCAL_FILE),swarm/env/cluster.env.local)" ; \
	DOMAIN_FILE="$(or $(DOMAIN_FILE),swarm/env/domain.txt)" ; \
	STACK_NAME="$(or $(STACK_NAME),homelab)" ; \
	test -f "$$ENV_FILE" || (echo "missing $$ENV_FILE" && exit 1) ; \
	set -a ; . "$$ENV_FILE" ; if [ -f "$$ENV_LOCAL_FILE" ]; then . "$$ENV_LOCAL_FILE" ; fi ; set +a ; \
	if [ -f "$$DOMAIN_FILE" ]; then \
		BASE_DOMAIN="$$(awk 'NF && $$1 !~ /^#/ {print $$1; exit}' "$$DOMAIN_FILE" | tr -d '\r')" ; \
		test -n "$$BASE_DOMAIN" || (echo "DOMAIN_FILE is empty: $$DOMAIN_FILE" && exit 1) ; \
		export BASE_DOMAIN ; \
	fi ; \
	test -n "$${BASE_DOMAIN:-}" || (echo "BASE_DOMAIN is not set (set DOMAIN_FILE or BASE_DOMAIN in ENV_FILE)" && exit 1) ; \
	export STACK_NAME ; \
	envsubst < swarm/stacks/homelab.yaml >/tmp/homelab-stack.rendered.yaml ; \
	docker compose -f /tmp/homelab-stack.rendered.yaml config >/dev/null ; \
	echo "Stack render is valid."
