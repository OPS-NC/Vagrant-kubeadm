<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ⚖️ `kyverno/` — policy engine Kubernetes + UI Policy Reporter

> **Kyverno = un webhook d'admission + des contrôleurs de fond.** Trois verbes : `validate`
> (accepter / refuser / auditer), `mutate` (réécrire la ressource entrante), `generate` (créer
> une ressource dérivée). Les verdicts atterrissent dans des `PolicyReport`, agrégés par
> **Policy Reporter** dans une UI web sous `kyverno.kubeadm.lab.example.io`.

> 🌐 **`kubeadm.lab.example.io` est le domaine NEUTRE du dépôt (public)** : `kyverno-up.sh` le
> remplace par `LAB_DOMAIN` (`lab.env`) au moment du `kubectl apply`. Cf.
> [`../LISEZ-MOI.md`](../LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

## 🎯 À quoi ça sert

Montrer, sur un cluster qui tourne déjà, ce qu'un policy engine attrape — **sans rien casser** :

- les 4 policies de validation sont livrées en **`Audit`** (elles signalent, ne bloquent pas) ;
- tous les webhooks d'évaluation sont **fail-open** (cf. 🔧) : même Kyverno KO, le cluster
  continue d'accepter les créations de pods ;
- une policy `mutate` et une policy `generate` complètent la démonstration des trois verbes.

On lit d'abord les violations de l'existant dans l'UI, puis on montre un passage en `Enforce`
sur une seule policy, le temps de la démo.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Plateforme en place (`../platform-up.sh`) | l'UI est exposée via `main-gateway` + cert wildcard | `kubectl -n envoy-gateway-system get certificate` |
| DNS `kyverno.kubeadm.lab.example.io → 192.168.56.200` (**DNS-only**) | hostname de l'`HTTPRoute` | `curl --resolve` sinon (cf. ✅) |
| Rien côté nodes | Kyverno tourne **sans privilège**, conforme PodSecurity `restricted` | `kubectl -n kyverno get pods` |

## ⚡ Installation

```bash
./_k8s/kyverno/kyverno-up.sh
```

Versions épinglées dans le script : chart `kyverno/kyverno` **`3.8.2`** (app **v1.18.2**) et
`policy-reporter/policy-reporter` **`3.8.1`** (`KYVERNO_VERSION` / `POLICY_REPORTER_VERSION`
surchargeables). Idempotent (`helm upgrade --install` + `kubectl apply`).

## 🔧 Ce que fait le script

1. installe **Kyverno** dans le namespace `kyverno` avec `values.yaml`, puis attend
   l'`admission-controller` ;
2. applique **`policies/`** (4 `validate` en Audit + 1 `mutate` + 1 `generate`) et les liste ;
3. installe **Policy Reporter** (+ UI + plugins **kyverno** et **trivy**) avec
   `policy-reporter-values.yaml` ;
4. applique **`httproute.yaml`** → `https://kyverno.kubeadm.lab.example.io`.

### Le choix décisif de ce lab : l'évaluation est fail-open

`values.yaml` pose `features.forceFailurePolicyIgnore.enabled: true`. Les webhooks qui
**évaluent tes ressources** passent donc en `failurePolicy: Ignore` — on le voit dans leurs
noms : `validate.kyverno.svc-ignore`, `mutate.kyverno.svc-ignore`.

| Situation | Conséquence |
|---|---|
| Kyverno **injoignable** (pod down, timeout) | la requête **passe quand même** — pas de deadlock « Kyverno KO ⇒ plus aucun pod ne démarre » |
| Kyverno **joignable**, policy en `Audit` | la requête passe, un `fail` est écrit dans le `PolicyReport` |
| Kyverno **joignable**, policy en `Enforce` | la requête est **refusée** (le fail-open ne désarme pas le blocage) |

> ℹ️ Les webhooks **internes** de Kyverno (validation des `ClusterPolicy`, des
> `PolicyException`, du cleanup) restent en `failurePolicy: Fail` : seule l'évaluation de tes
> ressources est fail-open. À vérifier soi-même :
> ```bash
> kubectl get validatingwebhookconfigurations \
>   -o 'custom-columns=NAME:.metadata.name,POLICY:.webhooks[*].failurePolicy' | grep kyverno
> ```
> Les guillemets autour de `custom-columns=…` sont nécessaires : sinon le shell interprète `[*]`.

### Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | 1 replica par contrôleur (4 contrôleurs), resources par défaut du chart, **`forceFailurePolicyIgnore` activé** |
| `policy-reporter-values.yaml` | Policy Reporter + **UI** + plugin **kyverno** + plugin **trivy** + métriques |
| `httproute.yaml` | `HTTPRoute` HTTPS `kyverno.kubeadm.lab.example.io` → `policy-reporter-ui:8080` |
| `kyverno-up.sh` | installe tout dans l'ordre, idempotent |
| `policies/01-require-labels.yaml` | **validate/Audit** — exige `app.kubernetes.io/name` |
| `policies/02-disallow-latest-tag.yaml` | **validate/Audit** — tag explicite obligatoire, `:latest` interdit |
| `policies/03-require-requests-limits.yaml` | **validate/Audit** — `requests` + `limits` (cpu **et** memory) |
| `policies/04-disallow-privileged.yaml` | **validate/Audit** — interdit les conteneurs privilégiés |
| `policies/10-mutate-add-labels.yaml` | **mutate** — ajoute `lab.kubeadm/managed-by: kyverno` |
| `policies/20-generate-default-netpol.yaml` | **generate** — NetworkPolicy default-deny (opt-in par label) |

## ✅ Vérifier

```bash
kubectl -n kyverno get pods                    # 4 contrôleurs + policy-reporter (+ui, +2 plugins)
kubectl get clusterpolicy                      # 6 policies, READY=True
kubectl get policyreport -A                    # rapports par namespace (PASS/FAIL/WARN)
kubectl get clusterpolicyreport                # rapports niveau cluster

# test end-to-end (cert wildcard trusté, servi par Envoy) :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve kyverno.kubeadm.lab.example.io:443:192.168.56.200 \
  https://kyverno.kubeadm.lab.example.io/            # attendu : 200 verify=0
```

Compter les `fail` par policy (utile pour préparer une démo) :

```bash
kubectl get policyreport -A -o json | jq -r \
  '.items[].results[] | select(.result=="fail") | .policy' | sort | uniq -c | sort -rn
```

## 🌐 Accès

| Quoi | Où | Authentification |
|---|---|---|
| UI Policy Reporter | `https://kyverno.kubeadm.lab.example.io` | **aucune** — cf. ⚠️ Pièges |
| API Policy Reporter | `kubectl -n kyverno port-forward svc/policy-reporter 8080:8080` | aucune |

## 🧪 Scénarios

### 1. Lire les violations (validate en Audit)

Le **background scan** évalue l'existant dès l'installation. Dans l'UI : violations par
namespace, par policy, par sévérité. Rien n'a été bloqué — c'est de l'audit. Commence par
`require-requests-limits` et `require-labels` : ce sont les plus bruyantes, et c'est
**instructif** (cf. ⚠️ Pièges, « le dépôt viole ses propres policies »).

### 2. Passer une policy en Enforce (blocage réel)

```bash
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
kubectl run bad --image=nginx:latest            # REFUSÉ par le webhook Kyverno
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
```

> ⚠️ **`spec.validationFailureAction` est déprécié** sur ce Kyverno (v1.18.2) :
> `kubectl explain clusterpolicy.spec.validationFailureAction` répond « Deprecated, use
> validationFailureAction under the validate rule instead ». Le champ fonctionne encore (les 4
> policies du dépôt l'utilisent au niveau `spec`), mais la forme moderne est
> `spec.rules[].validate.failureAction`. Rien à corriger pour la démo ; à savoir avant de
> monter Kyverno de version majeure.

### 3. Voir la mutation en action

```bash
kubectl run demo --image=nginx:1.27
kubectl get pod demo --show-labels              # lab.kubeadm/managed-by=kyverno ajouté
kubectl delete pod demo
```

### 4. Voir la génération en action (opt-in par label)

```bash
kubectl create ns demo-netpol
kubectl label ns demo-netpol kyverno-demo=true
kubectl -n demo-netpol get netpol               # default-deny générée par Kyverno
kubectl delete ns demo-netpol
```

### 5. Créer une exception ciblée (PolicyException)

`longhorn-system` DOIT tourner en privilégié → il apparaît en `fail` sur
`disallow-privileged-containers`. En vrai, on l'exempte proprement. Les `PolicyException` sont
**désactivées par défaut** dans le chart ; pour la démo, réinstalle avec
`--set features.policyExceptions.enabled=true --set features.policyExceptions.namespace=kyverno`,
puis crée une `PolicyException` ciblant `longhorn-system`. Sinon, montre simplement le `fail`
dans l'UI comme illustration du besoin.

## 🚑 Dépannage

- **Rien dans l'UI** → l'agrégation prend ~30 s. `kubectl get policyreport -A` doit déjà lister
  des lignes ; sinon vérifie que `policy-reporter-ui` et `policy-reporter-kyverno-plugin` sont
  `Running` (`kubectl -n kyverno get pods`).
- **404 / route non rattachée** → `kubectl -n kyverno describe httproute policy-reporter-ui`
  (`sectionName: https` sur `main-gateway`, hostname couvert par le wildcard).
- **`clusterpolicy` en `READY=False`** → `kubectl describe clusterpolicy <nom>` : souvent une
  erreur de `pattern` ou une CRD manquante côté générateur.

## ⚠️ Pièges

- **« Les composants système ne sont jamais soumis aux policies » est FAUX.** Le chart exclut
  bien `kube-system`, `kube-public`, `kube-node-lease` et `kyverno` via `config.resourceFilters`
  — mais ce filtre porte sur l'**admission**. Le **scan de fond** évalue quand même ces
  ressources et produit des rapports : sur ce lab, des dizaines de `fail` en `kube-system`
  (cilium, kube-proxy…) et dans `kyverno` lui-même. Vérifie-le :
  `kubectl -n kube-system get policyreport`. Conclusion pratique : aucun risque de **bloquer**
  un composant système, mais les rapports, eux, les incluent. *(Le commentaire de `values.yaml`
  est trop catégorique sur ce point.)*
- **Le dépôt viole ses propres policies — c'est assumé, mais ça fait du bruit :**
  - `03-require-requests-limits` exige `limits.cpu`, qu'**aucun** manifeste du dépôt ne pose
    (choix délibéré : on borne la mémoire, on ne *throttle* pas le CPU). Résultat : c'est de
    très loin la policy la plus en échec, et elle noie les autres dans l'UI.
  - `01-require-labels` exige `app.kubernetes.io/name` alors que tous les manifestes maison
    utilisent `app:` → `fail` systématique sur les démos du lab.
  - `02-disallow-latest-tag` ne contrôle que `spec.containers` : un `:latest` dans un
    **`initContainers`** passe inaperçu. Bon exercice d'extension de policy.
- **UI sans authentification.** Policy Reporter est publié en HTTPS sans auth : quiconque
  atteint le VIP `.200` (tout peer Tailscale autorisé) lit l'inventaire des faiblesses du
  cluster. Pour la protéger : `SecurityPolicy` Envoy Gateway (Basic Auth / OIDC) sur la route.
- **Un Pod légitime refusé après un passage en `Enforce`** → repasse la policy en `Audit`
  (scénario 2) ou crée une `PolicyException`. Ne laisse jamais une policy `Enforce` mal calibrée
  sur un cluster partagé.
- **1 replica pour l'admission-controller** = SPOF assumé (lab). Le fail-open évite le blocage,
  mais pendant un redémarrage les policies ne s'appliquent simplement plus. Pour de la
  robustesse : `admissionController.replicas: 3` dans `values.yaml` (coûte de la RAM).

## 🧹 Désinstallation

```bash
kubectl delete -f _k8s/kyverno/httproute.yaml
kubectl delete -f _k8s/kyverno/policies/
helm -n kyverno uninstall policy-reporter
helm -n kyverno uninstall kyverno            # retire aussi les CRD → supprime les PolicyReport
kubectl delete ns kyverno
```

> ⚠️ Si [`../trivy-operator/`](../trivy-operator/LISEZ-MOI.md) est installé, il **perd son UI** :
> c'est Policy Reporter (namespace `kyverno`) qui l'héberge.

## 📚 Références

- [Kyverno — documentation](https://kyverno.io/docs/)
- [Kyverno — bibliothèque de policies](https://kyverno.io/policies/)
- [Kyverno — PolicyException](https://kyverno.io/docs/exceptions/)
- [Policy Reporter](https://kyverno.github.io/policy-reporter/)
- [`../trivy-operator/LISEZ-MOI.md`](../trivy-operator/LISEZ-MOI.md) — le volet **détectif**, même UI
