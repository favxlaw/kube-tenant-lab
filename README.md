# kube-tenant-lab

A local multi-tenant Kubernetes platform built on Minikube. Simulates a shared cluster used by two application teams — `team-a` and `team-b` — with workload isolation, policy enforcement, secure network defaults, controlled ingress, and centralized observability.

---

## Stack

| Component | Role |
|---|---|
| Minikube | Local 3-node cluster using Docker driver |
| Cilium | CNI + eBPF-based network policy enforcement |
| Gateway API | Shared ingress routing via GatewayClass, Gateway, and HTTPRoute |
| Kyverno | Admission policy enforcement |
| OpenTelemetry | Centralized logs and metrics collection |

---

## Cluster Layout

| Node | Role Label | Taint | Purpose |
|---|---|---|---|
| minikube | role=system | none | Control plane + platform components |
| minikube-m02 | role=team-a | team=team-a:NoSchedule | team-a workloads only |
| minikube-m03 | role=team-b | team=team-b:NoSchedule | team-b workloads only |

Workload isolation is enforced at the scheduler level using node labels, taints, and tolerations. A team-a pod carries a `nodeSelector` pointing to `role=team-a` and a toleration for the taint on `minikube-m02`. Without both, the scheduler rejects the node. Team nodes are mutually exclusive by design.

---

## Namespace Topology

| Namespace | Owner | Purpose |
|---|---|---|
| team-a-demo | team-a | team-a application workloads |
| team-b-demo | team-b | team-b application workloads |
| platform-ingress | platform | Gateway and HTTPRoute resources |
| platform-observability | platform | OTel collectors and telemetry backend |

---

## Repository Structure

```
kube-tenant-lab/
├── Makefile
├── README.md
├── namespaces/
│   ├── team-a-demo.yaml
│   ├── team-b-demo.yaml
│   ├── platform-ingress.yaml
│   └── platform-observability.yaml
├── apps/
│   ├── team-a/
│   │   └── app.yaml
│   └── team-b/
│       └── app.yaml
└── gateway/
    ├── gateway.yaml
    └── httproutes.yaml
```

---

## Prerequisites

The following tools must be installed before running any make targets:

- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [cilium-cli](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)

---

## Setup

All setup is driven through the Makefile. Run targets one at a time on a resource-constrained machine to avoid overloading the system during image pulls.

### 1. Start the cluster

```bash
make cluster-start
```

Starts a 3-node Minikube cluster using the Docker driver. Kubernetes version and resource limits are pinned in the Makefile variables. Once complete, verify all nodes are present:

```bash
kubectl get nodes
```

Expected output:

```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   Xm    v1.34.0
minikube-m02   Ready    <none>          Xm    v1.34.0
minikube-m03   Ready    <none>          Xm    v1.34.0
```

All three nodes must show the same Kubernetes version before proceeding.

### 2. Install Cilium

```bash
make cilium-install
```

Installs Gateway API CRDs first, then installs Cilium via Helm into `kube-system`. Cilium runs as a DaemonSet — one agent pod per node. Each agent loads eBPF programs into that node's kernel and takes over pod networking.

Gateway API CRDs are installed before Cilium because Cilium's Gateway controller looks for those resource definitions at startup. If the CRDs are missing, the controller fails silently.

Monitor progress in a separate terminal:

```bash
kubectl get pods -n kube-system -w
```

Wait until all `cilium-*` agent pods show `Running` before proceeding. CoreDNS will show `CrashLoopBackOff` during this phase — this is expected and self-heals once Cilium is up.

### 3. Configure nodes

```bash
make configure-nodes
```

Labels and taints all three nodes to establish scheduling domains:

```bash
# Verify labels and taints
kubectl get nodes --show-labels
kubectl describe node minikube-m02 | grep Taints
kubectl describe node minikube-m03 | grep Taints
```

### 4. Validate Day 1

```bash
make validate
```

Runs a set of checks confirming the cluster, Cilium agents, and node configuration are all healthy.

---

## Deploying the Platform

Once the cluster is healthy, apply manifests in this order.

### Apply namespaces

```bash
kubectl apply -f namespaces/
```

### Deploy applications

```bash
kubectl apply -f apps/team-a/app.yaml
kubectl apply -f apps/team-b/app.yaml
```

Verify pods are scheduled to the correct nodes:

```bash
kubectl get pods -n team-a-demo -o wide
kubectl get pods -n team-b-demo -o wide
```

The `NODE` column must show `minikube-m02` for team-a and `minikube-m03` for team-b.

### Apply Gateway resources

```bash
kubectl apply -f gateway/gateway.yaml
kubectl apply -f gateway/httproutes.yaml
```

Verify the Gateway receives an address:

```bash
kubectl get gateway -n platform-ingress
```

Expected output:

```
NAME               CLASS    ADDRESS        PROGRAMMED   AGE
platform-gateway   cilium   <ip-address>   True         Xm
```

The `PROGRAMMED: True` status confirms Cilium has successfully provisioned the entry point and programmed the routing rules.

### Access the applications

In a separate terminal, run:

```bash
minikube tunnel
```

Then in your main terminal:

```bash
GATEWAY=$(kubectl get gateway platform-gateway -n platform-ingress -o jsonpath='{.status.addresses[0].value}')

curl http://$GATEWAY/team-a
curl http://$GATEWAY/team-b
```

Expected responses:

```
hello from team-a
hello from team-b
```

---

## Makefile Reference

| Target | Description |
|---|---|
| `make all` | Full setup in order: cluster, Cilium, node config, validate |
| `make cluster-start` | Start 3-node Minikube cluster |
| `make cluster-delete` | Tear down the cluster |
| `make cilium-install` | Install Gateway API CRDs and Cilium CNI via Helm |
| `make cilium-status` | Check Cilium agent health |
| `make configure-nodes` | Label and taint nodes for workload isolation |
| `make validate` | Verify cluster, nodes, and Cilium are healthy |

---

## How a Request Flows Through the Platform

```
curl http://gateway-ip/team-a
↓
Gateway IP (provisioned by Cilium from LoadBalancer Service)
↓
Cilium eBPF intercepts packet, routes to Envoy proxy
↓
Envoy checks HTTPRoute rules: /team-a → team-a-svc
↓
Cilium network policy check: is this traffic allowed?
↓
Request reaches team-a-app pod on minikube-m02
↓
hashicorp/http-echo responds: "hello from team-a"
```

---

## Trade-offs and Simplifications

| Decision | What was simplified | Production alternative |
|---|---|---|
| `minikube tunnel` | Not a real load balancer, requires a background process | Cloud provider LoadBalancer or MetalLB on bare metal |
| `kubeProxyReplacement=false` | Cilium and kube-proxy coexist, losing full eBPF Service routing | Full kube-proxy replacement with additional Minikube start flags |
| `hashicorp/http-echo` | Minimal app with no real business logic | Any real application workload |
| No TLS on Gateway | HTTP only, no certificate management | cert-manager with Let's Encrypt or internal CA |
| `allowedRoutes.namespaces.from: All` | Any namespace can attach routes to the Gateway | Restrict with a namespace label selector |
| Docker driver for Minikube | Nodes are containers, not real VMs | Bare metal or cloud nodes for production |

---

## Validation Commands

```bash
# Cluster and nodes
kubectl get nodes --show-labels
kubectl get pods -A -o wide

# Cilium
kubectl -n kube-system get pods -l k8s-app=cilium
cilium status

# Gateway
kubectl get gateway,httproute -A

# Applications
kubectl get pods -n team-a-demo -o wide
kubectl get pods -n team-b-demo -o wide

# Traffic
GATEWAY=$(kubectl get gateway platform-gateway -n platform-ingress -o jsonpath='{.status.addresses[0].value}')
curl http://$GATEWAY/team-a
curl http://$GATEWAY/team-b
```