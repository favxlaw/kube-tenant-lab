# ==============================================================
# kube-tenant-lab
# Local multi-tenant Kubernetes platform
# ==============================================================

# --- Configuration ---
CILIUM_VERSION      := 1.15.5
GATEWAY_API_VERSION := v1.1.0
KYVERNO_VERSION     := 3.1.4

# Node names — KIND naming convention
CONTROL_PLANE_NODE  := kube-tenant-lab-control-plane
WORKER_A_NODE       := kube-tenant-lab-worker
WORKER_B_NODE       := kube-tenant-lab-worker2

# --- Phony targets ---
.PHONY: all help \
        cluster-start cluster-delete \
        cilium-install cilium-status \
        configure-nodes \
        validate validate-all validate-network validate-policies validate-otel \
        image-build image-load image-push \
        namespaces-apply apps-deploy gateway-deploy platform-deploy platform-delete \
        test-clients-deploy test-clients-delete \
        rbac-apply \
        kyverno-install kyverno-policies-apply cilium-policies-apply \
        policies-deploy policies-delete \
        otel-gateway-deploy otel-collectors-deploy otel-deploy otel-delete otel-logs

# ==============================================================
# Help
# ==============================================================

help:
	@echo ""
	@echo "kube-tenant-lab"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "  --- Cluster ---"
	@echo "  cluster-start        Start 3-node KIND cluster"
	@echo "  cluster-delete       Tear down the cluster"
	@echo ""
	@echo "  --- Cilium ---"
	@echo "  cilium-install       Install Gateway API CRDs and Cilium CNI"
	@echo "  cilium-status        Check Cilium health"
	@echo ""
	@echo "  --- Nodes ---"
	@echo "  configure-nodes      Taint nodes for workload isolation"
	@echo ""
	@echo "  --- Application Image ---"
	@echo "  image-build          Build Go app Docker image"
	@echo "  image-load           Load image into KIND cluster"
	@echo "  image-push           Build and load in one step"
	@echo ""
	@echo "  --- Platform ---"
	@echo "  namespaces-apply     Apply all namespace definitions"
	@echo "  rbac-apply           Apply RBAC resources"
	@echo "  apps-deploy          Deploy team-a and team-b applications"
	@echo "  gateway-deploy       Deploy Gateway and HTTPRoutes"
	@echo "  platform-deploy      Deploy namespaces, RBAC, apps, and gateway"
	@echo "  platform-delete      Remove all platform resources"
	@echo ""
	@echo "  --- Test Clients ---"
	@echo "  test-clients-deploy  Deploy curl client pods for validation"
	@echo "  test-clients-delete  Remove curl client pods"
	@echo ""
	@echo "  --- Policies ---"
	@echo "  kyverno-install         Install Kyverno via Helm"
	@echo "  kyverno-policies-apply  Apply all Kyverno ClusterPolicies"
	@echo "  cilium-policies-apply   Apply all Cilium network policies"
	@echo "  policies-deploy         Install Kyverno and apply all policies"
	@echo "  policies-delete         Remove all policies"
	@echo ""
	@echo "  --- Observability ---"
	@echo "  otel-gateway-deploy     Deploy OTel gateway"
	@echo "  otel-collectors-deploy  Deploy platform-owned team collectors"
	@echo "  otel-deploy             Deploy full OTel stack"
	@echo "  otel-delete             Remove OTel resources"
	@echo "  otel-logs               Stream OTel gateway logs"
	@echo ""
	@echo "  --- Validate ---"
	@echo "  validate             Verify cluster, Cilium, and node config"
	@echo "  validate-all         Run all validation checks"
	@echo "  validate-network     Check Cilium policies and cross-team traffic"
	@echo "  validate-policies    Check Kyverno policies and test rejections"
	@echo "  validate-otel        Check OTel pods and gateway logs"
	@echo ""

# ==============================================================
# All — full cluster setup
# ==============================================================

all: cluster-start cilium-install configure-nodes validate

# ==============================================================
# Cluster
# ==============================================================

cluster-start:
	kind create cluster --config kind-config.yaml

cluster-delete:
	kind delete cluster --name kube-tenant-lab

# ==============================================================
# Cilium
# ==============================================================

cilium-install:
	@echo "==> Installing Gateway API CRDs..."
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/experimental-install.yaml
	@echo "==> Adding Cilium Helm repo..."
	helm repo add cilium https://helm.cilium.io/ || true
	helm repo update cilium
	@echo "==> Installing Cilium..."
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		--set ipam.mode=kubernetes \
		--set kubeProxyReplacement=false \
		--set gatewayAPI.enabled=true \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set image.pullPolicy=IfNotPresent \
		--timeout 10m \
		--wait
	@echo "==> Waiting for Cilium agents to report healthy..."
	cilium status

cilium-status:
	cilium status

# ==============================================================
# Nodes
# ==============================================================

configure-nodes:
	@echo "==> Tainting team nodes..."
	kubectl taint node $(WORKER_A_NODE) team=team-a:NoSchedule --overwrite
	kubectl taint node $(WORKER_B_NODE) team=team-b:NoSchedule --overwrite
	@echo "==> Verifying node labels..."
	kubectl get nodes --show-labels

# ==============================================================
# Application Image
# ==============================================================

image-build:
	docker build -t tenant-app:v1 ./apps/src

image-load:
	kind load docker-image tenant-app:v1 --name kube-tenant-lab

image-push: image-build image-load

# ==============================================================
# Platform
# ==============================================================

platform-deploy: namespaces-apply rbac-apply apps-deploy gateway-deploy

namespaces-apply:
	kubectl apply -f namespaces/

rbac-apply:
	@echo "==> Applying RBAC..."
	kubectl apply -f rbac/platform-readonly-clusterrole.yaml
	kubectl apply -f rbac/platform-readonly-clusterrolebinding.yaml
	kubectl apply -f rbac/team-serviceaccount.yaml
	kubectl apply -f rbac/kyverno-background-controller-permissions.yaml

apps-deploy:
	kubectl apply -f apps/team-a/
	kubectl apply -f apps/team-b/

gateway-deploy:
	kubectl apply -f gateway/

test-clients-deploy:
	kubectl apply -f test-client.yaml

test-clients-delete:
	kubectl delete -f test-client.yaml --ignore-not-found

platform-delete:
	kubectl delete -f gateway/ --ignore-not-found
	kubectl delete -f apps/team-a/ --ignore-not-found
	kubectl delete -f apps/team-b/ --ignore-not-found
	kubectl delete -f namespaces/ --ignore-not-found

# ==============================================================
# Policies
# ==============================================================

policies-deploy: kyverno-install rbac-apply cilium-policies-apply kyverno-policies-apply

kyverno-install:
	helm repo add kyverno https://kyverno.github.io/kyverno/ || true
	helm repo update kyverno
	helm upgrade --install kyverno kyverno/kyverno \
		--version $(KYVERNO_VERSION) \
		--namespace kyverno \
		--create-namespace \
		--set admissionController.tolerations[0].key=node-role.kubernetes.io/control-plane \
		--set admissionController.tolerations[0].operator=Exists \
		--set admissionController.tolerations[0].effect=NoSchedule \
		--set backgroundController.tolerations[0].key=node-role.kubernetes.io/control-plane \
		--set backgroundController.tolerations[0].operator=Exists \
		--set backgroundController.tolerations[0].effect=NoSchedule \
		--set cleanupController.tolerations[0].key=node-role.kubernetes.io/control-plane \
		--set cleanupController.tolerations[0].operator=Exists \
		--set cleanupController.tolerations[0].effect=NoSchedule \
		--set reportsController.tolerations[0].key=node-role.kubernetes.io/control-plane \
		--set reportsController.tolerations[0].operator=Exists \
		--set reportsController.tolerations[0].effect=NoSchedule \
		--timeout 15m \
		--wait

kyverno-policies-apply:
	@echo "==> Applying Kyverno policies..."
	kubectl apply -f policies/kyverno/require-team-label.yaml
	kubectl apply -f policies/kyverno/enforce-namespace-naming.yaml
	kubectl apply -f policies/kyverno/scheduling-guardrail.yaml
	kubectl apply -f policies/kyverno/block-otel-optout.yaml
	kubectl apply -f policies/kyverno/mutate-namespace-pod-security.yaml
	kubectl apply -f policies/kyverno/generate-resource-quota.yaml
	kubectl apply -f policies/kyverno/generate-limit-range.yaml
	kubectl apply -f policies/kyverno/generate-network-policy.yaml
	kubectl apply -f policies/kyverno/generate-rolebinding.yaml
	kubectl apply -f policies/kyverno/generate-platform-config.yaml

cilium-policies-apply:
	@echo "==> Applying Cilium clusterwide network policies..."
	kubectl apply -f policies/cilium/clusterwide-default-deny.yaml
	kubectl apply -f policies/cilium/clusterwide-allow-gateway.yaml
	kubectl apply -f policies/cilium/clusterwide-allow-dns.yaml
	kubectl apply -f policies/cilium/clusterwide-allow-otel.yaml

policies-delete:
	kubectl delete -f policies/cilium/ --ignore-not-found
	kubectl delete -f policies/kyverno/ --ignore-not-found

# ==============================================================
# Observability
# ==============================================================

otel-deploy: otel-gateway-deploy otel-collectors-deploy

otel-gateway-deploy:
	@echo "==> Deploying OTel gateway..."
	kubectl apply -f observability/gateway/otel-gateway-config.yaml
	kubectl apply -f observability/otel-gateway-deployment.yaml
	kubectl rollout status deployment/otel-gateway -n platform-observability

otel-collectors-deploy:
	@echo "==> Deploying platform-owned team collectors..."
	kubectl apply -f observability/collectors/
	kubectl rollout status deployment/otel-collector-team-a -n platform-observability
	kubectl rollout status deployment/otel-collector-team-b -n platform-observability

otel-delete:
	kubectl delete -f observability/collectors/ --ignore-not-found
	kubectl delete -f observability/gateway/ --ignore-not-found
	kubectl delete -f observability/otel-gateway-deployment.yaml --ignore-not-found

otel-logs:
	kubectl logs -n platform-observability deploy/otel-gateway --follow

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

validate-all: validate validate-network validate-policies validate-otel

validate-network:
	@echo ""
	@echo "==> Cilium clusterwide network policies"
	kubectl get ciliumclusterwidenetworkpolicies
	@echo ""
	@echo "==> Gateway and HTTPRoutes"
	kubectl get gateway,httproute -A
	@echo ""
	@echo "==> Testing cross-team traffic (should be BLOCKED)"
	kubectl exec -n team-a-demo pod/client -- \
		curl -m 3 http://team-b-svc.team-b-demo.svc.cluster.local \
		|| echo "BLOCKED as expected"
	@echo ""
	@echo "==> Testing gateway path (should be ALLOWED)"
	GATEWAY=$$(kubectl get svc -n platform-ingress \
		-o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'); \
	docker exec kube-tenant-lab-worker curl -s http://$$GATEWAY/team-a

validate-policies:
	@echo ""
	@echo "==> Kyverno cluster policies"
	kubectl get clusterpolicies
	@echo ""
	@echo "==> Testing bad namespace no label (should be rejected)"
	kubectl apply -f policies/kyverno/test-cases/bad-namespace-no-label.yaml \
		|| echo "REJECTED as expected"
	@echo ""
	@echo "==> Testing bad namespace wrong name (should be rejected)"
	kubectl apply -f policies/kyverno/test-cases/bad-namespace-wrong-name.yaml \
		|| echo "REJECTED as expected"
	@echo ""
	@echo "==> Testing bad workload wrong node (should be rejected)"
	kubectl apply -f policies/kyverno/test-cases/bad-workload-wrong-node.yaml \
		|| echo "REJECTED as expected"
	@echo ""
	@echo "==> Testing OTel opt-out annotation (should be rejected)"
	kubectl apply -f policies/kyverno/test-cases/bad-otel-optout.yaml \
		|| echo "REJECTED as expected"

validate-otel:
	@echo ""
	@echo "==> OTel pods"
	kubectl get pods -n platform-observability -o wide
	@echo ""
	@echo "==> OTel gateway logs (last 20 lines)"
	kubectl logs -n platform-observability deploy/otel-gateway --tail=20