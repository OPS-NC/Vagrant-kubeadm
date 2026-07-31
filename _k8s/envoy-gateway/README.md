<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🚪 `envoy-gateway/` — the cluster's HTTP(S) entry point

> **One VIP, two listeners, N applications.** [Envoy Gateway](https://gateway.envoyproxy.io/)
> (an implementation of the **Gateway API**) deploys an Envoy whose `LoadBalancer` Service picks
> up the `192.168.56.200` VIP from the Cilium pool. The `main-gateway` `Gateway` exposes `:80`
> **and** `:443` on it (wildcard TLS `*.kubeadm.lab.example.io`), and every component plugs in with
> an `HTTPRoute`.

> 🌐 **`kubeadm.lab.example.io` is the repo's NEUTRAL domain (it is public)**: `platform-up.sh`
> replaces it with `LAB_DOMAIN` (`lab.env`) — hostname of the `https` listener and name of the
> TLS Secret. See [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- **Share the exposure**: one IP, one certificate, one configuration point for every lab UI
  (Argo CD, Vault, Longhorn, Grafana, Policy Reporter, WordPress…).
- **Do the Gateway API for real**: `GatewayClass` → `Gateway` → `HTTPRoute`, with
  **cross-namespace** attachment, filters and routing by path or by hostname.
- **Terminate TLS** at the cluster edge: the backends speak plain HTTP.

> ⚠️ **Do not confuse this with the Envoy embedded in Cilium** (disabled here:
> `envoy.enabled=false`, see [`../cilium/README.md`](../cilium/README.md)). Here Envoy is driven
> by the **Envoy Gateway** controller, a component in its own right.

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| [`../cilium/`](../cilium/README.md) installed (L2 pool) | it is what gives the `.200` IP to the Gateway's Service | `kubectl get ciliumloadbalancerippool` |
| A wildcard TLS Secret, from **either** TLS mode | fills the `wildcard-kubeadm-lab-example-io-tls` Secret of the `:443` listener | `kubectl -n envoy-gateway-system get secret wildcard-…-tls` |
| Name resolution for `*.kubeadm.lab.example.io → 192.168.56.200` | routes match by hostname | `dig +short argo.kubeadm.lab.example.io` |

The TLS Secret comes from [`../self-signed/`](../self-signed/README.md) when
`SELF_SIGNED=true` (the default — a local CA, no domain and no token needed) or from
[`../cert-manager/`](../cert-manager/README.md) + a Cloudflare token when `SELF_SIGNED=false`.
The Gateway is the same either way: only the annotation differs. Likewise, resolution can be
an `/etc/hosts` line (self-signed) or a public **DNS-only** record (ACME).

HTTP (`:80`) works with neither TLS mode nor DNS: `curl http://192.168.56.200/...`.

## ⚡ Install

The controller **is** installed by the platform, step `[2/4]`:

```bash
./_k8s/platform-up.sh
```

OCI chart `oci://docker.io/envoyproxy/gateway-helm` **`1.8.3`**, pinned in `../platform-up.sh`
(`ENVOY_GW_VERSION`, overridable). The chart also installs the **standard Gateway API CRDs** —
which cert-manager depends on (`config.enableGatewayAPI=true`). The script then applies
`Envoy-Proxy.yml` and waits for the LoadBalancer IP (30 × 5 s).

<details>
<summary>Manual equivalent (if you only want to install this component)</summary>

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version 1.8.3 -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway
kubectl apply -f _k8s/envoy-gateway/Envoy-Proxy.yml
```
</details>

## 🔧 `Envoy-Proxy.yml` — the plumbing

| Object | Role |
|---|---|
| `EnvoyProxy` **`cilium-l2`** | configures the Envoy infrastructure: `type: LoadBalancer` Service with `loadBalancerClass: io.cilium/l2-announcer` → the IP comes from the **Cilium pool**; and `envoyDeployment.replicas: 2` for the data plane |
| `GatewayClass` **`envoy`** | class managed by `gateway.envoyproxy.io/gatewayclass-controller`, pointing at the `EnvoyProxy` above |
| `Gateway` **`main-gateway`** (ns `envoy-gateway-system`) | the entry point: **`http:80`** and **`https:443`** listeners, `allowedRoutes.namespaces.from: All` |

It is the `EnvoyProxy`'s Service that triggers the Cilium L2 announcement → hence the `.200` VIP.

### Data plane: 2 replicas

Do not confuse the two Deployments in `envoy-gateway-system`:

| Deployment | Role | Losing it |
|---|---|---|
| `envoy-gateway` | the **controller**: watches Gateways/HTTPRoutes and configures the proxies | no traffic impact, config just stops being reconciled |
| `envoy-…-main-gateway-…` | the **data plane**: the pods that actually carry the traffic | **every UI in the lab is down** |

That second one is the single path for every UI (one LoadBalancer IP, `.200`), so
`Envoy-Proxy.yml` pins it at **`replicas: 2`**: the Service keeps a ready endpoint while a pod
is being rescheduled, a node reboots, or [`../chaos-kube/`](../chaos-kube/README.md) draws it
in its hourly lottery. Both pods share the same IP — nothing to change in DNS or in any
`HTTPRoute`.

```bash
kubectl -n envoy-gateway-system get deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=main-gateway    # expect 2/2
```

> ℹ️ Nothing pins the two pods to **different** nodes: the scheduler spreads them on its own,
> but that is not a guarantee. For a hard guarantee, add a `podAntiAffinity` under
> `envoyDeployment.pod.affinity` — with a `required` rule, keep it under the number of workers
> or the surplus pods stay `Pending`.

### The two listeners (already wired, nothing to add)

| Listener | Port | Hostname | TLS |
|---|---|---|---|
| `http` | 80 | *(none — any hostname)* | — |
| `https` | 443 | `*.kubeadm.lab.example.io` | `Terminate`, `certificateRefs: wildcard-kubeadm-lab-example-io-tls` |

The `cert-manager.io/cluster-issuer` annotation on the Gateway is enough for cert-manager to
create the `Certificate`, solve the DNS-01 challenge and fill the Secret. The versioned
manifest carries `letsencrypt-staging`; `platform-up.sh` rewrites it from `LAB_ACME_ISSUER`
(`staging` by default, `prod` on demand — mind the **5 certificates/week** production cap). The
mechanism is detailed in [`../cert-manager/README.md`](../cert-manager/README.md).

> ℹ️ **With the default `SELF_SIGNED=true`, `platform-up.sh` strips that annotation entirely**
> and fills the very same Secret with an `openssl`-signed wildcard
> ([`../self-signed/`](../self-signed/README.md)). The `certificateRefs` above do not change —
> which is exactly why no addon has to care which TLS mode the lab runs.

### Attaching an application

This is the only work left for a new component: an `HTTPRoute` targeting the TLS listener.

```yaml
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https           # targets the :443 listener (without it, BOTH listeners)
  hostnames:
    - my-app.kubeadm.lab.example.io      # must match the wildcard *.kubeadm.lab.example.io
  rules:
    - backendRefs:
        - name: my-app
          port: 80
```

The route can live in **its own** namespace (the Gateway accepts `from: All`); the backend, on
the other hand, must be in the same namespace as the route — otherwise you need a
`ReferenceGrant`.

## ✅ Verify

```bash
kubectl -n envoy-gateway-system get svc        # EXTERNAL-IP = 192.168.56.200 (otherwise → ../cilium/)
kubectl get gateway -n envoy-gateway-system    # main-gateway, PROGRAMMED=True, ADDRESS=.200
kubectl get httproute -A                       # every route in the lab
# listeners + number of routes attached to each:
kubectl -n envoy-gateway-system get gateway main-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{" attached="}{.attachedRoutes}{"\n"}{end}'
# the cert served for a hostname of the wildcard:
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.kubeadm.lab.example.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

## 🧪 `GW-Example.yml` — the demo (optional)

Two apps and their `HTTPRoute`s, using **path-based routing**:

| App | Route | Backend |
|---|---|---|
| `hello-nginx` (`nginxdemos/nginx-hello:plain-text`) | `/hello` → rewritten to `/` | `hello-nginx:80` |
| `echo-app` (`ealen/echo-server:latest`) | `/echo` → rewritten to `/` | `echo-app:80` |

```bash
kubectl apply -f _k8s/envoy-gateway/GW-Example.yml       # namespace `default`
curl -sS http://192.168.56.200/hello
curl -sS http://192.168.56.200/echo
kubectl delete -f _k8s/envoy-gateway/GW-Example.yml      # remove after the demo
```

> ℹ️ These routes have **neither `hostnames` nor `sectionName`**: they therefore attach to **both**
> listeners. Verified consequence: `/hello` also answers over HTTPS, under *any* subdomain of the
> wildcard (`https://foo.kubeadm.lab.example.io/hello` → `200`). On the other hand
> `https://hello.kubeadm.lab.example.io/` returns **404**: the match is on the **path**, not on the
> hostname.

## ⚠️ Pitfalls

- **Empty `ADDRESS` / `<pending>`** → the problem is on the [`../cilium/`](../cilium/README.md)
  side (missing pool or inactive L2 announcement), not here.
- **404 on a route** → path/hostname matching nothing, `sectionName` missing or wrong, or a
  hostname outside the wildcard (`app.kubeadm.lab.example.io` ✔, `app.lab.example.io` ✘ — the
  wildcard covers **one** level only).
- **Not every UI exposed behind this Gateway has authentication.** The **Longhorn** UI
  (`../longhorn/httproute.yaml`) has **none**; neither does the Policy Reporter UI (nothing is
  configured in `../kyverno/policy-reporter-values.yaml`). Published on the VIP, they are
  reachable by anyone who reaches `.200` — so by every authorized Tailscale peer. To protect
  them: an Envoy Gateway `SecurityPolicy` (Basic Auth / OIDC) targeting the route. Vault and
  Argo CD do have their own authentication.
- **`GW-Example.yml` violates the repo's own policies**: `ealen/echo-server:latest` is rejected by
  `disallow-latest-tag` ([`../kyverno/`](../kyverno/README.md)), and
  `nginxdemos/nginx-hello:plain-text` is a **floating tag** (it passes the policy but pins no
  version). Both apps would also trip the `restricted` PodSecurity profile
  (`allowPrivilegeEscalation`, `capabilities`, `runAsNonRoot`, `seccompProfile`) — but on kubeadm
  the PodSecurity admission enforces **nothing** cluster-wide by default, so nothing complains
  until you label the namespace or install Kyverno. Ideal demo material for "here is what a
  policy catches".
- **The demo apps land in `default`** (no namespace in the manifest): delete them after the demo
  so they do not pollute the Kyverno/Trivy reports.
- **A competing `Gateway` overwrites this one**: `../cert-manager/04-gateway-https-example.yaml`
  redefines `main-gateway` with the same `name`/`namespace`. Do not apply it (see its README).

## 📚 References

- [Gateway API — documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway — documentation](https://gateway.envoyproxy.io/docs/)
- [Envoy Gateway — SecurityPolicy (Basic Auth, OIDC, JWT)](https://gateway.envoyproxy.io/docs/tasks/security/)
- [`../cilium/README.md`](../cilium/README.md) — where the VIP comes from ·
  [`../cert-manager/README.md`](../cert-manager/README.md) — where the certificate comes from
  with `SELF_SIGNED=false`, and [`../self-signed/README.md`](../self-signed/README.md) with the
  default `SELF_SIGNED=true`
