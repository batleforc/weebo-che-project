#!/usr/bin/env bash
# Measures the boot of a che-code workspace, step by step (RFC che-code-01 and che-code-02).
#
# Usage: scripts/measure-che-code-boot.sh <namespace> <devworkspace>
#        scripts/measure-che-code-boot.sh --fresh <namespace> <devfile> [editor definition]
#
# Default: stops the workspace if it runs, starts it and measures that boot.
#
# --fresh: simulates the creation of a new workspace from a devfile, as the dashboard does: a
# DevWorkspaceTemplate from the editor definition, and a DevWorkspace from the devfile that gets its
# editor from it. New workspace id, so new storage (empty /checode, fresh clone of the projects,
# empty home). Measures the first boot, restarts it to measure a second boot, then deletes both
# (a per-workspace PVC goes with them; with per-user storage, the operator cleans the subpath).
# The editor definition is a devfile (che-operator editors-definitions/*.yaml) or a ConfigMap
# holding one (default: deploy/develop/che-code-editor.yaml).
# The node image cache can't be cleared from here: check the pull times in the report.
#
# The readiness check runs curl in the first container that is not che-gateway. Kubernetes
# timestamps have a 1 s resolution, the readiness poll too. "VS Code server answers" is the HTTP 200
# of the workbench page: the browser still needs a few seconds to load and render it.
#
# Needs kubectl, jq and yq (--fresh).
# Env: TIMEOUT (seconds per boot, default 600)
#      --fresh only:
#      EDITOR_IMAGE   che-code image of che-code-injector, e.g. ghcr.io/weebo-si/che-code:sha-55a18ad
#      EDITOR_MEMORY  memory limit of che-code-injector, e.g. 1Gi
#      CHE_NAMESPACE  namespace of the CheCluster (default: eclipse-che)
#      STORAGE_TYPE   per-user, per-workspace or ephemeral (default: the CheCluster pvcStrategy if
#                     readable, else per-user)
#      KEEP=true      keep the workspace instead of deleting it

set -euo pipefail

usage="usage: $0 <namespace> <devworkspace> | $0 --fresh <namespace> <devfile> [editor definition]"
fresh=false
[ "${1:-}" = "--fresh" ] && { fresh=true; shift; }
ns=${1:?$usage}
timeout=${TIMEOUT:-600}

# Starts $dw (already stopped or just created, start time $t0) and prints the boot report.
# $boot labels the RESULT line (first, second or restart).
measure() {
  local id selector deadline pod="" container="" url="" listening="" reachable="" code phase
  id=""
  deadline=$((t0 + timeout))
  while [ -z "$id" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    id=$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.status.devworkspaceId}')
    [ -n "$id" ] || sleep 1
  done
  selector="controller.devfile.io/devworkspace_id=$id"

  # listening: VS Code answers on its port inside the pod
  # reachable: <mainUrl>healthz answers through the ingress and the gateways (no auth on that path)
  while [ -z "$reachable" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    phase=$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.status.phase}')
    [ "$phase" = "Failed" ] && break
    url=${url:-$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.status.mainUrl}')}
    pod=${pod:-$(kubectl get pod -n "$ns" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}
    if [ -n "$pod" ] && [ -z "$listening" ]; then
      container=${container:-$(kubectl get pod "$pod" -n "$ns" -o json | jq -r '[.spec.containers[].name | select(. != "che-gateway")][0]')}
      code=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
        curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ 2>/dev/null || true)
      [ "$code" = "200" ] && listening=$(date +%s)
    fi
    if [ -n "$url" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}healthz" || true)" = "200" ]; then
      reachable=$(date +%s)
      listening=${listening:-$reachable}
    fi
    [ -n "$reachable" ] || sleep 1
  done
  if [ -z "$reachable" ]; then
    local reason
    reason=$( { kubectl get pod "$pod" -n "$ns" -o json 2>/dev/null || echo '{}'; } | jq -r '
      [.status.initContainerStatuses[]? | select(.name == "che-code-injector")
       | .lastState.terminated.reason // .state.terminated.reason // empty][0] // "timeout"')
    echo "VS Code not reachable (${phase:-no phase}, che-code-injector: $reason)" >&2
    kubectl get dw "$dw" -n "$ns" -o jsonpath='DevWorkspace {.status.phase}: {.status.message}{"\n"}' >&2
    echo "RESULT boot=$boot image=${EDITOR_IMAGE:-} memory=${EDITOR_MEMORY:-} status=$reason"
    exit 1
  fi

  local pod_json dw_json events launcher copied fonts
  pod_json=$(kubectl get pod "$pod" -n "$ns" -o json)
  dw_json=$(kubectl get dw "$dw" -n "$ns" -o json)
  events=$(kubectl get events -n "$ns" --field-selector "involvedObject.name=$pod" -o json)
  # Written by the launcher right before it starts VS Code (RFC che-code-02 images only)
  launcher=$(kubectl exec "$pod" -n "$ns" -c "$container" -- stat -c %Y /checode/fonts.css 2>/dev/null || true)
  fonts=$(kubectl exec "$pod" -n "$ns" -c "$container" -- \
    sh -c 'grep -o "font-family: \"[^\"]*\"" /checode/fonts.css | sort | uniq -c' 2>/dev/null || true)
  copied=$(kubectl logs "$pod" -n "$ns" -c che-code-injector 2>/dev/null | grep "already on the volume\|Copying checode" || true)

  echo
  echo "$dw ($pod), image $(jq -r '.spec.initContainers[] | select(.name == "che-code-injector") | .image' <<<"$pod_json")"
  echo
  {
    jq -r '.metadata.creationTimestamp + "\tpod created"' <<<"$pod_json"
    jq -r '.status.conditions[] | select(.type == "PodScheduled") | .lastTransitionTime + "\tpod scheduled"' <<<"$pod_json"
    jq -r '.status.initContainerStatuses[] | .state.terminated as $t
      | ($t.startedAt + "\tinit " + .name + " started"),
        ($t.finishedAt + "\tinit " + .name + " finished (\(($t.finishedAt | fromdate) - ($t.startedAt | fromdate))s)")' <<<"$pod_json"
    jq -r '.status.containerStatuses[] | .state.running.startedAt + "\tcontainer " + .name + " started"' <<<"$pod_json"
    jq -r '.status.conditions[] | select(.type == "Ready") | .lastTransitionTime + "\tpod ready"' <<<"$pod_json"
    [ -n "$launcher" ] && echo "$(date -u -d "@$launcher" +%FT%TZ)	launcher done, VS Code starting"
    echo "$(date -u -d "@$listening" +%FT%TZ)	VS Code listening on 3100"
    echo "$(date -u -d "@$reachable" +%FT%TZ)	IDE reachable from its URL"
    jq -r '.status.conditions[] | select(.type == "Ready" and .status == "True") | .lastTransitionTime + "\tDevWorkspace ready"' <<<"$dw_json"
  } | sort -s -k1,1 | while IFS=$'\t' read -r time step; do
    [ -n "$time" ] && [ "$time" != "null" ] && printf '%5ss  %s\n' "$(($(date -d "$time" +%s) - t0))" "$step"
  done

  echo
  echo "Image pulls:"
  jq -r '.items[] | select(.reason == "Pulled") | "  " + .message' <<<"$events"
  [ -n "$copied" ] && { echo; echo "Init container: $copied"; }
  [ -n "$fonts" ] && { echo; echo "Fonts in /checode/fonts.css:"; echo "$fonts"; }

  echo
  echo "Total: $((listening - t0))s to VS Code listening, $((reachable - t0))s to the IDE URL"
  # One line per boot, to aggregate several runs
  echo "RESULT boot=$boot image=$(jq -r '.spec.initContainers[] | select(.name == "che-code-injector") | .image' <<<"$pod_json")" \
    "memory=$(jq -r '.spec.initContainers[] | select(.name == "che-code-injector") | .resources.limits.memory' <<<"$pod_json")" \
    "$(jq -r '[.status.initContainerStatuses[]
      | "\(.name)=\(.state.terminated | (.finishedAt | fromdate) - (.startedAt | fromdate))s"] | join(" ")' <<<"$pod_json")" \
    "listening=$((listening - t0))s url=$((reachable - t0))s status=ok"
}

stop() {
  local id
  id=$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.status.devworkspaceId}')
  if [ "$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.spec.started}')" = "true" ]; then
    echo "Stopping $dw..."
    kubectl patch dw "$dw" -n "$ns" --type merge -p '{"spec":{"started":false}}' >/dev/null
  fi
  kubectl wait pod -n "$ns" -l "controller.devfile.io/devworkspace_id=$id" --for=delete --timeout="${timeout}s" >/dev/null 2>&1 || true
}

restart() {
  stop
  echo "Starting $dw..."
  t0=$(date +%s)
  kubectl patch dw "$dw" -n "$ns" --type merge -p '{"spec":{"started":true}}' >/dev/null
  measure
}

if [ "$fresh" = false ]; then
  dw=${2:?$usage}
  boot=restart
  restart
  exit 0
fi

# --fresh: create the workspace from a devfile, as the dashboard does
devfile=${2:?$usage}
editor_file=${3:-$(dirname "$0")/../deploy/develop/che-code-editor.yaml}
che_ns=${CHE_NAMESPACE:-eclipse-che}
storage=${STORAGE_TYPE:-$(kubectl get checluster -n "$che_ns" -o jsonpath='{.items[0].spec.devEnvironments.storage.pvcStrategy}' 2>/dev/null || true)}
storage=${storage:-per-user}

editor=$(yq -o json '.' "$editor_file")
[ "$(jq -r .kind <<<"$editor")" = "ConfigMap" ] && editor=$(jq -r '.data | to_entries[0].value' <<<"$editor" | yq -o json '.')
dw=$(yq -r '.metadata.name' "$devfile")-boot-$(date +%s)
template=che-code-$dw

cleanup() {
  if [ "${KEEP:-false}" = "true" ]; then
    echo "Kept $dw (KEEP=true): kubectl delete dw $dw -n $ns"
    return
  fi
  echo "Deleting $dw..."
  kubectl delete dw "$dw" -n "$ns" --ignore-not-found --wait=false >/dev/null
  kubectl delete dwt "$template" -n "$ns" --ignore-not-found >/dev/null
}
trap cleanup EXIT

jq --arg name "$template" --arg ns "$ns" --arg image "${EDITOR_IMAGE:-}" --arg memory "${EDITOR_MEMORY:-}" '
  {apiVersion: "workspace.devfile.io/v1alpha2", kind: "DevWorkspaceTemplate",
   metadata: {name: $name, namespace: $ns},
   spec: (del(.schemaVersion, .metadata) | .components |= map(
     if .name == "che-code-injector" then
       (if $image != "" then .container.image = $image else . end)
       | (if $memory != "" then .container.memoryLimit = $memory else . end)
     else . end))}' <<<"$editor" | kubectl create -f - >/dev/null

echo "Creating $dw from $devfile ($storage storage, editor $(jq -r '.components[] | select(.name == "che-code-injector") | .container.image' <<<"$editor")${EDITOR_IMAGE:+ -> $EDITOR_IMAGE})..."
t0=$(date +%s)
yq -o json '.' "$devfile" | jq --arg name "$dw" --arg ns "$ns" --arg template "$template" --arg che_ns "$che_ns" \
  --arg storage "$storage" --arg raw "$(cat "$devfile")" \
  --arg editor_id "$(jq -r '.metadata | "\(.attributes.publisher)/\(.name)/\(.attributes.version)"' <<<"$editor")" '
  {apiVersion: "workspace.devfile.io/v1alpha2", kind: "DevWorkspace",
   metadata: {name: $name, namespace: $ns,
              annotations: {"che.eclipse.org/che-editor": $editor_id, "che.eclipse.org/devfile": $raw}},
   spec: {started: true, routingClass: "che",
          contributions: [{name: "editor", kubernetes: {name: $template}}],
          template: (del(.schemaVersion, .metadata) | .attributes += {
            "controller.devfile.io/storage-type": $storage,
            "controller.devfile.io/devworkspace-config": {name: "devworkspace-config", namespace: $che_ns}})}}' |
  kubectl create -f - >/dev/null

# The template is owned by the workspace, so it goes with it even if the cleanup does not run
uid=$(kubectl get dw "$dw" -n "$ns" -o jsonpath='{.metadata.uid}')
kubectl patch dwt "$template" -n "$ns" --type merge -p "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"workspace.devfile.io/v1alpha2\",\"kind\":\"DevWorkspace\",\"name\":\"$dw\",\"uid\":\"$uid\"}]}}" >/dev/null

echo
echo "=== First boot ==="
boot=first
measure
echo
echo "=== Second boot ==="
boot=second
restart
