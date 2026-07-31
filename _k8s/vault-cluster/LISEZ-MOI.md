<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🔒 `vault-cluster/` — HashiCorp Vault HA (Raft), UI exposée en HTTPS

> Le **serveur** Vault du lab : 3 nœuds en stockage **Raft intégré**, 1 PV Longhorn par nœud,
> UI + API en HTTPS sous `vault.kubeadm.lab.example.io`. À ne pas confondre avec
> `../vault-secret-operator/`, qui est le **client** (il synchronise des secrets Vault en
> `Secret` Kubernetes).

## 🎯 À quoi ça sert

Un coffre-fort central pour tout ce que le lab ne doit pas stocker en clair : secrets applicatifs
(KV-v2), mots de passe PostgreSQL rotés automatiquement (moteur `database`), certificats internes
(moteur `pki`). Les consommateurs ne parlent jamais à Vault directement — c'est le rôle du VSO.

Ce qui est monté ici :

| Brique | Choix du lab | Où c'est décidé |
|---|---|---|
| Haute dispo | 3 réplicas, **Raft intégré** (pas de Consul), anti-affinité par node | `values.yaml` (`server.ha`) |
| Stockage | 1 PVC Longhorn **2Gi RWO** par pod (`data-vault-0/1/2`) | `values.yaml` (`server.dataStorage`) |
| TLS | terminé par **Envoy** ; Vault écoute en **HTTP** en interne (`tls_disable`) | `values.yaml` + `httproute.yaml` |
| `disable_mlock` | `true` — sans risque ici (kubeadm exige le swap coupé, et `kubeadm/provision.sh` le coupe) et évite d'exiger `IPC_LOCK` | `values.yaml` (`raft.config`) |
| Agent Injector | **désactivé** : on passe par le VSO, pas par des sidecars | `values.yaml` (`injector.enabled`) |
| Audit device | **désactivé** (`auditStorage`) — un PVC de moins | `values.yaml` |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Longhorn (SC `longhorn`) | porte les 3 PVC Raft | `kubectl get sc` |
| `platform-up.sh` (`main-gateway` + écouteur `https`) | expose l'UI/API en HTTPS | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `*.kubeadm.lab.example.io` | le `HTTPRoute` n'a pas de `Certificate` dédié | `kubectl -n envoy-gateway-system get certificate` |
| DNS `vault.kubeadm.lab.example.io → 192.168.56.200` | joindre l'UI depuis l'hôte | `getent hosts vault.kubeadm.lab.example.io` |
| `jq` sur l'hôte | découper la sortie JSON de `operator init` | `jq --version` |

Voir `../longhorn/`, `../envoy-gateway/`, `../cert-manager/`.

## ⚡ Installation

```bash
./_k8s/vault-cluster/vault-up.sh
```

Installe le chart, **initialise** Vault, **descelle** les 3 pods et applique l'`HTTPRoute`.
Idempotent : n'initialise que si Vault ne l'est pas, ne descelle que les pods réellement
scellés — c'est donc aussi **la commande à relancer après un reboot**, qui ramène toujours les
pods scellés (§🔐). `VAULT_CHART_VERSION=…` surcharge la version du chart.

> 🔐 **Les clés de descellement et le token root atterrissent dans `_out/vault-init.json`**
> (mode `0600`, et `_out/` est gitignoré). Le script ne les affiche jamais. Ce fichier est le
> **seul** exemplaire : le perdre rend Vault définitivement inaccessible — sauvegarde-le hors du
> dépôt. Cf. §🔐 ci-dessous.

<details>
<summary>Le chart seul, à la main</summary>

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version 0.34.0 \
  --values _k8s/vault-cluster/values.yaml
```

</details>

Chart **0.34.0** → image **`hashicorp/vault:2.0.3`** (versions épinglées, cf. l'en-tête de
`values.yaml`).

Les 3 pods démarrent puis restent **`0/1 Running` et SCELLÉS** : normal, la readiness probe
échoue tant que Vault n'est ni initialisé ni descellé.

## 🔐 Initialiser + desceller

`vault-up.sh` l'a déjà fait — les commandes ci-dessous sont l'équivalent manuel, utile pour
comprendre ou pour rattraper à la main. 5 clés de descellement, **seuil de 3**.

> ⚠️ **`vault-1` et `vault-2` ne se descellent pas tout de suite.** Avec le Raft intégré ils
> démarrent **non initialisés** et ne rejoignent le cluster que par `retry_join`, une fois le
> leader descellé ; les desceller trop tôt échoue en `400 — Vault is not initialized`.
> `vault-up.sh` attend `initialized=true` sur chaque pod avant de le desceller.

```bash
# Init sur le pod 0 — GARDE LA SORTIE EN LIEU SÛR (clés + root token).
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json

# Descelle vault-0 (3 clés distinctes) : il devient leader
for i in 0 1 2; do
  kubectl -n vault exec vault-0 -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done

# vault-1 et vault-2 rejoignent le Raft (retry_join) puis se descellent à leur tour
for p in vault-1 vault-2; do for i in 0 1 2; do
  kubectl -n vault exec $p -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done; done

# Root token :
jq -r .root_token vault-init.json
```

> ⚠️ **`vault-init.json` contient les 5 clés de descellement ET le root token.** Ne jamais le
> committer — `vault-up.sh` l'écrit dans `_out/vault-init.json` justement parce que `_out/` est
> gitignoré. Chaque **redémarrage de pod** (upgrade du chart, node down, reboot du node / `vagrant halt`) le fait
> revenir **scellé** : relancer `./_k8s/vault-cluster/vault-up.sh` (ou desceller à la main avec
> 3 des 5 clés). Un vrai déploiement
> utiliserait un **auto-unseal** (Transit d'un autre Vault, ou KMS cloud) — hors scope du lab.

L'UI et l'API sont exposées par l'étape `[4/4]` du script. Pour réappliquer cette route seule :

```bash
kubectl apply -f _k8s/vault-cluster/httproute.yaml
```

> 🌐 **Domaine** : le manifeste porte le domaine neutre `kubeadm.lab.example.io` (dépôt public)
> et n'est pas passé par un `*-up.sh` : édite le hostname, ou substitue ton domaine à la volée :
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' \
>   _k8s/vault-cluster/httproute.yaml | kubectl apply -f -
> ```
>
> (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

## 🔧 Brancher le VSO

Le VSO (`../vault-secret-operator/`) est déjà câblé sur `http://vault.vault.svc.cluster.local:8200`
via le `VaultConnection` « default » de son `values.yaml`. Côté Vault, il reste à activer l'auth
Kubernetes, les moteurs de secrets, les policies et les roles : tout est dans
`../vault-secret-operator/vault/LISEZ-MOI.md`.

## ✅ Vérifier

```bash
kubectl -n vault get pods                                        # 1/1 Running après unseal
kubectl -n vault exec vault-0 -- vault status                      # Sealed=false, HA Mode
kubectl -n vault exec vault-0 -- vault operator raft list-peers   # 3 voters
kubectl -n vault get endpoints vault-active                       # 1 endpoint = le leader
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve vault.kubeadm.lab.example.io:443:192.168.56.200 \
  https://vault.kubeadm.lab.example.io/ui/                              # 200
```

## 🌐 Accès

| Quoi | Valeur / commande |
|---|---|
| UI (HTTPS public) | <https://vault.kubeadm.lab.example.io> — méthode de login **« Token »** |
| Root token | `jq -r .root_token vault-init.json` |
| API depuis le cluster | `http://vault.vault.svc.cluster.local:8200` (ce que consomme le VSO) |
| API depuis l'hôte, sans DNS | `kubectl -n vault port-forward svc/vault-active 8200:8200` → `http://127.0.0.1:8200` |

Le `HTTPRoute` pointe le service **`vault-active`** (le leader uniquement) : pas de redirection
307 émise par un standby. Le certificat est le wildcard porté par l'écouteur `https` de
`main-gateway` (annotation `cert-manager.io/cluster-issuer`, cf.
`../envoy-gateway/Envoy-Proxy.yml`). Avec le défaut `LAB_ACME_ISSUER=staging`, il n'est **pas
publiquement reconnu** : avertissement navigateur attendu, ou `curl -k`. Mets
`LAB_ACME_ISSUER=prod` pour un cert trusté — attention au plafond de **5 certificats/semaine**.

> ⚠️ **L'UI n'est accessible que si Vault est descellé.** `vault-active` n'a aucun endpoint tant
> qu'aucun leader n'est élu : la route répond alors **503**. Après un reboot du cluster, il faut
> **redesceller manuellement chaque pod** (3 clés sur 5) avant que l'UI revienne.

## ⚠️ Pièges

- **`longhorn` (3 réplicas) sous Raft = 9 copies pour 3 nœuds logiques.** `values.yaml:26` utilise
  la StorageClass `longhorn`, qui réplique **3× au niveau bloc** — alors que Vault Raft réplique
  **déjà 3× au niveau applicatif**. C'est exactement le cas d'usage que
  `../longhorn/longhorn-r1-storageclass.yaml` dit d'éviter (« réplication déjà faite au niveau
  applicatif »), et que CloudNativePG traite correctement avec `longhorn-r1`. Sur le disque OS
  partagé (~20 Go/node) ça alimente les `ReplicaSchedulingFailure`. Pour corriger : passer
  `server.dataStorage.storageClass` à `longhorn-r1`. Attention, **la StorageClass d'un PVC est
  immuable** : il faut supprimer les 3 PVC `data-vault-*`, donc **réinitialiser Vault** — à faire
  avant de mettre quoi que ce soit dedans.
- **Descellement manuel, à chaque reboot.** Pas d'auto-unseal dans ce lab (cf. §🔐). Un pod qui
  redémarre est un pod inutilisable jusqu'à ce que 3 clés lui soient présentées.
- **[`../chaos-kube/`](../chaos-kube/LISEZ-MOI.md) exclut ce namespace, et doit continuer.**
  chaoskube supprime un pod au hasard toutes les heures ; le Raft survit à la perte, mais le pod
  revient **scellé**. Retire `vault` de l'exclusion et en quelques heures les 3 sont scellés et
  Vault tombe — s'en sortir demande un `vault-up.sh` après chaque kill.
- **Mettre `VAULT_ADDR` / `VAULT_TOKEN` / `VAULT_UNSEAL_KEY_*` dans `lab.env` ne fait RIEN.**
  Aucun script du dépôt ne lit ces clés depuis `lab.env` — le seul champ pioché dans ce fichier est
  `CLOUDFLARE_API_TOKEN`, par `grep` explicite dans `../platform-up.sh` (ligne 30). Les scripts de
  `../vault-secret-operator/vault/` lisent uniquement l'**environnement**. Pour vraiment charger
  `lab.env` dans ton shell :
  ```bash
  set -a; . ./lab.env; set +a      # exporte tout ce que le fichier définit
  vault status                     # doit répondre Sealed=false
  ```
  `lab.env` est gitignoré, mais y stocker des clés de descellement le rend aussi sensible que
  `vault-init.json` : même précaution.
- **Les données ne survivent pas à une purge des PVC.** Elles survivent aux reboots (partition
  Longhorn), mais un `helm uninstall` suivi d'un `kubectl delete pvc` détruit le Raft — donc tout
  le contenu du coffre, y compris ce que le VSO référence.
- **`vault status` renvoie « standby » sur 2 pods sur 3** : c'est le fonctionnement normal du HA
  Raft (un seul leader). Les commandes d'écriture doivent viser `vault-active`, pas `vault-0`.

## 🚑 Dépannage

| Symptôme | Cause | Geste |
|---|---|---|
| Pods `0/1 Running` en boucle | Vault scellé (readiness KO) | desceller (cf. §🔐) |
| Route 503 / `vault-active` sans endpoint | aucun leader élu → Vault scellé | desceller les 3 pods |
| Un pod scellé après reboot | comportement normal, pas d'auto-unseal | `vault operator unseal` ×3 clés |
| Un peer Raft manquant | `retry_join` KO (service `vault-internal`) | `vault operator raft list-peers`, logs du pod |
| PVC `Pending` | Longhorn ne peut pas placer 3 réplicas | cf. le premier piège (`longhorn-r1`) |

## 📚 Références

- [Vault sur Kubernetes — chart Helm](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm)
- [Raft intégré (stockage)](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [`vault operator init` / `unseal`](https://developer.hashicorp.com/vault/docs/commands/operator/init)
- [Auto-unseal (Transit)](https://developer.hashicorp.com/vault/docs/configuration/seal/transit)
