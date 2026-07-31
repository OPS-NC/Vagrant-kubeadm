<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐙 `argocd/` — Argo CD (GitOps) exposé via la Gateway API

> **Le GitOps du lab, en HTTPS, en une commande.** Argo CD réconcilie l'état du cluster avec des
> manifestes Git ; son UI/API sont publiées sous `argo.kubeadm.lab.example.io` derrière le même
> `main-gateway` que le reste du lab, avec le **wildcard `*.kubeadm.lab.example.io`** déjà émis par
> cert-manager — rien de neuf côté certificat.

> 🌐 **`kubeadm.lab.example.io` est le domaine NEUTRE du dépôt (public)** : `argocd-up.sh` le
> remplace par `LAB_DOMAIN` (`lab.env`) dans les values Helm **et** l'`HTTPRoute`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

- Dérouler un **cycle GitOps complet** : dépôt → `Application` → sync → drift détecté → resync.
- Montrer un **rattachement Gateway API inter-namespace** de plus (route dans `argocd`, Gateway
  dans `envoy-gateway-system`).
- Servir de terrain de jeu pour déployer les autres addons **par Git** au lieu de `kubectl`.

> ℹ️ **Addon à part** : Argo CD n'est **pas** installé par `../platform-up.sh` (qui ne pose que
> Cilium + Envoy Gateway + metrics-server + cert-manager). Il s'installe à la demande, comme
> `../longhorn/`, `../vault-cluster/`, `../kyverno/`…

### Le montage en une phrase

**Envoy termine le TLS, `argocd-server` parle en clair.** On règle `server.insecure=true` : HTTPS
devant (cert wildcard), HTTP derrière. Sans ça, `argocd-server` ferait sa propre redirection
`307 http→https` alors que le proxy termine déjà le TLS → **boucle de redirection**. C'est le
mode recommandé derrière un ingress/gateway qui gère le TLS.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `main-gateway` avec l'écouteur **`https:443`** ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | porte l'UI en HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `wildcard-kubeadm-lab-example-io-tls` **`READY=True`** ([`../cert-manager/`](../cert-manager/LISEZ-MOI.md)) | sinon TLS non trusté | `kubectl -n envoy-gateway-system get certificate` |
| DNS `argo.kubeadm.lab.example.io → 192.168.56.200` en **DNS-only** | hostname de l'`HTTPRoute` | `curl --resolve` sinon (cf. ✅) |
| Rien côté nodes | Argo CD n'a besoin d'aucun privilège ni `hostPath` | `kubectl -n argocd get pods` |

## ⚡ Installation

```bash
./_k8s/argocd/argocd-up.sh
```

Chart `argo/argo-cd` **`10.2.1`** (app **v3.4.5**), épinglé dans le script via `ARGOCD_VERSION`
(surchargeable). Idempotent (`helm upgrade --install` + `kubectl apply`).

<details>
<summary>Équivalent manuel</summary>

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
# --version : garder celle du script (ARGOCD_VERSION)
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.2.1 \
  --values _k8s/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f _k8s/argocd/httproute.yaml
```
</details>

## 🔧 Ce que fait le script

1. installe le chart dans le namespace `argocd` avec `values.yaml`, puis attend
   `deploy/argocd-server` (300 s max) ;
2. applique `httproute.yaml` ;
3. rappelle l'URL, la commande du mot de passe initial et le `curl` de test.

### Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | `global.domain` + `server.insecure: true` + `url` publique ; **Dex** et **notifications** coupés (allègement) ; ApplicationSet laissé actif |
| `httproute.yaml` | `HTTPRoute` HTTPS `argo.kubeadm.lab.example.io` → `argocd-server:80`, `sectionName: https` |
| `argocd-up.sh` | installe Argo CD + applique la route (idempotent) |

La route vit dans `argocd` et s'attache à `main-gateway` (ns `envoy-gateway-system`) grâce à
`allowedRoutes.namespaces.from: All` côté Gateway ; le backend étant dans le même namespace que
la route, aucun `ReferenceGrant` n'est nécessaire.

## ✅ Vérifier

```bash
kubectl -n argocd get pods                            # server/repo-server/redis/app-controller Running
kubectl -n argocd get httproute argocd-server         # Accepted + ResolvedRefs = True
# test end-to-end (cert wildcard trusté, servi par Envoy) :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 \
  https://argo.kubeadm.lab.example.io/                      # attendu : 200 verify=0
```

`--resolve` court-circuite le DNS : pratique pour tester **avant** de créer l'enregistrement
Cloudflare.

## 🌐 Accès

| Quoi | Valeur |
|---|---|
| UI | `https://argo.kubeadm.lab.example.io` |
| Utilisateur | `admin` |
| Mot de passe initial | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d ; echo` |
| CLI | `argocd login argo.kubeadm.lab.example.io --grpc-web --username admin` |

> 💡 Change le mot de passe depuis l'UI, puis **supprime le Secret initial** :
> `kubectl -n argocd delete secret argocd-initial-admin-secret`.

`--grpc-web` est requis : le gRPC natif est souvent cassé par les proxies L7 ; ici l'API passe par
le même hôte HTTPS que l'UI.

## 🧪 Scénario — première `Application`

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
# Démo du self-heal : supprime un objet à la main, Argo CD le recrée
kubectl -n guestbook delete deploy --all
kubectl -n argocd delete application guestbook        # nettoyage (prune=true supprime les objets)
```

## 🚑 Dépannage

- **Boucle de redirection / `too many redirects`** → `server.insecure` n'est pas actif :
  `kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'` doit
  valoir `"true"`, puis `kubectl -n argocd rollout restart deploy/argocd-server`.
- **404 / route non rattachée** → `kubectl -n argocd describe httproute argocd-server` :
  `sectionName: https` doit exister sur `main-gateway`, et le hostname matcher le wildcard.
- **Certificat non trusté** → l'écouteur `https` sert-il bien `wildcard-kubeadm-lab-example-io-tls` ?
  (cf. [`../cert-manager/LISEZ-MOI.md`](../cert-manager/LISEZ-MOI.md)).
- **UI OK mais `argocd login` KO** → ajouter `--grpc-web`.

## ⚠️ Pièges

- **Le Secret `argocd-initial-admin-secret` reste en clair dans le cluster** tant que tu ne l'as
  pas supprimé : c'est un identifiant admin complet, lisible par tout ce qui a le droit `get
  secrets` dans `argocd`.
- **UI publiée sur le VIP** : Argo CD a sa propre authentification (contrairement à l'UI
  Longhorn), mais reste joignable par tout peer Tailscale autorisé. Mot de passe fort obligatoire.
- **Dex désactivé** = pas de SSO : seul l'admin local existe. Réactiver `dex.enabled` si tu veux
  brancher un IdP (coûte un pod).
- **Argo CD peut se battre avec `kubectl`** : si tu confies un addon à une `Application` avec
  `selfHeal: true`, tout `kubectl edit` manuel sera annulé. Choisis ton mode de déploiement.
- **Empiler cet addon sur des control planes trop justes en RAM** finit par affamer etcd.
  `lab.env` (`CP_MEM`) est la molette ; voir les pièges de [`../LISEZ-MOI.md`](../LISEZ-MOI.md).

## 📚 Références

- [Argo CD — Ingress / reverse proxy (`server.insecure`)](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
- [Argo CD — déclaration d'`Application`](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
- [argo-helm — releases du chart](https://github.com/argoproj/argo-helm/releases)
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le Gateway qui porte cette route
