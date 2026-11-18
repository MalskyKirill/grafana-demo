#!/usr/bin/env bash
# Restore the minimal monitoring stack in a fresh Killercoda Kubernetes playground.
# Deliberately excludes Jaeger, Elasticsearch, Fluentd and Kibana.
set -Eeuo pipefail

trap 'echo "[ERROR] setup.sh failed on line $LINENO. Check the output above." >&2' ERR

cd "$(dirname "${BASH_SOURCE[0]}")"

info() { printf '\n==> %s\n' "$*"; }

info "Checking prerequisites"
for cmd in kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $cmd" >&2
    exit 1
  fi
done

for file in k8s/app.yaml k8s/prometheus.yaml k8s/grafana-values.yaml k8s/dashboards/java-application-monitoring.json; do
  if [[ ! -f "$file" ]]; then
    echo "[ERROR] Missing $file. Run this script from a full grafana-demo checkout." >&2
    exit 1
  fi
done

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "[ERROR] Cannot reach Kubernetes with the current kubectl context." >&2
  exit 1
fi

info "Current Kubernetes context: $(kubectl config current-context)"
echo "This script creates/updates resources in the CURRENT cluster, namespace monitoring."
kubectl get nodes

info "1/3: Deploying Spring Boot application"
kubectl apply -f k8s/app.yaml
kubectl rollout status deployment/grafana-demo --namespace monitoring --timeout=240s

info "2/3: Deploying Prometheus"
kubectl apply -f k8s/prometheus.yaml
kubectl rollout status deployment/prometheus --namespace monitoring --timeout=240s

info "Provisioning JVM dashboard as a Kubernetes ConfigMap"
kubectl create configmap java-monitoring-dashboard \
  --namespace monitoring \
  --from-file=java-application-monitoring.json=k8s/dashboards/java-application-monitoring.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap java-monitoring-dashboard -n monitoring grafana_dashboard=1 --overwrite

info "3/3: Installing Grafana through Helm"
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
helm repo update grafana-community
helm upgrade --install grafana grafana-community/grafana \
  --namespace monitoring \
  --values k8s/grafana-values.yaml \
  --wait --timeout 5m

info "Deployment status"
kubectl get pods -n monitoring -o wide
kubectl get services -n monitoring

cat <<'NEXT'

Completed: Spring Boot, Prometheus and Grafana are deployed.\nThe three-panel Java Application Monitoring dashboard is provisioned from a ConfigMap.
Jaeger and EFK were intentionally NOT started to conserve Killercoda memory.

NEXT STEP (separate Killercoda terminal tab):
  kubectl port-forward -n monitoring --address 0.0.0.0 svc/grafana 3000:80

Open port 3000 using Killercoda's Traffic / Ports interface.
Grafana login: admin
Retrieve the password privately with:
  kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo

For the report: capture the terminal showing all three pods 1/1 Running.
NEXT
