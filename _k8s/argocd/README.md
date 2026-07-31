<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐙 `argocd/` — Argo CD (GitOps) exposed through the Gateway API

> **The lab's GitOps, over HTTPS, in one command.** Argo CD reconciles cluster state with Git
> manifests; its UI/API are published at `argo.kubeadm.lab.example.io` behind the same
> `main-gateway` as the rest of the lab, with the **`*.kubeadm.lab.example.io` wildcard** already
> issued by cert-manager — nothing new on the certificate side.

> 🌐 **`kubeadm.lab.example.io` is the repo's NEUTRAL domain (public)**: `argocd-up.sh` swaps it
> for `LAB_DOMAIN` (`lab.env`) in the Helm values **and** in the `HTTPRoute`. See
> [`../README.md`](../README.md#-lab_domain--the-ui-domain).

## 🎯 Purpose

- Run a **full GitOps cycle**: repo → `Application` → sync → drift detected → resync.
- Show one more **cross-namespace Gateway API attachment** (route in `argocd`, Gateway in
  `envoy-gateway-system`).
- Serve as a playground for deploying the other addons **through Git** instead of `kubectl`.

> ℹ️ **Standalone addon**: Argo CD is **not** installed by `../platform-up.sh` (which only
> lays down Cilium + Envoy Gateway + metrics-server + cert-manager). It installs on demand, like
> `../longhorn/`, `../vault-cluster/`, `../kyverno/`…

### The setup in one sentence

**Envoy terminates TLS, `argocd-server` speaks plaintext.** We set `server.insecure=true`: HTTPS
in front (wildcard cert), HTTP behind. Without it, `argocd-server` would issue its own
`307 http→https` redirect while the proxy already terminates TLS → **redirect loop**. This is
the recommended mode behind an ingress/gateway that handles TLS.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| `main-gateway` with the **`https:443`** listener ([`../envoy-gateway/`](../envoy-gateway/README.md)) | carries the UI over HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `wildcard-kubeadm-lab-example-io-tls` **`READY=True`** ([`../cert-manager/`](../cert-manager/README.md)) | otherwise TLS is untrusted | `kubectl -n envoy-gateway-system get certificate` |
| DNS `argo.kubeadm.lab.example.io → 192.168.56.200` in **DNS-only** | hostname of the `HTTPRoute` | `curl --resolve` otherwise (see ✅) |
| Nothing on the node side | Argo CD needs no privilege and no `hostPath` | `kubectl -n argocd get pods` |

## ⚡ Install

```bash
./_k8s/argocd/argocd-up.sh
```

Chart `argo/argo-cd` **`10.2.1`** (app **v3.4.5**), pinned in the script via `ARGOCD_VERSION`
(can be overridden). Idempotent (`helm upgrade --install` + `kubectl apply`).

<details>
<summary>Manual equivalent</summary>

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
# --version: keep the one from the script (ARGOCD_VERSION)
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.2.1 \
  --values _k8s/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f _k8s/argocd/httproute.yaml
```
</details>

## 🔧 What the script does

1. installs the chart in the `argocd` namespace with `values.yaml`, then waits for
   `deploy/argocd-server` (300 s max);
2. applies `httproute.yaml`;
3. prints the URL, the initial-password command and the test `curl`.

### Files

| File | Purpose |
|---------|------|
| `values.yaml` | `global.domain` + `server.insecure: true` + public `url`; **Dex** and **notifications** turned off (slimming down); ApplicationSet left enabled |
| `httproute.yaml` | HTTPS `HTTPRoute` `argo.kubeadm.lab.example.io` → `argocd-server:80`, `sectionName: https` |
| `argocd-up.sh` | installs Argo CD + applies the route (idempotent) |

The route lives in `argocd` and attaches to `main-gateway` (ns `envoy-gateway-system`) thanks to
`allowedRoutes.namespaces.from: All` on the Gateway side; since the backend sits in the same
namespace as the route, no `ReferenceGrant` is needed.

## ✅ Verify

```bash
kubectl -n argocd get pods                            # server/repo-server/redis/app-controller Running
kubectl -n argocd get httproute argocd-server         # Accepted + ResolvedRefs = True
# end-to-end test (trusted wildcard cert, served by Envoy):
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 \
  https://argo.kubeadm.lab.example.io/                      # expected: 200 verify=0
```

`--resolve` bypasses DNS: handy for testing **before** you create the Cloudflare record.

## 🌐 Access

| What | Value |
|---|---|
| UI | `https://argo.kubeadm.lab.example.io` |
| User | `admin` |
| Initial password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| CLI | `argocd login argo.kubeadm.lab.example.io --grpc-web --username admin` |

> 💡 Change the password from the UI, then **delete the initial Secret**:
> `kubectl -n argocd delete secret argocd-initial-admin-secret`.

`--grpc-web` is required: native gRPC is often broken by L7 proxies; here the API goes through the
same HTTPS host as the UI.

## 🧪 Scenario — your first `Application`

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
EOF
kubectl -n argocd get applications                    # SYNC STATUS / HEALTH STATUS
kubectl -n guestbook get pods
# Self-heal demo: delete an object by hand, Argo CD recreates it
kubectl -n guestbook delete deploy --all
kubectl -n argocd delete application guestbook        # cleanup (prune=true deletes the objects)
```

## 🚑 Troubleshooting

- **Redirect loop / `too many redirects`** → `server.insecure` is not active:
  `kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'` must
  return `"true"`, then `kubectl -n argocd rollout restart deploy/argocd-server`.
- **404 / route not attached** → `kubectl -n argocd describe httproute argocd-server`:
  `sectionName: https` must exist on `main-gateway`, and the hostname must match the wildcard.
- **Untrusted certificate** → does the `https` listener really serve
  `wildcard-kubeadm-lab-example-io-tls`? (see [`../cert-manager/README.md`](../cert-manager/README.md)).
- **UI fine but `argocd login` failing** → add `--grpc-web`.

## ⚠️ Pitfalls

- **The `argocd-initial-admin-secret` Secret stays in the cluster in plaintext** as long as you
  have not deleted it: it is a full admin credential, readable by anything holding `get secrets`
  in `argocd`.
- **UI published on the VIP**: Argo CD has its own authentication (unlike the Longhorn UI), but it
  stays reachable by every authorized Tailscale peer. A strong password is mandatory.
- **Dex disabled** = no SSO: only the local admin exists. Re-enable `dex.enabled` if you want to
  wire up an IdP (costs a pod).
- **Argo CD can fight with `kubectl`**: hand a component over to an `Application` with
  `selfHeal: true` and every manual `kubectl edit` gets reverted. Pick your deployment mode.
- **Stacking this component on control planes that are too tight on RAM** ends up starving etcd.
  `lab.env` (`CP_MEM`) is the knob; see the pitfalls in [`../README.md`](../README.md).

## 📚 References

- [Argo CD — Ingress / reverse proxy (`server.insecure`)](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
- [Argo CD — declaring an `Application`](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [argo-helm — chart releases](https://github.com/argoproj/argo-helm/releases)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the Gateway that carries this route
