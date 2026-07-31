<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ☸️ `_k8s/` — la couche applicative du lab

> Tout ce qui s'installe **après** le bootstrap du cluster, avec `kubectl`/`helm` depuis
> l'hôte — **y compris le CNI** : `kubeadm init` ne pose jamais de réseau pod, les nodes
> restent donc `NotReady` tant que l'étape `[1/4]` de `platform-up.sh` n'est pas passée.

Le dossier se lit en deux temps : une **plateforme de base** (4 briques, un seul script),
puis des **addons indépendants** que tu ajoutes à la carte, chacun dans son dossier avec
son `*-up.sh`.

## ⚡ Démarrage rapide

```bash
# 1. Bootstrap en CNI=cilium (défaut du dépôt) : kubeadm ne pose aucun CNI, cette couche si
CNI=cilium ./kubeadm/cluster-up.sh

# 2. La plateforme de base : Cilium → Envoy Gateway → metrics-server → wildcard TLS
./_k8s/platform-up.sh

# 3. Les addons, à la carte
./_k8s/longhorn/longhorn-up.sh      # stockage bloc (StorageClass longhorn)
./_k8s/vault-cluster/vault-up.sh    # Vault HA — exige longhorn-up.sh d'abord
./_k8s/argocd/argocd-up.sh
./_k8s/chaos-kube/chaoskube-up.sh    # optionnel : chaos, supprime 1 pod/heure
```

> ⚠️ **`CNI=cilium` est le seul choix « tout allumé ».** Cette couche a besoin d'un Service
> `LoadBalancer` qui obtienne réellement une IP : c'est ce que fait l'annonce L2 (ARP) de
> Cilium. Avec `flannel`, `calico` ou `none`, le Gateway reste en `EXTERNAL-IP <pending>` et
> **aucune UI n'est joignable**.

## 🌐 Le choix du CNI

`CNI` (dans `lab.env`) est lu à deux endroits : `kubeadm/cluster-up.sh` l'enregistre dans
`_out/cluster.env` (et s'en sert pour décider s'il saute l'addon `kube-proxy`), puis
`platform-up.sh` relit ce fichier et installe le CNI.

| `CNI=` | Qui pose le CNI | IP LoadBalancer (L2) | Utilisable pour cette couche |
|---|---|---|---|
| **`cilium`** *(défaut)* | `platform-up.sh` → [`cilium/`](cilium/LISEZ-MOI.md) | ✅ pool + annonce ARP | ✅ oui |
| `calico` | `platform-up.sh` → [`calico/`](calico/LISEZ-MOI.md) | ❌ BGP seulement | ⚠️ MetalLB requis en plus |
| `flannel` | `platform-up.sh` (chart `flannel/flannel`, en ligne) | ❌ | ❌ non |
| `none` | toi | ❌ | selon ce que tu installes |

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` EXIGE `CNI=cilium`.** À `true`, `kubeadm init` a tourné
> avec `--skip-phases=addon/kube-proxy` et seul Cilium sait prendre le relais en eBPF.
> `cluster-up.sh` comme `platform-up.sh` refusent les autres combinaisons : sans kube-proxy ET
> sans remplaçant, plus aucune ClusterIP ne répond — CoreDNS compris.

> ⚠️ **Changer de CNI sur un cluster existant n'est pas supporté** : `./kubeadm/cluster-reset.sh`
> (ou `vagrant destroy`) puis reconstruire. Deux CNI simultanés se disputent le réseau des pods.

## 🔗 Chaîne de dépendances

Chaque maillon suppose le précédent : pas d'IP LoadBalancer sans annonceur L2, pas d'HTTPS
sans le Gateway, pas d'UI sans certificat sur l'écouteur `:443`.

```
cluster bootstrapé  (./kubeadm/cluster-up.sh — nodes NotReady, aucun CNI)
   │
   ├─ 1. CNI              cilium/ (défaut, + pool L2 → IP LoadBalancer .200)
   │                      ou calico/ (CNI seul) ou flannel (CNI seul) ou rien
   ├─ 2. envoy-gateway/   contrôleur Envoy + main-gateway (écouteurs :80 et :443)
   ├─ 3. metric-server    API metrics.k8s.io  (kubectl top, HPA)
   └─ 4. wildcard TLS     *.kubeadm.lab.example.io — deux modes, selon SELF_SIGNED
              │             true  (défaut) → self-signed/   openssl, AC locale, pas de cert-manager
              │             false          → cert-manager/  Let's Encrypt DNS-01 Cloudflare
              │
              └─ addons : stockage → bases → secrets → observabilité → sécurité
```

C'est exactement l'ordre de `platform-up.sh` (`[1/4]` → `[4/4]`) : **metrics-server avant le
certificat**. Les deux modes TLS remplissent le **même** Secret
(`wildcard-<LAB_DOMAIN en tirets>-tls`), donc aucun addon n'a jamais à savoir lequel tu as
choisi — tous se contentent d'accrocher une `HTTPRoute` à l'écouteur `https`.

## 📋 Prérequis transverses

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` posé | tous les scripts testent `/readyz` | `kubectl get nodes` |
| `kubectl` + `helm` | install des charts | `helm version` |
| `main-gateway` en place | toute UI exposée en HTTPS passe par lui | `kubectl get gateway -n envoy-gateway-system` |
| `openssl` sur l'hôte — **seulement si `SELF_SIGNED=true`** (le défaut) | génère le wildcard TLS | `openssl version` |
| `CLOUDFLARE_API_TOKEN` dans `lab.env` — **seulement si `SELF_SIGNED=false`** | DNS-01 du wildcard TLS | lu par `platform-up.sh` |
| `LAB_DOMAIN` dans `lab.env` | domaine des UI (wildcard TLS + `HTTPRoute`) | `sed -n 's/^LAB_DOMAIN=//p' lab.env` |
| StorageClass selon l'addon | `local-path`, `longhorn` ou `longhorn-r1` | `kubectl get sc` |

> 💡 Les StorageClass ne sont pas interchangeables : `longhorn-r1` (1 réplica) est le socle
> des applis qui **répliquent déjà** au niveau applicatif (PostgreSQL, Vault), `longhorn`
> (3 réplicas) pour le reste, `local-path` pour l'éphémère. Voir
> [`longhorn/`](longhorn/LISEZ-MOI.md) et [`local-path-storage/`](local-path-storage/LISEZ-MOI.md).

## 🌐 `LAB_DOMAIN` — le domaine des UI

Le dépôt est **public** : tous les manifestes versionnés portent un domaine **neutre**,
`kubeadm.lab.example.io`. Mets le tien dans `lab.env` (gitignoré) :

```bash
echo 'LAB_DOMAIN=kubeadm.lab.mon-domaine.tld' >> lab.env
```

Les scripts `*-up.sh` (`platform-up.sh`, `argocd-up.sh`, `kyverno-up.sh`,
`observability-up.sh`, `minio-up.sh`, `minio-cluster-up.sh`, `trivy-operator-up.sh`,
`vault/00-secrets-engines.sh`) lisent `LAB_DOMAIN` — variable d'environnement d'abord,
sinon `lab.env`, sinon le défaut neutre — et substituent le domaine **à la volée** :

```bash
sed "s/kubeadm\.lab\.example\.io/${LAB_DOMAIN}/g" <manifeste> | kubectl apply -f -
```

Aucun fichier versionné n'est réécrit : `git status` reste propre.

> ⚠️ **Les manifestes appliqués à la main** (sans `*-up.sh`) ne bénéficient pas de cette
> substitution : `wordpress-example/wordpress-mariadb.yaml`, `longhorn/httproute.yaml`,
> `vault-cluster/httproute.yaml`, `vault-secret-operator/k8s/30-pki-tls.yaml`. Soit tu
> les édites, soit tu passes par le même `sed` :
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' <fichier> | kubectl apply -f -
> ```

> ℹ️ **`SELF_SIGNED` décide comment ce domaine obtient son certificat** (cf.
> `lab.env.example`). `true` — le **défaut** — signe un wildcard avec `openssl` sous une AC
> locale ([`self-signed/`](self-signed/LISEZ-MOI.md)) : pas de domaine réel, pas de token, pas
> de quota, et le domaine n'a jamais besoin de résoudre publiquement. `false` bascule sur
> [`cert-manager/`](cert-manager/LISEZ-MOI.md) + Let's Encrypt, et c'est seulement là que les
> trois variables ACME comptent : `LAB_DNS_ZONE` (zone du solveur DNS-01 ; défaut = les
> 2 derniers labels de `LAB_DOMAIN`), `LAB_ACME_EMAIL` (compte Let's Encrypt ; défaut
> `admin@<zone>`) et `LAB_ACME_ISSUER` — `staging` (défaut, cert non trusté) ou `prod`
> (trusté, mais plafonné à **5 certificats par semaine** pour un même wildcard, et chaque
> `vagrant destroy` en brûle un).

## 🧱 Plateforme de base — `platform-up.sh`

Installe **uniquement** les 4 briques ci-dessus, idempotent (`helm upgrade --install`),
relançable sans casse.

| Brique | Version épinglée | Source du pin |
|---|---|---|
| Cilium | `1.20.0` | `lab.env` (`CILIUM_VERSION`), repli dans `cilium/cilium-up.sh` |
| Envoy Gateway | `1.8.3` | `platform-up.sh` (`ENVOY_GW_VERSION`) |
| metrics-server | `v0.9.0` | `metric-server.yaml` |
| cert-manager — **seulement si `SELF_SIGNED=false`** | `v1.20.2` | `platform-up.sh` (`CERT_MANAGER_VERSION`) |

> ℹ️ Avec le défaut `SELF_SIGNED=true`, l'étape `[4/4]` lance
> [`self-signed/selfsigned-up.sh`](self-signed/LISEZ-MOI.md) à la place et **cert-manager
> n'est jamais installé** — ni chart, ni CRD, ni Secret Cloudflare.

> ℹ️ **metrics-server et `--kubelet-insecure-tls`** : sur kubeadm, le certificat de *service*
> du kubelet est auto-signé (pas signé par la CA du cluster), metrics-server ne peut donc pas
> le vérifier. L'alternative propre — `serverTLSBootstrap: true` plus un approbateur de CSR —
> est hors périmètre d'un lab jetable. Vérif : `kubectl top nodes`.

## 🗂️ Les addons

Ordre conseillé : le stockage d'abord (tout le reste en dépend), puis les bases, puis le
reste dans n'importe quel ordre.

### 💾 Stockage

| Dossier | Rôle | Installation | StorageClass fournie |
|---|---|---|---|
| [`longhorn/`](longhorn/LISEZ-MOI.md) | stockage bloc distribué ; **exige `open-iscsi` + `iscsid` sur les nodes** (posés par `kubeadm/provision.sh`) | `longhorn-up.sh` | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/LISEZ-MOI.md) | stockage local dynamique (hostPath), sans Longhorn | `local-path-up.sh` | `local-path` |
| [`minio-s3/`](minio-s3/LISEZ-MOI.md) | stockage objet S3 + console, **1 nœud** | `minio-up.sh` | — (consomme `local-path`) |
| [`minio-s3/cluster/`](minio-s3/cluster/LISEZ-MOI.md) | MinIO **distribué** 4 nœuds, erasure coding EC:2 — cible des backups | `minio-cluster-up.sh` | — (consomme `local-path`) |

### 🐘 Bases de données

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/LISEZ-MOI.md) | opérateur PostgreSQL HA `0.29.0` (app v1.30.0) + cluster de démo 3 nœuds, failover auto, **backups S3 + PITR** | `cloudnative-pg-up.sh` | SC `longhorn-r1` ; backups → `minio-s3/cluster` |

### 🔐 Secrets

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/LISEZ-MOI.md) | HashiCorp Vault HA (Raft) 3 nœuds, UI/API sous `vault.kubeadm.lab.example.io` | `vault-up.sh` | SC `longhorn` ; descellement manuel |
| [`vault-secret-operator/`](vault-secret-operator/LISEZ-MOI.md) | secrets Vault → `Secret` K8s natifs (static KV, dynamic DB, PKI) — côtés Vault **et** K8s | Helm + scripts `vault/` | `vault-cluster` descellé |

### 📈 Observabilité

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`observability/`](observability/LISEZ-MOI.md) | kube-prometheus-stack `87.19.0` + Loki `7.1.0` + Alloy `1.11.0` ; UI `grafana` / `prometheus` / `alertmanager` | `observability-up.sh` | SC `longhorn-r1` ; CP ≥ 4 Go |
| [`node-problem-detector/`](node-problem-detector/LISEZ-MOI.md) | santé des nodes (kernel, runtime) `2.3.14` | `node-problem-detector-up.sh` | — |
| [`chaos-kube/`](chaos-kube/LISEZ-MOI.md) | chaos engineering : chaoskube `0.39.0` supprime **1 pod au hasard/heure**, sauf `kube-system`, `longhorn-system`, `vault`, `cnpg-demo` | `chaoskube-up.sh` | — |

### 🛡️ Sécurité

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`kyverno/`](kyverno/LISEZ-MOI.md) | policy engine `3.8.2` (app v1.18.2) + Policy Reporter `3.8.1` (UI), policies pédagogiques en Audit | `kyverno-up.sh` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/LISEZ-MOI.md) | scanner continu `0.34.0` (CVE, config, secrets, RBAC) ; rapports dans l'UI Policy Reporter | `trivy-operator-up.sh` | `kyverno` (UI partagée) |

### 🌐 Réseau & TLS

| Dossier | Rôle | Installation |
|---|---|---|
| [`cilium/`](cilium/LISEZ-MOI.md) | **CNI par défaut** `1.19.6` + pool d'IP LoadBalancer + annonce L2 (ARP) | `cilium-up.sh`, appelé par `platform-up.sh` si `CNI=cilium` |
| [`calico/`](calico/LISEZ-MOI.md) | **CNI alternatif** `v3.32.1` (opérateur Tigera) — CNI **seul**, sans annonce L2 | `calico-up.sh`, appelé par `platform-up.sh` si `CNI=calico` |
| [`envoy-gateway/`](envoy-gateway/LISEZ-MOI.md) | contrôleur Envoy Gateway + `main-gateway` (`:80` et `:443` wildcard) + apps de démo | `platform-up.sh` |
| [`self-signed/`](self-signed/LISEZ-MOI.md) | **mode TLS par défaut** — wildcard signé par une AC locale (`openssl`), sans domaine ni token | `selfsigned-up.sh`, appelé par `platform-up.sh` si `SELF_SIGNED=true` |
| [`cert-manager/`](cert-manager/LISEZ-MOI.md) | certificats TLS wildcard automatiques (ACME DNS-01 Cloudflare) | `platform-up.sh`, si `SELF_SIGNED=false` |

### 🧪 Démos

| Dossier | Rôle | Installation |
|---|---|---|
| [`argocd/`](argocd/LISEZ-MOI.md) | Argo CD `10.2.1` (GitOps), UI sous `argo.kubeadm.lab.example.io` | `argocd-up.sh` |
| [`wordpress-example/`](wordpress-example/LISEZ-MOI.md) | WordPress + MariaDB sur Longhorn, exposé via Envoy | `kubectl apply` |
| `databasement/` | *(addon local, non versionné — cf. `.gitignore`)* | `databasement-up.sh` |

## 🌍 Accès distant (Tailscale + Cloudflare)

Le VIP `.200` est une IP **host-only** annoncée en ARP : joignable depuis l'hôte, pas
routable telle quelle.

1. **L3** — l'hôte annonce la route :
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Puis approuver dans la console Tailscale.
   > ⚠️ Reste sur le `/32` (ou cadre par ACL) : un `/24` exposerait aussi l'API Kubernetes
   > (`:6443`) et le SSH de chaque node.

2. **Nom + TLS** — wildcard Cloudflare public `*.kubeadm.lab.example.io → 192.168.56.200`, en
   **DNS-only (nuage gris)** : le proxy Cloudflare ne peut pas joindre une IP privée
   `192.168.56.x`. Le TLS est donc terminé par **Envoy**, pas par Cloudflare → le Gateway
   doit porter un certificat **publiquement trusté** (Let's Encrypt, cf. `cert-manager/`).
   Un certificat *Cloudflare Origin CA* serait rejeté par les navigateurs.

## ⚠️ Pièges

- **Deux StorageClass par défaut.** `longhorn/values.yaml` pose `persistence.defaultClass:
  true` et `local-path-storage.yaml` l'annotation `is-default-class: "true"`. Les deux
  addons installés ⇒ un PVC sans `storageClassName` explicite atterrit sur la SC la plus
  récemment créée, de façon non déterministe. Nomme toujours ta SC.
- **Les policies Kyverno du dépôt sont violées par le dépôt.** `require-requests-limits`
  exige `limits.cpu` que les manifestes maison ne posent jamais (choix délibéré : pas de
  throttling CPU), et `require-labels` attend `app.kubernetes.io/name` là où ils utilisent
  `app:`. Le rapport est donc bruyant par construction — voir
  [`kyverno/`](kyverno/LISEZ-MOI.md).
- **Les émetteurs de métriques sont coupés par défaut.** `serviceMonitor`/`podMonitor` sont
  à `false` chez trivy-operator, CloudNativePG et node-problem-detector : Prometheus ne
  collecte rien d'eux tant que tu ne les as pas basculés après l'install d'observability.
- **Ne descends jamais `CP_MEM` sous `3072`.** Empiler ces addons sur des control planes à
  2 Go affame etcd. `lab.env.example` livre `4096`, ce qu'`observability/` exige.
- **Un `git add -A` peut publier des secrets d'addons locaux.** `_k8s/databasement/` est
  désormais gitignoré pour cette raison — vérifie `git status` avant de commiter.

## 📚 Références

- [`../LISEZ-MOI.md`](../LISEZ-MOI.md) — le lab kubeadm/Vagrant, du `vagrant up` au cluster prêt
- [`../kubeadm/MISE-A-JOUR.md`](../kubeadm/MISE-A-JOUR.md) — mise à jour de Kubernetes
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/)
