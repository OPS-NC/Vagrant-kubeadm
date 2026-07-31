# Makefile — raccourcis du lab. RIEN ici ne touche à un cluster en route.
#
#   make docs        régénère la documentation HTML bilingue (docs/index.html)
#   make validate    valide Vagrantfile + scripts + YAML + modèles kubeadm + liens
#                    de la doc, SANS cluster
#
# `docs` a besoin de `uv` (https://docs.astral.sh/uv/) : les dépendances Python sont
# déclarées en PEP 723 dans docs/build.py et installées à la volée.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

DOCS_OUT := docs/index.html

# PyYAML n'est garanti présent nulle part (ni en local, ni sur un runner) : on passe
# par uv, déjà exigé par `make docs`. `--no-project` : ne pas chercher un pyproject.toml
# qui n'existe pas.
YAML_PY := uv run --quiet --with pyyaml --no-project python
# Drapeaux ajoutés à `vagrant validate` (cf. validate-vagrant).
VAGRANT_VALIDATE_FLAGS ?=

.PHONY: help docs docs-open validate validate-shell validate-yaml validate-vagrant \
        validate-kubeadm validate-defaults validate-docs clean

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}'

docs: ## Régénère docs/index.html depuis tous les README (EN + miroirs FR)
	@uv run docs/build.py

docs-open: docs ## Régénère puis ouvre la doc dans le navigateur
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

validate: validate-shell validate-yaml validate-vagrant validate-kubeadm validate-defaults validate-docs ## Tout valider (sans cluster)
	@echo "✅ Validation complète OK"

# lab.env est la SOURCE UNIQUE, mais ses valeurs sont dupliquées comme FILET DE SÉCURITÉ
# dans le Vagrantfile et dans kubeadm/cluster-up.sh (pour que le lab démarre sans lab.env).
# C'est la fragilité assumée du dépôt : deux défauts qui divergent donnent un lab
# incohérent — des paquets 1.36 avec une config générée pour 1.35, ou pire, un Vagrantfile
# qui crée 3 VM quand cluster-up.sh n'en joint qu'une. Ce test rend la divergence
# impossible à committer sans s'en apercevoir.
#
# ⚠️ Les deux extractions ci-dessous ont été un NID À FAUX NÉGATIFS. Version initiale :
#      sed -n "s/.*ENV\[\"$$k\"\][^|]*|| \([^)]*\)).*/\1/p"   <- exigeait une ')'
#    Or le Vagrantfile écrit les valeurs sous DEUX formes :
#      K8S_VERSION    = ENV["K8S_VERSION"] || "1.36.3"     (sans parenthèse)
#      CONTROL_PLANES = (ENV["CONTROL_PLANES"] || 1).to_i  (avec)
#    K8S_VERSION et NETWORK ressortaient donc VIDES, le garde `[ -n "$$vf" ]` sautait la
#    comparaison, et la cible affichait « alignés » sur un dépôt divergent. Même piège
#    côté cluster-up.sh : l'ancre `^` ratait les affectations en milieu de ligne
#    (`CP_IP_START=… ; CP_IP_STEP=…`), donc les deux *_STEP n'étaient pas vérifiés.
#    On accepte maintenant les deux formes, et une clé absente de lab.env.example est
#    une ERREUR au lieu d'un silence — un garde muet est pire que pas de garde.
#
# `VIP` est volontairement EXCLU : c'est le seul défaut DÉRIVÉ et non littéral
# (`"#{NETWORK}.5"` côté Ruby, `"${NETWORK}.5"` côté shell). La comparaison textuelle
# le signalerait faussement à chaque exécution, et un garde qui crie au loup finit
# ignoré — donc inutile. Sa cohérence est garantie autrement : les deux fichiers le
# dérivent de `NETWORK`, qui est lui bien vérifié ici.
validate-defaults: ## Vérifie que les défauts sont identiques dans lab.env.example, le Vagrantfile et cluster-up.sh
	@fail=0; \
	for k in K8S_VERSION K8S_APT_MINOR CONTAINERD_SOURCE SYSTEM_UPGRADE BOX NODE_PREFIX \
	         CLUSTER_NAME CONTROL_PLANES WORKERS CP_MEM CP_CPU WK_MEM WK_CPU \
	         NETWORK CP_IP_START CP_IP_STEP WK_IP_START WK_IP_STEP \
	         POD_CIDR SERVICE_CIDR CNI KUBE_PROXY_REPLACEMENT UNTAINT_CP VRRP_ROUTER_ID; do \
	  ref="$$(sed -n "s/^$$k=//p" lab.env.example | head -n1)"; \
	  [ -n "$$ref" ] || { echo "❌ $$k : absent de lab.env.example"; fail=1; continue; }; \
	  vf="$$(sed -n "s/.*ENV\[\"$$k\"\][^|]*|| *\([^);]*\).*/\1/p" Vagrantfile | head -n1 | tr -d '\" ')"; \
	  cu="$$(sed -n "s/.*$$k=\"\$${$$k:-\([^}]*\)}\".*/\1/p" kubeadm/cluster-up.sh | head -n1 | tr -d '\" ')"; \
	  if [ -n "$$vf" ] && [ "$$vf" != "$$ref" ]; then \
	    echo "❌ $$k : lab.env.example=$$ref mais Vagrantfile=$$vf"; fail=1; fi; \
	  if [ -n "$$cu" ] && [ "$$cu" != "$$ref" ]; then \
	    echo "❌ $$k : lab.env.example=$$ref mais cluster-up.sh=$$cu"; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ] && echo "✅ défauts : 24 clés alignées (lab.env.example / Vagrantfile / cluster-up.sh)"

validate-docs: ## Construit la doc dans un fichier jetable et exige des liens valides
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	uv run docs/build.py --strict --out "$$out/index.html" >/dev/null && echo "✅ docs : liens et ancres OK"

validate-shell: ## Vérifie la syntaxe de tous les scripts shell
	@fail=0; \
	while IFS= read -r f; do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; \
	done < <(git ls-files '*.sh'); \
	[ $$fail -eq 0 ] && echo "✅ shell : $$(git ls-files '*.sh' | wc -l) scripts OK"

validate-yaml: ## Vérifie que tous les YAML du dépôt parsent
	@git ls-files -z '*.yaml' '*.yml' | xargs -0 $(YAML_PY) -c 'import sys, yaml; [list(yaml.safe_load_all(open(f, encoding="utf-8"))) for f in sys.argv[1:]]' \
	  && echo "✅ yaml : $$(git ls-files '*.yaml' '*.yml' | wc -l) fichiers OK"

# --ignore-provider : indispensable en CI, où VirtualBox n'est pas installé (le job
# échouerait sur le provider avant même de regarder le Vagrantfile). En local, sans le
# drapeau, la validation couvre EN PLUS la config provider — donc on ne l'impose pas ici.
validate-vagrant: ## Valide le Vagrantfile (VAGRANT_VALIDATE_FLAGS=--ignore-provider en CI)
	@vagrant validate $(VAGRANT_VALIDATE_FLAGS) && echo "✅ Vagrantfile OK"

# Rend les trois modèles kubeadm avec des valeurs factices, dans un dossier jetable,
# puis les valide. Deux niveaux, parce que `kubeadm` n'est pas forcément installé sur
# le poste (c'est un binaire Linux) :
#   1. le YAML doit parser                       — toujours vérifié ;
#   2. `kubeadm config validate` doit passer     — seulement si kubeadm est là.
# C'est ce second niveau qui attrape les vraies erreurs de schéma v1beta4, comme un
# `extraArgs` resté sous forme de dictionnaire (forme v1beta3).
validate-kubeadm: ## Rend les modèles kubeadm et valide leur schéma
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	printf '    - 192.168.56.5\n    - 127.0.0.1\n' >"$$out/certsans.txt"; \
	for tpl in kubeadm/templates/*.yaml.tpl; do \
	  dest="$$out/$$(basename "$$tpl" .tpl)"; \
	  sed -e 's|@NODE_NAME@|k8s-cp1|g' -e 's|@NODE_IP@|192.168.56.10|g' \
	      -e 's|@VIP@|192.168.56.5|g' -e 's|@K8S_VERSION@|1.36.3|g' \
	      -e 's|@CLUSTER_NAME@|kubeadm-lab|g' -e 's|@POD_CIDR@|10.244.0.0/16|g' \
	      -e 's|@SERVICE_CIDR@|10.96.0.0/12|g' \
	      -e 's|@TOKEN@|abcdef.0123456789abcdef|g' \
	      -e "s|@CA_HASH@|$$(printf '0%.0s' {1..64})|g" \
	      -e "s|@CERT_KEY@|$$(printf '0%.0s' {1..64})|g" \
	      -e "/@CERT_SANS@/r $$out/certsans.txt" -e '/@CERT_SANS@/d' \
	      "$$tpl" >"$$dest"; \
	done; \
	$(YAML_PY) -c 'import sys, yaml; [list(yaml.safe_load_all(open(f, encoding="utf-8"))) for f in sys.argv[1:]]' "$$out"/*.yaml; \
	if command -v kubeadm >/dev/null 2>&1; then \
	  for f in "$$out"/*.yaml; do kubeadm config validate --config "$$f" >/dev/null || exit 1; done; \
	  echo "✅ kubeadm : 3 modèles rendus, YAML + schéma v1beta4 OK"; \
	else \
	  echo "✅ kubeadm : 3 modèles rendus, YAML OK  (schéma non vérifié : kubeadm absent du PATH)"; \
	fi

clean: ## Supprime la doc générée
	@rm -f $(DOCS_OUT) && echo "docs/index.html supprimé"
