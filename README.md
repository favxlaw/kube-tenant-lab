# kube-tenant-lab

A local multi-tenant Kubernetes platform built on KIND (Kubernetes IN Docker).
Simulates a shared cluster used by two application teams — `team-a` and `team-b` —
with workload isolation, policy enforcement, secure network defaults,
controlled ingress, and centralized observability.

---

## Stack

| Component | Role |
|---|---|
| KIND | Local 3-node cluster using Docker containers as nodes |
| Cilium | CNI + eBPF-based network policy enforcement + Gateway API controller |
| Gateway API | Shared ingress routing via GatewayClass, Gateway, and HTTPRoute |
| Kyverno | Admission webhook policy enforcement |
| OpenTelemetry | Centralized logs, metrics, and trace collection |

---

## Cluster Layout

| Node | Role Label | Taint | Purpose |
|---|---|---|---|
| kube-tenant-lab-control-plane | role=system | none | Control plane + platform components |
| kube-tenant-lab-worker | role=team-a | team=team-a:NoSchedule | team-a workloads only |
| kube-tenant-lab-worker2 | role=team-b | team=team-b:NoSchedule | team-b workloads only |

Workload isolation is enforced at the scheduler level using node labels,
taints, and tolerations. A team-a pod carries a `nodeSelector` pointing
to `role=team-a` and a toleration for the taint on `kube-tenant-lab-worker`.
Without both, the scheduler rejects the node. Team nodes are mutually
exclusive by design.

---

## Namespace Topology

| Namespace | Owner | Purpose |
|---|---|---|
| team-a-demo | team-a | team-a application workloads |
| team-b-demo | team-b | team-b application workloads |
| platform-ingress | platform | Gateway and HTTPRoute resources |
| platform-observability | platform | OTel collectors and telemetry backend |
| kyverno | platform | Kyverno admission controller |

---

## Repository Structure

```
kube-tenant-lab/
├── Makefile
├── README.md
├── kind-config.yaml
├── namespaces/
│   ├── team-a-demo.yaml
│   ├── team-b-demo.yaml
│   ├── platform-ingress.yaml
│   └── platform-observability.yaml
├── apps/
│   ├── src/
│   │   ├── main.go
│   │   ├── go.mod
│   │   ├── go.sum
│   │   └── Dockerfile
│   ├── team-a/
│   │   └── app.yaml
│   └── team-b/
│       └── app.yaml
├── gateway/
│   ├── gateway.yaml
│   └── httproutes.yaml
├── policies/
│   ├── kyverno/
│   │   ├── require-team-label.yaml
│   │   ├── enforce-namespace-naming.yaml
│   │   ├── scheduling-guardrail.yaml
│   │   ├── block-otel-optout.yaml
│   │   └── test-cases/
│   │       ├── bad-namespace-no-label.yaml
│   │       ├── bad-namespace-wrong-name.yaml
│   │       ├── bad-workload-wrong-node.yaml
│   │       └── bad-otel-optout.yaml
│   └── cilium/
│       ├── default-deny-team-a.yaml
│       ├── default-deny-team-b.yaml
│       ├── allow-gateway-team-a.yaml
│       ├── allow-gateway-team-b.yaml
│       └── allow-dns.yaml
└── observability/
    ├── otel-collector-config-agent.yaml
    ├── otel-agent-daemonset.yaml
    ├── otel-collector-config-gateway.yaml
    └── otel-gateway-deployment.yaml
```

---

## Prerequisites

Install the following tools before running any make targets:

- [Docker](https://docs.docker.com/get-docker/)
- [KIND](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [cilium-cli](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)

Verify all tools are available:

```bash
docker version
kind version
kubectl version --client
helm version
cilium version
```

---

## Architecture

This platform enforces multi-tenancy through three independent layers.
Each layer catches a different class of violation.

```
Layer 1 — Scheduling
  Node taints + pod tolerations + nodeSelector
  Prevents team-a pods landing on team-b nodes at placement time

Layer 2 — Policy (Kyverno)
  Admission webhook intercepts every API server request
  Rejects namespaces without team labels
  Rejects namespaces with wrong naming convention
  Rejects workloads targeting the wrong team node
  Rejects pods opting out of log collection

Layer 3 — Network (Cilium)
  eBPF identity-based default-deny posture
  Pods cannot communicate unless explicitly allowed
  Only the Gateway path is open to team workloads
  DNS egress is the only other permitted flow
```

Removing any one layer leaves a gap the other two cannot cover.

---

## How a Request Flows Through the Platform

```
curl http://<gateway-ip>/team-a
        ↓
Gateway IP — LoadBalancer Service provisioned by Cilium
        ↓
Cilium eBPF intercepts packet at the node network stack
Routes to embedded Envoy proxy
        ↓
Envoy checks routing table programmed from HTTPRoute team-a-route
Path /team-a matches → forward to team-a-svc:80
        ↓
Cilium eBPF translates ClusterIP to pod IP, checks network policy
Policy: allow ingress from platform-ingress on port 8080
        ↓
Request reaches team-a-app container on kube-tenant-lab-worker
Go HTTP server handles request
OTel SDK generates trace_id, increments http_requests_total counter
Structured JSON log written to stdout
        ↓
OTel agent on same node reads log from /var/log/pods/
Forwards to OTel gateway in platform-observability
        ↓
Response returns through Envoy to curl
```

---

## Setup

All setup is driven through the Makefile.
Run targets individually on resource-constrained machines.

### 1. Start the cluster

```bash
make cluster-start
```

Creates a 3-node KIND cluster from `kind-config.yaml`.
Nodes are pre-labeled from the config file.
CNI is disabled — Cilium is installed in the next step.

Verify:

```bash
kubectl get nodes --show-labels
```

Expected:

```
NAME                            STATUS     ROLES           VERSION
kube-tenant-lab-control-plane   NotReady   control-plane   v1.35.0
kube-tenant-lab-worker          NotReady   <none>          v1.35.0
kube-tenant-lab-worker2         NotReady   <none>          v1.35.0
```

`NotReady` is expected — no CNI yet. All nodes must show the same version.

### 2. Install Cilium

```bash
make cilium-install
```

Installs experimental Gateway API CRDs first — Cilium 1.15.5 requires
`tlsroutes` which is only in the experimental channel.
Then installs Cilium via Helm with Gateway API and Hubble enabled.

Monitor in a second terminal:

```bash
kubectl get pods -n kube-system -w
```

Wait until all three `cilium-*` agent pods show `Running`.

Verify:

```bash
cilium status
```

All components must show `OK` before proceeding.

### 3. Configure nodes

```bash
make configure-nodes
```

Applies taints to team nodes. Labels are already set from `kind-config.yaml`.

Verify:

```bash
kubectl describe node kube-tenant-lab-worker | grep Taints
kubectl describe node kube-tenant-lab-worker2 | grep Taints
```

### 4. Validate cluster

```bash
make validate
```

### 5. Build and load application image

```bash
make image-push
```

Builds the Go HTTP server and loads it into all 3 KIND nodes.
No registry required — KIND loads images directly into its internal containerd.

Verify:

```bash
docker images | grep tenant-app
```

### 6. Deploy the platform

```bash
make platform-deploy
```

Applies namespaces, deploys both team applications, and creates
Gateway and HTTPRoute resources in order.

Verify pod placement:

```bash
kubectl get pods -A -o wide
```

team-a-app must be on `kube-tenant-lab-worker`.
team-b-app must be on `kube-tenant-lab-worker2`.

Verify Gateway is programmed:

```bash
kubectl get gateway -n platform-ingress
```

`PROGRAMMED` must show `True` and `ADDRESS` must have an IP.

Test routing:

```bash
GATEWAY=$(kubectl get gateway platform-gateway \
  -n platform-ingress \
  -o jsonpath='{.status.addresses[0].value}')

curl http://$GATEWAY/team-a
curl http://$GATEWAY/team-b
```

Expected responses:

```json
{"message":"hello from team-a","team":"team-a","namespace":"team-a-demo","trace_id":"..."}
{"message":"hello from team-b","team":"team-b","namespace":"team-b-demo","trace_id":"..."}
```

### 7. Deploy policies

```bash
make policies-deploy
```

Installs Kyverno via Helm then applies all four ClusterPolicies
and all Cilium network policies.

### 8. Deploy observability

```bash
make otel-deploy
```

Deploys OTel gateway first, then OTel agents.
Gateway must be ready before agents start to avoid connection errors on startup.

---

## Makefile Reference

| Target | Description |
|---|---|
| `make cluster-start` | Start 3-node KIND cluster |
| `make cluster-delete` | Tear down the cluster |
| `make cilium-install` | Install Gateway API CRDs and Cilium CNI |
| `make cilium-status` | Check Cilium health |
| `make configure-nodes` | Taint nodes for workload isolation |
| `make image-push` | Build Go app image and load into KIND |
| `make platform-deploy` | Deploy namespaces, apps, and gateway |
| `make policies-deploy` | Install Kyverno and apply all policies |
| `make otel-deploy` | Deploy OTel agent and gateway |
| `make validate` | Verify cluster, Cilium, and node config |
| `make validate-all` | Run all validation checks |
| `make validate-network` | Test Cilium policies and cross-team traffic |
| `make validate-policies` | Test Kyverno policy rejections |
| `make validate-otel` | Check OTel pods and gateway logs |
| `make platform-delete` | Remove all platform resources |
| `make otel-delete` | Remove OTel resources |
| `make otel-logs` | Stream OTel gateway logs |

---

## Validation

### Cluster and scheduling

```bash
kubectl get nodes --show-labels
kubectl get pods -A -o wide
kubectl -n kube-system get pods -l k8s-app=cilium
cilium status
```

### Gateway

```bash
kubectl get gateway,httproute -A

GATEWAY=$(kubectl get gateway platform-gateway \
  -n platform-ingress \
  -o jsonpath='{.status.addresses[0].value}')

curl http://$GATEWAY/team-a
curl http://$GATEWAY/team-b
```

### Kyverno policies

```bash
kubectl get clusterpolicies

# Each of these must be rejected
kubectl apply -f policies/kyverno/test-cases/bad-namespace-no-label.yaml
kubectl apply -f policies/kyverno/test-cases/bad-namespace-wrong-name.yaml
kubectl apply -f policies/kyverno/test-cases/bad-workload-wrong-node.yaml
kubectl apply -f policies/kyverno/test-cases/bad-otel-optout.yaml
```

### Cilium network policies

```bash
kubectl get ciliumnetworkpolicies -A

# Must be blocked
kubectl exec -n team-a-demo deploy/team-a-app -- \
  wget -qO- --timeout=3 \
  http://team-b-svc.team-b-demo.svc.cluster.local \
  || echo "BLOCKED as expected"
```

### Observability

```bash
kubectl get pods -n platform-observability -o wide
kubectl logs -n platform-observability deploy/otel-gateway --tail=20
```

---

## Trade-offs and Simplifications

| Decision | Simplification | Production alternative |
|---|---|---|
| KIND instead of cloud | Nodes are Docker containers, not real VMs | Cloud provider managed nodes |
| No LoadBalancer | KIND assigns IPs from Docker network — not externally routable | MetalLB on bare metal, cloud LB on cloud |
| `kubeProxyReplacement=false` | Cilium and kube-proxy coexist | Full kube-proxy replacement |
| Experimental Gateway API CRDs | Required by Cilium 1.15.5 for tlsroutes | Standard channel sufficient on Cilium 1.16+ |
| debug exporter for OTel | Telemetry printed to stdout only | Prometheus, Loki, Jaeger backends |
| No TLS on Gateway | HTTP only | cert-manager with Let's Encrypt |
| `allowedRoutes.from: All` | Any namespace can attach to Gateway | Namespace label selector |
| Single OTel gateway replica | No high availability | Multiple replicas with load balancing |
```

