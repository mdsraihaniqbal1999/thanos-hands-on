# Prometheus + Thanos + Grafana: multi-cluster kind lab

This hands-on lab creates two independent three-node kind clusters. Each cluster
runs its own Prometheus and Thanos Sidecar; a Thanos Query in `thanos-demo`
federates both Store APIs. Grafana in `thanos-demo` uses that global Thanos
Query as its Prometheus-compatible data source.

The first cluster configuration preserves the supplied values exactly:
`kind.x-k8s.io/v1alpha4`, cluster name `thanos-demo`, one control-plane node,
and two workers. The second cluster repeats that topology as
`thanos-demo-west`.

## Requirements

- Docker Desktop (or a working Docker Engine)
- `kind`, `kubectl`, Helm 3, `curl`, `jq`, and `openssl`
- Enough local resources for six Kubernetes nodes and monitoring workloads

The lab uses pinned Helm chart versions and a shared Docker `kind` bridge
network. It does not modify or delete existing kind clusters. If clusters named
`thanos-demo` or `thanos-demo-west` already exist, the bootstrap script reuses
them.

## Deploy

From the repository root:

```sh
./scripts/up.sh
```

The script creates both clusters, then runs the components as separate Helm
releases/commands:

```sh
helm upgrade --install prometheus prometheus-community/prometheus \
  --kube-context kind-thanos-demo --version 29.40.1 \
  --namespace monitoring --create-namespace \
  --values helm/prometheus-east.yaml

helm upgrade --install prometheus prometheus-community/prometheus \
  --kube-context kind-thanos-demo-west --version 29.40.1 \
  --namespace monitoring --create-namespace \
  --values helm/prometheus-west.yaml

helm upgrade --install thanos thanos-community/thanos \
  --kube-context kind-thanos-demo --version 0.48.0 \
  --namespace thanos --create-namespace \
  --values helm/thanos-query.yaml

helm upgrade --install grafana grafana-community/grafana \
  --kube-context kind-thanos-demo --version 14.2.0 \
  --namespace monitoring --create-namespace \
  --values helm/grafana.yaml
```

The bootstrap adds both discovered kind-node IPs as Thanos Store API endpoints
to the Thanos Helm command. Each Prometheus Helm release also runs a Thanos
Sidecar container, sharing the Prometheus TSDB volume. A small NodePort Service
exposes only the sidecar gRPC port (`31091`) on the kind Docker network so the
Query pod in one cluster can reach the other cluster's sidecar.

The Grafana admin password is generated locally and stored in a Kubernetes
Secret; it is not checked into this repository or printed by the script. Read
it when needed with:

```sh
kubectl --context kind-thanos-demo -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

## End-to-end verification

```sh
./scripts/test.sh
```

The check verifies three nodes in each cluster, the four Helm releases and
workload rollouts, Grafana's health endpoint, both Thanos Store APIs, and
non-empty `up{cluster="east"}` and `up{cluster="west"}` query results.

## Explore

In separate terminals, forward the local web interfaces:

```sh
kubectl --context kind-thanos-demo -n thanos \
  port-forward svc/thanos-query 19090:9090
```

```sh
kubectl --context kind-thanos-demo -n monitoring \
  port-forward svc/grafana 13000:80
```

- Thanos Query: <http://127.0.0.1:19090>
- Grafana: <http://127.0.0.1:13000> (username `admin`)

In Thanos Query, try `up`, `count by (cluster) (up)`, and
`sum by (cluster) (prometheus_tsdb_head_samples_appended_total)`. In Grafana,
open **Explore**, choose the **Thanos** data source, and run the same PromQL.
The `cluster` external label distinguishes the two Prometheus installations.

## Production considerations

This is a local learning environment, not a production reference deployment:

- The Thanos Sidecars serve live Prometheus data only. There is no object
  storage, Store Gateway, or Compactor, so this lab does not demonstrate
  durable, long-term Thanos block storage. For production, configure a
  supported object store, least-privilege credentials from a secret manager,
  Store Gateway, and a single appropriately sharded Compactor per bucket.
- The Query component has one replica, and each Prometheus has one replica.
  Production availability requires redundant Prometheus replicas with unique
  replica labels, multiple Query replicas, topology-aware placement, and
  disruption budgets.
- The NodePort exists only to bridge the isolated kind Kubernetes networks.
  Do not expose unauthenticated Thanos gRPC with a public NodePort in
  production. Use private routable networking, firewall rules, TLS/mTLS, and
  narrowly scoped network policies.
- The Grafana Secret is a convenience for this local lab. Use an external
  secrets manager, rotate credentials, enable TLS and authentication, and
  restrict access to Grafana and Prometheus endpoints in production.
- Review resource requests/limits, PVC sizing and storage performance, scrape
  intervals, retention, alerting, backups, and chart/image security updates for
  your workload. The pinned versions make the lab reproducible, but should be
  deliberately upgraded and validated as part of production maintenance.

## Remove the lab

To delete only the two clusters created for this lab:

```sh
kind delete cluster --name thanos-demo
kind delete cluster --name thanos-demo-west
```
