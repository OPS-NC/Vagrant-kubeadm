<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 📜 `cert-manager/` — automatic wildcard TLS (ACME DNS-01 Cloudflare)

> **A public `*.kubeadm.lab.example.io` certificate, issued and renewed with zero effort.**
> cert-manager watches `main-gateway`, reads an annotation on it, creates the `Certificate`,
> proves to Let's Encrypt that you control the domain through a **DNS TXT record at Cloudflare**,
> then fills the Secret that Envoy's `:443` listener serves. No inbound port, no hand-written
> `Certificate`.

> ⚠️ **This is the opt-in TLS mode.** `platform-up.sh` installs cert-manager **only** when
> `SELF_SIGNED=false` in `lab.env`. The default (`SELF_SIGNED=true`) signs the same wildcard
> locally with `openssl` and installs none of this — see
> [`../self-signed/`](../self-signed/README.md), which also compares the two modes side by
> side. Everything below assumes you set `SELF_SIGNED=false`.

## 🎯 Purpose

Every lab UI (`argo.`, `vault.`, `longhorn.`, `grafana.`, `kyverno.`, `wordpress.`…) is served
over HTTPS **trusted by browsers** behind a private IP, with no security exception to click and
no home-made CA to distribute.

### Why DNS-01, why Let's Encrypt

- **DNS-01**: Let's Encrypt validates the domain through a
  `_acme-challenge.kubeadm.lab.example.io` TXT record, written by cert-manager with the Cloudflare
  token. **No inbound connection required** → it works behind a host-only network + Tailscale,
  where HTTP-01 would fail.
- **Wildcard**: only DNS-01 can issue `*.kubeadm.lab.example.io` (HTTP-01 cannot).
- **Let's Encrypt rather than Cloudflare Origin CA**: since DNS is in **DNS-only mode (grey
  cloud)**, TLS is terminated by **Envoy**, not by the Cloudflare edge. So it is the browser that
  validates Envoy's certificate → it must be **publicly trusted**. An *Origin CA* cert (trusted
  only by the Cloudflare edge) would be rejected.

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| `main-gateway` in place ([`../envoy-gateway/`](../envoy-gateway/README.md)) | that is the object cert-manager watches | `kubectl get gateway -n envoy-gateway-system` |
| **Gateway API CRDs** present | cert-manager discovers them at startup (installed by the Envoy Gateway chart) | `kubectl get crd gateways.gateway.networking.k8s.io` |
| `example.io` zone at Cloudflare, `*.kubeadm.lab.example.io → 192.168.56.200` in **DNS-only** mode | the DNS-01 solver writes into that zone | `dig +short TXT _acme-challenge.kubeadm.lab.example.io` |
| **Cloudflare API token** (`Zone/DNS/Edit` + `Zone/Zone/Read`, scoped to `example.io`) | lets cert-manager write the TXT record | `kubectl -n cert-manager get secret cloudflare-api-token` |

The token goes into **`lab.env`** (`CLOUDFLARE_API_TOKEN=…`, a gitignored file): that is where
`platform-up.sh` picks it up to create the Secret.

> 🌐 **Neutral domain by default** (the repo is public): the manifests carry
> `kubeadm.lab.example.io` and the `example.io` zone. `platform-up.sh` substitutes on the fly, from
> `lab.env`: `LAB_DOMAIN` (wildcard hostname), `LAB_DNS_ZONE` (the solver's `dnsZones` — default:
> the last 2 labels of `LAB_DOMAIN`) and `LAB_ACME_EMAIL` (default `admin@<zone>`). The TLS
> `Certificate`/`Secret` follows the domain: `wildcard-<LAB_DOMAIN with dashes>-tls`. Without the
> substitution the solver would never match your zone and the certificate would stay pending. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## ⚡ Install

cert-manager is installed by the platform, step `[4/4]`, **provided `SELF_SIGNED=false`**:

```bash
echo 'SELF_SIGNED=false' >> lab.env      # otherwise step [4/4] goes the self-signed route
./_k8s/platform-up.sh
```

Chart `jetstack/cert-manager` **`v1.20.2`**, pinned in `../platform-up.sh`
(`CERT_MANAGER_VERSION`). The script:

1. installs the chart with `crds.enabled=true` and **`config.enableGatewayAPI=true`** (Gateway API
   integration, no longer behind a feature flag since cert-manager 1.15);
2. creates the `cloudflare-api-token` Secret from `lab.env` (it warns and continues if the token
   is empty — the certificate then stays pending);
3. applies **`02-clusterissuer-staging.yaml`** and **`03-clusterissuer-prod.yaml`**;
4. waits for `Ready=True` on the `wildcard-kubeadm-lab-example-io-tls` `Certificate` — a name
   derived from `LAB_DOMAIN` (~1-2 min, 24 × 10 s).

<details>
<summary>Manual equivalent (installing only this component)</summary>

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
# --version: keep the one from platform-up.sh (CERT_MANAGER_VERSION)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token='<YOUR_TOKEN>'
kubectl apply -f _k8s/cert-manager/02-clusterissuer-staging.yaml \
              -f _k8s/cert-manager/03-clusterissuer-prod.yaml
```
</details>

## 🔧 How the certificate is issued

```
Gateway main-gateway
  ├─ annotation cert-manager.io/cluster-issuer: letsencrypt-staging   (LAB_ACME_ISSUER)
  └─ listener https (hostname *.kubeadm.lab.example.io, certificateRefs: wildcard-kubeadm-lab-example-io-tls)
        │
        ▼  cert-manager (config.enableGatewayAPI=true) watches the Gateway
   Certificate wildcard-kubeadm-lab-example-io-tls   (dnsNames derived from the listener `hostname`)
        │  Order ──► Challenge dns-01 ──► TXT _acme-challenge.kubeadm.lab.example.io (Cloudflare API)
        ▼
   Secret wildcard-kubeadm-lab-example-io-tls  (ns envoy-gateway-system)  ──►  served by Envoy on :443
```

The `Certificate` **and** the Secret are born in the Gateway's namespace
(`envoy-gateway-system`), not in `cert-manager`. Renewal is automatic (at ~2/3 of the lifetime).

> 💡 **Without the Gateway API integration**, you get the same result by hand: write a
> `Certificate` (`dnsNames: ["*.kubeadm.lab.example.io"]`, `issuerRef: letsencrypt-staging`,
> `secretName: wildcard-kubeadm-lab-example-io-tls`) and let the listener reference it. Same
> outcome, you just create the object instead of cert-manager.

### Files

| File | Role |
|---------|------|
| `01-cloudflare-api-token.example.yaml` | **template** for the token Secret — never commit the real one (prefer `lab.env` + `platform-up.sh`) |
| `02-clusterissuer-staging.yaml` | Let's Encrypt **staging** `ClusterIssuer` (generous quotas, untrusted cert) |
| `03-clusterissuer-prod.yaml` | Let's Encrypt **prod** `ClusterIssuer` (trusted cert) — the one referenced by the Gateway |
| `04-gateway-https-example.yaml` | **historical illustration, do NOT apply** (see ⚠️ Pitfalls) |

> ⚠️ **`04-gateway-https-example.yaml` must not be applied any more.** It contains a full
> `main-gateway` `Gateway` (same `name`/`namespace`): a `kubectl apply` would **replace** the
> Gateway in place. The merge is **already done** in `../envoy-gateway/Envoy-Proxy.yml`
> (`https:443` listener + wildcard `hostname` + `certificateRefs` + `cluster-issuer` annotation),
> and `../platform-up.sh` only applies `02-` and `03-`. Keep the file as reading material: it
> shows the "HTTPS + cert-manager" part of the Gateway in isolation.

## ✅ Verify

```bash
kubectl get clusterissuer                                        # both issuers, READY=True
kubectl -n envoy-gateway-system get certificate                  # wildcard-…-tls, READY=True
kubectl -n envoy-gateway-system describe certificate wildcard-kubeadm-lab-example-io-tls
                                                                 # events: Order → Challenge → issued
kubectl get challenges -A                                        # empty once validated

# Which certificate does Envoy serve? (no HTTPRoute needed: we only test TLS)
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.kubeadm.lab.example.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# expected: subject=CN=*.kubeadm.lab.example.io, issuer=Let's Encrypt (and not "STAGING")
```

End-to-end HTTPS test: you need a hostname that **carries an `HTTPRoute`** (the demo routes in
`../envoy-gateway/GW-Example.yml` match by path, not by hostname). For example, once the Argo CD
component is installed:

```bash
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 https://argo.kubeadm.lab.example.io/
# expected: 200 verify=0   (verify=0 = chain validated without -k)
```

## 🚑 Troubleshooting

- **`Challenge` stuck in `pending`** → Cloudflare token (permissions or zone), or slow TXT
  propagation. `kubectl describe challenge <name>` gives the exact error from the Cloudflare API.
- **`cloudflare-api-token` Secret missing** → `CLOUDFLARE_API_TOKEN` was empty in `lab.env` when
  `platform-up.sh` ran (the script reports it without failing). Create the Secret, then
  `kubectl -n envoy-gateway-system delete challenge --all` to retry (the `Order`s/`Challenge`s
  live in the `Certificate`'s namespace, so in the Gateway's).
- **`Certificate` never created despite the annotation** → cert-manager is not running with
  `config.enableGatewayAPI=true`, or it started **before** the Gateway API CRDs:
  `kubectl -n cert-manager rollout restart deploy/cert-manager`.
- **Browser refusing the certificate** → you are on `letsencrypt-staging`, which is the
  **default**. Set `LAB_ACME_ISSUER=prod` in `lab.env`, re-run `platform-up.sh`, then delete the
  Secret to force a reissue:
  `kubectl -n envoy-gateway-system delete secret wildcard-<domain-in-dashes>-tls`.
- **`429 rateLimited` in prod** → the **5 certificates per week per identifier set** cap is
  reached. Nothing to fix, nothing to retry: the message carries the `retry after` timestamp and
  the window is 168 h sliding. Note that **every `vagrant destroy` burns a slot**, because the
  wildcard only lives in etcd. Go back to `LAB_ACME_ISSUER=staging` while you wait, or back the
  Secret up before destroying (see [`../../README.md`](../../README.md) §5).

## ⚠️ Pitfalls

- **`SELF_SIGNED=true` (the default) skips this whole page.** If `kubectl get clusterissuer`
  answers `no resources found` and the Gateway carries no `cert-manager.io/cluster-issuer`
  annotation, nothing is broken — you are simply on the self-signed path. Set
  `SELF_SIGNED=false` in `lab.env` and re-run `platform-up.sh`, then delete the leftover
  self-signed Secret so cert-manager issues its own:
  `kubectl -n envoy-gateway-system delete secret <wildcard>-tls`.
- **Do not apply `04-gateway-https-example.yaml`** (see the callout above).
- **A single wildcard level**: `*.kubeadm.lab.example.io` covers `argo.kubeadm.lab.example.io`, not
  `a.b.kubeadm.lab.example.io`. A route with a hostname that is not covered will not attach to the
  listener.
- **The committed ACME e-mail is neutral** (`admin@example.io`): `platform-up.sh` replaces it with
  `LAB_ACME_EMAIL` (default `admin@<LAB_DNS_ZONE>`). With a direct `kubectl apply -f`, you apply
  the example address — and Let's Encrypt rejects some reserved domains.
- **DNS-only is mandatory on the Cloudflare side**: in "orange proxy" mode the edge would try to
  reach `192.168.56.200` and access would break (the DNS-01 challenge itself would still work).

## 📚 References

- [`../self-signed/README.md`](../self-signed/README.md) — the other TLS mode (`SELF_SIGNED=true`, the default)
- [cert-manager — Gateway API integration](https://cert-manager.io/docs/usage/gateway/)
- [cert-manager — DNS-01 Cloudflare](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Let's Encrypt — Rate limits](https://letsencrypt.org/docs/rate-limits/)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the Gateway that carries this certificate
