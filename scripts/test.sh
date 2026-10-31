#!/usr/bin/env bash
set -euo pipefail

EAST_CONTEXT="kind-thanos-demo"
WEST_CONTEXT="kind-thanos-demo-west"
NAMESPACE="monitoring"
THANOS_NAMESPACE="thanos"
QUERY_PORT=19090
GRAFANA_PORT=13000

for context in "$EAST_CONTEXT" "$WEST_CONTEXT"; do
  node_count="$(kubectl --context "$context" get nodes --no-headers | wc -l | tr -d ' ')"
  if [[ "$node_count" != "3" ]]; then
    printf '%s should have 3 kind nodes; found %s\n' "$context" "$node_count" >&2
    exit 1
  fi
done

helm status prometheus --kube-context "$EAST_CONTEXT" --namespace "$NAMESPACE" >/dev/null
helm status prometheus --kube-context "$WEST_CONTEXT" --namespace "$NAMESPACE" >/dev/null
helm status thanos --kube-context "$EAST_CONTEXT" --namespace "$THANOS_NAMESPACE" >/dev/null
helm status grafana --kube-context "$EAST_CONTEXT" --namespace "$NAMESPACE" >/dev/null

kubectl --context "$EAST_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/prometheus-server --timeout=3m
kubectl --context "$WEST_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/prometheus-server --timeout=3m
kubectl --context "$EAST_CONTEXT" --namespace "$THANOS_NAMESPACE" \
  rollout status deployment/thanos-query --timeout=3m
kubectl --context "$EAST_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/grafana --timeout=3m

tmp_dir="$(mktemp -d)"
query_log="$tmp_dir/query-port-forward.log"
grafana_log="$tmp_dir/grafana-port-forward.log"
query_pid=""
grafana_pid=""
cleanup() {
  if [[ -n "$query_pid" ]]; then
    kill "$query_pid" 2>/dev/null || true
  fi
  if [[ -n "$grafana_pid" ]]; then
    kill "$grafana_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

kubectl --context "$EAST_CONTEXT" --namespace "$THANOS_NAMESPACE" \
  port-forward "svc/thanos-query" "$QUERY_PORT:9090" >"$query_log" 2>&1 &
query_pid=$!
kubectl --context "$EAST_CONTEXT" --namespace "$NAMESPACE" \
  port-forward "svc/grafana" "$GRAFANA_PORT:80" >"$grafana_log" 2>&1 &
grafana_pid=$!

wait_for_url() {
  local url="$1"
  local log="$2"
  for _ in $(seq 1 60); do
    if curl --fail --silent "$url" >/dev/null; then
      return 0
    fi
    if ! kill -0 "$query_pid" 2>/dev/null && [[ "$log" == "$query_log" ]]; then
      cat "$log" >&2
      return 1
    fi
    sleep 1
  done
  cat "$log" >&2
  printf 'Timed out waiting for %s\n' "$url" >&2
  return 1
}

wait_for_url "http://127.0.0.1:$QUERY_PORT/-/healthy" "$query_log"
wait_for_url "http://127.0.0.1:$GRAFANA_PORT/api/health" "$grafana_log"

for cluster in east west; do
  result="$(
    curl --fail --silent --show-error --get \
      "http://127.0.0.1:$QUERY_PORT/api/v1/query" \
      --data-urlencode "query=up{cluster=\"$cluster\"}"
  )"
  if ! jq -e --arg cluster "$cluster" \
    '.status == "success" and (.data.result | length > 0) and all(.data.result[]; .metric.cluster == $cluster)' \
    <<<"$result" >/dev/null; then
    printf 'Thanos did not return healthy Prometheus series for cluster %s:\n%s\n' \
      "$cluster" "$result" >&2
    exit 1
  fi
  printf 'Thanos Query returned live series for cluster %s.\n' "$cluster"
done

stores="$(
  curl --fail --silent --show-error \
    "http://127.0.0.1:$QUERY_PORT/api/v1/stores"
)"
if ! jq -e '.status == "success" and (.data | length >= 2)' <<<"$stores" >/dev/null; then
  printf 'Expected Thanos Query to discover both Store API endpoints:\n%s\n' "$stores" >&2
  exit 1
fi

printf 'Grafana health endpoint is healthy and Thanos has both Store API endpoints.\n'
