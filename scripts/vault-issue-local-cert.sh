#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
GARRISON_VAULT_TLS_DIR="${GARRISON_VAULT_TLS_DIR:-$ROOT_DIR/logs/vault/tls}"
GARRISON_VAULT_CA_FILE="${GARRISON_VAULT_CA_FILE:-$GARRISON_VAULT_TLS_DIR/vault-ca.pem}"
GARRISON_VAULT_CERT_TTL="${GARRISON_VAULT_CERT_TTL:-24h}"

mkdir -p "${GARRISON_VAULT_TLS_DIR}"

if [[ "${VAULT_ADDR}" == https://* && -f "${GARRISON_VAULT_CA_FILE}" ]]; then
  export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$GARRISON_VAULT_CA_FILE}"
fi

payload="$(CERT_TTL="${GARRISON_VAULT_CERT_TTL}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "common_name": "vault",
    "alt_names": "vault,localhost",
    "ip_sans": "127.0.0.1",
    "ttl": os.environ.get("CERT_TTL", "24h"),
    "format": "pem",
}))
PY
)"

response="$(curl -fsS -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${payload}" \
  "${VAULT_ADDR}/v1/pki_int/issue/vault-server")"

VAULT_ISSUE_RESPONSE="${response}" python3 - "${GARRISON_VAULT_TLS_DIR}" "${GARRISON_VAULT_CA_FILE}" <<'PY'
import json
import os
import sys
from pathlib import Path

tls_dir = Path(sys.argv[1])
ca_file = Path(sys.argv[2])
data = json.loads(os.environ["VAULT_ISSUE_RESPONSE"])["data"]

certificate = (data.get("certificate") or "").strip()
private_key = (data.get("private_key") or "").strip()
issuing_ca = (data.get("issuing_ca") or "").strip()
ca_chain = [item.strip() for item in (data.get("ca_chain") or []) if item and item.strip()]

if not certificate or not private_key:
    raise SystemExit("Vault PKI did not return certificate material")

cert_chain = "\n".join([certificate, *ca_chain]).strip() + "\n"
ca_bundle_items = [item for item in [issuing_ca, *ca_chain] if item]
if not ca_bundle_items:
    ca_bundle_items = [certificate]

(tls_dir / "vault.crt").write_text(cert_chain)
(tls_dir / "vault.key").write_text(private_key + "\n")
ca_file.write_text("\n".join(dict.fromkeys(ca_bundle_items)) + "\n")
PY

chmod 600 "${GARRISON_VAULT_TLS_DIR}/vault.key"
chmod 644 "${GARRISON_VAULT_TLS_DIR}/vault.crt" "${GARRISON_VAULT_CA_FILE}"

echo "Vault listener certificate refreshed from Vault PKI."
