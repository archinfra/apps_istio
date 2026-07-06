#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="istio"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
VERSION="${DEFAULT_VERSION}"
ARCH="all"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_ROOT="${ROOT_DIR}/.build"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
RELEASE_BASE_URL=""
GATEWAY_API_VERSION="1.5.1"
GATEWAY_API_BASE_URL=""
USE_LOCAL_ASSETS=0
SKIP_IMAGES=0
KEEP_BUILD=0

usage() {
  cat <<USAGE
Usage: bash build.sh [options]

Build Istio offline .run installer packages.

Options:
  --arch <amd64|arm64|all>          Target architecture. Default: all.
  --version <version>               Istio version without leading v. Default: ${VERSION}
  --release-base-url <url>          Override Istio release asset base URL.
  --gateway-api-version <version>   Gateway API CRD version without leading v. Default: ${GATEWAY_API_VERSION}
  --gateway-api-base-url <url>      Override Gateway API release asset base URL.
  --use-local-assets                Use upstream assets instead of downloading.
  --skip-images                     Package charts/CRDs only; do not pull/save images. For CI syntax tests only.
  --keep-build                      Keep .build/ working directories after packaging.
  -h, --help                        Show this help.

Expected Istio release asset names when --use-local-assets is used:
  upstream/istio-<version>-linux-amd64.tar.gz
  upstream/istio-<version>-linux-arm64.tar.gz

Expected Gateway API CRD asset names when --use-local-assets is used:
  upstream/gateway-api-v<gateway-api-version>-standard-install.yaml
  upstream/gateway-api-v<gateway-api-version>-experimental-install.yaml

The package includes Gateway API CRDs, Helm charts, and Istio images for base,
istiod, CNI, ztunnel, ingress gateway, and egress gateway installation profiles.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --release-base-url) RELEASE_BASE_URL="${2:-}"; shift 2 ;;
    --gateway-api-version) GATEWAY_API_VERSION="${2:-}"; shift 2 ;;
    --gateway-api-base-url) GATEWAY_API_BASE_URL="${2:-}"; shift 2 ;;
    --use-local-assets) USE_LOCAL_ASSETS=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --keep-build) KEEP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

VERSION="${VERSION#v}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION#v}"
[[ -n "${VERSION}" ]] || die "version cannot be empty"
[[ -n "${GATEWAY_API_VERSION}" ]] || die "gateway api version cannot be empty"
case "${ARCH}" in amd64|arm64|all) ;; *) die "--arch must be amd64, arm64, or all" ;; esac
if [[ -z "${RELEASE_BASE_URL}" ]]; then
  RELEASE_BASE_URL="https://github.com/istio/istio/releases/download/${VERSION}"
fi
if [[ -z "${GATEWAY_API_BASE_URL}" ]]; then
  GATEWAY_API_BASE_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}"
fi

need tar
need sha256sum
need python3
if [[ "${USE_LOCAL_ASSETS}" != "1" ]]; then
  need curl
fi
if [[ "${SKIP_IMAGES}" != "1" ]]; then
  need docker
fi

[[ -f "${ROOT_DIR}/install.sh" ]] || die "install.sh not found"
[[ -f "${ROOT_DIR}/images/image.json" ]] || die "images/image.json not found"
marker_count="$(grep -cx '__PAYLOAD_BELOW__' "${ROOT_DIR}/install.sh" || true)"
[[ "${marker_count}" == "1" ]] || die "install.sh must contain exactly one standalone __PAYLOAD_BELOW__ marker"
bash -n "${ROOT_DIR}/install.sh"
python3 -m json.tool "${ROOT_DIR}/images/image.json" >/dev/null

arch_list() {
  case "${ARCH}" in
    all) printf '%s\n' amd64 arm64 ;;
    *) printf '%s\n' "${ARCH}" ;;
  esac
}

platform_for_arch() {
  case "$1" in
    amd64) printf '%s\n' linux/amd64 ;;
    arm64) printf '%s\n' linux/arm64 ;;
    *) die "unsupported arch: $1" ;;
  esac
}

asset_name_for_arch() {
  printf 'istio-%s-linux-%s.tar.gz\n' "${VERSION}" "$1"
}

gateway_api_local_asset_name() {
  local channel="$1"
  printf 'gateway-api-v%s-%s-install.yaml\n' "${GATEWAY_API_VERSION}" "${channel}"
}

prepare_release_asset() {
  local arch="$1"
  local asset_name cache_dir asset_path url
  asset_name="$(asset_name_for_arch "${arch}")"
  cache_dir="${BUILD_ROOT}/upstream-${VERSION}-${arch}"
  asset_path="${cache_dir}/${asset_name}"
  rm -rf "${cache_dir}"
  mkdir -p "${cache_dir}"

  if [[ "${USE_LOCAL_ASSETS}" == "1" ]]; then
    [[ -f "${ROOT_DIR}/upstream/${asset_name}" ]] || die "missing local asset: upstream/${asset_name}"
    cp "${ROOT_DIR}/upstream/${asset_name}" "${asset_path}"
  else
    url="${RELEASE_BASE_URL%/}/${asset_name}"
    info "downloading ${url}"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "${asset_path}" "${url}"
  fi

  tar -tzf "${asset_path}" >/dev/null
  printf '%s\n' "${asset_path}"
}

prepare_gateway_api_crds() {
  local dest_dir="$1"
  local channel local_name source_path out_path url
  mkdir -p "${dest_dir}/crds"
  for channel in standard experimental; do
    local_name="$(gateway_api_local_asset_name "${channel}")"
    out_path="${dest_dir}/crds/gateway-api-${channel}-install.yaml"
    if [[ "${USE_LOCAL_ASSETS}" == "1" ]]; then
      source_path="${ROOT_DIR}/upstream/${local_name}"
      [[ -f "${source_path}" ]] || die "missing local asset: upstream/${local_name}"
      cp "${source_path}" "${out_path}"
    else
      url="${GATEWAY_API_BASE_URL%/}/${channel}-install.yaml"
      info "downloading ${url}"
      curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "${out_path}" "${url}"
    fi
    [[ -s "${out_path}" ]] || die "Gateway API ${channel} CRD asset is empty"
    grep -q 'gateway.networking.k8s.io' "${out_path}" || die "Gateway API ${channel} CRD asset does not look valid"
  done
}

copy_charts_from_release() {
  local asset_path="$1"
  local dest_dir="$2"
  local tmp_dir root
  tmp_dir="$(mktemp -d -t istio-release.XXXXXX)"
  tar -xzf "${asset_path}" -C "${tmp_dir}"
  root="${tmp_dir}/istio-${VERSION}"
  [[ -d "${root}/manifests/charts" ]] || die "release asset missing manifests/charts"
  mkdir -p "${dest_dir}/charts" "${dest_dir}/tools"
  cp -a "${root}/manifests/charts/base" "${dest_dir}/charts/base"
  cp -a "${root}/manifests/charts/istio-control/istio-discovery" "${dest_dir}/charts/istiod"
  cp -a "${root}/manifests/charts/istio-cni" "${dest_dir}/charts/istio-cni"
  cp -a "${root}/manifests/charts/ztunnel" "${dest_dir}/charts/ztunnel"
  cp -a "${root}/manifests/charts/gateway" "${dest_dir}/charts/gateway"
  if [[ -x "${root}/bin/istioctl" ]]; then
    cp "${root}/bin/istioctl" "${dest_dir}/tools/istioctl"
    chmod +x "${dest_dir}/tools/istioctl"
  fi
  rm -rf "${tmp_dir}"
}

write_profile_index() {
  local dest="$1"
  cat > "${dest}" <<'INDEX'
profile|base|istiod|cni|ztunnel|ingressgateway|egressgateway|ambient
full|true|true|true|true|true|true|true
ambient|true|true|true|true|true|true|true
classic|true|true|false|false|true|true|false
default|true|true|true|true|true|true|true
INDEX
}

write_image_index_header() {
  local dest="$1"
  cat > "${dest}" <<'INDEX'
name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile
INDEX
}

image_rows_for_arch() {
  local arch="$1"
  python3 - "${ROOT_DIR}/images/image.json" "${arch}" <<'PY'
import json, sys
path, arch = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    images = json.load(f)
matched = [i for i in images if i.get('arch') == arch]
if not matched:
    raise SystemExit(f'no images found for arch {arch}')
seen = set()
for i in matched:
    required = ['name', 'tar', 'tag', 'platform']
    missing = [k for k in required if not i.get(k)]
    if missing:
        raise SystemExit(f'image entry missing fields {missing}: {i}')
    if not (i.get('pull') or i.get('dockerfile')):
        raise SystemExit(f'image entry must define pull or dockerfile: {i}')
    if i['tar'] in seen:
        raise SystemExit(f'duplicate tar name: {i["tar"]}')
    seen.add(i['tar'])
    print('|'.join([
        i.get('name', ''),
        i.get('tar', ''),
        i.get('tag', ''),
        i.get('tag', ''),
        i.get('platform', ''),
        i.get('pull', ''),
        i.get('dockerfile', ''),
    ]))
PY
}

prepare_images() {
  local arch="$1"
  local image_dir="$2"
  local index_file="$3"
  local name tar_name load_ref default_target_ref platform pull dockerfile

  write_image_index_header "${index_file}"
  while IFS='|' read -r name tar_name load_ref default_target_ref platform pull dockerfile; do
    [[ -n "${name}" ]] || continue
    echo "${name}|${tar_name}|${load_ref}|${default_target_ref}|${platform}|${pull}|${dockerfile}" >> "${index_file}"
    if [[ "${SKIP_IMAGES}" == "1" ]]; then
      info "skip image packaging: ${name} (${platform})"
      continue
    fi
    if [[ -n "${pull}" ]]; then
      info "pulling ${pull} for ${platform}"
      docker pull --platform "${platform}" "${pull}"
      docker tag "${pull}" "${load_ref}"
    else
      die "dockerfile image entries are not used by this package yet: ${name}"
    fi
    info "saving ${load_ref} -> ${tar_name}"
    docker save "${load_ref}" -o "${image_dir}/${tar_name}"
  done < <(image_rows_for_arch "${arch}")
}

write_default_values() {
  local dest_dir="$1"
  mkdir -p "${dest_dir}/values"
  cat > "${dest_dir}/values/istiod-common.yaml" <<'YAML'
global:
  proxy:
    autoInject: enabled
meshConfig:
  accessLogFile: /dev/stdout
  enablePrometheusMerge: true
YAML

  cat > "${dest_dir}/values/gateway-ingress.yaml" <<'YAML'
service:
  type: LoadBalancer
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 80
  - name: https
    port: 443
    protocol: TCP
    targetPort: 443
labels:
  istio: ingressgateway
YAML

  cat > "${dest_dir}/values/gateway-egress.yaml" <<'YAML'
service:
  type: ClusterIP
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 80
  - name: https
    port: 443
    protocol: TCP
    targetPort: 443
labels:
  istio: egressgateway
YAML
}

build_one() {
  local arch="$1"
  local platform build_dir payload_dir payload_tar run_name run_path asset_path
  platform="$(platform_for_arch "${arch}")"
  build_dir="${BUILD_ROOT}/${PACKAGE_NAME}-${VERSION}-${arch}"
  payload_dir="${build_dir}/payload"
  payload_tar="${build_dir}/payload.tar.gz"
  run_name="${PACKAGE_NAME}-${VERSION}-${arch}.run"
  run_path="${DIST_DIR}/${run_name}"

  info "building ${run_name} (${platform})"
  rm -rf "${build_dir}"
  mkdir -p "${payload_dir}/images" "${payload_dir}/meta" "${DIST_DIR}"

  asset_path="$(prepare_release_asset "${arch}")"
  prepare_gateway_api_crds "${payload_dir}"
  copy_charts_from_release "${asset_path}" "${payload_dir}"
  write_default_values "${payload_dir}"
  cp "${ROOT_DIR}/images/image.json" "${payload_dir}/images/image.json"
  prepare_images "${arch}" "${payload_dir}/images" "${payload_dir}/images/image-index.tsv"
  write_profile_index "${payload_dir}/meta/profile-index.tsv"

  cat > "${payload_dir}/meta/package.env" <<META
PACKAGE_NAME=${PACKAGE_NAME}
VERSION=${VERSION}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION}
ARCH=${arch}
PLATFORM=${platform}
PACKAGE_TYPE=helm-images-gateway-api-crds
DEFAULT_REGISTRY=${DEFAULT_REGISTRY}
DEFAULT_IMAGE_HUB=${DEFAULT_REGISTRY}/istio
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RELEASE_ASSET=${RELEASE_BASE_URL%/}/$(asset_name_for_arch "${arch}")
GATEWAY_API_STANDARD_ASSET=${GATEWAY_API_BASE_URL%/}/standard-install.yaml
GATEWAY_API_EXPERIMENTAL_ASSET=${GATEWAY_API_BASE_URL%/}/experimental-install.yaml
META

  (cd "${payload_dir}" && tar -czf "${payload_tar}" .)
  tar -tzf "${payload_tar}" >/dev/null
  cat "${ROOT_DIR}/install.sh" "${payload_tar}" > "${run_path}"
  chmod +x "${run_path}"
  (cd "${DIST_DIR}" && sha256sum "${run_name}" > "${run_name}.sha256")
  info "wrote ${run_path}"
  info "wrote ${run_path}.sha256"

  if [[ "${KEEP_BUILD}" != "1" ]]; then
    rm -rf "${build_dir}"
  fi
}

mkdir -p "${BUILD_ROOT}" "${DIST_DIR}"
while read -r target_arch; do
  build_one "${target_arch}"
done < <(arch_list)

if [[ "${KEEP_BUILD}" != "1" ]]; then
  find "${BUILD_ROOT}" -maxdepth 1 -type d -name 'upstream-*' -exec rm -rf {} +
fi

info "artifacts:"
ls -lh "${DIST_DIR}"/*.run "${DIST_DIR}"/*.sha256
