# kube-tenant-lab

A local multi-tenant Kubernetes platform built on Minikube.

Simulates a shared cluster used by two application teams — `team-a` and `team-b` — with workload isolation, policy enforcement, secure network defaults, controlled ingress, and centralized observability.

## Stack

| Component | Role |
|---|---|
| Minikube | Local 3-node cluster |
| Cilium | CNI + network policy enforcement |
| Gateway API | Ingress routing |
| Kyverno | Policy enforcement |
| OpenTelemetry | Logs and metrics collection |

## Cluster Layout

| Node | Purpose |
|---|---|
| node-1 | team-a workloads |
| node-2 | team-b workloads |
| node-3 | shared platform components |

## Structurekube-tenant-lab/
├── README.md
└── cluster/
├── start-cluster.sh
└── configure-nodes.sh

> Setup instructions, validation commands, architecture notes, and trade-offs will be added as the platform is built out.