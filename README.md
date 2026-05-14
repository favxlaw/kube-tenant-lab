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
| Kyverno | Admission webhook policy enforcement + resource generation |
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

| Namespace | Owner | Pod Security | Purpose |
|---|---|---|---|
| team-a-demo | team-a | restricted | team-a application workloads |
| team-b-demo | team-b | restricted | team-b application workloads |
| platform-ingress | platform | baseline | Gateway and HTTPRoute resources |
| platform-observability | platform | privileged | OTel collectors and telemetry backend |
| kyverno | platform | baseline | Kyverno admission controller |

---

## Repository Structure

```
kube-tenant-lab/
├── Makefile
├── README.md
├── kind-config.yaml
├── test-client.yaml
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
├── rbac/
│   ├── platform-readonly-clusterrole.yaml
│   ├── platform-readonly-clusterrolebinding.yaml
│   ├── team-serviceaccount.yaml
│   └── kyverno-background-controller-permissions.yaml
├── policies/
│   ├── kyverno/
│   │   ├── require-team-label.yaml
│   │   ├── enforce-namespace-naming.yaml
│   │   ├── scheduling-guardrail.yaml
│   │   ├── block-otel-optout.yaml
│   │   ├── mutate-namespace-pod-security.yaml
│   │   ├── generate-resource-quota.yaml
│   │   ├── generate-limit-range.yaml
│   │   ├── generate-network-policy.yaml
│   │   ├── generate-rolebinding.yaml
│   │   ├── generate-platform-config.yaml
│   │   └── test-cases/
│   │       ├── bad-namespace-no-label.yaml
│   │       ├── bad-namespace-wrong-name.yaml
│   │       ├── bad-workload-wrong-node.yaml
│   │       └── bad-otel-optout.yaml
│   └── cilium/
│       ├── clusterwide-default-deny.yaml
│       ├── clusterwide-allow-gateway.yaml
│       ├── clusterwide-allow-dns.yaml
│       └── clusterwide-allow-otel.yaml
└── observability/
    ├── otel-gateway-deployment.yaml
    ├── gateway/
    │   └── otel-gateway-config.yaml
    └── collectors/
        ├── team-a-collector.yaml
        └── team-b-collector.yaml
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
  Admission webhook intercepts every API server request before etcd
  Validate rules reject bad resources immediately
  Mutate rules add pod security labels automatically
  Generate rules provision ResourceQuota, LimitRange, NetworkPolicy,
  RoleBinding, and platform ConfigMap into every new team namespace

Layer 3 — Network (Cilium)
  CiliumClusterwideNetworkPolicy with label-based selectors
  Covers all team namespaces automatically without hardcoding names
  eBPF identity-based default-deny posture
  Only Gateway ingress, DNS egress, and OTel egress are explicitly allowed
```

Removing any one layer leaves a gap the other two cannot cover.

---

## Platform Contract

When any namespace with a `team` label is created, the following are
automatically provisioned by Kyverno generate rules with no manual action:

| Resource | Purpose |
|---|---|
| ResourceQuota | Total CPU, memory, and object budget per namespace |
| LimitRange | Per-container resource defaults and ceiling |
| NetworkPolicy | Default-deny for both ingress and egress |
| RoleBinding | Team group gets edit access to their own namespace only |
| platform-config ConfigMap | Platform metadata for auditing and tooling |

Cilium clusterwide policies automatically cover all team namespaces
the moment they are created via label-based endpoint selectors.

The only resources requiring manual platform action per new team are
the OTel collector Deployment and the team's HTTPRoute.

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
CiliumClusterwideNetworkPolicy: allow ingress from reserved:ingress on port 8080
        ↓
Request reaches team-a-app container on kube-tenant-lab-worker
Go HTTP server handles request
OTel SDK generates trace_id, increments http_requests_total counter
Structured JSON log written to stdout
        ↓
otel-collector-team-a in platform-observability reads log from
/var/log/pods/team-a-demo_* on the node filesystem
Tags record: team=team-a, namespace=team-a-demo, platform=kube-tenant-lab
Forwards to otel-gateway in platform-observability
        ↓
Response returns through Envoy to curl
```

---

## Setup

All setup is driven through the Makefile.
Run targets individually on resource-constrained machines.

### Important — Correct Setup Order

Policies must be deployed before namespaces are created.
Kyverno generate rules only fire on namespace creation.
If namespaces exist before policies, delete and recreate them.

```
make cluster-start
make cilium-install
make configure-nodes
make validate
make image-push
make policies-deploy     ← policies before platform
make platform-deploy     ← namespaces created after policies exist
make test-clients-deploy
make otel-deploy
```

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
Uses `helm upgrade --install` for idempotency.

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

### 6. Deploy policies

```bash
make policies-deploy
```

Must run before `platform-deploy`. Kyverno generate rules only fire on
namespace creation. Policies must exist first.

Installs Kyverno via Helm with control plane tolerations, applies all
Kyverno ClusterPolicies, all RBAC resources, and all
CiliumClusterwideNetworkPolicies.

Verify:

```bash
kubectl get clusterpolicies
kubectl get ciliumclusterwidenetworkpolicies
```

### 7. Deploy the platform

```bash
make platform-deploy
```

Applies namespaces, RBAC, deploys both team applications, and creates
Gateway and HTTPRoute resources in order.

When namespaces are created, Kyverno automatically generates:
ResourceQuota, LimitRange, NetworkPolicy, RoleBinding, and platform-config.

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

To get the Gateway IP, `cloud-provider-kind` must be running in a
separate terminal:

```bash
sudo $(go env GOPATH)/bin/cloud-provider-kind
```

Test routing from inside the KIND network:

```bash
GATEWAY=$(kubectl get svc -n platform-ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-a
docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-b
```

Expected responses:

```json
{"message":"hello from team-a","team":"team-a","namespace":"team-a-demo","trace_id":"..."}
{"message":"hello from team-b","team":"team-b","namespace":"team-b-demo","trace_id":"..."}
```

### 8. Deploy test clients

```bash
make test-clients-deploy
```

Deploys a curl client pod in each team namespace for network policy
validation. Pods comply with the restricted pod security standard.

### 9. Deploy observability

```bash
make otel-deploy
```

Deploys the OTel gateway first, then the platform-owned per-team collectors.

OTel collectors run in `platform-observability` under `privileged` pod
security because they require `hostPath` to read node log files.
Each collector is scoped to only one team's namespace log paths.
Teams have no RBAC access to `platform-observability` and cannot modify
or delete their collector.

Verify all pods are running:

```bash
kubectl get pods -n platform-observability -o wide
```

Expected:

```
NAME                                   READY   NODE
otel-gateway-xxx                       1/1     control-plane
otel-collector-team-a-xxx              1/1     kube-tenant-lab-worker
otel-collector-team-b-xxx              1/1     kube-tenant-lab-worker2
```

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
| `make policies-deploy` | Install Kyverno, RBAC, and apply all policies |
| `make platform-deploy` | Deploy namespaces, RBAC, apps, and gateway |
| `make test-clients-deploy` | Deploy curl client pods for validation |
| `make otel-deploy` | Deploy OTel gateway and team collectors |
| `make validate` | Verify cluster, Cilium, and node config |
| `make validate-all` | Run all validation checks |
| `make validate-network` | Test Cilium policies and cross-team traffic |
| `make validate-policies` | Test Kyverno policy rejections |
| `make validate-otel` | Check OTel pods and gateway logs |
| `make rbac-apply` | Apply RBAC resources only |
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

GATEWAY=$(kubectl get svc -n platform-ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-a
docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-b
```

### Kyverno policies

```bash
kubectl get clusterpolicies

# Each of these must produce a Kyverno rejection error
kubectl apply -f policies/kyverno/test-cases/bad-namespace-no-label.yaml
kubectl apply -f policies/kyverno/test-cases/bad-namespace-wrong-name.yaml
kubectl apply -f policies/kyverno/test-cases/bad-workload-wrong-node.yaml
kubectl apply -f policies/kyverno/test-cases/bad-otel-optout.yaml
```

### Kyverno auto-generated resources

Verify Kyverno generates the full platform contract on namespace creation:

```bash
kubectl get resourcequota,limitrange,networkpolicy -n team-a-demo
kubectl get rolebinding -n team-a-demo
kubectl get configmap platform-config -n team-a-demo
```

### Cilium network policies

```bash
kubectl get ciliumclusterwidenetworkpolicies

# Cross-team traffic must be blocked
kubectl exec -n team-a-demo pod/client -- \
  curl -m 3 http://team-b-svc.team-b-demo.svc.cluster.local \
  || echo "BLOCKED as expected"

# Gateway path must be allowed
GATEWAY=$(kubectl get svc -n platform-ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-a
```

### Observability

```bash
kubectl get pods -n platform-observability -o wide

# Generate traffic first
docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-a
docker exec kube-tenant-lab-worker curl -s http://$GATEWAY/team-b

# Check gateway logs — must show team and namespace attributes
kubectl logs -n platform-observability deploy/otel-gateway --tail=30
```

Logs must contain `team: team-a` or `team: team-b` and
`platform: kube-tenant-lab` on every record.

### Hubble UI

Port-forward in a separate terminal:

```bash
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
```

Open `http://localhost:12000` in your browser.
Select `team-a-demo` or `team-b-demo` from the namespace dropdown.
Generate traffic and observe allowed and dropped flows in real time.

---

## Trade-offs and Simplifications

| Decision | Simplification | Production alternative |
|---|---|---|
| KIND instead of cloud | Nodes are Docker containers, not real VMs | Cloud provider managed nodes |
| Gateway IP not routable from host | KIND Docker network IPs unreachable from laptop, must use docker exec | MetalLB or cloud provider assigns externally routable IPs |
| cloud-provider-kind required | Must run manually in background for LoadBalancer IP assignment | Cloud provider handles this automatically |
| `kubeProxyReplacement=false` | Cilium and kube-proxy coexist | Full kube-proxy replacement |
| Experimental Gateway API CRDs | Required by Cilium 1.15.5 for tlsroutes | Standard channel sufficient on Cilium 1.16+ |
| Kyverno on control-plane only | Team node taints prevent Kyverno scheduling on worker nodes | Dedicated platform nodes with explicit tolerations |
| debug exporter for OTel | Telemetry printed to stdout only | Prometheus, Loki, Jaeger backends |
| No TLS on Gateway | HTTP only | cert-manager with Let's Encrypt |
| `allowedRoutes.from: All` | Any namespace can attach to Gateway | Namespace label selector |
| Single OTel gateway replica | No high availability | Multiple replicas with load balancing |
| OTel collectors are static per team | New teams require a platform engineer to manually deploy a collector in platform-observability | OTel Operator watches for new namespaces and provisions collectors automatically |
| OTel collectors in platform-observability | hostPath volumes required for log reading violate restricted pod security in team namespaces | OTel Operator handles privilege escalation cleanly outside team namespaces |
| reserved:ingress for Gateway allow | Cilium embedded Envoy uses ingress identity not namespace identity | Dedicated Envoy DaemonSet with explicit namespace identity |
| require-team-label excludes system namespaces by name | Small hardcoded list for known system namespaces | Label-based system namespace identification |
```