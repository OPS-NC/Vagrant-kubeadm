<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🔏 `self-signed/` — wildcard TLS sans cert-manager (`openssl`)

> **Du HTTPS sur toutes les UI du lab sans domaine, sans token Cloudflare et sans Internet.**
> Une AC locale, générée une fois sur l'hôte, signe un wildcard `*.<LAB_DOMAIN>` qui atterrit
> exactement dans le Secret qu'attend déjà l'écouteur `:443` d'Envoy. cert-manager n'est pas
> installé du tout.

## 🎯 Objectif

C'est le **mode TLS par défaut** du lab (`SELF_SIGNED=true` dans `lab.env`). Il existe parce
que l'autre chemin a de vrais prérequis : la voie ACME
([`../cert-manager/`](../cert-manager/LISEZ-MOI.md)) exige un **domaine qui t'appartient
vraiment**, un **token Cloudflare**, et elle consomme du **quota Let's Encrypt** à chaque
rebuild. Pour un lab jetable sur un réseau host-only, ça fait beaucoup de mise en place pour
un certificat que personne, hors de ta machine, ne verra jamais.

Le compromis est le seul qui compte ici : le certificat n'est **pas publiquement trusté**.
Le navigateur avertit tant que tu n'as pas importé l'AC une fois — voir [🌐 Accès](#-accès).

| | `SELF_SIGNED=true` (cette page) | `SELF_SIGNED=false` ([`cert-manager/`](../cert-manager/LISEZ-MOI.md)) |
|---|---|---|
| Domaine réel nécessaire | non | **oui** |
| `CLOUDFLARE_API_TOKEN` | inutilisé | **obligatoire** |
| Fonctionne hors-ligne | oui | non (ACME + DNS-01) |
| Trusté par le navigateur d'emblée | non (importer l'AC une fois) | oui (avec `LAB_ACME_ISSUER=prod`) |
| Quota | aucun | **5 certs/semaine** en `prod` |
| Renouvellement auto dans le cluster | non (relancer le script) | oui (cert-manager) |
| Survit à `vagrant destroy` | **oui** (AC + cert vivent sur l'hôte) | non (le wildcard ne vit que dans etcd) |

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `openssl` sur l'hôte | génère l'AC et le certificat | `openssl version` |
| `main-gateway` en place ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | c'est l'écouteur qui sert le Secret | `kubectl get gateway -n envoy-gateway-system` |
| `LAB_DOMAIN` renseigné dans `lab.env` | pilote le SAN et le nom du Secret | `sed -n 's/^LAB_DOMAIN=//p' lab.env` |

Aucune zone DNS, aucun token d'API, aucun port entrant. Le domaine **n'a pas besoin
d'exister publiquement** : il doit seulement résoudre sur la machine depuis laquelle tu
navigues.

## ⚡ Installation

Posé par la plateforme, étape `[4/4]`, dès que `SELF_SIGNED=true` :

```bash
./_k8s/platform-up.sh
```

Seul, sur une plateforme déjà en place :

```bash
./_k8s/self-signed/selfsigned-up.sh
```

Idempotent : relancé, il réutilise l'AC et conserve le certificat tant qu'il est valide.

## 🔧 Fonctionnement

```
_out/self-signed/ca.key + ca.crt        AC locale, 10 ans, générée UNE FOIS puis réutilisée
        │  signe
        ▼
_out/self-signed/tls.key + tls.crt      feuille, 825 jours
        │  SAN : DNS:*.<LAB_DOMAIN>, DNS:<LAB_DOMAIN>   ·   extendedKeyUsage : serverAuth
        ▼
Secret wildcard-<LAB_DOMAIN en tirets>-tls   (ns envoy-gateway-system, type kubernetes.io/tls)
        │  tls.crt = feuille + AC (chaîne complète)
        ▼
servi par Envoy sur :443 — le même nom de Secret que cert-manager aurait rempli
```

Comme le nom du Secret est identique sur les deux chemins, **le manifeste de la Gateway ne
change pas** d'un mode à l'autre : `platform-up.sh` se contente de retirer l'annotation
`cert-manager.io/cluster-issuer` de `main-gateway` quand `SELF_SIGNED=true`, pour que rien ne
vienne jamais reprendre la main sur le Secret.

### Pourquoi le matériel vit dans `_out/`

`_out/` est **gitignoré** : la clé privée de l'AC ne peut pas se retrouver dans un commit.
Il vit aussi sur l'**hôte**, pas dans etcd, donc il **survit à `vagrant destroy`** : tu
importes l'AC une fois dans ton magasin de confiance et tous les rebuilds suivants sont
trustés d'emblée. C'est l'inverse du chemin ACME, où chaque rebuild brûle un certificat neuf.

### Quand le certificat est régénéré

Le script refabrique la feuille (jamais l'AC) quand :

- `_out/self-signed/tls.crt` manque — p.ex. après avoir effacé `_out/` ;
- il expire dans moins de **30 jours** (`RENEW_DAYS`) ;
- `LAB_DOMAIN` a changé, donc le SAN ne couvre plus le lab.

Réglages surchargeables : `CA_DAYS` (3650), `CERT_DAYS` (825), `RENEW_DAYS` (30). 825 jours
est le plafond qu'acceptent les navigateurs pour un certificat serveur — ne monte pas
`CERT_DAYS` au-delà.

### Fichiers

| Fichier | Rôle |
|---|---|
| `selfsigned-up.sh` | génère l'AC + la feuille, crée le Secret TLS. Appelé par `../platform-up.sh` à l'étape `[4/4]` |

Tout ce qu'il produit est non versionné, sous `_out/self-signed/`.

## ✅ Vérifier

```bash
kubectl -n envoy-gateway-system get secret wildcard-<domaine-en-tirets>-tls  # type kubernetes.io/tls
kubectl -n envoy-gateway-system get gateway main-gateway                     # PROGRAMMED=True
openssl x509 -in _out/self-signed/tls.crt -noout -subject -issuer -dates -ext subjectAltName

# Quel certificat Envoy sert-il vraiment ?
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.<LAB_DOMAIN> 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# attendu : subject=CN=*.<LAB_DOMAIN>, issuer=CN=Vagrant-KubeADM self-signed CA

# De bout en bout, en validant contre l'AC locale (il faut un hostname portant une HTTPRoute) :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --cacert _out/self-signed/ca.crt \
  --resolve argo.<LAB_DOMAIN>:443:192.168.56.200 https://argo.<LAB_DOMAIN>/
# attendu : 200 verify=0
```

## 🌐 Accès

Deux choses te séparent du cadenas vert.

**1. Résoudre le nom.** Le domaine n'a pas besoin d'exister publiquement ; `/etc/hosts`
suffit :

```
192.168.56.200  argo.<LAB_DOMAIN> grafana.<LAB_DOMAIN> vault.<LAB_DOMAIN>
```

`192.168.56.200` est l'`EXTERNAL-IP` de la Gateway (`LB_POOL_START`). Si tu possèdes une zone
DNS, un enregistrement `A` wildcard est plus confortable — voir
[`../LISEZ-MOI.md`](../LISEZ-MOI.md#-accès-distant-tailscale--cloudflare).

**2. Faire confiance à l'AC** — une fois, et ça tient pour tous les rebuilds :

```bash
# Linux (Debian/Ubuntu), magasin système
sudo cp _out/self-signed/ca.crt /usr/local/share/ca-certificates/vagrant-kubeadm-lab.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain _out/self-signed/ca.crt
```

**Firefox a son propre magasin** et ignore celui du système : Paramètres → Vie privée et
sécurité → Certificats → Afficher les certificats → Autorités → Importer →
`_out/self-signed/ca.crt`.

Sauter cette étape est acceptable aussi : tu cliques simplement à travers l'avertissement du
navigateur sur chaque UI.

## ⚠️ Pièges

- **Passer de `false` à `true` sur un cluster vivant** laisse cert-manager derrière, et son
  objet `Certificate` continue de réconcilier le Secret. Relancer `platform-up.sh` retire
  l'annotation de la Gateway, ce qui fait abandonner le `Certificate` à cert-manager — mais
  si l'objet survit, supprime-le explicitement, sinon il écrase le Secret auto-signé :
  `kubectl -n envoy-gateway-system delete certificate <wildcard>-tls`.
- **Passer de `true` à `false`** demande l'inverse : supprimer le Secret auto-signé pour que
  cert-manager en émette un neuf
  (`kubectl -n envoy-gateway-system delete secret <wildcard>-tls`).
- **Effacer `_out/` jette l'AC.** Une nouvelle AC, c'est un ré-import dans chaque magasin de
  confiance. `_out/` est gitignoré et n'est jamais sauvegardé — si l'AC compte pour toi, copie
  `ca.crt` **et** `ca.key` ailleurs avant un nettoyage.
- **La clé privée de l'AC est un vrai secret.** Qui détient `_out/self-signed/ca.key` peut
  forger un certificat pour **n'importe quel** domaine que ton magasin de confiance
  acceptera, pas seulement ceux du lab. C'est le prix d'importer une AC plutôt qu'un
  certificat isolé : garde le fichier en `600` (le script s'en charge) et ne le promène pas.
- **Aucun renouvellement dans le cluster.** Rien ne surveille l'expiration : au bout de
  825 jours — 795 avec la marge de 30 jours — tu relances `selfsigned-up.sh`. Pour un lab
  reconstruit régulièrement, le cas ne se présente jamais.
- **Un seul niveau de wildcard** : `*.<LAB_DOMAIN>` couvre `argo.<LAB_DOMAIN>`, pas
  `a.b.<LAB_DOMAIN>`. Même contrainte que sur le chemin ACME.
- **`curl` sans `--cacert` échoue** avec `unable to get local issuer certificate`. C'est le
  certificat qui fait son travail, pas un bug — passe `--cacert _out/self-signed/ca.crt`, ou
  importe l'AC.

## 📚 Références

- [`../cert-manager/LISEZ-MOI.md`](../cert-manager/LISEZ-MOI.md) — l'autre mode TLS (`SELF_SIGNED=false`)
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — la Gateway qui sert ce certificat
- [Kubernetes — Secrets TLS](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)
- [`openssl-x509(1)`](https://docs.openssl.org/master/man1/openssl-x509/) — la commande de signature utilisée ici
