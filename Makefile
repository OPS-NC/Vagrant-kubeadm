# Makefile — lab shortcuts. NOTHING here touches a running cluster.
#
#   make docs        regenerates the bilingual HTML documentation (docs/index.html)
#   make validate    validates Vagrantfile + scripts + YAML + kubeadm templates + doc
#                    links, WITHOUT a cluster
#
# `docs` needs `uv` (https://docs.astral.sh/uv/): the Python dependencies are declared in
# PEP 723 form inside docs/build.py and installed on the fly.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

DOCS_OUT := docs/index.html

# PyYAML is guaranteed nowhere (neither locally nor on a runner): we go through uv,
# already required by `make docs`. `--no-project`: do not look for a pyproject.toml that
# does not exist.
YAML_PY := uv run --quiet --with pyyaml --no-project python
# Flags added to `vagrant validate` (see validate-vagrant).
VAGRANT_VALIDATE_FLAGS ?=

.PHONY: help docs docs-open validate validate-shell validate-yaml validate-vagrant \
        validate-kubeadm validate-defaults validate-submodule validate-docs k8s-update clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}'

docs: ## Regenerate docs/index.html from every README (EN + FR mirrors)
	@uv run docs/build.py

docs-open: docs ## Regenerate then open the documentation in the browser
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

validate: validate-shell validate-yaml validate-vagrant validate-kubeadm validate-defaults validate-submodule validate-docs ## Validate everything (without a cluster)
	@echo "✅ Full validation OK"

# lab.env is the SINGLE SOURCE, but its values are duplicated as a SAFETY NET in the
# Vagrantfile and in kubeadm/cluster-up.sh (so the lab starts without a lab.env).
# That is the repo's acknowledged fragility: two defaults that diverge give an incoherent
# lab — 1.36 packages with a configuration generated for 1.35, or worse, a Vagrantfile that
# creates 3 VMs when cluster-up.sh only joins one. This test makes the divergence
# impossible to commit without noticing.
#
# ⚠️ The two extractions below have been a NEST OF FALSE NEGATIVES. The initial version:
#      sed -n "s/.*ENV\[\"$$k\"\][^|]*|| \([^)]*\)).*/\1/p"   <- required a ')'
#    But the Vagrantfile writes the values in TWO forms:
#      K8S_VERSION    = ENV["K8S_VERSION"] || "1.36.3"     (no parenthesis)
#      CONTROL_PLANES = (ENV["CONTROL_PLANES"] || 1).to_i  (with one)
#    So K8S_VERSION and NETWORK came out EMPTY, the `[ -n "$$vf" ]` guard skipped the
#    comparison, and the target printed "aligned" on a diverging repo. Same trap on the
#    cluster-up.sh side: the `^` anchor missed mid-line assignments
#    (`CP_IP_START=… ; CP_IP_STEP=…`), so neither *_STEP was checked.
#    We now accept both forms, and a key missing from lab.env.example is an ERROR instead
#    of a silence — a mute guard is worse than no guard.
#
# `VIP` is deliberately EXCLUDED: it is the only DERIVED, non-literal default
# (`"#{NETWORK}.5"` on the Ruby side, `"${NETWORK}.5"` on the shell side). A textual
# comparison would flag it falsely on every run, and a guard that cries wolf ends up
# ignored — hence useless. Its coherence is guaranteed otherwise: both files derive it
# from `NETWORK`, which IS checked here.
validate-defaults: ## Check the defaults are identical in lab.env.example, the Vagrantfile and cluster-up.sh
	@fail=0; \
	for k in K8S_VERSION K8S_APT_MINOR CONTAINERD_SOURCE SYSTEM_UPGRADE BOX NODE_PREFIX \
	         CLUSTER_NAME CONTROL_PLANES WORKERS CP_MEM CP_CPU WK_MEM WK_CPU \
	         NETWORK CP_IP_START CP_IP_STEP WK_IP_START WK_IP_STEP \
	         POD_CIDR SERVICE_CIDR CNI KUBE_PROXY_REPLACEMENT UNTAINT_CP VRRP_ROUTER_ID; do \
	  ref="$$(sed -n "s/^$$k=//p" lab.env.example | head -n1)"; \
	  [ -n "$$ref" ] || { echo "❌ $$k: missing from lab.env.example"; fail=1; continue; }; \
	  vf="$$(sed -n "s/.*ENV\[\"$$k\"\][^|]*|| *\([^);]*\).*/\1/p" Vagrantfile | head -n1 | tr -d '\" ')"; \
	  cu="$$(sed -n "s/.*$$k=\"\$${$$k:-\([^}]*\)}\".*/\1/p" kubeadm/cluster-up.sh | head -n1 | tr -d '\" ')"; \
	  if [ -n "$$vf" ] && [ "$$vf" != "$$ref" ]; then \
	    echo "❌ $$k: lab.env.example=$$ref but Vagrantfile=$$vf"; fail=1; fi; \
	  if [ -n "$$cu" ] && [ "$$cu" != "$$ref" ]; then \
	    echo "❌ $$k: lab.env.example=$$ref but cluster-up.sh=$$cu"; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ] && echo "✅ defaults: 24 keys aligned (lab.env.example / Vagrantfile / cluster-up.sh)"

# `_k8s/` is a submodule (k8s-playground). Two ways to break a fresh clone without
# noticing from YOUR own copy, where everything works:
#   1. pinning a never-pushed commit — `git clone --recurse-submodules` then fails for
#      everyone but you;
#   2. declaring a `git@github.com:` URL — the clone fails for anyone without a GitHub SSH
#      key, on a repo that is public and invites cloning.
# Both are invisible locally: this test makes them visible.
validate-submodule: ## Check the _k8s submodule is declared, public and fetchable
	@url="$$(git config -f .gitmodules submodule._k8s.url)"; \
	case "$$url" in \
	  https://*) ;; \
	  *) echo "❌ submodule _k8s: URL '$$url' — expected https:// (a public clone cannot use SSH)"; exit 1 ;; \
	esac; \
	sha="$$(git ls-files -s _k8s | awk '{print $$2}')"; \
	[ -n "$$sha" ] || { echo "❌ _k8s is not registered as a submodule"; exit 1; }; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	git -C "$$tmp" init -q .; \
	if git -C "$$tmp" fetch -q --depth 1 "$$url" "$$sha" 2>/dev/null; then \
	  echo "✅ submodule: _k8s -> $$url @ $$(echo "$$sha" | cut -c1-7) (publicly fetchable)"; \
	else \
	  echo "❌ submodule: commit $$(echo "$$sha" | cut -c1-7) not found on $$url"; \
	  echo "   -> it has most likely never been pushed. A clone --recurse-submodules would fail."; \
	  exit 1; \
	fi

validate-docs: ## Build the docs into a throwaway file and require valid links
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	uv run docs/build.py --strict --out "$$out/index.html" >/dev/null && echo "✅ docs: links and anchors OK"

validate-shell: ## Check the syntax of every shell script
	@fail=0; \
	while IFS= read -r f; do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; \
	done < <(git ls-files '*.sh'); \
	[ $$fail -eq 0 ] && echo "✅ shell: $$(git ls-files '*.sh' | wc -l) scripts OK"

validate-yaml: ## Check that every YAML in the repo parses
	@git ls-files -z '*.yaml' '*.yml' | xargs -0 $(YAML_PY) -c 'import sys, yaml; [list(yaml.safe_load_all(open(f, encoding="utf-8"))) for f in sys.argv[1:]]' \
	  && echo "✅ yaml: $$(git ls-files '*.yaml' '*.yml' | wc -l) files OK"

# --ignore-provider: indispensable in CI, where VirtualBox is not installed (the job would
# fail on the provider before even looking at the Vagrantfile). Locally, without the flag,
# the validation ALSO covers the provider config — so we do not force it here.
validate-vagrant: ## Validate the Vagrantfile (VAGRANT_VALIDATE_FLAGS=--ignore-provider in CI)
	@vagrant validate $(VAGRANT_VALIDATE_FLAGS) && echo "✅ Vagrantfile OK"

# Renders the three kubeadm templates with dummy values, into a throwaway directory, then
# validates them. Two levels, because `kubeadm` is not necessarily installed on the
# workstation (it is a Linux binary):
#   1. the YAML must parse                       — always checked;
#   2. `kubeadm config validate` must pass       — only when kubeadm is there.
# It is that second level which catches the real v1beta4 schema mistakes, such as an
# `extraArgs` left in dictionary form (the v1beta3 shape).
validate-kubeadm: ## Render the kubeadm templates and validate their schema
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
	  echo "✅ kubeadm: 3 templates rendered, YAML + v1beta4 schema OK"; \
	else \
	  echo "✅ kubeadm: 3 templates rendered, YAML OK  (schema not checked: kubeadm absent from PATH)"; \
	fi

# A submodule ALWAYS records a precise commit in the parent repo — that is how git
# guarantees a clone gives exactly the same tree. "Follow main" is therefore declared in
# .gitmodules (`branch = main`) and materialised by `--remote`, which fetches the tip of
# that branch and updates the recorded pointer.
k8s-update: ## Align the _k8s submodule on the tip of main (then commit the pointer)
	@git submodule update --remote --init _k8s
	@if git diff --quiet -- _k8s; then \
	  echo "✅ _k8s already on the tip of main ($$(git -C _k8s rev-parse --short HEAD))"; \
	else \
	  echo "⬆️  _k8s -> $$(git -C _k8s rev-parse --short HEAD)"; \
	  git -C _k8s log --oneline -5; \
	  echo; echo "   Pointer updated in the working tree. To freeze it:"; \
	  echo "     git add _k8s && git commit -m '[Claude] chore: bump _k8s'"; \
	fi

clean: ## Remove the generated documentation
	@rm -f $(DOCS_OUT) && echo "docs/index.html removed"
