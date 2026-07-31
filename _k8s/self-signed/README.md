<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🔏 `self-signed/` — wildcard TLS without cert-manager (`openssl`)

> **HTTPS on every lab UI with no domain, no Cloudflare token and no Internet.**
> A local CA generated once on the host signs a `*.<LAB_DOMAIN>` wildcard, which lands in
> exactly the Secret the Envoy `:443` listener already expects. cert-manager is not
> installed at all.

## 🎯 Purpose

This is the **default TLS mode** of the lab (`SELF_SIGNED=true` in `lab.env`). It exists
because the other path has real prerequisites: the ACME route
([`../cert-manager/`](../cert-manager/README.md)) needs a **domain you actually own**, a
**Cloudflare token**, and it spends **Let's Encrypt quota** on every rebuild. For a
throwaway lab on a host-only network, that is a lot of setup for a certificate nobody
outside your machine will ever see.

The trade-off is the only one that matters here: the certificate is **not publicly
trusted**. Browsers warn until you import the CA once — see [🌐 Access](#-access).

| | `SELF_SIGNED=true` (this page) | `SELF_SIGNED=false` ([`cert-manager/`](../cert-manager/README.md)) |
|---|---|---|
| Real domain required | no | **yes** |
| `CLOUDFLARE_API_TOKEN` | not used | **required** |
| Works offline | yes | no (ACME + DNS-01) |
| Browser-trusted out of the box | no (import the CA once) | yes (with `LAB_ACME_ISSUER=prod`) |
| Rate limit | none | **5 certs/week** in `prod` |
| Auto-renewal in-cluster | no (re-run the script) | yes (cert-manager) |
| Survives `vagrant destroy` | **yes** (CA + cert live on the host) | no (wildcard only lives in etcd) |

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| `openssl` on the host | generates the CA and the certificate | `openssl version` |
| `main-gateway` in place ([`../envoy-gateway/`](../envoy-gateway/README.md)) | it is the listener that serves the Secret | `kubectl get gateway -n envoy-gateway-system` |
| `LAB_DOMAIN` set in `lab.env` | drives the SAN and the Secret name | `sed -n 's/^LAB_DOMAIN=//p' lab.env` |

No DNS zone, no API token, no inbound port. The domain **does not have to exist
publicly** — it only has to resolve on the machine you browse from.

## ⚡ Install

It is installed by the platform, step `[4/4]`, whenever `SELF_SIGNED=true`:

```bash
./_k8s/platform-up.sh
```

Standalone, on an existing platform:

```bash
./_k8s/self-signed/selfsigned-up.sh
```

Idempotent: re-running it reuses the CA and keeps the certificate as long as it is still
valid.

## 🔧 How it works

```
_out/self-signed/ca.key + ca.crt        local CA, 10 years, generated ONCE and reused
        │  signs
        ▼
_out/self-signed/tls.key + tls.crt      leaf, 825 days
        │  SAN: DNS:*.<LAB_DOMAIN>, DNS:<LAB_DOMAIN>   ·   extendedKeyUsage: serverAuth
        ▼
Secret wildcard-<LAB_DOMAIN with dashes>-tls   (ns envoy-gateway-system, type kubernetes.io/tls)
        │  tls.crt = leaf + CA (full chain)
        ▼
served by Envoy on :443 — the same Secret name cert-manager would have filled
```

Because the Secret name is identical on both paths, **the Gateway manifest does not
change** between modes: `platform-up.sh` only strips the
`cert-manager.io/cluster-issuer` annotation from `main-gateway` when `SELF_SIGNED=true`,
so nothing ever tries to take the Secret over.

### Why the material lives in `_out/`

`_out/` is **gitignored** — the CA private key can never end up in a commit. It also sits
on the **host**, not in etcd, so it **survives `vagrant destroy`**: you import the CA into
your trust store once and every future rebuild of the lab is trusted immediately. That is
the opposite of the ACME path, where each rebuild burns a fresh certificate.

### When the certificate is regenerated

The script rebuilds the leaf (never the CA) when:

- `_out/self-signed/tls.crt` is missing — e.g. after you wiped `_out/`;
- it expires in less than **30 days** (`RENEW_DAYS`);
- `LAB_DOMAIN` changed, so the SAN no longer covers the lab.

Overridable knobs: `CA_DAYS` (3650), `CERT_DAYS` (825), `RENEW_DAYS` (30). 825 days is the
ceiling browsers accept for a server certificate — do not raise `CERT_DAYS` above it.

### Files

| File | Role |
|---|---|
| `selfsigned-up.sh` | generates the CA + leaf, creates the TLS Secret. Called by `../platform-up.sh` step `[4/4]` |

Everything it produces is untracked, under `_out/self-signed/`.

## ✅ Verify

```bash
kubectl -n envoy-gateway-system get secret wildcard-<domain-in-dashes>-tls   # type kubernetes.io/tls
kubectl -n envoy-gateway-system get gateway main-gateway                     # PROGRAMMED=True
openssl x509 -in _out/self-signed/tls.crt -noout -subject -issuer -dates -ext subjectAltName

# Which certificate does Envoy actually serve?
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.<LAB_DOMAIN> 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# expected: subject=CN=*.<LAB_DOMAIN>, issuer=CN=Vagrant-KubeADM self-signed CA

# End-to-end, validating against the local CA (needs a hostname carrying an HTTPRoute):
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --cacert _out/self-signed/ca.crt \
  --resolve argo.<LAB_DOMAIN>:443:192.168.56.200 https://argo.<LAB_DOMAIN>/
# expected: 200 verify=0
```

## 🌐 Access

Two things stand between you and a green padlock.

**1. Resolve the name.** The domain need not exist publicly; `/etc/hosts` is enough:

```
192.168.56.200  argo.<LAB_DOMAIN> grafana.<LAB_DOMAIN> vault.<LAB_DOMAIN>
```

`192.168.56.200` is the Gateway's `EXTERNAL-IP` (`LB_POOL_START`). If you do own a DNS
zone, a wildcard `A` record is nicer — see
[`../README.md`](../README.md#-remote-access-tailscale--cloudflare).

**2. Trust the CA** — once, and it holds across every rebuild:

```bash
# Linux (Debian/Ubuntu), system store
sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain _out/self-signed/ca.crt
```

**Firefox has its own store** and ignores the system one: Settings → Privacy & Security →
Certificates → View Certificates → Authorities → Import → `_out/self-signed/ca.crt`.

Skipping this step is fine too — you just click through the browser warning on each UI.

## ⚠️ Pitfalls

- **Switching `false` → `true` on a live cluster** leaves cert-manager behind, and its
  `Certificate` object keeps reconciling the Secret. Re-running `platform-up.sh` removes
  the Gateway annotation, which makes cert-manager drop the `Certificate` — but if the
  object survives, delete it explicitly, otherwise it overwrites the self-signed Secret:
  `kubectl -n envoy-gateway-system delete certificate <wildcard>-tls`.
- **Switching `true` → `false`** does the reverse: delete the self-signed Secret so
  cert-manager issues a fresh one
  (`kubectl -n envoy-gateway-system delete secret <wildcard>-tls`).
- **Deleting `_out/` throws the CA away.** A new CA means re-importing it into every trust
  store. `_out/` is gitignored and never backed up — if you care about the CA, copy
  `ca.crt` **and** `ca.key` somewhere safe before a cleanup.
- **The CA private key is a real secret.** Anyone holding `_out/self-signed/ca.key` can
  forge a certificate for **any** domain that your trust store will accept, not just the
  lab's. That is the price of importing a CA rather than a single certificate — keep the
  file at `600` (the script sets it) and do not copy it around.
- **No in-cluster renewal.** Nothing watches the expiry: after 825 days, or after 795 with
  the 30-day margin, you re-run `selfsigned-up.sh`. For a lab that is rebuilt regularly,
  this never comes up.
- **A single wildcard level**: `*.<LAB_DOMAIN>` covers `argo.<LAB_DOMAIN>`, not
  `a.b.<LAB_DOMAIN>`. Same constraint as the ACME path.
- **`curl` without `--cacert` fails** with `unable to get local issuer certificate`. That
  is the certificate doing its job, not a bug — pass `--cacert _out/self-signed/ca.crt`,
  or import the CA.

## 📚 References

- [`../cert-manager/README.md`](../cert-manager/README.md) — the other TLS mode (`SELF_SIGNED=false`)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the Gateway that serves this certificate
- [Kubernetes — TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)
- [`openssl-x509(1)`](https://docs.openssl.org/master/man1/openssl-x509/) — the signing command used here
