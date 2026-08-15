#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
POD="${VAULT_POD:-vault-0}"
CERT_FILE="${CERT_FILE:?Set CERT_FILE to the wildcard certificate path}"
KEY_FILE="${KEY_FILE:?Set KEY_FILE to the wildcard private key path}"
INIT_FILE="${VAULT_INIT_FILE:-vault-init.json}"

kubectl -n "$NAMESPACE" wait \
  --for=jsonpath='{.status.phase}'=Running \
  pod/"$POD" \
  --timeout=180s

STATUS_JSON="$(kubectl -n "$NAMESPACE" exec "$POD" -- vault status -format=json 2>/dev/null || true)"
INITIALIZED="$(jq -r '.initialized // false' <<< "$STATUS_JSON")"
SEALED="$(jq -r '.sealed // true' <<< "$STATUS_JSON")"

if [[ "$INITIALIZED" == "true" ]]; then
  echo "Vault is already initialized."
  if [[ -f "$INIT_FILE" ]]; then
    ROOT_TOKEN="$(jq -r '.root_token' "$INIT_FILE")"
  else
    ROOT_TOKEN="${VAULT_TOKEN:?Set VAULT_TOKEN for an initialized Vault}"
  fi
  if [[ "$SEALED" == "true" ]]; then
    UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")"
    kubectl -n "$NAMESPACE" exec "$POD" -- vault operator unseal "$UNSEAL_KEY"
  fi
else
  kubectl -n "$NAMESPACE" exec "$POD" -- vault operator init \
    -format=json \
    -key-shares=1 \
    -key-threshold=1 > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  ROOT_TOKEN="$(jq -r '.root_token' "$INIT_FILE")"
  UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")"
  kubectl -n "$NAMESPACE" exec "$POD" -- vault operator unseal "$UNSEAL_KEY"
  echo "Initialization data saved to $INIT_FILE. Protect it securely."
fi

kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault secrets enable -path=secret kv-v2 || true"

kubectl -n "$NAMESPACE" cp "$CERT_FILE" "$POD:/tmp/ndomi-local-wildcard.crt"
kubectl -n "$NAMESPACE" cp "$KEY_FILE" "$POD:/tmp/ndomi-local-wildcard.key"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault kv put secret/ndomi-local-wildcard \\
    tls.crt=@/tmp/ndomi-local-wildcard.crt \\
    tls.key=@/tmp/ndomi-local-wildcard.key"

REVIEWER_JWT="$(kubectl -n "$NAMESPACE" create token vault)"
kubectl -n "$NAMESPACE" get configmap kube-root-ca.crt \
  -o jsonpath='{.data.ca\.crt}' > /tmp/kube-ca.crt
kubectl -n "$NAMESPACE" cp /tmp/kube-ca.crt "$POD:/tmp/kube-ca.crt"

kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault auth enable kubernetes || true"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault write auth/kubernetes/config \\
    token_reviewer_jwt='$REVIEWER_JWT' \\
    kubernetes_host=https://kubernetes.default.svc:443 \\
    kubernetes_ca_cert=@/tmp/kube-ca.crt"
kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault policy write external-secrets -" <<'EOF'
path "secret/data/ndomi-local-wildcard" {
  capabilities = ["read"]
}
EOF
kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
  "VAULT_TOKEN='$ROOT_TOKEN' vault write auth/kubernetes/role/external-secrets \\
    bound_service_account_names=vault-auth \\
    bound_service_account_namespaces=argocd,vault,monitoring \\
    policies=external-secrets \\
    ttl=1h"

if [[ -n "${VAULT_USER_PASSWORD:-}" ]]; then
  kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
    "VAULT_TOKEN='$ROOT_TOKEN' vault auth enable userpass || true"
  kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -ec \
    "VAULT_TOKEN='$ROOT_TOKEN' vault policy write ndomi-user -" <<'EOF'
path "secret/data/ndomi-local-wildcard" {
  capabilities = ["read", "create", "update"]
}

path "secret/metadata/ndomi-local-wildcard" {
  capabilities = ["read", "list"]
}

path "secret/metadata" {
  capabilities = ["list"]
}

path "sys/internal/ui/mounts/secret" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts/secret/*" {
  capabilities = ["read"]
}
EOF
  kubectl -n "$NAMESPACE" exec "$POD" -- sh -ec \
    "VAULT_TOKEN='$ROOT_TOKEN' vault write auth/userpass/users/ndomi \\
      password='$VAULT_USER_PASSWORD' \\
      policies=ndomi-user"
fi

kubectl apply -k vault
kubectl apply -k infrastructure/monitoring

for item in \
  "argocd argocd-tls" \
  "vault vault-tls" \
  "monitoring prometheus-tls" \
  "monitoring grafana-tls"; do
  read -r sync_namespace sync_name <<< "$item"
  kubectl -n "$sync_namespace" annotate externalsecret "$sync_name" \
    force-sync="$(date +%s)" --overwrite
done

echo "Vault bootstrap complete. Remove or securely store $INIT_FILE."
