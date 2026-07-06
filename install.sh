#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="istio"
DEFAULT_NAMESPACE="istio-system"
DEFAULT_PROFILE="full"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_WAIT_TIMEOUT="10m"
DEFAULT_GATEWAY_SERVICE_TYPE="LoadBalancer"
DEFAULT_GATEWAY_API_CRD_CHANNEL="standard"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

NAMESPACE="${DEFAULT_NAMESPACE}"
PROFILE="${DEFAULT_PROFILE}"
REGISTRY="${DEFAULT_REGISTRY}"
IMAGE_HUB=""
IMAGE_TAG=""
REGISTRY_USER=""
REGISTRY_PASS=""
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
GATEWAY_SERVICE_TYPE="${DEFAULT_GATEWAY_SERVICE_TYPE}"
INSTALL_GATEWAY_API_CRDS=1
GATEWAY_API_CRD_CHANNEL="${DEFAULT_GATEWAY_API_CRD_CHANNEL}"
FORCE_GATEWAY_API_CRDS=0
DELETE_GATEWAY_API_CRDS=0
SKIP_IMAGE_PREPARE=0
YES=0
DRY_RUN=0
DELETE_NAMESPACE=0
HELM_BIN="${HELM:-helm}"
KUBECTL_BIN="${KUBECTL:-kubectl}"
DOCKER_BIN="${DOCKER:-docker}"
HELM_ARGS=()
KUBECTL_ARGS=()
EXTRA_SET_ARGS=()
WORKDIR=""

usage() {
  cat <<USAGE
Usage:
  ./istio-<version>-<arch>.run install [options]
  ./istio-<version>-<arch>.run status [options]
  ./istio-<version>-<arch>.run uninstall [options]
  ./istio-<version>-<arch>.run help

Actions:
  install      Apply Gateway API CRDs, load/push images, and install Istio with Helm charts.
  status       Show Gateway API CRDs plus Istio Helm releases, pods, services, and gateways.
  uninstall    Uninstall Istio Helm releases. Namespace and Gateway API CRDs are kept unless explicitly deleted.
  help         Show this help.

Profiles:
  full         base + istiod + istio-cni + ztunnel + ingressgateway + egressgateway. Default.
  ambient      same component set as full, with ambient CNI and ztunnel enabled.
  default      alias of full.
  classic      base + istiod + ingressgateway + egressgateway, without CNI/ztunnel.

Options:
  -n, --namespace <ns>                 Istio namespace. Default: ${DEFAULT_NAMESPACE}
  --profile <name>                     full|ambient|default|classic. Default: ${DEFAULT_PROFILE}
  --registry <repo-prefix>             Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>               Target registry username.
  --registry-pass <pass>               Target registry password.
  --image-hub <hub>                    Override Istio image hub. Default: <registry>/istio
  --image-tag <tag>                    Override Istio image tag. Default: package version.
  --skip-image-prepare                 Skip docker load/tag/push. Use when images already exist.
  --gateway-service-type <type>        ingressgateway service type. Default: ${DEFAULT_GATEWAY_SERVICE_TYPE}
  --gateway-api-channel <channel>      Gateway API CRD channel: standard|experimental. Default: ${DEFAULT_GATEWAY_API_CRD_CHANNEL}
  --gateway-api-crds <channel>         Enable Gateway API CRDs and set channel: standard|experimental.
  --skip-gateway-api-crds              Do not apply packaged Gateway API CRDs.
  --force-gateway-api-crds             Add --force-conflicts to server-side Gateway API CRD apply.
  --delete-gateway-api-crds            During uninstall, delete packaged Gateway API CRDs. Dangerous cluster-wide operation.
  --set <key=value>                    Extra Helm --set-string value, repeatable.
  --wait-timeout <duration>            Helm wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --dry-run                            Render/apply dry-runs without changing resources.
  --delete-namespace                   During uninstall, delete namespace after uninstalling releases.
  --kubeconfig <path>                  Pass an explicit kubeconfig to kubectl and helm.
  --context <name>                     Pass an explicit kube context to kubectl and helm.
  -y, --yes                            Do not ask for confirmation.
  -h, --help                           Show this help.

Notes:
  - This is intentionally not a minimal Istio install. The default full profile installs CNI, ztunnel,
    ingress gateway, and egress gateway in addition to base and istiod.
  - Gateway API CRDs are bundled and applied by default before Istio base/istiod, so Gateway/HTTPRoute
    resources are available after one install command.
  - Use --skip-gateway-api-crds only when the cluster provider already manages compatible Gateway API CRDs.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
warn() { echo "WARNING: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --image-hub) IMAGE_HUB="${2:-}"; shift 2 ;;
    --image-tag) IMAGE_TAG="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    --gateway-service-type) GATEWAY_SERVICE_TYPE="${2:-}"; shift 2 ;;
    --gateway-api-channel) GATEWAY_API_CRD_CHANNEL="${2:-}"; shift 2 ;;
    --gateway-api-crds) INSTALL_GATEWAY_API_CRDS=1; GATEWAY_API_CRD_CHANNEL="${2:-}"; shift 2 ;;
    --skip-gateway-api-crds|--no-gateway-api-crds) INSTALL_GATEWAY_API_CRDS=0; shift ;;
    --force-gateway-api-crds) FORCE_GATEWAY_API_CRDS=1; shift ;;
    --delete-gateway-api-crds) DELETE_GATEWAY_API_CRDS=1; shift ;;
    --set) EXTRA_SET_ARGS+=(--set-string "${2:-}"); shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    --kubeconfig) KUBECTL_ARGS+=(--kubeconfig "${2:-}"); HELM_ARGS+=(--kubeconfig "${2:-}"); shift 2 ;;
    --context) KUBECTL_ARGS+=(--context "${2:-}"); HELM_ARGS+=(--kube-context "${2:-}"); shift 2 ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi
case "${PROFILE}" in full|ambient|default|classic) ;; *) die "--profile must be full, ambient, default, or classic" ;; esac
case "${GATEWAY_API_CRD_CHANNEL}" in standard|experimental) ;; *) die "--gateway-api-channel must be standard or experimental" ;; esac
[[ -n "${NAMESPACE}" ]] || die "namespace cannot be empty"
[[ -n "${REGISTRY}" ]] || die "registry cannot be empty"

k() { "${KUBECTL_BIN}" "${KUBECTL_ARGS[@]}" "$@"; }
h() { "${HELM_BIN}" "${HELM_ARGS[@]}" "$@"; }
d() { "${DOCKER_BIN}" "$@"; }

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${WORKDIR}/crds/gateway-api-standard-install.yaml" ]] || die "payload missing Gateway API standard CRDs"
  [[ -f "${WORKDIR}/crds/gateway-api-experimental-install.yaml" ]] || die "payload missing Gateway API experimental CRDs"
  [[ -d "${WORKDIR}/charts/base" ]] || die "payload missing charts/base"
  [[ -d "${WORKDIR}/charts/istiod" ]] || die "payload missing charts/istiod"
  [[ -d "${WORKDIR}/charts/gateway" ]] || die "payload missing charts/gateway"
  [[ -f "${WORKDIR}/images/image-index.tsv" ]] || die "payload missing images/image-index.tsv"
}

package_meta_value() {
  local key="$1"
  [[ -f "${WORKDIR}/meta/package.env" ]] || return 0
  awk -F= -v k="${key}" '$1 == k { print substr($0, length(k) + 2); exit }' "${WORKDIR}/meta/package.env"
}

package_version() {
  package_meta_value VERSION
}

gateway_api_version() {
  package_meta_value GATEWAY_API_VERSION
}

resolve_image_tag() {
  if [[ -z "${IMAGE_TAG}" ]]; then
    IMAGE_TAG="$(package_version)"
  fi
  [[ -n "${IMAGE_TAG}" ]] || die "failed to resolve image tag"
}

resolve_image_hub() {
  if [[ -z "${IMAGE_HUB}" ]]; then
    IMAGE_HUB="${REGISTRY%/}/istio"
  fi
  IMAGE_HUB="${IMAGE_HUB%/}"
  [[ -n "${IMAGE_HUB}" ]] || die "failed to resolve image hub"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} Istio profile '${PROFILE}' in namespace '${NAMESPACE}'."
  if [[ "${ACTION}" == "install" && "${INSTALL_GATEWAY_API_CRDS}" == "1" ]]; then
    echo "Gateway API CRDs: apply packaged ${GATEWAY_API_CRD_CHANNEL} channel before Istio."
  fi
  if [[ "${ACTION}" == "uninstall" && "${DELETE_GATEWAY_API_CRDS}" == "1" ]]; then
    echo "WARNING: Gateway API CRDs will be deleted cluster-wide. This also removes Gateway API resources."
  fi
  if [[ "${ACTION}" == "uninstall" && "${DELETE_NAMESPACE}" == "1" ]]; then
    echo "WARNING: namespace ${NAMESPACE} will also be deleted."
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_ref() {
  local ref="$1"
  local default_registry suffix
  default_registry="$(package_meta_value DEFAULT_REGISTRY)"
  default_registry="${default_registry:-${DEFAULT_REGISTRY}}"
  if [[ "${ref}" == "${default_registry}/"* ]]; then
    suffix="${ref#${default_registry}/}"
  else
    suffix="${ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

prepare_images() {
  if [[ "${SKIP_IMAGE_PREPARE}" == "1" ]]; then
    info "skip image preparation; expecting images under ${IMAGE_HUB}:${IMAGE_TAG} naming convention"
    return 0
  fi

  need "${DOCKER_BIN}"
  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "--registry-user and --registry-pass must be set together"
    info "docker login ${REGISTRY}"
    printf '%s' "${REGISTRY_PASS}" | d login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin
  fi

  local line name tar_name load_ref default_target_ref platform pull dockerfile target_ref
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == name\|tar_name\|* ]] && continue
    IFS='|' read -r name tar_name load_ref default_target_ref platform pull dockerfile <<< "${line}"
    [[ -n "${tar_name}" ]] || continue
    [[ -f "${WORKDIR}/images/${tar_name}" ]] || die "missing image tar: images/${tar_name}"
    target_ref="$(retarget_ref "${default_target_ref}")"
    info "docker load ${tar_name}"
    d load -i "${WORKDIR}/images/${tar_name}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      d tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    d push "${target_ref}"
  done < "${WORKDIR}/images/image-index.tsv"
}

install_gateway_api_crds() {
  [[ "${INSTALL_GATEWAY_API_CRDS}" == "1" ]] || { info "skip Gateway API CRDs"; return 0; }
  local crd_file="${WORKDIR}/crds/gateway-api-${GATEWAY_API_CRD_CHANNEL}-install.yaml"
  [[ -f "${crd_file}" ]] || die "Gateway API CRD manifest not found for channel: ${GATEWAY_API_CRD_CHANNEL}"
  info "apply Gateway API CRDs v$(gateway_api_version) channel=${GATEWAY_API_CRD_CHANNEL}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    k apply --dry-run=client -f "${crd_file}" >/dev/null
    return 0
  fi
  local -a apply_args=(apply --server-side -f "${crd_file}")
  if [[ "${FORCE_GATEWAY_API_CRDS}" == "1" ]]; then
    apply_args+=(--force-conflicts)
  fi
  k "${apply_args[@]}"
}

delete_gateway_api_crds() {
  [[ "${DELETE_GATEWAY_API_CRDS}" == "1" ]] || return 0
  local crd_file="${WORKDIR}/crds/gateway-api-${GATEWAY_API_CRD_CHANNEL}-install.yaml"
  [[ -f "${crd_file}" ]] || die "Gateway API CRD manifest not found for channel: ${GATEWAY_API_CRD_CHANNEL}"
  warn "deleting Gateway API CRDs cluster-wide from ${GATEWAY_API_CRD_CHANNEL} channel manifest"
  if [[ "${DRY_RUN}" == "1" ]]; then
    k delete --dry-run=client --ignore-not-found=true -f "${crd_file}" >/dev/null
    return 0
  fi
  k delete --ignore-not-found=true -f "${crd_file}"
}

chart_common_sets() {
  printf '%s\n' \
    --set-string "global.hub=${IMAGE_HUB}" \
    --set-string "global.tag=${IMAGE_TAG}" \
    --set-string "hub=${IMAGE_HUB}" \
    --set-string "tag=${IMAGE_TAG}" \
    --set-string "_internal_defaults_do_not_set.hub=${IMAGE_HUB}" \
    --set-string "_internal_defaults_do_not_set.tag=${IMAGE_TAG}"
}

helm_upgrade() {
  local release="$1" chart="$2"
  shift 2
  local -a args extra
  mapfile -t args < <(chart_common_sets)
  extra=("$@")
  if [[ "${DRY_RUN}" == "1" ]]; then
    info "helm template ${release} ${chart}"
    h template "${release}" "${chart}" \
      -n "${NAMESPACE}" \
      "${args[@]}" \
      "${EXTRA_SET_ARGS[@]}" \
      "${extra[@]}" >/dev/null
    return 0
  fi

  info "helm upgrade --install ${release} ${chart}"
  h upgrade --install "${release}" "${chart}" \
    -n "${NAMESPACE}" \
    --create-namespace \
    --wait \
    --timeout "${WAIT_TIMEOUT}" \
    "${args[@]}" \
    "${EXTRA_SET_ARGS[@]}" \
    "${extra[@]}"
}

install_base() {
  helm_upgrade istio-base "${WORKDIR}/charts/base"
}

install_cni() {
  local ambient_enabled="false"
  case "${PROFILE}" in full|ambient|default) ambient_enabled="true" ;; esac
  helm_upgrade istio-cni "${WORKDIR}/charts/istio-cni" \
    --set "ambient.enabled=${ambient_enabled}" \
    --set "_internal_defaults_do_not_set.ambient.enabled=${ambient_enabled}"
}

install_istiod() {
  local cni_enabled="false"
  local trusted_ztunnel_ns=""
  case "${PROFILE}" in full|ambient|default) cni_enabled="true"; trusted_ztunnel_ns="${NAMESPACE}" ;; esac
  helm_upgrade istiod "${WORKDIR}/charts/istiod" \
    -f "${WORKDIR}/values/istiod-common.yaml" \
    --set "cni.enabled=${cni_enabled}" \
    --set "_internal_defaults_do_not_set.cni.enabled=${cni_enabled}" \
    --set-string "trustedZtunnelNamespace=${trusted_ztunnel_ns}" \
    --set-string "_internal_defaults_do_not_set.trustedZtunnelNamespace=${trusted_ztunnel_ns}"
}

install_ztunnel() {
  helm_upgrade ztunnel "${WORKDIR}/charts/ztunnel" \
    --set-string "istioNamespace=${NAMESPACE}" \
    --set-string "_internal_defaults_do_not_set.istioNamespace=${NAMESPACE}"
}

install_gateway() {
  local release="$1" values_file="$2" service_type="$3"
  helm_upgrade "${release}" "${WORKDIR}/charts/gateway" \
    -f "${values_file}" \
    --set-string "service.type=${service_type}" \
    --set-string "_internal_defaults_do_not_set.service.type=${service_type}"
}

install_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  extract_payload
  resolve_image_tag
  resolve_image_hub
  info "package ${PACKAGE_NAME} version=$(package_version) gatewayApi=$(gateway_api_version) profile=${PROFILE} namespace=${NAMESPACE} imageHub=${IMAGE_HUB} imageTag=${IMAGE_TAG}"
  confirm
  install_gateway_api_crds
  prepare_images

  if [[ "${DRY_RUN}" != "1" ]]; then
    k create namespace "${NAMESPACE}" --dry-run=client -o yaml | k apply -f -
  fi

  install_base
  case "${PROFILE}" in
    full|ambient|default)
      install_cni
      install_istiod
      install_ztunnel
      ;;
    classic)
      install_istiod
      ;;
  esac
  install_gateway istio-ingressgateway "${WORKDIR}/values/gateway-ingress.yaml" "${GATEWAY_SERVICE_TYPE}"
  install_gateway istio-egressgateway "${WORKDIR}/values/gateway-egress.yaml" "ClusterIP"

  if [[ "${DRY_RUN}" == "1" ]]; then
    info "dry-run completed; no resources were changed"
    return 0
  fi

  status_app
}

status_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  echo "Gateway API CRDs:"
  k get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io 2>/dev/null || true
  echo
  echo "Istio Helm releases:"
  h list -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "Istio pods:"
  k get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "Istio services:"
  k get svc -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "Istio gateways:"
  k get gateway -A 2>/dev/null || true
  echo
  if [[ -x "${WORKDIR:-}/tools/istioctl" ]]; then
    echo "Istio proxy status:"
    "${WORKDIR}/tools/istioctl" proxy-status 2>/dev/null || true
  fi
}

helm_uninstall_release() {
  local release="$1"
  if h status "${release}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "helm uninstall ${release}"
    h uninstall "${release}" -n "${NAMESPACE}" --wait --timeout "${WAIT_TIMEOUT}" || true
  fi
}

uninstall_app() {
  need "${KUBECTL_BIN}"
  need "${HELM_BIN}"
  confirm
  if [[ "${DELETE_GATEWAY_API_CRDS}" == "1" ]]; then
    extract_payload
  fi
  helm_uninstall_release istio-egressgateway
  helm_uninstall_release istio-ingressgateway
  helm_uninstall_release ztunnel
  helm_uninstall_release istiod
  helm_uninstall_release istio-cni
  helm_uninstall_release istio-base
  delete_gateway_api_crds
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "deleting namespace ${NAMESPACE}"
    k delete namespace "${NAMESPACE}" --ignore-not-found=true
  else
    info "namespace ${NAMESPACE} kept"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
