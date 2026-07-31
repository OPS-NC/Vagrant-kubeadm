<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 📜 `cert-manager/` — TLS wildcard automatique (ACME DNS-01 Cloudflare)

> **Un certificat `*.kubeadm.lab.example.io` public, émis et renouvelé sans rien faire.** cert-manager
> surveille `main-gateway`, y lit une annotation, crée le `Certificate`, prouve à Let's Encrypt
> que tu contrôles le domaine via un **TXT DNS chez Cloudflare**, puis remplit le Secret que
> l'écouteur `:443` d'Envoy sert. Aucun port entrant, aucun `Certificate` écrit à la main.

> ⚠️ **C'est le mode TLS optionnel.** `platform-up.sh` n'installe cert-manager **que** si
> `SELF_SIGNED=false` dans `lab.env`. Le défaut (`SELF_SIGNED=true`) signe le même wildcard
> localement avec `openssl` et n'installe rien de tout ceci — voir
> [`../self-signed/`](../self-signed/LISEZ-MOI.md), qui compare aussi les deux modes point par
> point. Tout ce qui suit suppose que tu as posé `SELF_SIGNED=false`.

## 🎯 À quoi ça sert

Toutes les UI du lab (`argo.`, `vault.`, `longhorn.`, `grafana.`, `kyverno.`, `wordpress.`…)
sont servies en HTTPS **trusté par les navigateurs** derrière une IP privée, sans exception de
sécurité à cliquer et sans CA maison à distribuer.

### Pourquoi DNS-01, pourquoi Let's Encrypt

- **DNS-01** : Let's Encrypt vérifie le domaine via un TXT `_acme-challenge.kubeadm.lab.example.io`,
  posé par cert-manager avec le token Cloudflare. **Aucune connexion entrante requise** → ça
  marche derrière un réseau host-only + Tailscale, là où HTTP-01 échouerait.
- **Wildcard** : seul DNS-01 sait émettre `*.kubeadm.lab.example.io` (HTTP-01 ne peut pas).
- **Let's Encrypt plutôt que Cloudflare Origin CA** : comme le DNS est en **DNS-only (nuage
  gris)**, le TLS est terminé par **Envoy**, pas par l'edge Cloudflare. C'est donc le
  navigateur qui valide le certificat d'Envoy → il doit être **publiquement trusté**. Un cert
  *Origin CA* (trusté seulement par l'edge Cloudflare) serait rejeté.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `main-gateway` en place ([`../envoy-gateway/`](../envoy-gateway/LISEZ-MOI.md)) | c'est l'objet que cert-manager observe | `kubectl get gateway -n envoy-gateway-system` |
| **CRD Gateway API** présentes | cert-manager les découvre au démarrage (installées par le chart Envoy Gateway) | `kubectl get crd gateways.gateway.networking.k8s.io` |
| Zone `example.io` chez Cloudflare, `*.kubeadm.lab.example.io → 192.168.56.200` en **DNS-only** | le solveur DNS-01 écrit dans cette zone | `dig +short TXT _acme-challenge.kubeadm.lab.example.io` |
| **Token API Cloudflare** (`Zone/DNS/Edit` + `Zone/Zone/Read`, scopé `example.io`) | permet à cert-manager de poser le TXT | `kubectl -n cert-manager get secret cloudflare-api-token` |

Le token se met dans **`lab.env`** (`CLOUDFLARE_API_TOKEN=…`, fichier gitignoré) : c'est là que
`platform-up.sh` va le chercher pour créer le Secret.

> 🌐 **Domaine neutre par défaut** (le dépôt est public) : les manifestes portent
> `kubeadm.lab.example.io` et la zone `example.io`. `platform-up.sh` substitue à la volée, depuis
> `lab.env` : `LAB_DOMAIN` (hostname du wildcard), `LAB_DNS_ZONE` (le `dnsZones` du solveur —
> défaut : les 2 derniers labels de `LAB_DOMAIN`) et `LAB_ACME_EMAIL` (défaut `admin@<zone>`).
> Le `Certificate`/`Secret` TLS suit le domaine : `wildcard-<LAB_DOMAIN avec des tirets>-tls`.
> Sans substitution, le solveur ne matcherait jamais ta zone et le certificat resterait en
> attente. Cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## ⚡ Installation

cert-manager est installé par la plateforme, étape `[4/4]`, **à condition que
`SELF_SIGNED=false`** :

```bash
echo 'SELF_SIGNED=false' >> lab.env      # sinon l'étape [4/4] part en auto-signé
./_k8s/platform-up.sh
```

Chart `jetstack/cert-manager` **`v1.20.2`**, épinglé dans `../platform-up.sh`
(`CERT_MANAGER_VERSION`). Le script :

1. installe le chart avec `crds.enabled=true` et **`config.enableGatewayAPI=true`** (intégration
   Gateway API, non gatée par un feature-flag depuis cert-manager 1.15) ;
2. crée le Secret `cloudflare-api-token` depuis `lab.env` (il avertit et continue si le token
   est vide — le certificat restera alors en attente) ;
3. applique **`02-clusterissuer-staging.yaml`** et **`03-clusterissuer-prod.yaml`** ;
4. attend `Ready=True` sur le `Certificate` `wildcard-kubeadm-lab-example-io-tls` — nom dérivé de
   `LAB_DOMAIN` (~1-2 min, 24 × 10 s).

<details>
<summary>Équivalent manuel (poser uniquement cette brique)</summary>

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
# --version : garder celle de platform-up.sh (CERT_MANAGER_VERSION)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token='<TON_TOKEN>'
kubectl apply -f _k8s/cert-manager/02-clusterissuer-staging.yaml \
              -f _k8s/cert-manager/03-clusterissuer-prod.yaml
```
</details>

## 🔧 Comment le certificat est émis

```
Gateway main-gateway
  ├─ annotation cert-manager.io/cluster-issuer: letsencrypt-staging   (LAB_ACME_ISSUER)
  └─ listener https (hostname *.kubeadm.lab.example.io, certificateRefs: wildcard-kubeadm-lab-example-io-tls)
        │
        ▼  cert-manager (config.enableGatewayAPI=true) observe le Gateway
   Certificate wildcard-kubeadm-lab-example-io-tls   (dnsNames déduits du `hostname` de l'écouteur)
        │  Order ──► Challenge dns-01 ──► TXT _acme-challenge.kubeadm.lab.example.io (API Cloudflare)
        ▼
   Secret wildcard-kubeadm-lab-example-io-tls  (ns envoy-gateway-system)  ──►  servi par Envoy sur :443
```

Le `Certificate` **et** le Secret naissent dans le namespace du Gateway
(`envoy-gateway-system`), pas dans `cert-manager`. Le renouvellement est automatique (à ~2/3 de
la durée de vie).

> 💡 **Sans l'intégration Gateway API**, le résultat s'obtient à la main : écrire un
> `Certificate` (`dnsNames: ["*.kubeadm.lab.example.io"]`, `issuerRef: letsencrypt-staging`,
> `secretName: wildcard-kubeadm-lab-example-io-tls`) et laisser l'écouteur le référencer. Même
> résultat, c'est juste toi qui crées l'objet au lieu de cert-manager.

### Fichiers

| Fichier | Rôle |
|---------|------|
| `01-cloudflare-api-token.example.yaml` | **gabarit** du Secret token — ne jamais committer le vrai (préférer `lab.env` + `platform-up.sh`) |
| `02-clusterissuer-staging.yaml` | `ClusterIssuer` Let's Encrypt **staging** (quotas larges, cert non trusté) |
| `03-clusterissuer-prod.yaml` | `ClusterIssuer` Let's Encrypt **prod** (cert trusté) — celui référencé par le Gateway |
| `04-gateway-https-example.yaml` | **illustration historique, à NE PAS appliquer** (cf. ⚠️ Pièges) |

> ⚠️ **`04-gateway-https-example.yaml` ne doit plus être appliqué.** Il contient un `Gateway`
> `main-gateway` complet (mêmes `name`/`namespace`) : le `kubectl apply` **remplacerait** le
> Gateway en place. La fusion est **déjà faite** dans `../envoy-gateway/Envoy-Proxy.yml`
> (écouteur `https:443` + `hostname` wildcard + `certificateRefs` + annotation
> `cluster-issuer`), et `../platform-up.sh` n'applique que `02-` et `03-`. Garde ce fichier
> comme support de lecture : il montre, isolée, la partie « HTTPS + cert-manager » du Gateway.

## ✅ Vérifier

```bash
kubectl get clusterissuer                                        # les 2 émetteurs, READY=True
kubectl -n envoy-gateway-system get certificate                  # wildcard-…-tls, READY=True
kubectl -n envoy-gateway-system describe certificate wildcard-kubeadm-lab-example-io-tls
                                                                 # events : Order → Challenge → issued
kubectl get challenges -A                                        # vide une fois validé

# Quel certificat Envoy sert-il ? (aucune HTTPRoute nécessaire : on ne teste que le TLS)
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.kubeadm.lab.example.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# attendu : subject=CN=*.kubeadm.lab.example.io, issuer=Let's Encrypt (et non "STAGING")
```

Test HTTPS de bout en bout : il faut un hostname **qui porte une `HTTPRoute`** (les routes de
démo de `../envoy-gateway/GW-Example.yml` matchent par chemin, pas par hostname). Par exemple,
une fois l'addon Argo CD installé :

```bash
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.kubeadm.lab.example.io:443:192.168.56.200 https://argo.kubeadm.lab.example.io/
# attendu : 200 verify=0   (verify=0 = chaîne validée sans -k)
```

## 🚑 Dépannage

- **`Challenge` bloqué en `pending`** → token Cloudflare (permissions ou zone), ou propagation
  TXT lente. `kubectl describe challenge <name>` donne l'erreur exacte de l'API Cloudflare.
- **Secret `cloudflare-api-token` absent** → `CLOUDFLARE_API_TOKEN` vide dans `lab.env` au
  moment du `platform-up.sh` (le script le signale sans échouer). Crée le Secret, puis
  `kubectl -n envoy-gateway-system delete challenge --all` pour relancer (les `Order`/`Challenge`
  vivent dans le namespace du `Certificate`, donc du Gateway).
- **`Certificate` jamais créé malgré l'annotation** → cert-manager ne tourne pas avec
  `config.enableGatewayAPI=true`, ou il a démarré **avant** les CRD Gateway API :
  `kubectl -n cert-manager rollout restart deploy/cert-manager`.
- **Navigateur qui refuse le certificat** → tu es sur `letsencrypt-staging`, qui est le
  **défaut**. Mets `LAB_ACME_ISSUER=prod` dans `lab.env`, relance `platform-up.sh`, puis
  supprime le Secret pour forcer une réémission :
  `kubectl -n envoy-gateway-system delete secret wildcard-<domaine-en-tirets>-tls`.
- **`429 rateLimited` en prod** → le plafond de **5 certificats par semaine et par jeu
  d'identifiants** est atteint. Rien à corriger, rien à retenter : le message porte l'heure de
  `retry after` et la fenêtre de 168 h est glissante. À noter que **chaque `vagrant destroy` en
  brûle un**, puisque le wildcard ne vit que dans etcd. Repasse en `LAB_ACME_ISSUER=staging` en
  attendant, ou sauvegarde le Secret avant de détruire (cf. [`../../LISEZ-MOI.md`](../../LISEZ-MOI.md) §5).

## ⚠️ Pièges

- **`SELF_SIGNED=true` (le défaut) court-circuite toute cette page.** Si
  `kubectl get clusterissuer` répond `no resources found` et que la Gateway ne porte aucune
  annotation `cert-manager.io/cluster-issuer`, rien n'est cassé : tu es simplement sur le
  chemin auto-signé. Pose `SELF_SIGNED=false` dans `lab.env`, relance `platform-up.sh`, puis
  supprime le Secret auto-signé résiduel pour que cert-manager émette le sien :
  `kubectl -n envoy-gateway-system delete secret <wildcard>-tls`.
- **Ne pas appliquer `04-gateway-https-example.yaml`** (voir l'encart plus haut).
- **Un seul niveau de wildcard** : `*.kubeadm.lab.example.io` couvre `argo.kubeadm.lab.example.io`, pas
  `a.b.kubeadm.lab.example.io`. Une route avec un hostname non couvert ne s'attachera pas à l'écouteur.
- **L'e-mail ACME versionné est neutre** (`admin@example.io`) : `platform-up.sh` le remplace par
  `LAB_ACME_EMAIL` (défaut `admin@<LAB_DNS_ZONE>`). En `kubectl apply -f` direct, tu appliques
  l'adresse d'exemple — Let's Encrypt refuse certains domaines réservés.
- **DNS-only obligatoire côté Cloudflare** : en mode « proxy orange », l'edge tenterait de
  joindre `192.168.56.200` et l'accès casserait (le challenge DNS-01, lui, marcherait quand même).

## 📚 Références

- [`../self-signed/LISEZ-MOI.md`](../self-signed/LISEZ-MOI.md) — l'autre mode TLS (`SELF_SIGNED=true`, le défaut)
- [cert-manager — Gateway API integration](https://cert-manager.io/docs/usage/gateway/)
- [cert-manager — DNS-01 Cloudflare](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Let's Encrypt — Rate limits](https://letsencrypt.org/docs/rate-limits/)
- [`../envoy-gateway/LISEZ-MOI.md`](../envoy-gateway/LISEZ-MOI.md) — le Gateway qui porte ce certificat
