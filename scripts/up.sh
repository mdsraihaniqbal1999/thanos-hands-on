#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

EAST_CLUSTER="thanos-demo"
WEST_CLUSTER="thanos-demo-west"
NAMESPACE="monitoring"
THANOS_NAMESPACE="thanos"
PROMETHEUS_CHART_VERSION="29.40.1"
THANOS_CHART_VERSION="0.48.0"
GRAFANA_CHART_VERSION="14.2.0"

for tool in kind kubectl helm docker curl openssl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required tool not found: %s\n' "$tool" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  printf 'Docker is not running or is not accessible.\n' >&2
  exit 1
fi

ensure_cluster() {
  local cluster="$1"
  local config="$2"
  if kind get clusters | grep -Fxq "$cluster"; then
    printf 'Using existing kind cluster %s\n' "$cluster"
  else
    kind create cluster --config "$config" --wait 5m
  fi
}

ensure_cluster "$EAST_CLUSTER" kind/thanos-demo.yaml
ensure_cluster "$WEST_CLUSTER" kind/thanos-demo-west.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add thanos-community https://thanos-community.github.io/helm-charts >/dev/null
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --kube-context "kind-$EAST_CLUSTER" \
  --version "$PROMETHEUS_CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --values helm/prometheus-east.yaml \
  --wait --timeout 10m --atomic

helm upgrade --install prometheus prometheus-community/prometheus \
  --kube-context "kind-$WEST_CLUSTER" \
  --version "$PROMETHEUS_CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --values helm/prometheus-west.yaml \
  --wait --timeout 10m --atomic

for cluster in "$EAST_CLUSTER" "$WEST_CLUSTER"; do
  kubectl --context "kind-$cluster" --namespace "$NAMESPACE" \
    apply -f k8s/thanos-sidecar-nodeport.yaml
done

east_node="thanos-demo-control-plane"
west_node="thanos-demo-west-control-plane"
east_ip="$(docker inspect --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$east_node")"
west_ip="$(docker inspect --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$west_node")"
if [[ -z "$east_ip" || -z "$west_ip" ]]; then
  printf 'Could not resolve both kind node IPs on the shared Docker network.\n' >&2
  exit 1
fi

helm upgrade --install thanos thanos-community/thanos \
  --kube-context "kind-$EAST_CLUSTER" \
  --version "$THANOS_CHART_VERSION" \
  --namespace "$THANOS_NAMESPACE" --create-namespace \
  --values helm/thanos-query.yaml \
  --set-string "query.endpoints.static[0]=${east_ip}:31091" \
  --set-string "query.endpoints.static[1]=${west_ip}:31091" \
  --wait --timeout 10m --atomic

if ! kubectl --context "kind-$EAST_CLUSTER" --namespace "$NAMESPACE" \
  get secret grafana-admin >/dev/null 2>&1; then
  grafana_password="$(openssl rand -hex 24)"
  kubectl --context "kind-$EAST_CLUSTER" --namespace "$NAMESPACE" \
    create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal="admin-password=$grafana_password"
  unset grafana_password
fi

helm upgrade --install grafana grafana-community/grafana \
  --kube-context "kind-$EAST_CLUSTER" \
  --version "$GRAFANA_CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --values helm/grafana.yaml \
  --wait --timeout 10m --atomic

cat <<EOF

Lab is installed.

Open separate terminals and run:
  kubectl --context kind-$EAST_CLUSTER -n $THANOS_NAMESPACE port-forward svc/thanos-query 19090:9090
  kubectl --context kind-$EAST_CLUSTER -n $NAMESPACE port-forward svc/grafana 13000:80

Thanos Query: http://127.0.0.1:19090
Grafana:      http://127.0.0.1:13000 (user: admin)
Grafana password:
  kubectl --context kind-$EAST_CLUSTER -n $NAMESPACE get secret grafana-admin \\
    -o jsonpath='{.data.admin-password}' | base64 --decode; echo

Run the end-to-end checks with: ./scripts/test.sh
EOF
