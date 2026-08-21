# Platform Engineer Project

This repository defines a local Kubernetes platform managed with Helm, Kustomize,
and Argo CD. It combines MetalLB, Traefik Gateway API, Argo CD, HashiCorp Vault,
External Secrets Operator, Prometheus, and Grafana.

The manifests target a development cluster. They are not a production Vault,
certificate-management, or high-availability design.

## Prerequisites

Install and configure the following before starting:

- A running Kubernetes cluster with `kubectl` configured for the target context.
- Helm 3, Kustomize support through `kubectl`, and the `argocd` CLI.
- `jq`, required by `vault/bootstrap.sh`.
- The Vault CLI, required for the optional human-login setup.
- An unused private LAN address range for MetalLB.
- A wildcard certificate and private key covering `*.ndomi.local`.

The bootstrap script expects `CERT_FILE` and `KEY_FILE` to point to PEM files.
It also uses `kubectl create token`, so the cluster must support projected service
account tokens.

## Installation Order

Run the components in this order because later resources depend on the earlier
ones:

1. Install MetalLB and reserve its address range.
2. Install Traefik with Gateway API enabled.
3. Install Argo CD and wait for its control plane to become available.
4. Sync the `local-path` Argo CD Application and verify its StorageClass.
5. Install Vault and wait for its StatefulSet to be running.
6. Install External Secrets Operator if it is not already installed.
7. Run `vault/bootstrap.sh` to initialize Vault and create the sync resources.
8. Confirm the ExternalSecrets and TLS Secrets are ready.

The bootstrap script applies the Vault Gateway, Vault authentication resources,
and monitoring resources after configuring Vault.

Apply the Argo CD development overlay with:

```bash
kubectl apply --server-side -k infrastructure/argocd/overlays/dev
```

The production overlay is present at `infrastructure/argocd/overlays/production`,
but should be reviewed and adapted before use.

## Repository Layout

```text
infrastructure/argocd/base/       Argo CD Applications and base resources
infrastructure/argocd/overlays/  Environment-specific Argo CD entry points
infrastructure/monitoring/       Prometheus and Grafana Gateway resources
metallb/                          MetalLB chart values and address pool
traefik/                          Traefik chart values
vault/                            Vault chart values, bootstrap, and sync resources
```

## Architecture

- MetalLB provides the Traefik LoadBalancer address `192.168.1.240`.
- Traefik handles Gateway API traffic on ports 80 and 443.
- Argo CD is available at `https://argocd.ndomi.local`.
- Vault is available at `https://vault.ndomi.local`.
- Prometheus is available at `https://prometheus.ndomi.local`.
- Argo CD, Vault, and Prometheus share the Traefik IP and are routed by hostname.
- Vault stores the wildcard certificate at `secret/ndomi-local-wildcard`.
- External Secrets Operator synchronizes that certificate into namespace-local Secrets:
   - `argocd/argocd-tls`
   - `vault/vault-tls`
   - `monitoring/prometheus-tls`
   - `monitoring/grafana-tls`
- External Secrets authenticates to Vault with Kubernetes service accounts, not the Vault root token.

This setup is for local development. Vault uses a persistent single-node Raft volume and must not be exposed directly to the public internet.

## MetalLB

Install MetalLB and configure an address range reserved on the local LAN:

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb \
   --namespace metallb-system \
   --create-namespace
kubectl label namespace metallb-system \
   pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl apply -f metallb/ipaddresspool.yaml
```

The pool must contain unused private LAN addresses, such as `192.168.1.240-192.168.1.250`.

## Traefik

Install Traefik with Gateway API enabled. Kubernetes Ingress discovery is disabled:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik \
   --namespace traefik \
   --create-namespace \
   -f traefik/values.yaml
kubectl -n traefik get pods,svc
```

## Argo CD

Apply the development overlay:

```bash
kubectl apply --server-side \
   -k infrastructure/argocd/overlays/dev
kubectl -n argocd get pods
```

Argo CD is exposed through the Gateway API resources in `infrastructure/argocd/base` and uses the `argocd-tls` Secret.

## Vault

Install Vault with persistent storage:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault \
   --namespace vault \
   --create-namespace \
   -f vault/values.yaml
kubectl -n vault get pods,svc
```

Vault's in-cluster API address is `http://vault.vault.svc.cluster.local:8200`. The Gateway address is `https://vault.ndomi.local`.
The Helm values use a single-node Raft backend backed by a 10Gi PVC.

The current Vault PVC uses the `local-path` StorageClass. Its provisioner is
managed by the Argo CD Application in `infrastructure/argocd/base/local-path`.

Install the storage provisioner before upgrading Vault:

```bash
argocd app sync local-path
kubectl get storageclass local-path
helm upgrade vault hashicorp/vault \
   --namespace vault \
   -f vault/values.yaml
```

After the StatefulSet is running, run the bootstrap script. It initializes and
unseals Vault on first provisioning, or reuses an existing initialized Vault:

```bash
export CERT_FILE=/path/to/cert.pem
export KEY_FILE=/path/to/key.pem
bash ./vault/bootstrap.sh
```

The script creates `vault-init.json` in the current working directory on first
initialization. It contains the unseal key and root token; protect it and remove
it from the working directory after securely storing the recovery information.

If Vault is recreated, do not wait for the readiness condition before running
bootstrap: an uninitialized Vault is Running but not Ready. The bootstrap
script waits for pod phase `Running`, initializes/unseals Vault, enables KV v2,
and configures Kubernetes auth.

To create the optional non-root Vault UI login during bootstrap, set
`VAULT_USER_PASSWORD` before running the script:

```bash
export VAULT_USER_PASSWORD='choose-a-strong-password'
bash ./vault/bootstrap.sh
unset VAULT_USER_PASSWORD
```

## Certificate Storage

The local certificate and private key are intentionally not stored in this repository. The bootstrap script stores an existing wildcard certificate in Vault at:

```bash
secret/ndomi-local-wildcard
```

The certificate should cover `*.ndomi.local`, including `argocd.ndomi.local` and `vault.ndomi.local`.

## External Secrets Operator

Install the operator:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
   --namespace external-secrets \
   --create-namespace \
   --set installCRDs=true
```

Apply the Vault Gateway and synchronization resources:

```bash
kubectl apply -k vault
```

The resources in `vault/argocd-secret-sync.yaml` create dedicated `vault-auth`
service accounts. `vault/bootstrap.sh` configures Kubernetes authentication,
the read-only policy, and the `external-secrets` role before applying these
resources.

The bootstrap script also applies `infrastructure/monitoring`, so the
Prometheus and Grafana TLS Secrets are recreated from the same Vault value.
Deleting the Vault PVC intentionally destroys the Vault state and requires
initialization again; uninstalling and reinstalling the Helm release alone
does not delete the PVC.

Force synchronization after changing the Vault value or authentication:

```bash
kubectl -n argocd annotate externalsecret argocd-tls \
   force-sync="$(date +%s)" --overwrite
kubectl -n vault annotate externalsecret vault-tls \
   force-sync="$(date +%s)" --overwrite
```

Verify:

```bash
kubectl -n argocd get externalsecret,secret argocd-tls
kubectl -n vault get externalsecret,secret vault-tls
kubectl -n monitoring get externalsecret,secret prometheus-tls
kubectl -n monitoring get externalsecret,secret grafana-tls
```

## Hostnames and TLS Tests

Add the Gateway IP to `/etc/hosts`:

```text
192.168.1.240 argocd.ndomi.local vault.ndomi.local prometheus.ndomi.local grafana.ndomi.local
```

Test both routes:

```bash
curl -k --resolve argocd.ndomi.local:443:192.168.1.240 \
   https://argocd.ndomi.local
curl -k --resolve vault.ndomi.local:443:192.168.1.240 \
   https://vault.ndomi.local/v1/sys/health
curl -k --resolve prometheus.ndomi.local:443:192.168.1.240 \
   https://prometheus.ndomi.local/-/ready
curl -k --resolve grafana.ndomi.local:443:192.168.1.240 \
   https://grafana.ndomi.local/api/health
```

The `-k` flag is only needed when the local `mkcert` CA is not trusted by the client.

## Verification Checklist

Use these checks after installation:

```bash
kubectl get nodes
kubectl get gateway -A
kubectl get httproute -A
kubectl get applications -n argocd
kubectl get externalsecret -A
kubectl get secret -A | grep -E '(argocd-tls|vault-tls|prometheus-tls|grafana-tls)'
argocd app list
```

An Argo CD Application should report `Synced` and `Healthy`. Each ExternalSecret
should report `SecretSynced`; a missing TLS Secret usually means Vault is sealed,
the Kubernetes auth role is incorrect, or the External Secrets controller has
not been restarted after its installation.

## Grafana

Grafana is a standalone Argo CD Helm Application. Its data is persistent on
the `local-path` StorageClass, and the Grafana datasource uses the internal
Prometheus Service rather than the external hostname:

```text
http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
```

The admin password can be reset inside the running pod:

```bash
kubectl -n monitoring exec deploy/grafana -- \
   grafana cli admin reset-admin-password 'NewStrongPassword'
```

If Grafana remains unready, inspect the `init-chown-data` container. The local
path configuration disables that init container because it cannot chown the
mounted volume under this cluster's security policy.

## Prometheus Metrics

Metrics are enabled for the platform components:

- Traefik exposes Prometheus metrics and creates a ServiceMonitor through `traefik/values.yaml`.
- MetalLB and bundled FRR-K8s expose metrics and create ServiceMonitors through `metallb/values.yaml`.
- Argo CD metrics Services receive Prometheus scrape annotations through the Argo CD Kustomization.
- Talos-incompatible control-plane, kube-proxy, and node-exporter monitors are disabled in the Argo-managed chart values.

These settings configure scrape targets. Prometheus is managed by Argo CD through `infrastructure/argocd/base/prometheus-application.yaml`.

Bootstrap the Argo Application:

```bash
kubectl apply --server-side \
   -k infrastructure/argocd/overlays/dev
argocd app get prometheus
argocd app sync prometheus
```

If Prometheus was previously installed directly with Helm, remove that release
after the Argo Application is created and healthy:

```bash
helm uninstall prometheus --namespace monitoring
argocd app sync prometheus
```

Apply component metric configuration after upgrading their releases:

```bash
helm upgrade traefik traefik/traefik \
   --namespace traefik \
   -f traefik/values.yaml
helm upgrade metallb metallb/metallb \
   --namespace metallb-system \
   -f metallb/values.yaml
```

Check the monitoring resources:

```bash
kubectl -n monitoring get servicemonitor
kubectl -n argocd get svc -o wide
kubectl -n traefik get svc -o wide
kubectl -n metallb-system get svc -o wide
```

Expose the Argo-managed Prometheus UI through Gateway API:

```bash
kubectl apply -k monitoring
```

The monitoring Kustomization creates a namespace-local TLS Secret from Vault
and routes `prometheus.ndomi.local` to
`prometheus-kube-prometheus-prometheus:9090`.

## GitOps with Argo CD

The platform Application monitors the GitHub repository and synchronizes the
development overlay:

```text
Repository: https://github.com/Ndomi-Nqeketo/platform_engineer_project.git
Branch: masters
Path: infrastructure/argocd/overlays/dev
```

It is defined in `infrastructure/argocd/base/platform-application.yaml` with
automated pruning, self-healing, and server-side apply. The repository must
contain the configured path before Argo CD can generate manifests.

Apply or inspect it with:

```bash
kubectl apply --server-side \
   -k infrastructure/argocd/overlays/dev
argocd app get platform-engineer-project
argocd app sync platform-engineer-project
```

Do not combine Argo CD `Force=true` with `ServerSideApply=true`; Kubernetes
rejects that combination.

## Vault Human Login

Kubernetes authentication is reserved for External Secrets. For interactive access, use a non-root `userpass` account:

```bash
export VAULT_ADDR=https://vault.ndomi.local
export VAULT_TOKEN=root
export VAULT_SKIP_VERIFY=true
vault auth enable userpass
vault policy write ndomi-user - <<'EOF'
path "secret/data/ndomi-local-wildcard" {
   capabilities = ["create", "read", "update"]
}
path "secret/metadata/ndomi-local-wildcard" {
   capabilities = ["read", "list"]
}
EOF
vault write auth/userpass/users/ndomi \
   password='choose-a-strong-password' \
   policies=ndomi-user
unset VAULT_TOKEN
vault login -method=userpass username=ndomi
```

The Vault UI is available at `https://vault.ndomi.local`. Use the Username authentication method there.
