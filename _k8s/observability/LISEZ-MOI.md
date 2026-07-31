<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 📈 `observability/` — métriques (Prometheus/Grafana) + logs (Loki/Alloy)

> La pile d'observabilité du lab, en une commande : **kube-prometheus-stack** (Prometheus,
> Grafana, Alertmanager, node-exporter, kube-state-metrics) + **Loki** (logs) + **Grafana
> Alloy** (collecte). Trois UI en HTTPS derrière `main-gateway`.

> 🌐 **`kubeadm.lab.example.io` est le domaine NEUTRE du dépôt (public)** : `observability-up.sh`
> le remplace par `LAB_DOMAIN` (`lab.env`) dans les values Helm **et** les `HTTPRoute`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

- Support des modules **PromQL / dashboards / alerting** (Prometheus + Grafana + Alertmanager).
- **Logs centralisés** : Alloy lit `/var/log/pods` sur chaque node → Loki → onglet *Explore*
  de Grafana (Grafana est pré-câblé avec les **deux** datasources).
- Base sur laquelle brancher les métriques des autres addons (⚠️ rien n'est branché par
  défaut, cf. Pièges).

### Deux partis-pris importants

- **Alloy en mode fichier (pas API).** Lire les logs via `loki.source.kubernetes` (API k8s)
  fait transiter **tous les logs à travers le kube-apiserver** → charge énorme (a contribué à
  l'incident CP de ce lab). Ici Alloy lit directement `/var/log/pods` sur chaque node (un
  DaemonSet, une part par node) ; `discovery.kubernetes` ne sert qu'à **étiqueter** (watch
  léger de métadonnées).
- **Stockage `longhorn-r1` (1 réplica bloc).** Métriques et logs sont reconstructibles : pas
  besoin de répliquer les blocs 3×, ça saturerait le disque OS partagé.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `../platform-up.sh` (Cilium + Envoy Gateway + cert-manager) | expose les 3 UI en HTTPS:443 avec le cert wildcard | `kubectl get gateway -n envoy-gateway-system` |
| **Longhorn** + SC **`longhorn-r1`** (`../longhorn/longhorn-r1-storageclass.yaml`) | PVC de Prometheus (3Gi), Loki (3Gi), Grafana (1Gi) ; le script **s'arrête** sans elle | `kubectl get sc longhorn-r1` |
| **CP à 4 Go** (`CP_MEM=4096` dans `lab.env`) | cette pile charge l'apiserver (scrapes + watches) | `vagrant ssh k8s-cp1 -c 'free -h'` |

> ⚠️ **RAM des control-plane — `lab.env.example` livre `CP_MEM=3072`, ce qui NE SUFFIT PAS pour
> cette pile.** Monte-le à **`CP_MEM=4096`** dans ton `lab.env` **avant** d'installer, puis
> `vagrant reload` des CP **un par un**.
>
> Sur des CP à **3 Go**, empiler cette pile sur le reste du lab **sature etcd/apiserver**
> (incident vécu : OOM en boucle, API injoignable). À **4 Go**, la pile tient à ~50 % de la
> mémoire CP. 2 Go **affament déjà etcd** tout seuls.

## ⚡ Installation

```bash
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml   # si pas déjà fait
./_k8s/observability/observability-up.sh
```

Versions épinglées dans le script (surchargeables par variable d'env) :

| Chart | Version | App |
|---|---|---|
| `prometheus-community/kube-prometheus-stack` | `87.19.0` (`KPS_VERSION`) | Prometheus Operator v0.92.1 |
| `grafana/loki` | `7.1.0` (`LOKI_VERSION`) | Loki v3.6.8 |
| `grafana/alloy` | `1.11.0` (`ALLOY_VERSION`) | Alloy v1.18.0 |

## 🔧 Ce que fait le script

1. **namespace `monitoring`** en PodSecurity `privileged` (node-exporter en hostNetwork/hostPath
   + Alloy en hostPath sur `/var/log/pods`) ;
2. **kube-prometheus-stack** → attend le rollout de Grafana ;
3. **Loki** (SingleBinary, filesystem) → attend le StatefulSet ;
4. **Alloy** (DaemonSet) → attend le DaemonSet ;
5. **HTTPRoutes** grafana / prometheus / alertmanager.

### Fichiers

| Fichier | Rôle |
|---------|------|
| `namespace.yaml` | ns `monitoring` en PodSecurity `privileged` |
| `kube-prometheus-stack-values.yaml` | Prometheus (`retention: 2d`, PVC 3Gi `longhorn-r1`) + Grafana (PVC 1Gi + datasource Loki) + Alertmanager (emptyDir) ; controller-manager et scheduler **scrutés**, etcd et kube-proxy coupés (cf. ci-dessous) ; scrape **tous** les ServiceMonitor/PodMonitor |
| `loki-values.yaml` | Loki **SingleBinary** + filesystem sur PVC 3Gi `longhorn-r1` ; caches memcached **coupés** (sinon ~9 Go de RAM demandés) |
| `alloy-values.yaml` | Alloy **DaemonSet, mode fichier** (`/var/log/pods`) → Loki ; **ne charge PAS l'apiserver** |
| `httproutes.yaml` | 3 `HTTPRoute` HTTPS sur `main-gateway` (TLS wildcard déjà porté par l'écouteur) |
| `observability-up.sh` | Installe tout dans l'ordre (idempotent) |

### Cibles du control plane : deux allumées, deux éteintes

Le lab Talos désactivait les **quatre** moniteurs du control plane, parce que ces composants
n'y écoutaient qu'en loopback. Sur kubeadm la situation diffère composant par composant : on les
active donc **un par un**, jamais en bloc — pas question de livrer une cible morte.

| Moniteur | État | Pourquoi |
|---|---|---|
| `kubeControllerManager` | **on**, `:10257` HTTPS | `kubeadm/templates/kubeadm-init.yaml.tpl` lui pose `bind-address: 0.0.0.0`. `insecureSkipVerify: true` : le certificat servi est signé par la CA du cluster mais ne porte pas le nom DNS du Service. |
| `kubeScheduler` | **on**, `:10259` HTTPS | idem. |
| `kubeEtcd` | **off** | etcd *est* bien un pod statique empilé et expose *bien* `:2381`, mais kubeadm génère son manifeste avec `--listen-metrics-urls=http://127.0.0.1:2381` — **loopback uniquement**, ça sert la probe de liveness du pod. Pour l'ouvrir vraiment : ajouter `listen-metrics-urls: http://0.0.0.0:2381` à `etcd.local.extraArgs` dans `kubeadm/templates/kubeadm-init.yaml.tpl`, puis repasser `kubeEtcd.enabled: true` avec `service.port: 2381` et `serviceMonitor.scheme: http`. |
| `kubeProxy` | **off** | il n'y a **pas de kube-proxy** : `KUBE_PROXY_REPLACEMENT=true` (défaut de `lab.env`) lance `kubeadm init --skip-phases=addon/kube-proxy` et Cilium prend les Services en eBPF. Les métriques équivalentes viennent de Cilium. |

Les deux pods statiques portent les labels `component: kube-controller-manager` /
`component: kube-scheduler` sur lesquels le Service headless du chart sélectionne : rien
d'autre à câbler.

## ✅ Vérifier

```bash
kubectl -n monitoring get pods                         # tout Running (dont 1 alloy par node)
kubectl -n monitoring get httproute                    # grafana/prometheus/alertmanager

# Cibles du control plane réellement UP (une ligne par control plane, deux fois) :
kubectl -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
  | grep -o '"job":"kube-[a-z-]*"' | sort -u   # kube-controller-manager, kube-scheduler

# Endpoints (cert wildcard ; --resolve court-circuite le DNS). -k si cert staging.
for h in grafana prometheus alertmanager; do
  curl -sk -o /dev/null -w "$h -> %{http_code}\n" \
    --resolve $h.kubeadm.lab.example.io:443:192.168.56.200 https://$h.kubeadm.lab.example.io/
done   # attendu : grafana 302, prometheus 302, alertmanager 200

# Logs qui arrivent dans Loki (labels posés par Alloy) :
kubectl -n monitoring exec deploy/loki-gateway -- \
  wget -qO- http://localhost:8080/loki/api/v1/labels     # app, container, namespace, pod…
```

## 🌐 Accès

| Service | URL | Identifiant | Mot de passe |
|---|---|---|---|
| Grafana | `https://grafana.kubeadm.lab.example.io` | `admin` | `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' \| base64 -d; echo` |
| Prometheus | `https://prometheus.kubeadm.lab.example.io` | — | aucune authentification |
| Alertmanager | `https://alertmanager.kubeadm.lab.example.io` | — | aucune authentification |

## 🚑 Dépannage

- **404 sur les UI juste après l'install** → propagation Envoy des HTTPRoute ; réessayer après ~30 s.
- **CP qui saturent / apiserver qui flappe** → CP sous-dimensionnés : passer à **4 Go**
  (`CP_MEM`, puis `vagrant reload` des CP un par un).
- **PVC `Pending` / `ReplicaSchedulingFailure`** → `longhorn-r1` absente, ou disque plein
  (baisser la rétention ou les tailles de PVC).
- **Pas de logs dans Loki** → un Alloy par node en `2/2` ? `kubectl -n monitoring get ds alloy`.
  Puis vérifier `loki.write` dans les logs d'Alloy.
- **Un pod « sans logs »** → souvent juste une **plage temporelle** trop courte : les pods sains
  (prometheus, node-exporter…) loguent au démarrage puis se taisent. Élargir la fenêtre (12-24 h).
- **Logs du control-plane (apiserver/scheduler/controller-manager/etcd)** → ce sont des **static
  pods** : leur dossier `/var/log/pods` est nommé `<ns>_<pod>_<HASH>` (hash de config), pas
  `<uid>` API. Le `__path__` d'Alloy matche par `<ns>_<pod>_*` pour couvrir les deux cas.
  Contrairement au lab Talos — où etcd était un **service Talos**, invisible pour Loki — ici
  etcd est un pod statique ordinaire : **ses logs arrivent bien dans Loki**
  (`{pod=~"etcd-.*"}`). Seul son endpoint de *métriques* reste hors de portée (cf. « Cibles du
  control plane » ci-dessus).

## ⚠️ Pièges

- **La rétention Loki repose sur le compactor, pas sur `retention_period`.** Dans Loki,
  `limits_config.retention_period` ne fait qu'**exprimer** la limite : la suppression est le
  travail du **compactor**, dont `retention_enabled` vaut `false` par défaut. Une configuration
  qui ne pose que `retention_period` laisse donc les logs s'accumuler jusqu'au disque plein.
  `loki-values.yaml` active les deux (rétention **24 h**, `retention_enabled: true`,
  `delete_request_store: filesystem`, purge effective après `retention_delete_delay: 2h`).
  Vérifier que le bloc est bien rendu :
  ```bash
  kubectl -n monitoring get cm loki -o jsonpath='{.data.config\.yaml}' \
    | grep -A4 '^compactor:'
  ```
- **Prometheus n'a pas de `retentionSize`.** Il n'y a que `retention: 2d`, qui borne l'**âge**
  des séries, pas le **volume** occupé : un pic de cardinalité (ajout de ServiceMonitors, pods
  qui churnent) peut remplir les 3 Gi avant les 2 jours, et Prometheus se met alors en erreur
  d'écriture. Un `retentionSize: 2GiB` dans `prometheusSpec` bornerait les deux.
- **Grafana garde le mot de passe admin par défaut du chart** (documenté en commentaire dans
  `kube-prometheus-stack-values.yaml`, et **affiché en clair** par `observability-up.sh` en fin
  d'exécution) — alors que l'UI est exposée **en HTTPS public** avec un certificat Let's
  Encrypt **prod** (donc un nom résolvable et un cert trusté). Un lab, oui, mais joignable :
  changer le mot de passe dès la première connexion, ou passer par
  `grafana.admin.existingSecret`.
- **Prometheus et Alertmanager sont exposés SANS aucune authentification** (aucun filtre sur
  les HTTPRoute) : quiconque atteint la Gateway peut lire toutes les métriques et **silencer
  des alertes**.
- **Rien n'émet de métriques applicatives par défaut.**
  `serviceMonitorSelectorNilUsesHelmValues: false` fait bien que Prometheus scrape **tous** les
  ServiceMonitor/PodMonitor du cluster… mais **tous les émetteurs du lab sont coupés**. À
  basculer à `true` **après** cette install (les CRD `ServiceMonitor`/`PodMonitor` n'existent
  qu'ensuite), puis relancer le `*-up.sh` de l'addon concerné :

  | Fichier | Clé à passer à `true` |
  |---|---|
  | `../trivy-operator/values.yaml` | `serviceMonitor.enabled` |
  | `../cloudnative-pg/values.yaml` | `monitoring.podMonitorEnabled` (opérateur) |
  | `../cloudnative-pg/cluster-demo.yaml` | `monitoring.enablePodMonitor` (instances PG) |
  | `../node-problem-detector/values.yaml` | `metrics.serviceMonitor.enabled` |
  | `../vault-secret-operator/values.yaml` | `telemetry.serviceMonitor.enabled` |

## 📚 Références

- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki (Helm)](https://grafana.com/docs/loki/latest/setup/install/helm/) ·
  [Rétention Loki (compactor)](https://grafana.com/docs/loki/latest/operations/storage/retention/)
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- Addons liés : `../longhorn/` (SC `longhorn-r1`) · `../node-problem-detector/` (santé des
  nodes) · `../envoy-gateway/` + `../cert-manager/` (exposition HTTPS)
