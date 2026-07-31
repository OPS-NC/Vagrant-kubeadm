# 🤖 CLAUDE.md

**Kubernetes built with `kubeadm` on Debian 13 VMs**, on VirtualBox, driven by Vagrant. Unlike
the [Talos sibling](https://github.com/OPS-NC/Vagrant-Talos) of this lab, the nodes are ordinary
Linux boxes: **SSH, `apt`, `systemd`, `journalctl` all work**, and every step is a `kubeadm`
command you could type by hand. User docs: [`README.md`](README.md) · application layer:
[`_k8s/README.md`](_k8s/README.md) · symptoms: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) ·
version bumps: [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).

## 🚫 There is NO cluster, and you must not try to build one

**No agent working in this repository runs `vagrant`, `kubectl`, `helm` or `talosctl`.** There
is no running lab attached to your session, `kubeconfig` does not exist, and `vagrant up` would
spend fifteen minutes failing. Every claim you make must be backed by **reading the code**, not
by running it. The one thing you may and should run is `make validate` — see below.

If a change can only be proven by a live cluster, say so explicitly and hand the verification
back to the human, with the exact commands to run.

## 🚀 Order of work

```
lab.env  ──────────────► Vagrantfile ──► kubeadm/provision.sh        (in each VM, at `vagrant up`)
   │  (single source)         │
   │                          └─ 7 steps: /etc/hosts · kernel prereqs · base packages ·
   │                             containerd · kubelet/kubeadm/kubectl (+ hold) · image pull ·
   │                             keepalived (control planes only)
   │
   ├──────────────────► kubeadm/cluster-up.sh                        (on the HOST)
   │                          ├─ renders kubeadm/templates/*.tpl into _out/
   │                          ├─ vagrant ssh cp1 → kubeadm/node-init.sh   (kubeadm init)
   │                          ├─ vagrant ssh others → kubeadm/node-join.sh (kubeadm join)
   │                          └─ writes ./kubeconfig and _out/cluster.env
   │
   └──────────────────► _k8s/platform-up.sh                          (on the HOST)
                              ├─ [1/4] CNI  → _k8s/cilium/cilium-up.sh (or calico/flannel/none)
                              ├─ [2/4] Envoy Gateway + main-gateway
                              ├─ [3/4] metrics-server
                              └─ [4/4] wildcard TLS → _k8s/self-signed/ or cert-manager
                                    then opt-in addons, one _k8s/<addon>/<addon>-up.sh each
```

Undo without destroying the VMs: `kubeadm/cluster-reset.sh` → `kubeadm/node-reset.sh` in every
VM (workers first, so they deregister while the API still answers).

### What lives where

| Path | Role |
|---|---|
| `lab.env.example` → `lab.env` | **the single source** of topology, versions, addressing, CNI, TLS. `lab.env` is gitignored. |
| `Vagrantfile` | creates/prepares the VMs. Bootstraps **no** cluster. Holds topology guard rails (odd CP count, reserved IPs, duplicate IPs). |
| `kubeadm/provision.sh` | in-VM system preparation, idempotent, replayable with `vagrant provision`. |
| `kubeadm/cluster-up.sh` | host-side orchestrator. **Does nothing inside the VMs itself**: it renders configs and calls the two node scripts over `vagrant ssh`. Idempotent — and this is also how you grow the lab. |
| `kubeadm/node-init.sh` / `node-join.sh` | the actual `kubeadm init` / `kubeadm join`, in-VM. Both refuse to act on an already-initialised/joined node. |
| `kubeadm/cluster-reset.sh` / `node-reset.sh` | undo the cluster, keep the VMs. |
| `kubeadm/templates/*.yaml.tpl` | `InitConfiguration` / `JoinConfiguration` (v1beta4), `@MARKER@` substitution. |
| `_k8s/` | the application layer. `platform-up.sh` is the base; every other directory is opt-in and carries its own `README.md` + `*-up.sh`. |
| `docs/build.py` | generates the single-page bilingual `docs/index.html`. |
| `Makefile` | `make validate`, `make docs`. Nothing here ever touches a running cluster. |
| `.github/workflows/` | CI calls the **same** `make` targets. Never duplicate a check's definition in a workflow. |
| `bootstrap.sh`, `README-installkubeadm.md` | **legacy scratch notes** from before the repo took shape (K3s-era registry mirror, hand-typed install). Referenced by nothing. Do not wire them into anything; do not "fix" them either without being asked. |

### The files that carry state between layers

| File | Written by | Read by |
|---|---|---|
| `_out/kubeadm-init.yaml`, `_out/join-<node>.yaml`, `_out/certsans.txt` | `cluster-up.sh` (host) | `node-init.sh` / `node-join.sh`, in the VM through `/vagrant/_out/` |
| `_out/join.env` (**token + certificate key**) | `node-init.sh` (VM) | `cluster-up.sh` (host) |
| `_out/admin.conf` → `./kubeconfig` | `node-init.sh` | everything on the host |
| `_out/cluster.env` | `cluster-up.sh` | every `_k8s/*-up.sh` — these are **detected facts** |
| `/etc/kubeadm-lab/node.env` | `provision.sh` | `cluster-up.sh` (reads `HOSTONLY_IF` back out) |

The synced folder `/vagrant` is **a mechanism, not a convenience**: it is what removes every
`scp` and every secret passed on a command line. Keep it that way.

## 🔑 The golden rule: `lab.env` is the single source, and its defaults are DUPLICATED

Precedence, everywhere: **real environment variable > `lab.env` > in-file fallback default.**
That is why `WORKERS=5 vagrant up` works, and why `lab.env` never has to be `export`-ed.

The fallback defaults exist so a freshly cloned repo works **without** a `lab.env`. They are
deliberately copied into several files:

| Default | Also lives in |
|---|---|
| `K8S_VERSION`, `K8S_APT_MINOR` | `Vagrantfile`, `kubeadm/provision.sh`, `kubeadm/cluster-up.sh` (no `K8S_APT_MINOR` there — it needs none) |
| `CONTROL_PLANES`, `WORKERS`, `NODE_PREFIX` | `Vagrantfile`, `kubeadm/cluster-up.sh`, `kubeadm/cluster-reset.sh` |
| `NETWORK`, `VIP`, `CP_IP_*`, `WK_IP_*` | `Vagrantfile`, `kubeadm/cluster-up.sh`, `kubeadm/provision.sh` |
| `POD_CIDR`, `SERVICE_CIDR`, `CNI`, `KUBE_PROXY_REPLACEMENT` | `kubeadm/cluster-up.sh`, `_k8s/platform-up.sh`, `_k8s/cilium/cilium-up.sh` |
| `LB_POOL_START` / `LB_POOL_END`, `CILIUM_VERSION` | `_k8s/platform-up.sh`, `_k8s/cilium/cilium-up.sh` |
| `LAB_DOMAIN`, `SELF_SIGNED`, `LAB_ACME_ISSUER` | `_k8s/platform-up.sh`, `_k8s/self-signed/selfsigned-up.sh` |

> ⚠️ **Two defaults that diverge produce an incoherent lab** — packages from one minor,
> generated configuration for another; a pod CIDR declared to kubeadm that the CNI does not
> announce; a wildcard Secret name the Gateway does not look for. Changing a default means
> changing it **everywhere in the same commit**, `lab.env.example` included.

The `_k8s/*-up.sh` scripts add one more layer, and the order matters: **`_out/cluster.env`
(facts about the running cluster) wins over `lab.env` (a mere intent, possibly edited after the
bootstrap)**. `_k8s/cilium/cilium-up.sh` implements this in `lire_param`. Keep that ordering
when you add a script.

## ✅ Validating a change WITHOUT a cluster (do this every time)

```bash
make validate      # shell syntax + YAML parse + Vagrantfile + kubeadm templates + doc links
make docs          # regenerates docs/index.html (needs uv)
```

| Target | What it proves |
|---|---|
| `validate-shell` | `bash -n` on every git-tracked `*.sh` |
| `validate-yaml` | every git-tracked `*.yaml`/`*.yml` parses (PyYAML pulled in by `uv`) |
| `validate-vagrant` | `vagrant validate`. In CI: `VAGRANT_VALIDATE_FLAGS=--ignore-provider` (runners have no VirtualBox) |
| `validate-kubeadm` | renders the three templates with dummy values into an `mktemp -d`, parses them, **and** runs `kubeadm config validate` if the binary is present. This is the target that catches a v1beta4 schema mistake. |
| `validate-docs` | builds the docs into a throwaway file with `--strict` and **fails on the first unresolved `*.md` link or anchor** |

`make docs` also lists, at the end of the build, every link and cross-file anchor that does not
resolve. Run it after renaming any heading.

## ⚠️ Design pitfalls — do NOT reintroduce these

### Shell

- **`grep` under `set -e` + `pipefail` kills the script.** A `grep` with no match exits 1, and
  in a pipeline under `pipefail` that becomes the script's exit status — silently, long before
  the interesting part. The repo reads key/value files with **`sed -n 's/^KEY=//p'`** and a
  trailing `|| true` (for the case where the file does not exist at all, where `sed` exits 2).
  Look at `lire_lab_env` / `lire_cluster_env` and copy them; never introduce a
  `grep … | head -1` in that role.
- **Backticks inside a double-quoted string are command substitution.** Writing
  `` echo "use `kubeadm init`" `` runs `kubeadm init`. This repo's prose is full of
  backtick-quoted identifiers, so the risk is constant in `echo`/`printf` messages and in
  unquoted heredocs (`<<EOF`). Use `'…'`, a quoted heredoc (`<<'EOF'`), or simply no backticks
  in shell output.
- **`./script.sh; echo "EXIT=$?"` reports `echo`'s status, not the script's.** Check
  `${PIPESTATUS[0]}` or the exit line inside the log.
- **`lab.env` is parsed, not sourced.** Strict `KEY=value`, no spaces around `=`, no `;`. The
  key name is validated against `^[A-Za-z_][A-Za-z0-9_]*$` **before** any `eval`: a hand-edited
  `lab.env` must not be able to execute arbitrary code. Keep that check if you touch the parser.

### kubeadm

- **`node-ip` is mandatory on every node.** Each VM has a NAT NIC at `10.0.2.15`, *identical on
  every VM*. Without `kubeletExtraArgs: node-ip`, every node registers with that address and
  logs, `exec`, probes and cross-node traffic all go to the wrong place. This is **the** reason
  the lab joins nodes through `JoinConfiguration` files instead of the printed `kubeadm join`
  line: that line cannot carry `node-ip`, and `kubeadm join` has no equivalent flag. Never
  "simplify" the join back to the printed command.
- **v1beta4: `extraArgs` and `kubeletExtraArgs` are LISTS, not dictionaries.**
  ```yaml
  # v1beta3 — invalid now
  extraArgs: {bind-address: "0.0.0.0"}
  # v1beta4 — correct
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
  ```
  The change exists so a flag can be repeated. Any pre-1.31 snippet copied from the internet is
  invalid, and the error message does not say so. `make validate-kubeadm` catches it.
- **The host-only interface name is never hard-coded.** `provision.sh` finds the interface that
  *carries the node's IP* and writes it to `/etc/kubeadm-lab/node.env`; `cluster-up.sh` copies
  it into `_out/cluster.env` as `HOSTONLY_IF`; Cilium's L2 announcement and keepalived both use
  it. Debian 13 usually gives `enp0s8`, some boxes still give `eth1`. Writing either literally
  anywhere is a bug.
- **The `pause` image is never hard-coded either.** `provision.sh` asks
  `kubeadm config images list` for it. A mismatch between containerd's pinned image and the one
  kubeadm expects is invisible online and fatal offline.
- **`controlPlaneEndpoint` is the VIP even with one control plane.** It is frozen in the
  certificates and in every kubeconfig at `kubeadm init` time; pointing it at cp1's real IP
  would make "1 CP → 3 CP" a full certificate regeneration instead of a `join`.
- **`certSANs` pre-declares five control-plane IPs**, including nodes that do not exist yet.
  A forgotten SAN can only be added by regenerating the certificates. Do not trim that list.
- **`--skip-phases=addon/kube-proxy` is preferred to v1beta4's declarative `proxy.disabled`** —
  identical result, but the flag is proven across versions and is what Cilium documents.
- **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`,** and `cluster-up.sh` refuses any other
  combination. Without kube-proxy and without a replacement, no ClusterIP answers at all — not
  even CoreDNS reaching the API. Keep the refusal; do not downgrade it to a warning.
- **Cilium needs `k8sServiceHost`/`k8sServicePort` = the VIP** when kube-proxy is gone: nothing
  provisions the apiserver ClusterIP, so the agent cannot bootstrap through it. And Cilium's
  `cluster-pool` IPAM defaults to `10.0.0.0/8`, unrelated to what kubeadm was told — that is why
  `cilium-up.sh` passes `POD_CIDR` explicitly.
- **`kubeadm reset` leaves the CNI datapath behind** — interfaces, pinned eBPF programs under
  `/sys/fs/bpf`, kube-proxy iptables rules. `node-reset.sh` is that cleanup; without it a later
  `init` inherits a ghost datapath. Do not slim it down.
- **`apt-mark hold` on `kubelet`/`kubeadm`/`kubectl` is deliberate**, and `vagrant provision` is
  **not** an upgrade path: it would jump every node's kubelet to a new minor at once, ahead of
  the control plane. See [`kubeadm/UPGRADE.md`](kubeadm/UPGRADE.md).
- **Control planes must be odd**, and the check exists in **two** places (`Vagrantfile` and
  `cluster-up.sh`) on purpose. CI asserts that the `Vagrantfile` really refuses
  `CONTROL_PLANES=2` — a test that checks an error *happens* beats a comment claiming it does.
- **containerd's config is regenerated from `containerd config default` on every provision**, so
  the file format follows the installed binary. The `pause` key changed name *and* location
  between formats (`sandbox_image` under `[plugins."io.containerd.grpc.v1.cri"]` in v2,
  `sandbox` under `[plugins.'io.containerd.cri.v1.images'.pinned_images]` in v3) — both are
  patched. Never hand-edit that file and expect it to survive.
- **keepalived, not kube-vip**, and no `authentication` block. The VIP must exist *before*
  `kubeadm init`; kube-vip elects its leader *through* the API it is meant to front. VRRP is
  **unicast** (multicast misbehaves on a VirtualBox host-only switch), and the isolation knob is
  `VRRP_ROUTER_ID`, not a cleartext VRRPv2 password.

## 🔐 Secrets

- `lab.env` is gitignored and may hold **real** secrets (`CLOUDFLARE_API_TOKEN`). Never commit
  it, never copy a value from it into a README, a commit message, a report or terminal output.
- `_out/join.env` holds the **join token and the certificate key**; `_out/admin.conf` and
  `./kubeconfig` hold admin credentials; `_out/self-signed/ca.key` is a private CA key. `_out/`
  is gitignored **but readable by every VM** through `/vagrant`.
- The repo is **public**: every versioned default must be neutral (`kubeadm.lab.example.io`,
  empty `CLOUDFLARE_API_TOKEN`, empty `REGISTRY_MIRROR`).
- Before committing: `git status`. No secret file may appear.

## 📝 Conventions

- **Bilingual docs, English first.** Every page exists twice **in the same directory**: English
  carries the canonical name, French its mirror.

  | English | French |
  |---|---|
  | `README.md` | `LISEZ-MOI.md` |
  | `TROUBLESHOOTING.md` | `DEPANNAGE.md` |
  | `UPGRADE.md` | `MISE-A-JOUR.md` |

  Both versions change in the **same commit**: an English page whose mirror did not follow is a
  documentation bug. **This file is the exception** — English only, on purpose, because it
  addresses coding agents (it is listed in `SANS_MIROIR` in `docs/build.py`, so it carries no
  "not translated" badge).
- **Every page starts with the i18n banner**, which `docs/build.py` strips at build time (the
  HTML page has its own switcher). Keep it in the files, and put nothing else between the
  markers:
  ```markdown
  <!-- i18n -->
  **English** · [Français](LISEZ-MOI.md)
  <!-- /i18n -->
  ```
- **EN and FR must share the exact same heading structure**, in the same order: the site's
  language switcher keeps the current anchor when it toggles. Slugs derive from headings, so
  FR anchors differ from EN anchors by construction — which means renaming a heading breaks
  every link that targeted it, and `make validate-docs` is what tells you.
- **`docs/build.py` discovers pages on its own**: every `*.md` in the repo is picked up. Adding
  a page needs **no** code change; only its menu group (`GROUPES`) and its emoji (`EMOJIS`) are
  declared, and an unknown directory falls into "Other". Pages are grouped per directory through
  `MIROIRS`; a page with no mirror is shown in English inside the French menu with an `EN`
  badge — that badge is the symptom of a forgotten translation.
- **Code comments in French** (scripts, YAML, `docs/build.py`): that is the repo's working
  language. **Exceptions, in English**: `Vagrantfile` and `lab.env.example`, the first two files
  a newcomer opens.
- **Commit messages in English**, conventional (`fix(...)`, `feat(...)`, `docs: ...`). Branch
  from `main`, one feature per PR, squash merge.
- Every `_k8s/<addon>/README.md` follows the same skeleton (one emoji per `##`, `⚠️`/`💡`/`ℹ️`
  callouts) and carries its own pitfalls section. Stick to plain CommonMark + GitHub tables so
  the generator renders it.

### Adding a component = propagating it EVERYWHERE

A variable, an option or an addon is only "done" once it appears at **every** level. One
isolated mention is a documentation bug — the reader will never find it.

| Where | What to update |
|---|---|
| `_k8s/<addon>/README.md` | the dedicated page |
| `_k8s/README.md` | the index table of the right family, and the dependency chain if it changed |
| `README.md` (root) | only if it touches the install path, `lab.env` or the CNI choice |
| `lab.env.example` | every new variable, commented, with a **neutral** default |
| every file carrying a duplicated fallback default | see the golden rule above |
| `CLAUDE.md` | every newly earned pitfall, every new validation command |
| `TROUBLESHOOTING.md` | if the component has a failure mode a reader will meet |
| `kubeadm/UPGRADE.md` | if it constrains a version or has its own release cycle |
| `docs/build.py` | the page emoji in `EMOJIS`, its placement in `GROUPES` |
| **the FR mirror of every page touched** | same structure, same content, **same commit** |

Then `make docs`, then `make validate`, before committing.

## 🧭 What is deliberately absent from this repo

Knowing what is *not* here saves you from "adding" it back.

- **No `talosctl`, no immutable OS, no API-driven machine config.** The nodes are plain Debian;
  that is the entire point of this repo next to its Talos sibling.
- **No kube-vip.** keepalived carries the VIP because the VIP must pre-date `kubeadm init`.
  kube-vip stays a legitimate option *once the cluster is up* (`--services` mode) — worth
  mentioning, never the default path.
- **No MetalLB.** Cilium's L2/ARP announcement gives LoadBalancer Services their IP. MetalLB is
  only relevant on the `CNI=calico` branch, and that is documented in `_k8s/calico/`.
- **No cluster bootstrap inside `vagrant up`.** The `Vagrantfile` prepares VMs and stops there.
  Bootstrapping is a separate, re-runnable script — that separation is what makes growing the
  lab a re-run instead of a rebuild.
- **No external etcd.** Stacked etcd on the control planes: kubeadm's default, and the right
  call for a lab.
- **No ingress-nginx.** Gateway API through Envoy Gateway.
- **No cert-manager by default.** `SELF_SIGNED=true` builds a local CA with `openssl`, works
  offline, and burns no Let's Encrypt quota. Both TLS modes fill the *same* Secret, so no addon
  ever branches on the TLS mode — keep it that way.
- **No CI that boots a VM or talks to a cluster.** Everything CI does is a `make validate-*`
  target that also runs on a laptop. A check that passes in CI and fails locally is a broken
  check.
- **No committed `lab.env`, `_out/`, `kubeconfig` or `docs/index.html`.** All generated, all
  gitignored.
