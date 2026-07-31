<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 📝 `wordpress-example/` — WordPress + MariaDB (démo de stockage persistant)

> **La démo qui exerce Longhorn de bout en bout.** Deux PVC de **2Gi** (RWO, StorageClass
> `longhorn`) pour MariaDB (`/var/lib/mysql`) et WordPress (`/var/www/html`), exposés en **HTTPS**
> via Envoy Gateway sous `wordpress.kubeadm.lab.example.io`. Un seul manifeste, aucun script.

## 🎯 À quoi ça sert

- Prouver qu'un **PVC survit** au redémarrage d'un pod, et le montrer avec une vraie appli.
- Illustrer trois classiques du stockage bloc : **RWO / mono-attach**, `strategy: Recreate`,
  et le `subPath` pour éviter le `lost+found`.
- Illustrer la **terminaison TLS déportée** : une appli qui doit être *prévenue* qu'elle est
  derrière un proxy HTTPS.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| **StorageClass `longhorn`** ([`../longhorn/`](../longhorn/LISEZ-MOI.md)) | les 2 PVC la nomment explicitement | `kubectl get sc longhorn` |
| `main-gateway` + écouteur `https:443` ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | porte l'`HTTPRoute` | `kubectl get gateway -n envoy-gateway-system` |
| Cert wildcard `READY=True` ([`../cert-manager/`](../cert-manager/LISEZ-MOI.md)) | HTTPS trusté | `kubectl -n envoy-gateway-system get certificate` |
| DNS `wordpress.kubeadm.lab.example.io → 192.168.56.200` (**DNS-only**) | hostname de la route | `curl --resolve` sinon (cf. ✅) |

> ⚠️ **Aucun garde-fou : il n'y a pas de `*-up.sh` ici.** Le manifeste référence la StorageClass
> `longhorn` sans vérifier qu'elle existe. Sans Longhorn (ou avec seulement `local-path`), le
> `kubectl apply` **réussit** et les PVC restent silencieusement `Pending`, pods bloqués en
> `Pending` eux aussi. Vérifie `kubectl get sc` **avant**. Pour une démo sans Longhorn, remplace
> `storageClassName: longhorn` par `local-path` dans les deux PVC — en assumant qu'un PV
> `local-path` est **node-local et non répliqué** (cf.
> [`../local-path-storage/`](../local-path-storage/LISEZ-MOI.md)).

## ⚡ Installation

```bash
kubectl apply -f _k8s/wordpress-example/wordpress-mariadb.yaml
```

Tout est dans ce seul fichier, namespace **`wordpress-test`** inclus.

> 🌐 **Domaine** : le manifeste porte le domaine neutre `kubeadm.lab.example.io` (dépôt public)
> et n'est pas passé par un `*-up.sh` : édite le hostname, ou substitue ton domaine à la volée :
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.mon-domaine.tld/g' \
>   _k8s/wordpress-example/wordpress-mariadb.yaml | kubectl apply -f -
> ```
>
> (cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

> Trois endroits à couvrir dans ce manifeste : le `hostname` de l'`HTTPRoute` **et**
> `WP_HOME`/`WP_SITEURL` (`WORDPRESS_CONFIG_EXTRA`) — WordPress génère ses URL depuis
> ces deux constantes, un domaine faux casse le CSS et la redirection d'install.

## 🔧 Contenu de `wordpress-mariadb.yaml`

| Objet | Rôle |
|---|---|
| `Namespace wordpress-test` | isole la démo |
| `Secret mariadb` | identifiants DB — **mots de passe d'exemple en clair dans le manifeste** (cf. ⚠️ Pièges) |
| `PVC mariadb-data` / `wordpress-data` | **2Gi Longhorn** chacun, `ReadWriteOnce` |
| `Deployment mariadb` (`mariadb:11.4`) | DB, `strategy: Recreate`, volume monté en `subPath: mysql`, sondes `healthcheck.sh` |
| `Deployment wordpress` (`wordpress:6.7-php8.3-apache`) | front, `Recreate`, `subPath: wp`, sonde sur `/wp-login.php` |
| `Service mariadb` / `wordpress` | ClusterIP (3306 / 80) |
| `HTTPRoute wordpress` | `wordpress.kubeadm.lab.example.io` → `wordpress:80`, `sectionName: https` de `main-gateway` |

Les deux conteneurs déclarent `requests` (cpu + memory) et une **limite mémoire** seulement —
pas de limite CPU (choix du dépôt : borner la RAM, ne pas *throttler* le CPU).

### Les trois points qui font la démo

- **`strategy: Recreate`** — les volumes Longhorn sont **RWO** (mono-attach) : l'ancien pod doit
  libérer le volume avant que le nouveau l'attache. Avec `RollingUpdate` (le défaut), le nouveau
  pod resterait bloqué en multi-attach.
- **`subPath`** — la base et le site vivent dans un **sous-dossier** du volume, pour éviter le
  `lost+found` créé par ext4 à la racine (MariaDB refuse un `datadir` « non vide »).
- **TLS terminé par Envoy** — WordPress ne voit que du HTTP. On force la détection via
  `HTTP_X_FORWARDED_PROTO` et on **fige** `WP_HOME`/`WP_SITEURL` en `https://…` dans
  `WORDPRESS_CONFIG_EXTRA` ; sinon WordPress génère des URLs en `http` et boucle en redirection.

## ✅ Vérifier

```bash
kubectl -n wordpress-test get pvc,pods            # PVC Bound, pods Running 1/1
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve wordpress.kubeadm.lab.example.io:443:192.168.56.200 \
  https://wordpress.kubeadm.lab.example.io/             # 302 → /wp-admin/install.php (WP frais)
# puis finir l'installation dans le navigateur : https://wordpress.kubeadm.lab.example.io/
```

## 🧪 Scénario — la persistance, en direct

```bash
# 1. Termine l'installation WordPress dans le navigateur, publie un article.
# 2. Tue les deux pods : leurs PVC sont réattachés au redémarrage.
kubectl -n wordpress-test delete pod --all
kubectl -n wordpress-test get pods -w             # Recreate : l'ancien libère, le nouveau attache
# 3. Recharge la page : l'article est toujours là (les données vivent dans les volumes Longhorn).
```

Côté Longhorn (UI `longhorn.kubeadm.lab.example.io`, ou `kubectl -n longhorn-system get volumes`), on
voit les deux volumes se détacher puis se rattacher — et sur quel node ils sont attachés.

## ⚠️ Pièges

- **Des mots de passe en clair dans le manifeste.** Le `Secret mariadb` est écrit en
  `stringData` avec des valeurs d'exemple versionnées dans le dépôt : c'est un **support de
  formation**, pas un modèle. Hors lab, passer par un `Secret` créé hors Git (voire par
  [`../vault-secret-operator/`](../vault-secret-operator/LISEZ-MOI.md), qui fait exactement ça).
  Changer ces valeurs **après** le premier démarrage ne suffit pas : MariaDB n'initialise ses
  identifiants qu'à la création du `datadir`.
- **PVC `Pending` sans erreur visible** → StorageClass `longhorn` absente (voir 📋 Prérequis) ou
  Longhorn en panne. `kubectl -n wordpress-test describe pvc mariadb-data` donne la vraie raison.
- **`Multi-Attach error`** → un `RollingUpdate` s'est glissé à la place de `Recreate`, ou l'ancien
  pod est coincé en `Terminating` (node perdu). Forcer la suppression du vieux pod.
- **Le domaine est figé en dur** dans `WORDPRESS_CONFIG_EXTRA` (`WP_HOME`/`WP_SITEURL`) **et**
  dans l'`HTTPRoute`. Si tu changes de domaine, il faut modifier les deux — sinon WordPress
  redirige vers l'ancien nom.
- **`wordpress:6.7-php8.3-apache` et `mariadb:11.4` sont des tags de série**, pas des digests :
  le contenu peut bouger sous le même tag. C'est suffisant pour un lab, insuffisant pour de la
  reproductibilité stricte.

## 🧹 Nettoyer

```bash
kubectl delete -f _k8s/wordpress-example/wordpress-mariadb.yaml   # supprime le namespace + les PVC
```

> ℹ️ Supprimer les PVC libère les volumes Longhorn (`reclaimPolicy: Delete` de la StorageClass) :
> **les données sont perdues**, y compris les articles publiés pendant la démo.

## 📚 Références

- [Image Docker `wordpress` — variables d'environnement](https://hub.docker.com/_/wordpress)
- [WordPress — `WP_HOME` / `WP_SITEURL` derrière un proxy](https://developer.wordpress.org/apis/wp-config-php/#wp-siteurl)
- [`../longhorn/LISEZ-MOI.md`](../longhorn/LISEZ-MOI.md) — le stockage que cette démo exerce
