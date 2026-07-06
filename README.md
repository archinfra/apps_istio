# apps_istio

Istio offline `.run` installer package.

This repository builds a self-extracting, air-gapped Kubernetes installer for Istio. The package now includes **Gateway API CRDs** and applies them by default before installing Istio, so a single install command prepares the cluster for Istio Gateway API resources such as `Gateway`, `HTTPRoute`, and `GRPCRoute`.

Unlike a minimal Istio install, the default profile installs the control plane and commonly needed platform components:

- Gateway API CRDs, default channel: `standard`
- `base` CRDs and cluster resources
- `istiod` control plane
- `istio-cni`
- `ztunnel` for ambient-ready deployments
- `istio-ingressgateway`
- `istio-egressgateway`

The installer uses the official Istio release tarball as the chart source, downloads Gateway API CRD release manifests, and packages the required container images into the `.run` payload.

## Version

- Istio: `1.30.0`
- Gateway API CRDs: `v1.5.1`
- package type: Gateway API CRDs + Helm charts + offline images
- architectures: `amd64`, `arm64`
- default profile: `full`
- default Gateway API CRD channel: `standard`

## Repository layout

```text
apps_istio/
  VERSION
  build.sh
  install.sh
  images/
    image.json
  upstream/
    .gitkeep
  .github/workflows/
    offline-run-packages.yml
```

## Packaged content

The `.run` payload contains:

- Gateway API `standard-install.yaml`
- Gateway API `experimental-install.yaml`
- Istio Helm charts from the official release tarball
- `istioctl` from the official release tarball when available
- Istio runtime images for each architecture:
  - `istio/pilot`
  - `istio/proxyv2`
  - `istio/install-cni`
  - `istio/ztunnel`

The gateway chart uses `image: auto`; gateway pods are injected by Istio and use the packaged `proxyv2` image through the configured Istio image hub/tag.

## Build locally

Build host requirements:

- Linux shell
- `curl`
- `tar`
- `sha256sum`
- `python3`
- `docker`

Build both architectures:

```bash
bash build.sh --arch all
```

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build another Istio or Gateway API CRD version:

```bash
bash build.sh --arch all --version 1.30.0 --gateway-api-version 1.5.1
```

Use pre-downloaded assets:

```text
upstream/istio-1.30.0-linux-amd64.tar.gz
upstream/istio-1.30.0-linux-arm64.tar.gz
upstream/gateway-api-v1.5.1-standard-install.yaml
upstream/gateway-api-v1.5.1-experimental-install.yaml
```

```bash
bash build.sh --arch all --use-local-assets
```

Artifacts are written to `dist/`:

```text
dist/istio-1.30.0-amd64.run
dist/istio-1.30.0-amd64.run.sha256
dist/istio-1.30.0-arm64.run
dist/istio-1.30.0-arm64.run.sha256
```

## One-click offline install

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`
- `kubectl`
- `helm`
- `docker`, unless `--skip-image-prepare` is used
- optional `sha256sum` for artifact verification

Install the default full profile and Gateway API CRDs in one command:

```bash
sha256sum -c istio-1.30.0-amd64.run.sha256
chmod +x istio-1.30.0-amd64.run
./istio-1.30.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -y
```

The installer order is:

```text
Gateway API CRDs -> Istio base -> istiod -> istio-cni -> ztunnel -> ingressgateway -> egressgateway
```

If the images already exist in the target registry:

```bash
./istio-1.30.0-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -y
```

Use an explicit kubeconfig/context:

```bash
./istio-1.30.0-amd64.run install \
  --kubeconfig /etc/kubernetes/admin.conf \
  --context my-cluster \
  --registry sealos.hub:5000/kube4 \
  -y
```

Render without applying:

```bash
./istio-1.30.0-amd64.run install --dry-run --skip-image-prepare -y
```

## Gateway API CRD options

Default behavior is to apply the packaged Gateway API `standard` channel before installing Istio:

```bash
./istio-1.30.0-amd64.run install -y
```

Install the `experimental` channel instead:

```bash
./istio-1.30.0-amd64.run install --gateway-api-channel experimental -y
```

Skip Gateway API CRDs when the Kubernetes provider already manages compatible Gateway API CRDs:

```bash
./istio-1.30.0-amd64.run install --skip-gateway-api-crds -y
```

Force server-side apply conflicts during CRD upgrade:

```bash
./istio-1.30.0-amd64.run install --force-gateway-api-crds -y
```

Gateway API CRDs are cluster-scoped and shared. Uninstall keeps them by default. Delete them only when you are certain no other controller or workload depends on them:

```bash
./istio-1.30.0-amd64.run uninstall --delete-gateway-api-crds -y
```

## Profiles

| Profile | Installed components |
| --- | --- |
| `full` | Gateway API CRDs, base, istiod, istio-cni, ztunnel, ingressgateway, egressgateway |
| `ambient` | same component set as `full`, with ambient CNI and ztunnel enabled |
| `default` | alias of `full` |
| `classic` | Gateway API CRDs, base, istiod, ingressgateway, egressgateway |

The default is intentionally `full`, not `minimal`.

Examples:

```bash
./istio-1.30.0-amd64.run install --profile full -y
./istio-1.30.0-amd64.run install --profile classic -y
```

## Customization

Override the namespace:

```bash
./istio-1.30.0-amd64.run install -n istio-system -y
```

Override the image hub/tag when the images are already mirrored:

```bash
./istio-1.30.0-amd64.run install \
  --skip-image-prepare \
  --image-hub registry.local/kube4/istio \
  --image-tag 1.30.0 \
  -y
```

Set ingressgateway service type:

```bash
./istio-1.30.0-amd64.run install --gateway-service-type NodePort -y
```

Pass extra Helm values:

```bash
./istio-1.30.0-amd64.run install \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set pilot.autoscaleMin=2 \
  -y
```

## Status

```bash
./istio-1.30.0-amd64.run status
```

Equivalent manual checks:

```bash
helm list -n istio-system
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io grpcroutes.gateway.networking.k8s.io
kubectl get pods -n istio-system -o wide
kubectl get svc -n istio-system
kubectl get gateway -A
```

## Uninstall

Uninstall Helm releases but keep the namespace and Gateway API CRDs:

```bash
./istio-1.30.0-amd64.run uninstall -y
```

Uninstall and delete the namespace:

```bash
./istio-1.30.0-amd64.run uninstall --delete-namespace -y
```

Delete Gateway API CRDs explicitly:

```bash
./istio-1.30.0-amd64.run uninstall --delete-gateway-api-crds -y
```

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds two artifacts:

- `istio-run-amd64`
- `istio-run-arm64`

Triggers:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.

## Validation checklist

```bash
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
bash build.sh --arch amd64
bash build.sh --arch arm64
(cd dist && sha256sum -c *.sha256)
./dist/istio-1.30.0-amd64.run help
./dist/istio-1.30.0-amd64.run install --dry-run --skip-image-prepare -y
```
