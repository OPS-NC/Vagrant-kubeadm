<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🐒 `chaos-kube/` — chaos engineering (chaoskube 0.39)

> Supprime **un pod au hasard par heure**, partout sauf `kube-system`,
> `longhorn-system`, `vault` et `cnpg-demo`. Le but n'est pas de casser : c'est de prouver que ce que fait tourner le
> lab revient **tout seul**. Ce qui ne revient pas n'a jamais été vraiment hautement
> disponible.

## 🎯 À quoi ça sert

[chaoskube](https://github.com/linki/chaoskube) tire un pod au hasard à chaque tick et le
supprime. Ce seul comportement répond à des questions qu'aucun `kubectl get` ne tranchera :

| Question | Ce qu'un kill révèle |
|---|---|
| Cette charge est-elle vraiment pilotée ? | un pod nu (sans Deployment/StatefulSet) **ne revient jamais** |
| L'appli tolère-t-elle la perte d'un réplica ? | un Deployment à 1 réplica = coupure visible |
| Les PVC se rattachent-ils ? | un volume `longhorn` RWO doit suivre le pod sur son nouveau node |
| La HA est-elle réelle ou sur le papier ? | `../vault-cluster/` survit à la perte d'1 pod — mais revient **scellé**, d'où son exclusion |

Fichiers du dossier :

| Fichier | Rôle |
|---|---|
| `chaoskube-up.sh` | l'install : chart, flags, et il réaffiche les flags réellement actifs dans le pod |
| `values.yaml` | valeurs Helm : `interval: 1h`, les exclusions de namespace, `no-dry-run` |

## 📋 Prérequis

L'addon le plus léger du lab — pas de stockage, pas de Gateway, pas de certificat.

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` posé | le script teste `/readyz` | `kubectl get nodes` |
| `helm` dans le `PATH` | l'install passe par le chart amont | `helm version` |
| Quelque chose à tuer | sur un cluster vide, chaoskube n'a rien à prouver | `kubectl get deploy -A` |

> ℹ️ Le chart crée son `ServiceAccount` + son `ClusterRole` (`pods : list, delete` et
> `events : create`, à l'échelle du cluster). Large par nature — c'est **le métier** de l'outil.

## ⚡ Installation

Versions épinglées : chart **0.6.0**, app **v0.39.0**.

```bash
./_k8s/chaos-kube/chaoskube-up.sh
```

Idempotent (`helm upgrade --install`), relançable. Deux molettes :

```bash
CHAOS_DRY_RUN=1 ./_k8s/chaos-kube/chaoskube-up.sh   # observation seule, ne supprime rien
CHAOSKUBE_VERSION=0.6.0 ./…                          # épingler une autre version de chart
```

Le script termine en relisant les flags **depuis le Deployment** plutôt qu'en réaffichant
`values.yaml` : c'est la seule preuve que les exclusions et `--no-dry-run` ont bien atterri dans
le pod.

## 🔧 Sous le capot

Toute la configuration tient en quatre flags, issus de `values.yaml` :

```
--interval=1h
--namespaces=!kube-system,!longhorn-system,!vault,!cnpg-demo
--no-dry-run
--timezone=Pacific/Noumea
```

### La syntaxe d'exclusion

`--namespaces` prend une liste façon sélecteur où `!ns` veut dire *exclure*, séparée par des
virgules. Les quatre exclusions de ce lab ne sont pas arbitraires :

- **`kube-system`** — avec un seul control plane, tuer `kube-apiserver`, `etcd`, `coredns` ou
  l'agent Cilium fait tomber le *cluster*, pas une application. Il n'y a aucune HA à tester là.
- **`longhorn-system`** — le CSI porte les volumes de tout le reste. Tuer un `instance-manager`
  arrache des volumes encore montés ailleurs ; les dégâts tombent sur des innocents plutôt que
  sur le pod testé.
- **`vault`** — le Raft survit à la perte d'un pod, mais le pod revient **scellé** et ce lab n'a
  pas d'auto-unseal. En quelques heures les 3 sont scellés et Vault tombe : ça ne teste plus la
  résilience, ça devient une corvée (`../vault-cluster/vault-up.sh`, à chaque fois).
- **`cnpg-demo`** — le cluster Postgres de démo (`Cluster/pg-demo`, cf.
  `../cloudnative-pg/cluster-demo.yaml`). C'est bien le namespace du **cluster**, pas celui de
  l'opérateur : `cnpg-system` reste du gibier, tuer l'opérateur ne coupe aucun chemin de donnée.

Tout le reste est une cible, y compris `envoy-gateway-system` — depuis #62 le plan de données
tourne à 2 réplicas, donc un kill n'y coûte rien (le contrôleur redémarre, l'autre envoy
continue de servir).

### Le dry-run est le défaut amont

chaoskube est livré **dry-run activé** : sans `--no-dry-run` il logue `would kill …` à l'infini
et ne supprime rien. `values.yaml` porte donc `no-dry-run: ""` — une valeur vide, parce que le
chart rend `--<clé>` pour toute clé dont la valeur est vide.

Repasser en dry-run demande de **retirer la clé**, pas de la mettre à `false` : le template du
chart émet `--<clé>` dès que la valeur est fausse, donc `--set chaoskube.args.no-dry-run=null`
laisse le flag en place (vérifié au `helm template`), et `--no-dry-run=false` n'est pas un flag
chaoskube. D'où le `CHAOS_DRY_RUN=1` qui rend les values dans un fichier temporaire, la ligne en
moins.

## ✅ Vérifier

```bash
# dryRun=false est LA ligne qui compte — dryRun=true veut dire qu'il ne fait que parler
kubectl -n chaos-kube logs deploy/chaoskube | head -5

# les filtres tels que chaoskube les a COMPRIS (pas tels que tu les as écrits)
kubectl -n chaos-kube logs deploy/chaoskube | grep 'setting pod filter'

# le tableau de chasse, le plus récent en dernier
kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp
```

Attendu au démarrage : `dryRun=false interval=1h0m0s`, puis
`namespaces="!cnpg-demo,!kube-system,!longhorn-system,!vault"` — chaoskube les trie, l'ordre ne
correspondra donc pas à `values.yaml` — puis un premier `terminating pod` : il tue une fois au
démarrage, puis toutes les heures.

## 🌐 Accès

**Pas d'UI, pas d'`HTTPRoute`, pas de domaine** : chaoskube est une boucle de contrôle, il
n'expose rien. On l'observe par ses logs et par les Events `Killing` qu'il écrit sur ses
victimes.

| Interface | Commande |
|---|---|
| Log en direct | `kubectl -n chaos-kube logs -f deploy/chaoskube` |
| Victimes | `kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp` |

Le mettre en pause sans désinstaller — le moyen le plus rapide d'arrêter l'hémorragie pendant
une session de debug :

```bash
kubectl -n chaos-kube scale deploy/chaoskube --replicas=0
```

## ⚠️ Pièges

- **Retirer `vault` de l'exclusion le scelle.** Il est exclu par défaut pour cette raison :
  Vault survit à la perte d'un pod (Raft, 3 réplicas), mais le pod redémarré est scellé et reste
  `0/1` — pas d'auto-unseal ici. Enlève `!vault` de la liste et en quelques heures les trois sont
  scellés et Vault tombe ; s'en sortir demande de relancer `../vault-cluster/vault-up.sh` après
  chaque kill.
- **Exclure un namespace qui n'existe pas ne pose aucun problème.** `cnpg-demo` n'apparaît
  qu'une fois `../cloudnative-pg/` installé ; chaoskube ne filtre que sur un nom et ne se plaint
  jamais. L'exclusion peut donc être posée avant l'addon — c'est exactement le cas ici.
- **Le dry-run est le défaut amont** — la première façon de croire que le chaos tourne alors que
  rien n'est supprimé. Vérifier `dryRun=false` dans les logs, pas dans le manifeste.
- **Un pod nu ne revient jamais.** chaoskube supprime des pods, il ne regarde pas qui les
  possède. Tout ce qui a été créé avec un simple `kubectl run` / un manifeste `Pod` est perdu —
  ce qui est précisément le constat, pas un bug.
- **chaoskube peut se tuer lui-même** : son propre namespace n'est pas exclu. Le Deployment le
  recrée, mais le minuteur horaire repart de zéro : un auto-kill saute donc silencieusement un
  tour.
- **Un seul control plane** : c'est la raison de l'exclusion de `kube-system`. Ne **pas** retirer
  cette exclusion sur cette topologie (`CONTROL_PLANES=1` dans `lab.env`) — il n'y a pas de
  second API server pour prendre le relais.
- **`minimum-age` n'est pas posé**, donc un pod qui vient de démarrer est une cible valide, y
  compris en plein rollout. Mettre `minimum-age: "1h"` dans `values.yaml` pour ne toucher que
  des charges stabilisées.
- **Le fuseau est `Pacific/Noumea`**, aligné sur le `LAB_DOMAIN` du lab (`*.ops.nc`). Il n'agit
  que sur l'horodatage des logs tant qu'aucun `excluded-weekdays` / `excluded-times-of-day`
  n'est posé — ajoute l'un des deux et le fuseau devient structurant.

## 📚 Références

- [chaoskube — flags](https://github.com/linki/chaoskube#flags)
- [chaoskube — chart Helm](https://github.com/linki/chaoskube/tree/master/chart)
- [`../vault-cluster/LISEZ-MOI.md`](../vault-cluster/LISEZ-MOI.md) — le descellement que le chaos
  impose
- [`../node-problem-detector/LISEZ-MOI.md`](../node-problem-detector/LISEZ-MOI.md) — l'autre face
  de la pièce : détecter les ennuis au niveau node plutôt que les provoquer
