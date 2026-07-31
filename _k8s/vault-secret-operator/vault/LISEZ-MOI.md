<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ⚙️ `vault/` — la configuration **côté Vault**

> La moitié serveur du câblage VSO. Ces scripts créent tout ce que le VSO va **consommer** :
> la méthode d'auth Kubernetes, les moteurs de secrets, les policies (moindre privilège) et les
> roles qui relient une identité K8s à une policy. Le pendant côté cluster est dans `../k8s/`.

## 🎯 Le contrat d'identité

VSO présente le **token JWT** du `ServiceAccount` de l'app. Vault le valide via l'API
**TokenReview** du cluster, puis vérifie qu'il correspond à un **role**
(`bound_service_account_names` + `_namespaces` + `audience`). Si oui, Vault renvoie un token
porteur des **policies** du role — donc des droits de lecture précis, et rien d'autre.

```
JWT du SA (audience "vault")  ─►  auth/kubernetes/config (TokenReview)  ─►  role  ─►  policy
                                                                                       │
                                    kvv2/ · database/ · pki/ · transit/  ◄─────────────┘
```

Casser un seul maillon (nom du SA, namespace, audience, chemin de policy, nom de mount) donne un
`403` côté VSO et un `SecretSynced: false` sur le CR. C'est l'écrasante majorité des pannes.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| CLI `vault` sur l'hôte | tous les scripts l'appellent | `vault version` |
| `VAULT_ADDR` **exporté** | sinon le CLI tape `https://127.0.0.1:8200` | `echo $VAULT_ADDR` |
| `VAULT_TOKEN` **exporté** (root/admin) | activer des moteurs et écrire des policies | `vault token lookup` |
| Vault **descellé** | un Vault scellé refuse tout | `vault status` → `Sealed false` |
| `KUBECONFIG` (uniquement `pg-dynamic-rotate.sh`) | lit le mot de passe superuser CNPG | `kubectl get nodes` |

```bash
export VAULT_ADDR="https://vault.kubeadm.lab.example.io"   # ou http://127.0.0.1:8200 en port-forward
export VAULT_TOKEN="<root-token>"                    # cf. ../../vault-cluster/LISEZ-MOI.md
vault status                                         # doit répondre Sealed=false
```

Port-forward si Vault n'est pas exposé :
`kubectl -n vault port-forward svc/vault-active 8200:8200`.

> ⚠️ **`VAULT_ADDR`/`VAULT_TOKEN` posés dans `lab.env` n'ont AUCUN effet** : aucun script ne lit ce
> fichier. Il faut les **exporter** (ou `set -a; . ./lab.env; set +a`). Détail et précautions dans
> `../../vault-cluster/LISEZ-MOI.md` (section Pièges).

## ⚡ Deux parcours

Le dossier contient **deux jeux de scripts** qui ne servent pas la même chose. Ne pas les mélanger :
ils utilisent des mounts, des namespaces et des noms de role différents.

### Parcours A — le lab réel (testé)

```bash
./_k8s/vault-secret-operator/vault/kubeadm-lab.sh          # auth k8s + moteur kubeadm-lab/ + démo
./_k8s/vault-secret-operator/vault/pg-dynamic-rotate.sh  # moteur database/ + rotation PG
```

C'est le chemin qui tourne vraiment : mount KV-v2 **`kubeadm-lab/`** (un sous-dossier par appli) et
rotation d'un mot de passe PostgreSQL par static role. Les démos K8s correspondantes sont
`../k8s/nginx-test-vault/` et `../k8s/pg-dynamic-rotate/`.

### Parcours B — la démo pédagogique (mounts `kvv2/`, `pki/`, `transit/`)

```bash
cd _k8s/vault-secret-operator/vault
bash 00-secrets-engines.sh                 # moteurs + un secret de démo + CA PKI + clé transit
MODE=incluster bash 01-kubernetes-auth.sh   # auth/kubernetes (voir le piège plus bas !)
bash 02-roles.sh                            # policies + roles vso-static/-dynamic/-pki/-transit
```

Elle sert de support de lecture pour les CR numérotés de `../k8s/` (`10-`, `20-`, `30-`, `40-`).
Deux de ses trois scripts ont des défauts documentés en ⚠️ **Pièges** — les lire avant.

## 🔧 Ce que chaque script écrit dans Vault

### `00-secrets-engines.sh` — les moteurs de secrets

| Objet Vault | Commande | Note |
|---|---|---|
| `kvv2/` | `vault secrets enable -path=kvv2 -version=2 kv` | secrets statiques |
| `kvv2/demo/app` | `vault kv put … username password` | secret de démo, **écrasé à chaque relance** |
| `database/` | `vault secrets enable database` | ⚠️ monté sur **`database/`**, pas `db/` — cf. Pièges |
| `pki/` | `enable -path=pki pki` + `secrets tune -max-lease-ttl=87600h` | 10 ans de bail max |
| CA racine PKI | `vault write pki/root/generate/internal common_name=$LAB_DOMAIN ttl=87600h` | `LAB_DOMAIN` (lab.env, défaut `kubeadm.lab.example.io`) ; ⚠️ **empile** une CA par relance — cf. Pièges |
| `pki/config/urls` | `issuing_certificates` + `crl_distribution_points` sur `$VAULT_ADDR` | dépend de `VAULT_ADDR` |
| `pki/roles/demo` | `allowed_domains=$LAB_DOMAIN allow_subdomains=true max_ttl=72h` RSA 2048 | borne ce que le `VaultPKISecret` peut demander — le CN de `30-pki-tls.yaml` doit y rester |
| `transit/` + clé `vso-client-cache` | `enable transit` ; `write -f transit/keys/vso-client-cache` | chiffrement du cache client VSO |

La connexion et le role du moteur `database` sont laissés **en commentaire** dans le script (ils
dépendent de ta base). Le parcours A, lui, les écrit pour de vrai (`pg-dynamic-rotate.sh`).

### `01-kubernetes-auth.sh` — la méthode d'auth

Deux modes, selon où tourne Vault. C'est le point qui bloque le plus.

**`MODE=incluster`** (notre cas) — Vault appelle TokenReview avec le token de **son propre pod** :
son `ServiceAccount` doit porter le ClusterRole `system:auth-delegator`, ce que le chart
`hashicorp/vault` fait par défaut (`server.authDelegator.enabled=true`). La config se réduit alors
à `kubernetes_host` ; `token_reviewer_jwt` et `kubernetes_ca_cert` restent vides (Vault utilise le
CA monté dans son conteneur). Aucun `issuer=` n'est posé : `disable_iss_validation` reste à
`true` (défaut ≥ Vault 1.9), la revendication `iss` du token n'est donc jamais comparée — c'est
ce qu'on veut ici, kubeadm émettant les tokens de ServiceAccount avec l'issuer
`https://kubernetes.default.svc.cluster.local` alors que `kubernetes_host` vaut
`https://kubernetes.default.svc`.

**`MODE=external`** — Vault est hors du cluster, il ne peut rien déduire. Il faut lui fournir :
1. un `ServiceAccount` **délégateur** côté K8s (`system:auth-delegator`) ;
2. son **token long** (`token_reviewer_jwt`), avec lequel Vault validera les JWT des apps ;
3. l'**endpoint** de l'API (`KUBE_HOST`, par défaut la VIP du lab `https://192.168.56.5:6443`,
   portée par **keepalived**, cf. `kubeadm/provision.sh`) **et** le CA de cette API (`SA_CA_CRT`).

```bash
MODE=external KUBE_HOST=https://192.168.56.5:6443 SA_JWT=… SA_CA_CRT=… bash 01-kubernetes-auth.sh
```

Les commandes `kubectl` qui produisent `SA_JWT` / `SA_CA_CRT` sont en commentaire dans le script.
⚠️ Ne pas passer `--audience` à `kubectl create token` pour le JWT du reviewer : kubeadm laisse
`--api-audiences` à son défaut (l'issuer, et rien d'autre), un token demandé sur une autre
audience est donc rejeté à l'authentification et le TokenReview de Vault renvoie 401.

### `02-roles.sh` — policies + roles

Charge les 4 fichiers de `policies/`, puis crée 4 roles `auth/kubernetes`. Tous en `token_ttl=15m`
et `audience=vault` (qui **doit** matcher `VaultAuth.spec.kubernetes.audiences` côté K8s).

| Role Vault | SA / namespace bindé | Policy |
|---|---|---|
| `vso-static` | `vso-app` / `demo` | `vso-static-kv` |
| `vso-dynamic` | `vso-app` / `demo` | `vso-dynamic-db` |
| `vso-pki` | `vso-app` / `demo` | `vso-pki` |
| `vso-transit` | `vault-secrets-operator-controller-manager` / `vault-secrets-operator` | `vso-transit` |

`vso-transit` est le role de **l'opérateur lui-même** (chiffrement de son cache client), pas d'une
app.

### `kubeadm-lab.sh` — le moteur du lab

Auth Kubernetes (`kubernetes_host=https://kubernetes.default.svc`), moteur KV-v2 **`kubeadm-lab/`**,
secret `kubeadm-lab/nginx-test-vault/config` (3 clés `APP_*`), policy
`kubeadm-lab-nginx-test-vault` (lecture de `kubeadm-lab/data|metadata/nginx-test-vault/*` seulement) et
role `nginx-test-vault` bindé au SA/ns `nginx-test-vault`.

Ajouter une appli = un sous-dossier `kubeadm-lab/<appli>/…`, une policy scopée à ce sous-dossier, un
role dédié au SA/ns de l'appli. Ce script est le gabarit à copier.

### `pg-dynamic-rotate.sh` — rotation du mot de passe PostgreSQL

Vault prend en gestion un user PG **fixe** (`vault-rotate`) et n'en **rotate que le mot de passe**
(static role) — la chaîne de connexion de l'app reste stable. Vue d'ensemble du scénario et
prérequis PostgreSQL : `../LISEZ-MOI.md`.

| Objet Vault | Commande (résumé) | Rôle |
|---|---|---|
| `database/` | `vault secrets enable database` | moteur « base de données » |
| `database/config/pg-demo` | `plugin_name=postgresql-database-plugin allowed_roles=vault-rotate connection_url=…@pg-demo-rw.cnpg-demo…/postgres?sslmode=require username=postgres password=<superuser> password_authentication=scram-sha-256` | **où** Vault se connecte et **comment** (admin `postgres`, TLS). Le mot de passe est lu dans le Secret `pg-demo-superuser` par le script. |
| `database/static-roles/vault-rotate` | `db_name=pg-demo username=vault-rotate rotation_period=$ROTATION_PERIOD` | prend en gestion le user PG fixe. `db_name` = nom de la **connexion**, pas de la base. `ROTATION_PERIOD` par défaut `3h`. |
| Policy `pg-rotate-demo` | `path "database/static-creds/vault-rotate" { capabilities = ["read"] }` | droit minimal : lire ce seul static-creds |
| Role `auth/kubernetes/role/pg-rotate-demo` | SA `pg-rotate` / ns `pg-rotate-demo`, `audience=vault` | **qui** peut se logger et **quels** droits il reçoit |

```bash
vault read database/static-creds/vault-rotate     # username (fixe) + password courant + ttl restant
vault write -f database/rotate-role/vault-rotate  # forcer une rotation immédiate
```

## 🛡️ Les policies

Une policy = un usage, scopée au chemin exact. Aucun wildcard de mount.

| Fichier | Autorise |
|---|---|
| `policies/vso-static-kv.hcl` | `read` sur `kvv2/data/demo/app` + `kvv2/metadata/demo/app` |
| `policies/vso-dynamic-db.hcl` | `read` sur `db/creds/demo-app` (⚠️ mount `db/` — cf. Pièges) + `update` sur `sys/leases/renew\|revoke` |
| `policies/vso-pki.hcl` | `create`/`update` sur `pki/issue/demo` et `pki/revoke` |
| `policies/vso-transit-cache.hcl` | `encrypt`/`decrypt` de la clé `vso-client-cache` (opérateur) |
| `policies/kubeadm-lab-nginx-test-vault.hcl` | `read` sur `kubeadm-lab/data\|metadata/nginx-test-vault/*` |

> ℹ️ **KV-v2** : le chemin de policy est `<mount>/data/<path>` pour les données et
> `<mount>/metadata/<path>` pour les versions — **pas** `<mount>/<path>`. Erreur classique.

## ✅ Vérifier

```bash
vault status                                       # Sealed=false
vault secrets list                                 # kvv2/, database/, pki/, transit/, kubeadm-lab/
vault auth list                                    # kubernetes/ présent
vault read auth/kubernetes/config                  # kubernetes_host DOIT être une vraie URL
vault list auth/kubernetes/role                     # vso-*, nginx-test-vault, pg-rotate-demo
vault policy list
vault kv get kvv2/demo/app                          # secret de démo (parcours B)
vault kv get kubeadm-lab/nginx-test-vault/config       # secret du lab (parcours A)
vault list pki/issuers                              # UNE seule CA attendue (cf. Pièges)

# Test de login « à blanc », sans passer par VSO — isole les problèmes d'identité :
JWT=$(kubectl -n demo create token vso-app --audience=vault)
vault write auth/kubernetes/login role=vso-static jwt="$JWT"   # doit renvoyer un token + sa policy
```

## ⚠️ Pièges

- **La démo « dynamic DB » ne peut pas fonctionner en l'état — décalage de mount.**
  `00-secrets-engines.sh:19` fait `vault secrets enable database`, **sans `-path`** : le moteur est
  donc monté sur **`database/`**. Or `../k8s/20-dynamic-db.yaml:11` demande `mount: db` et
  `policies/vso-dynamic-db.hcl:5` n'autorise que `db/creds/demo-app`. Le `VaultDynamicSecret` ne
  peut renvoyer qu'un **403 ou un 404**, quoi qu'on fasse par ailleurs. Pour aligner le tout sur
  `db/`, il faut monter le moteur au bon endroit :
  ```bash
  vault secrets enable -path=db database      # au lieu de : vault secrets enable database
  ```
  (Le parcours A n'est pas concerné : `pg-dynamic-rotate.sh` écrit et lit cohéremment `database/`.)
- **`01-kubernetes-auth.sh` en mode `incluster` casse tous les logins.** La ligne 26 écrit
  `kubernetes_host="https://\$KUBERNETES_PORT_443_TCP_ADDR:443"` : le `\$` est un `$` **littéral**
  en bash, et Vault ne fait aucune substitution d'environnement sur les valeurs de config. Vault
  stocke donc la chaîne telle quelle, et toute authentification via `auth/kubernetes` échoue.
  Le script frère fait correctement `kubernetes_host="https://kubernetes.default.svc"`
  (`kubeadm-lab.sh:22`). Diagnostic :
  ```bash
  vault read auth/kubernetes/config     # si kubernetes_host contient un "$", c'est ce bug
  vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"   # correctif
  ```
- **Les scripts `00-`/`01-`/`02-` ne sont PAS idempotents, contrairement à ce que dit leur
  en-tête.** Trois raisons distinctes :
  - `00-secrets-engines.sh:16` (`vault kv put kvv2/demo/app …`) et `kubeadm-lab.sh:31-34`
    (`APP_SECRET_TOKEN`) **réécrasent la valeur** et créent une **nouvelle version KV** à chaque
    relance. Si tu as fait tourner le secret pour observer la resync du VSO, relancer le script
    remet silencieusement la valeur d'origine.
  - `00-secrets-engines.sh:35-36` : depuis Vault 1.11 (multi-issuers), `pki/root/generate/internal`
    **n'échoue plus** sur un mount déjà configuré — il ajoute simplement un **nouvel émetteur**.
    Le garde-fou `|| echo "(CA racine déjà générée)"` ne se déclenche donc jamais, et chaque
    relance **empile une CA racine de plus**. Contrôler avec `vault list pki/issuers` et supprimer
    les doublons (`vault delete pki/issuer/<id>`).
  - `pg-dynamic-rotate.sh` réécrit `database/config/pg-demo` et le static role à chaque passage.
    C'est le mécanisme prévu pour changer `ROTATION_PERIOD`, mais ce n'est pas neutre.
- **Aucune garde d'environnement dans `00-`/`01-`/`02-`**, contrairement à `kubeadm-lab.sh:14-15` et
  `pg-dynamic-rotate.sh:21-22` qui refusent de démarrer sans `VAULT_ADDR`/`VAULT_TOKEN`. Sans
  `VAULT_ADDR`, le CLI tape silencieusement `https://127.0.0.1:8200` ; le script ne s'arrête qu'à
  la ligne 38 de `00-` (`${VAULT_ADDR}` sous `set -u` → *unbound variable*), donc **après** avoir
  déjà tenté d'écrire. Exporter les deux variables avant de lancer quoi que ce soit.
- **`00-secrets-engines.sh:11` masque toutes les erreurs Vault.** Le helper
  `enable() { vault secrets enable "$@" 2>/dev/null || echo "  (déjà activé : $*)"; }` avale
  `stderr` : un `Vault is sealed`, un `permission denied` ou un `connection refused` s'affichent
  comme **« (déjà activé) »**. Le script s'interrompra bien à la commande suivante (`set -e`), mais
  avec un diagnostic trompeur. En cas de doute, relancer la commande à la main sans `2>/dev/null`.
- **`permission denied` au login** : le SA/namespace du pod ne matche pas
  `bound_service_account_names`/`_namespaces`, ou l'**audience** du JWT ≠ `audience` du role. Le
  test de login « à blanc » de la section ✅ isole le problème sans impliquer VSO.
- **`error validating token: … 403`** : le reviewer n'a pas `system:auth-delegator` (in-cluster), ou
  le `token_reviewer_jwt` est faux/expiré (externe).
- **Ne pas remettre `disable_iss_validation=false`** : le défaut est `true` depuis Vault 1.9, et
  l'`iss` des tokens projetés varie → logins cassés.
- **Secrets de démo en clair dans les scripts.** `00-secrets-engines.sh` et `kubeadm-lab.sh` posent
  des valeurs bidon, versionnées dans git. C'est assumé pour un lab ; en prod, les valeurs
  s'injectent hors git (`vault kv put … @-` depuis un pipe, ou un vrai flux d'approvisionnement).

## 📚 Références

- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes auth — HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [Policies Vault](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [Moteur `database` — static roles](https://developer.hashicorp.com/vault/docs/secrets/databases#static-roles)
- [Moteur PKI — multi-issuers](https://developer.hashicorp.com/vault/docs/secrets/pki/considerations)
