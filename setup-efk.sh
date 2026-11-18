#!/usr/bin/env bash
# Standalone EFK lab for a fresh Killercoda Kubernetes playground.
# Runs ONLY Spring Boot + Elasticsearch + Fluentd + Kibana (no Grafana/Prometheus/Jaeger).
set -Eeuo pipefail
trap 'echo "[ERROR] EFK setup stopped on line $LINENO. Check pod status and events below." >&2; kubectl get pods -n monitoring -o wide 2>/dev/null || true; kubectl get events -n monitoring --sort-by=.lastTimestamp 2>/dev/null | tail -n 12 || true' ERR
cd "$(dirname "${BASH_SOURCE[0]}")"
info() { printf '\n==> %s\n' "$*"; }

for bin in kubectl; do command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }; done
for file in k8s/app.yaml k8s/elasticsearch.yaml k8s/fluentd.yaml k8s/kibana.yaml; do
  [[ -f "$file" ]] || { echo "Missing $file" >&2; exit 1; }
done
kubectl cluster-info >/dev/null
info "Kubernetes context: $(kubectl config current-context)"
kubectl get nodes

info "1/4 Deploy application"
kubectl apply -f k8s/app.yaml
kubectl rollout status -n monitoring deployment/grafana-demo --timeout=240s

info "2/4 Deploy Elasticsearch (single node, no mmap)"
kubectl apply -f k8s/elasticsearch.yaml
kubectl rollout status -n monitoring deployment/elasticsearch --timeout=300s

info "3/4 Deploy Fluentd log collector"
kubectl apply -f k8s/fluentd.yaml
kubectl rollout status -n monitoring daemonset/fluentd --timeout=180s

info "4/4 Deploy Kibana"
kubectl apply -f k8s/kibana.yaml
kubectl rollout status -n monitoring deployment/kibana --timeout=300s

info "EFK status"
kubectl get pods -n monitoring -o wide
kubectl get svc -n monitoring

cat <<'NEXT'

EFK deployment requested. Verify incoming application documents before claiming success.

In a new Killercoda terminal:
  kubectl port-forward -n monitoring --address 0.0.0.0 svc/kibana 5601:5601

Open port 5601 through Killercoda Traffic / Ports.
In Kibana: Stack Management -> Data Views -> Create data view
  Name: Spring Boot logs
  Index pattern: logstash-*
  Timestamp: @timestamp
Then open Discover, select that data view, and filter recent logs for grafana-demo.

Generate a fresh application log if needed:
  kubectl run efk-log-test -n monitoring --image=curlimages/curl --restart=Never -- \
    curl -sS -X POST http://grafana-demo:8080/api/load/gc

Validate documents through Elasticsearch from a temporary curl pod:
  kubectl run es-check -n monitoring --image=curlimages/curl --restart=Never -- \
    curl -sS 'http://elasticsearch:9200/_cat/indices?v'
  kubectl logs -n monitoring es-check

If any pods are Pending or CrashLoopBackOff, send output of:
  kubectl get pods -n monitoring -o wide
  kubectl get events -n monitoring --sort-by=.lastTimestamp | tail -n 15
NEXT
