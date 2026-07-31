<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🩺 `node-problem-detector/` — santé des nodes (NodeConditions + Events)

> **[node-problem-detector](https://github.com/kubernetes/node-problem-detector)** (NPD) : un
> DaemonSet qui tourne sur **chaque node** (control-plane inclus), lit le journal du noyau et
> remonte les problèmes bas-niveau à Kubernetes en **NodeConditions** et **Events**.

## 🎯 À quoi ça sert

Directement motivé par l'incident **cp2** (guest figé) : NPD aurait produit un event
`TaskHung`/`OOMKilling` **visible via `kubectl`**, au lieu d'un simple `NotReady` opaque.

### Ce qu'il détecte (kernel-monitor, via `/dev/kmsg`)

| Signal noyau | Remontée |
|---|---|
| `Killed process … total-vm:…` (OOM-killer) | Event `OOMKilling` |
| `task … blocked for more than … seconds` | Event `TaskHung` |
| `unregister_netdevice: waiting for …` | Event `UnregisterNetDevice` |
| NULL pointer dereference / `divide error` | Event `KernelOops` |
| `EXT4-fs error`/`warning`, `Buffer I/O error`, `CE memory read error` | Events `Ext4Error` / `Ext4Warning` / `IOError` / `MemoryReadError` |
| `Remounting filesystem read-only` | Condition **`ReadonlyFilesystem=True`** |
| `task docker:… blocked for more than … seconds` | Condition **`KernelDeadlock=True`** |

NPD maintient en continu ces deux conditions sur chaque node (`KernelDeadlock`,
`ReadonlyFilesystem`, à `False` en temps normal) : c'est dessus qu'on alerte.

### Adaptation au lab (important)

- **kernel-monitor seulement** (`/config/kernel-monitor.json`, lecture de `/dev/kmsg`). Le
  chart charge par défaut *kernel-monitor **+ docker-monitor*** : le runtime est ici
  **containerd** (kubeadm), il n'y a pas de socket Docker → ce moniteur échoue. Le
  `systemd-monitor`, lui, lit journald ; systemd existe bien sur Debian 13, mais Debian garde
  le journal en **volatile** (`/run/log/journal`) tant que `/var/log/journal` n'est pas créé,
  alors que le chart ne monte que `/var/log` → il ne verrait rien. `values.yaml` réduit donc
  `settings.log_monitors` au seul kernel-monitor.
- **Namespace en PodSecurity `privileged`** : NPD tourne en `privileged` (accès `/dev/kmsg`).
  kubeadm n'applique aucun niveau au niveau cluster par défaut, mais le script étiquette quand
  même le namespace : ça documente l'intention et ça tient si on durcit l'admission.
- **Tolérations** `NoSchedule/Exists` → NPD tourne **aussi sur les control-plane** (cp1/2/3).

## ⚡ Installation

```bash
./_k8s/node-problem-detector/node-problem-detector-up.sh
```

Version épinglée : chart **`deliveryhero/node-problem-detector` 2.3.14** (app **v0.8.19**),
surchargeable par `NPD_VERSION=…`. Aucun prérequis : ni stockage, ni Gateway, ni CRD.

## 🔧 Ce que fait le script

1. crée le namespace `node-problem-detector` et le labellise
   `pod-security.kubernetes.io/{enforce,warn,audit}=privileged` ;
2. installe le chart avec `values.yaml` (kernel-monitor seul, `privileged`, tolérations,
   métriques sur `:20257`) et attend le DaemonSet.

## ✅ Vérifier

```bash
kubectl -n node-problem-detector get pods -o wide          # 1 pod par node (CP + workers), 1/1
# Conditions posées par NPD (False = sain) :
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n
  | .status.conditions[] | select(.type|test("KernelDeadlock|ReadonlyFilesystem"))
  | "\($n)  \(.type)=\(.status)"'
# Logs d'un agent (doit charger UNIQUEMENT kernel-monitor, 0 erreur) :
kubectl -n node-problem-detector logs ds/node-problem-detector | grep -E 'kernel-monitor|Problem detector started'
```

## 🧪 Tester une détection (optionnel)

Injecter une entrée kmsg de test sur un node déclenche l'event NPD. Les nodes sont de simples
VM Debian : le plus direct est un shell sur le node.

```bash
vagrant ssh k8s-w1 -c 'echo "task test:1234 blocked for more than 120 seconds." | sudo tee /dev/kmsg'
kubectl get events -A --field-selector reason=TaskHung
```

## 📈 Métriques

NPD expose des métriques Prometheus sur `:20257` (`metrics.enabled: true`), mais **le
ServiceMonitor est coupé** : le CRD n'existe qu'après `../observability/`. Une fois cet addon
installé, passer `metrics.serviceMonitor.enabled: true` dans `values.yaml` et relancer le
script → compteurs `problem_counter` / `problem_gauge` par type de problème.

## ⚠️ Pièges

- **`settings.custom_monitors: []` dans `values.yaml` ne fait RIEN.** Cette clé **n'existe pas**
  dans le chart 2.3.14 : les vraies clés sont `settings.custom_monitor_definitions` (map de
  fichiers de config montés dans `/custom-config`) et `settings.custom_plugin_monitors` (liste,
  vide par défaut). Helm accepte silencieusement une valeur inconnue → aucune erreur, aucun
  effet. Le commentaire du fichier laisse croire à une désactivation explicite ; en réalité les
  plugin-monitors sont déjà vides par défaut, et c'est **`log_monitors`** (bien réel) qui fait
  tout le travail d'adaptation.
- **La condition `KernelDeadlock` ne passera (presque) jamais à `True` sur ce lab.** Dans
  `kernel-monitor.json` (v0.8.19) la seule règle permanente qui la déclenche est le motif
  `task docker:\w+ blocked for more than \w+ seconds` — un processus **`docker`**, qui n'existe
  pas non plus ici (containerd). Un hang réel remontera en **event `TaskHung`** (règle temporaire,
  tous processus confondus), pas en condition de node : alerter sur les **Events**, pas
  seulement sur `KernelDeadlock`. `ReadonlyFilesystem`, lui, fonctionne normalement
  (`Remounting filesystem read-only`).
- **NPD ne corrige rien : il rend visible.** Le remède (cordon/drain, reschedule, reboot,
  auto-remédiation) reste à l'opérateur, ou à un outil type **Draino** / **Descheduler**.
- **Un gel « total » peut passer sous le radar.** Comme sur cp2, un guest qui fige sans rien
  écrire dans kmsg ne produit aucune trace : NPD aide surtout sur les pannes **OOM / I/O / FS /
  task-hung**, qui, elles, laissent une ligne noyau.
- **Écrire dans `/dev/kmsg` demande root sur le node** — trivial ici (`vagrant ssh` + `sudo`),
  mais l'écriture doit se faire **sur le node dont on regarde la condition** : une ligne
  injectée sur `k8s-w1` ne remontera jamais sur `k8s-cp1`.

## 📚 Références

- [node-problem-detector (upstream)](https://github.com/kubernetes/node-problem-detector)
- [Chart deliveryhero/node-problem-detector](https://github.com/deliveryhero/helm-charts/tree/master/stable/node-problem-detector)
- Addon lié : `../observability/` (scrape des métriques NPD, alerting sur les NodeConditions)
