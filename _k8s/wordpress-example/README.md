<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 📝 `wordpress-example/` — WordPress + MariaDB (persistent storage demo)

> **The demo that exercises Longhorn end to end.** Two **2Gi** PVCs (RWO, StorageClass
> `longhorn`) for MariaDB (`/var/lib/mysql`) and WordPress (`/var/www/html`), exposed over
> **HTTPS** through Envoy Gateway at `wordpress.kubeadm.lab.example.io`. One manifest, no script.

## 🎯 Purpose

- Prove that a **PVC survives** a pod restart, and show it with a real application.
- Illustrate three block-storage classics: **RWO / single-attach**, `strategy: Recreate`, and
  `subPath` to dodge `lost+found`.
- Illustrate **offloaded TLS termination**: an app that has to be *told* it sits behind an HTTPS
  proxy.

## 📋 Prerequisites

| Prerequisite | Why | Verify |
|---|---|---|
| **StorageClass `longhorn`** ([`../longhorn/`](../longhorn/README.md)) | both PVCs name it explicitly | `kubectl get sc longhorn` |
| `main-gateway` + `https:443` listener ([`../envoy-gateway/`](../envoy-gateway/README.md)) | carries the `HTTPRoute` | `kubectl get gateway -n envoy-gateway-system` |
| Wildcard cert `READY=True` ([`../cert-manager/`](../cert-manager/README.md)) | trusted HTTPS | `kubectl -n envoy-gateway-system get certificate` |
| DNS `wordpress.kubeadm.lab.example.io → 192.168.56.200` (**DNS-only**) | hostname of the route | `curl --resolve` otherwise (see ✅) |

> ⚠️ **No safety net: there is no `*-up.sh` here.** The manifest references the `longhorn`
> StorageClass without checking that it exists. Without Longhorn (or with only `local-path`), the
> `kubectl apply` **succeeds** and the PVCs stay silently `Pending`, with the pods stuck in
> `Pending` too. Check `kubectl get sc` **first**. For a demo without Longhorn, replace
> `storageClassName: longhorn` with `local-path` in both PVCs — accepting that a `local-path` PV
> is **node-local and not replicated** (see
> [`../local-path-storage/`](../local-path-storage/README.md)).

## ⚡ Install

```bash
kubectl apply -f _k8s/wordpress-example/wordpress-mariadb.yaml
```

Everything sits in this single file, namespace **`wordpress-test`** included.

> 🌐 **Domain**: the manifest carries the neutral domain `kubeadm.lab.example.io` (public repo) and
> does not go through a `*-up.sh`: edit the hostname, or substitute your own domain on the fly:
>
> ```bash
> sed 's/kubeadm\.lab\.example\.io/kubeadm.lab.my-domain.tld/g' \
>   _k8s/wordpress-example/wordpress-mariadb.yaml | kubectl apply -f -
> ```
>
> (see [`../README.md`](../README.md#-lab_domain--the-ui-domain)).

> Three places to cover in this manifest: the `hostname` of the `HTTPRoute` **and**
> `WP_HOME`/`WP_SITEURL` (`WORDPRESS_CONFIG_EXTRA`) — WordPress builds its URLs from those
> two constants, and a wrong domain breaks the CSS and the install redirect.

## 🔧 Contents of `wordpress-mariadb.yaml`

| Object | Purpose |
|---|---|
| `Namespace wordpress-test` | isolates the demo |
| `Secret mariadb` | DB credentials — **example passwords in plaintext in the manifest** (see ⚠️ Pitfalls) |
| `PVC mariadb-data` / `wordpress-data` | **2Gi Longhorn** each, `ReadWriteOnce` |
| `Deployment mariadb` (`mariadb:11.4`) | DB, `strategy: Recreate`, volume mounted with `subPath: mysql`, `healthcheck.sh` probes |
| `Deployment wordpress` (`wordpress:6.7-php8.3-apache`) | front end, `Recreate`, `subPath: wp`, probe on `/wp-login.php` |
| `Service mariadb` / `wordpress` | ClusterIP (3306 / 80) |
| `HTTPRoute wordpress` | `wordpress.kubeadm.lab.example.io` → `wordpress:80`, `sectionName: https` of `main-gateway` |

Both containers declare `requests` (cpu + memory) and a **memory limit** only — no CPU limit
(repo choice: cap RAM, do not *throttle* CPU).

### The three points that make the demo

- **`strategy: Recreate`** — Longhorn volumes are **RWO** (single-attach): the old pod has to
  release the volume before the new one can attach it. With `RollingUpdate` (the default), the new
  pod would stay stuck on multi-attach.
- **`subPath`** — the database and the site live in a **subdirectory** of the volume, to avoid the
  `lost+found` that ext4 creates at the root (MariaDB refuses a "non-empty" `datadir`).
- **TLS terminated by Envoy** — WordPress only ever sees HTTP. We force detection through
  `HTTP_X_FORWARDED_PROTO` and **freeze** `WP_HOME`/`WP_SITEURL` to `https://…` in
  `WORDPRESS_CONFIG_EXTRA`; otherwise WordPress generates `http` URLs and loops on redirects.

## ✅ Verify

```bash
kubectl -n wordpress-test get pvc,pods            # PVC Bound, pods Running 1/1
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve wordpress.kubeadm.lab.example.io:443:192.168.56.200 \
  https://wordpress.kubeadm.lab.example.io/             # 302 → /wp-admin/install.php (fresh WP)
# then finish the install in the browser: https://wordpress.kubeadm.lab.example.io/
```

## 🧪 Scenario — persistence, live

```bash
# 1. Finish the WordPress install in the browser, publish a post.
# 2. Kill both pods: their PVCs are reattached on restart.
kubectl -n wordpress-test delete pod --all
kubectl -n wordpress-test get pods -w             # Recreate: the old one releases, the new one attaches
# 3. Reload the page: the post is still there (the data lives in the Longhorn volumes).
```

On the Longhorn side (UI `longhorn.kubeadm.lab.example.io`, or `kubectl -n longhorn-system get
volumes`), you watch both volumes detach then reattach — and see which node they are attached to.

## ⚠️ Pitfalls

- **Plaintext passwords in the manifest.** The `mariadb` Secret is written with `stringData` and
  example values committed to the repo: this is **training material**, not a template. Outside
  the lab, use a `Secret` created outside Git (or even
  [`../vault-secret-operator/`](../vault-secret-operator/README.md), which does exactly that).
  Changing those values **after** the first start is not enough: MariaDB only initializes its
  credentials when the `datadir` is created.
- **PVC `Pending` with no visible error** → the `longhorn` StorageClass is missing (see
  📋 Prerequisites) or Longhorn is down. `kubectl -n wordpress-test describe pvc mariadb-data`
  gives the real reason.
- **`Multi-Attach error`** → a `RollingUpdate` slipped in instead of `Recreate`, or the old pod is
  stuck in `Terminating` (lost node). Force-delete the old pod.
- **The domain is hardcoded** in `WORDPRESS_CONFIG_EXTRA` (`WP_HOME`/`WP_SITEURL`) **and** in the
  `HTTPRoute`. If you change domain, you have to edit both — otherwise WordPress redirects to the
  old name.
- **`wordpress:6.7-php8.3-apache` and `mariadb:11.4` are release-series tags**, not digests: the
  content can move under the same tag. Good enough for a lab, not enough for strict
  reproducibility.

## 🧹 Cleanup

```bash
kubectl delete -f _k8s/wordpress-example/wordpress-mariadb.yaml   # deletes the namespace + the PVCs
```

> ℹ️ Deleting the PVCs releases the Longhorn volumes (`reclaimPolicy: Delete` on the
> StorageClass): **the data is lost**, including the posts published during the demo.

## 📚 References

- [`wordpress` Docker image — environment variables](https://hub.docker.com/_/wordpress)
- [WordPress — `WP_HOME` / `WP_SITEURL` behind a proxy](https://developer.wordpress.org/apis/wp-config-php/#wp-siteurl)
- [`../longhorn/README.md`](../longhorn/README.md) — the storage this demo exercises
