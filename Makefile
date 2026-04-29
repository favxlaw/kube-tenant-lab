# ==============================================================
# kube-tenant-lab
# Local multi-tenant Kubernetes platform
# ==============================================================

# --- Configuration ---
MINIKUBE_NODES      := 3
MINIKUBE_DRIVER     := docker
MINIKUBE_MEMORY     := 2500
MINIKUBE_CPUS       := 2

CILIUM_VERSION      := 1.18.5
GATEWAY_API_VERSION := v1.1.0

# --- Phony targets ---
.PHONY: all help \
        cluster-start cluster-delete \
        cilium-install cilium-status \
        configure-nodes \
        validate

# ==============================================================
# Help
# ==============================================================

help:
	@echo ""
	@echo "kube-tenant-lab"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "  all               Full Day 1 setup in order"
	@echo ""
	@echo "  cluster-start     Start 3-node Minikube cluster"
	@echo "  cluster-delete    Tear down the cluster"
	@echo ""
	@echo "  cilium-install    Install Gateway API CRDs and Cilium CNI"
	@echo "  cilium-status     Check Cilium health"
	@echo ""
	@echo "  configure-nodes   Label and taint nodes for workload isolation"
	@echo ""
	@echo "  validate          Verify cluster, Cilium, and node config are healthy"
	@echo ""

# ==============================================================
# All
# ==============================================================

all: cluster-start cilium-install configure-nodes validate

# ==============================================================
# Cluster
# ==============================================================

cluster-start:
	minikube start \
		--nodes=$(MINIKUBE_NODES) \
		--driver=$(MINIKUBE_DRIVER) \
		--memory=$(MINIKUBE_MEMORY) \
		--cpus=$(MINIKUBE_CPUS)

cluster-delete:
	minikube delete

# ==============================================================
# Cilium
# ==============================================================

cilium-install:
	@echo "==> Installing Gateway API CRDs..."
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	@echo "==> Adding Cilium Helm repo..."
	helm repo add cilium https://helm.cilium.io/ || true
	helm repo update cilium
	@echo "==> Installing Cilium..."
	helm install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--set ipam.mode=kubernetes \
		--set kubeProxyReplacement=false \
		--set gatewayAPI.enabled=true \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--wait
	@echo "==> Waiting for Cilium agents to report healthy..."
	cilium status --wait

cilium-status:
	cilium status

# ==============================================================
# Nodes
# ==============================================================

configure-nodes:
	@echo "==> Labelling nodes..."
	kubectl label node minikube        role=system  --overwrite
	kubectl label node minikube-m02    role=team-a  --overwrite
	kubectl label node minikube-m03    role=team-b  --overwrite
	@echo "==> Tainting team nodes..."
	kubectl taint node minikube-m02    team=team-a:NoSchedule --overwrite
	kubectl taint node minikube-m03    team=team-b:NoSchedule --overwrite

# ==============================================================
# Validate
# ==============================================================

validate:
	@echo ""
	@echo "==> Node status and labels"
	kubectl get nodes --show-labels
	@echo ""
	@echo "==> Cilium agent pods"
	kubectl -n kube-system get pods -l k8s-app=cilium -o wide
	@echo ""
	@echo "==> Cilium health"
	cilium status

