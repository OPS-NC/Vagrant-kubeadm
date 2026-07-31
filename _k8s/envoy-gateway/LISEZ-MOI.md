<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🚪 `envoy-gateway/` — le point d'entrée HTTP(S) du cluster

> **Un seul VIP, deux écouteurs, N applications.** [Envoy Gateway](https://gateway.envoyproxy.io/)
> (implémentation de la **Gateway API**) déploie un Envoy dont le Service `LoadBalancer` récupère
> le VIP `192.168.56.200` du pool Cilium. Le `Gateway` `main-gateway` y expose `:80` **et** `:443`
> (TLS wildcard `*.kubeadm.lab.example.io`), et chaque addon s'y branche avec une `HTTPRoute`.

> 🌐 **`kubeadm.lab.example.io` est le domaine NEUTRE du dépôt (public)** : `platform-up.sh` le
> remplace par `LAB_DOMAIN` (`lab.env`) — hostname de l'écouteur `https` et nom du Secret TLS.
> Cf. [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

- **Mutualiser l'exposition** : une IP, un certificat, un point de configuration pour toutes les
  UI du lab (Argo CD, Vault, Longhorn, Grafana, Policy Reporter, WordPress…).
- **Faire la Gateway API en vrai** : `GatewayClass` → `Gateway` → `HTTPRoute`, avec
  rattachement **inter-namespace**, filtres et routage par chemin ou par hostname.
- **Terminer le TLS** au bord du cluster : les backends parlent HTTP en clair.

> ⚠️ **Ne pas confondre avec l'Envoy embarqué dans Cilium** (désactivé ici :
> `envoy.enabled=false`, cf. [`../cilium/LISEZ-MOI.md`](../cilium/LISEZ-MOI.md)). Ici Envoy est
> piloté par le contrôleur **Envoy Gateway**, un composant à part entière.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| [`../cilium/`](../cilium/LISEZ-MOI.md) installé (pool L2) | c'est lui qui donne l'IP `.200` au Service du Gateway | `kubectl get ciliumloadbalancerippool` |
| Un Secret TLS wildcard, venu de **l'un ou l'autre** mode TLS | remplit le Secret `wildcard-kubeadm-lab-example-io-tls` de l'écouteur `:443` | `kubectl -n envoy-gateway-system get secret wildcard-…-tls` |
| Résolution de `*.kubeadm.lab.example.io → 192.168.56.200` | les routes matchent par hostname | `dig +short argo.kubeadm.lab.example.io` |

Le Secret TLS vient de [`../self-signed/`](../self-signed/LISEZ-MOI.md) quand
`SELF_SIGNED=true` (le défaut — une AC locale, sans domaine ni token) ou de
[`../cert-manager/`](../cert-manager/LISEZ-MOI.md) + un token Cloudflare quand
`SELF_SIGNED=false`. Le Gateway est le même dans les deux cas : seule l'annotation change. De
même, la résolution peut être une ligne `/etc/hosts` (auto-signé) ou un enregistrement public
**DNS-only** (ACME).

Le HTTP (`:80`) fonctionne sans aucun des deux modes TLS et sans DNS :
`curl http://192.168.56.200/...`.

## ⚡ Installation

Le contrôleur **est** installé par la plateforme, étape `[2/4]` :

```bash
./_k8s/platform-up.sh
```

Chart OCI `oci://docker.io/envoyproxy/gateway-helm` **`1.8.3`**, épinglé dans
`../platform-up.sh` (`ENVOY_GW_VERSION`, surchargeable). Le chart installe aussi les **CRD
Gateway API standard** — dont dépend cert-manager (`config.enableGatewayAPI=true`). Le script
applique ensuite `Envoy-Proxy.yml`, puis attend l'IP LoadBalancer (30 × 5 s).

<details>
<summary>Équivalent manuel (si tu veux ne poser que cette brique)</summary>

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version 1.8.3 -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway
kubectl apply -f _k8s/envoy-gateway/Envoy-Proxy.yml
```
</details>

## 🔧 `Envoy-Proxy.yml` — la plomberie

| Objet | Rôle |
|---|---|
| `EnvoyProxy` **`cilium-l2`** | paramètre l'infra Envoy : Service `type: LoadBalancer` avec `loadBalancerClass: io.cilium/l2-announcer` → l'IP vient du **pool Cilium** ; et `envoyDeployment.replicas: 2` pour le plan de données |
| `GatewayClass` **`envoy`** | classe gérée par `gateway.envoyproxy.io/gatewayclass-controller`, pointant l'`EnvoyProxy` ci-dessus |
| `Gateway` **`main-gateway`** (ns `envoy-gateway-system`) | le point d'entrée : écouteurs **`http:80`** et **`https:443`**, `allowedRoutes.namespaces.from: All` |

C'est le Service de l'`EnvoyProxy` qui déclenche l'annonce L2 Cilium → d'où le VIP `.200`.

### Plan de données : 2 réplicas

Ne pas confondre les deux Deployments de `envoy-gateway-system` :

| Deployment | Rôle | Le perdre |
|---|---|---|
| `envoy-gateway` | le **contrôleur** : observe Gateways/HTTPRoutes et configure les proxys | aucun impact trafic, la config cesse juste d'être réconciliée |
| `envoy-…-main-gateway-…` | le **plan de données** : les pods qui portent réellement le trafic | **toutes les UI du lab tombent** |

Ce second Deployment est le passage unique de toutes les UI (une seule IP LoadBalancer, `.200`),
d'où le **`replicas: 2`** figé dans `Envoy-Proxy.yml` : le Service garde un endpoint prêt pendant
qu'un pod est reprogrammé, qu'un node redémarre, ou que [`../chaos-kube/`](../chaos-kube/LISEZ-MOI.md)
le tire dans sa loterie horaire. Les deux pods partagent la même IP — rien à changer côté DNS ni
dans les `HTTPRoute`.

```bash
kubectl -n envoy-gateway-system get deploy \
  -l gateway.envoyproxy.io/owning-gateway-name=main-gateway    # attendu 2/2
```

> ℹ️ Rien n'épingle les deux pods sur des nodes **différents** : le scheduler les répartit de
> lui-même, mais ce n'est pas une garantie. Pour une garantie dure, ajouter un `podAntiAffinity`
> sous `envoyDeployment.pod.affinity` — avec une règle `required`, rester sous le nombre de
> workers sinon les pods en trop restent `Pending`.

### Les deux écouteurs (déjà câblés, rien à ajouter)

| Écouteur | Port | Hostname | TLS |
|---|---|---|---|
| `http` | 80 | *(aucun — tout hostname)* | — |
| `https` | 443 | `*.kubeadm.lab.example.io` | `Terminate`, `certificateRefs: wildcard-kubeadm-lab-example-io-tls` |

L'annotation `cert-manager.io/cluster-issuer` sur le Gateway suffit à ce que cert-manager crée
le `Certificate`, résolve le challenge DNS-01 et remplisse le Secret. Le manifeste versionné
porte `letsencrypt-staging` ; `platform-up.sh` la réécrit depuis `LAB_ACME_ISSUER` (`staging`
par défaut, `prod` sur demande — attention au plafond de **5 certificats/semaine** en
production). Le mécanisme est détaillé dans
[`../cert-manager/LISEZ-MOI.md`](../cert-manager/LISEZ-MOI.md).

> ℹ️ **Avec le défaut `SELF_SIGNED=true`, `platform-up.sh` retire purement et simplement cette
> annotation** et remplit exactement le même Secret avec un wildcard signé par `openssl`
> ([`../self-signed/`](../self-signed/LISEZ-MOI.md)). Les `certificateRefs` ci-dessus ne
> changent pas — c'est précisément pour ça qu'aucun addon n'a à savoir dans quel mode TLS
> tourne le lab.

### Brancher une application

C'est le seul travail restant pour un nouvel addon : une `HTTPRoute` qui cible l'écouteur TLS.

```yaml
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https           # cible l'écouteur :443 (sans ça, les DEUX écouteurs)
  hostnames:
    - mon-app.kubeadm.lab.example.io     # doit matcher le wildcard *.kubeadm.lab.example.io
  rules:
    - backendRefs:
        - name: mon-app
          port: 80
```

La route peut vivre dans **son** namespace (le Gateway accepte `from: All`) ; le backend doit,
lui, être dans le même namespace que la route — sinon il faut un `ReferenceGrant`.

## ✅ Vérifier

```bash
kubectl -n envoy-gateway-system get svc        # EXTERNAL-IP = 192.168.56.200 (sinon → ../cilium/)
kubectl get gateway -n envoy-gateway-system    # main-gateway, PROGRAMMED=True, ADDRESS=.200
kubectl get httproute -A                       # toutes les routes du lab
# écouteurs + nombre de routes attachées à chacun :
kubectl -n envoy-gateway-system get gateway main-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{" attached="}{.attachedRoutes}{"\n"}{end}'
# le cert servi pour un hostname du wildcard :
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.kubeadm.lab.example.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

## 🧪 `GW-Example.yml` — la démo (optionnelle)

Deux apps + leurs `HTTPRoute`, en **routage par chemin** :

| App | Route | Backend |
|---|---|---|
| `hello-nginx` (`nginxdemos/nginx-hello:plain-text`) | `/hello` → réécrit `/` | `hello-nginx:80` |
| `echo-app` (`ealen/echo-server:latest`) | `/echo` → réécrit `/` | `echo-app:80` |

```bash
kubectl apply -f _k8s/envoy-gateway/GW-Example.yml       # namespace `default`
curl -sS http://192.168.56.200/hello
curl -sS http://192.168.56.200/echo
kubectl delete -f _k8s/envoy-gateway/GW-Example.yml      # à retirer après la démo
```

> ℹ️ Ces routes n'ont **ni `hostnames` ni `sectionName`** : elles s'attachent donc aux **deux**
> écouteurs. Conséquence vérifiée : `/hello` répond aussi en HTTPS, sous *n'importe quel*
> sous-domaine du wildcard (`https://foo.kubeadm.lab.example.io/hello` → `200`). En revanche
> `https://hello.kubeadm.lab.example.io/` renvoie **404** : le match porte sur le **chemin**, pas sur
> le nom d'hôte.

## ⚠️ Pièges

- **`ADDRESS` vide / `<pending>`** → le problème est côté [`../cilium/`](../cilium/LISEZ-MOI.md)
  (pool absent ou annonce L2 inactive), pas ici.
- **404 sur une route** → chemin/hostname qui ne matche rien, `sectionName` absent ou faux, ou
  hostname hors du wildcard (`app.kubeadm.lab.example.io` ✔, `app.lab.example.io` ✘ — le wildcard ne
  couvre **qu'un** niveau).
- **Les UI exposées derrière ce Gateway n'ont pas toutes d'authentification.** L'UI **Longhorn**
  (`../longhorn/httproute.yaml`) n'en a **aucune** ; l'UI Policy Reporter non plus (rien n'est
  configuré dans `../kyverno/policy-reporter-values.yaml`). Publiées sur le VIP, elles sont
  accessibles à quiconque atteint `.200` — donc à tout peer Tailscale autorisé. Pour les
  protéger : `SecurityPolicy` Envoy Gateway (Basic Auth / OIDC) ciblant la route. Vault et
  Argo CD, eux, ont leur propre authentification.
- **`GW-Example.yml` viole les policies du dépôt lui-même** : `ealen/echo-server:latest` est
  refusé par `disallow-latest-tag` ([`../kyverno/`](../kyverno/LISEZ-MOI.md)), et
  `nginxdemos/nginx-hello:plain-text` est un **tag flottant** (il passe la policy mais ne fixe
  aucune version). Les deux apps violeraient aussi le profil PodSecurity `restricted`
  (`allowPrivilegeEscalation`, `capabilities`, `runAsNonRoot`, `seccompProfile`) — mais sur
  kubeadm l'admission PodSecurity n'applique **rien** au niveau cluster par défaut : personne ne
  proteste tant qu'on n'a pas étiqueté le namespace ou installé Kyverno. Support de démo idéal
  pour « voici ce qu'une policy attrape ».
- **Les apps de démo atterrissent dans `default`** (aucun namespace dans le manifeste) : à
  supprimer après la démo pour ne pas polluer les rapports Kyverno/Trivy.
- **Un `Gateway` concurrent écrase celui-ci** : `../cert-manager/04-gateway-https-example.yaml`
  redéfinit `main-gateway` avec les mêmes `name`/`namespace`. Ne pas l'appliquer (cf. son README).

## 📚 Références

- [Gateway API — documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway — documentation](https://gateway.envoyproxy.io/docs/)
- [Envoy Gateway — SecurityPolicy (Basic Auth, OIDC, JWT)](https://gateway.envoyproxy.io/docs/tasks/security/)
- [`../cilium/LISEZ-MOI.md`](../cilium/LISEZ-MOI.md) — d'où vient le VIP ·
  [`../cert-manager/LISEZ-MOI.md`](../cert-manager/LISEZ-MOI.md) — d'où vient le certificat
  avec `SELF_SIGNED=false`, et [`../self-signed/LISEZ-MOI.md`](../self-signed/LISEZ-MOI.md)
  avec le défaut `SELF_SIGNED=true`
