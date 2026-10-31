#!/bin/sh
# Run on a server: k3s's CRDs are Established and Traefik is running, unless
# Traefik is disabled. Node Ready proves neither. Prints the state on failure.
crds="crd/addons.k3s.cattle.io crd/etcdsnapshotfiles.k3s.cattle.io crd/helmcharts.helm.cattle.io crd/helmchartconfigs.helm.cattle.io"

settled() {
  k3s kubectl wait --for=condition=Established $crds --timeout=5s >/dev/null 2>&1 || return 1
  grep -q traefik /etc/rancher/k3s/config.yaml && return 0
  k3s kubectl -n kube-system wait --for=condition=Available deploy/traefik --timeout=5s >/dev/null 2>&1
}

for _ in $(seq 60); do
  settled && { echo "CRDs Established, Traefik ok"; exit 0; }
  sleep 5
done

echo "k3s did not settle:" >&2
k3s kubectl get $crds -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions}{"\n"}{end}' >&2
k3s kubectl get pods -A >&2
journalctl -u k3s --no-pager | grep -E 'level=fatal|Waiting for CRD' | tail -n 20 >&2
exit 1
