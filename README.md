# TDP GitOps

ArgoCD manifests repository for deploying Tecnisys Data Platform (TDP) components to Kubernetes, using the **App of Apps** pattern.

## Overview

This repository drives the deployment of TDP (Tecnisys Data Platform) components — Ozone, Trino, Spark, Airflow, Kafka, Superset, and others — onto Kubernetes clusters using ArgoCD's App-of-Apps pattern. Application manifests are kept as envsubst templates under `available/`, rendered per environment into `current/` (the source of truth ArgoCD watches), and reference versioned Helm charts hosted on Tecnisys' OCI registry. A single `deploy.sh` script handles the ArgoCD bootstrap, template rendering, and both GitOps (git-driven) and direct (`kubectl apply`) deployment modes.

### How it works

```
deploy.sh                 your git repo             ArgoCD
─────────                 ─────────────             ──────
available/ ─┐  render     current/        watch     App of Apps (in ARGOCD_NAMESPACE)
common/   ──┴──────────►  ├─ common/   ◄──────────     │ creates one Application per component
                          ├─ tdp-ozone/                ▼
                          └─ tdp-trino/  ◄──────────  Applications (in TDP_PROJECT_NAMESPACE)
                                         values        │ Helm chart from registry.tecnisys.com.br
                                                       ▼
                                                     Workloads (in TDP_NAMESPACE)
```

- `available/` and `common/` contain the **templates** (with `${VAR}`) — **never** applied directly.
- `deploy.sh -p` renders `common/` (and the components you name) → `current/`, substituting variables.
- `current/` is **committed to git** and watched by the App of Apps. Each Application installs its chart from the registry, with the values files from `current/<component>/`.
- The rendered Secrets (`current/common/*-secret.yaml`) hold your git and registry credentials: they are git-ignored, excluded from the App of Apps and applied by `deploy.sh` only. **Never commit them.**
- Charts and images come from **`registry.tecnisys.com.br` only**: `community/*` is public, `tdp/*` needs the `tdp-registry` pull secret that `deploy.sh` creates.

### Structure

```
tdp-gitops/
├── common/           # Bootstrap templates: AppProject, App of Apps, repository and pull Secrets
├── available/        # One folder per TDP component:
│   ├── tdp-airflow/      #   tdp-airflow.yaml          the ArgoCD Application
│   │                     #   values.yaml               chart defaults
│   │                     #   values-gitops.yaml        GitOps defaults (optional overlay)
│   │                     #   values-integration.yaml   wiring to other components (optional overlay)
│   ├── tdp-clickhouse/
│   ├── …
│   └── tdp-trino/
├── current/          # Rendered by deploy.sh — committed to git,
│                     # except current/common/*-secret.yaml (git-ignored)
├── variables.env     # Reference variables (do not edit, copy to variables.env.local)
├── deploy.sh         # Render and deploy script
└── README.md
```

---

## Prerequisites

| Item | Requirement |
| --- | --- |
| Cluster | Kubernetes 1.32+, OpenShift 4.19+ or Rancher 2.10.x+ |
| Workstation | `kubectl` configured for the cluster, `helm` 3, `envsubst` (`gettext` package), `git` |
| Registry account | A user or robot account on `registry.tecnisys.com.br`, used for the charts and for the private images |
| Git server | An empty repository that ArgoCD can reach, and a token for it |
| Cluster classes | An IngressClass and a StorageClass, or cluster defaults for both |
| Installed by the cluster administrator | `tdp-license` (license enforcement) and `tdp-operator` (Kafka and ClickHouse operators), via `helm install`, outside this GitOps flow |

---

## Installation

### Step 1 — Create your GitOps repository

This repository (**Tecnisys-OSS/tdp-k8s-gitops**) is the distribution source — kept in sync with each TDP release, and overwritten on every release sync. Use it as the starting point for **your own** repository, the one ArgoCD will watch:

```bash
# Get the kit
git clone https://github.com/Tecnisys-OSS/tdp-k8s-gitops.git my-tdp-gitops
cd my-tdp-gitops

# Point it at your own, empty repository and publish it
git remote set-url origin https://git.example.com/<org>/my-tdp-gitops.git
git push -u origin main
```

The App of Apps follows the **`main`** branch.

### Step 2 — Configure `variables.env.local`

```bash
cp variables.env variables.env.local
```

`variables.env.local` is git-ignored. It is sourced by bash, so **single-quote any value containing `$`**, such as a Harbor robot account (`TECNISYS_HELM_REGISTRY_USER='robot$tdp+pull'`).

| Variable | Example | Used for |
| --- | --- | --- |
| `ARGOCD_NAMESPACE` | `tdp-system` | Where ArgoCD is installed (and the App of Apps lives) |
| `TDP_NAMESPACE` | `tdp` | Where the component pods run, and the `tdp-registry` pull secret |
| `TDP_PROJECT_NAMESPACE` | `tdp` | Where the component Applications live |
| `TDP_APPLICATIONS` | `argo-gitops-tdp` | Name of the App of Apps |
| `GIT_REPO_URL`, `GIT_REPO_USER`, `GIT_REPO_TOKEN_OR_PASS` | your repository | The repository ArgoCD watches |
| `HELM_CHART_REPO_URL`, `HELM_CHART_VERSION` | `registry.tecnisys.com.br/tdp/charts`, `3.0.2` | Where the charts come from |
| `KUBERNETES_SERVER` | `https://kubernetes.default.svc` | Destination cluster (in-cluster by default) |
| `TECNISYS_HELM_REGISTRY_USER`, `TECNISYS_HELM_REGISTRY_TOKEN` | `'robot$tdp+pull'` | Chart pulls (ArgoCD) and image pulls (`tdp-registry` secret) |
| `TDP_DOMAIN` | `example.com` | Ingress/Gateway API hosts: `airflow.example.com`, … (default `tdp.local`; `-d` overrides it) |
| `TDP_INGRESS_CLASS`, `TDP_STORAGE_CLASS` | `nginx`, `local-path` | Written into every `values-gitops.yaml`; empty = chart default and the cluster's default class |

### Step 3 — Install the CRDs and ArgoCD

```bash
./deploy.sh --install -v variables.env.local
```

What runs, in order:

1. `helm registry login` — authenticates to the OCI registry.
2. `helm upgrade --install tdp-crds` — the cluster CRDs; skipped when the ArgoCD CRDs already exist.
3. `helm upgrade --install tdp-argo` — ArgoCD in `ARGOCD_NAMESPACE`, with `application.namespaces: "*"` so it can manage Applications in any namespace; waits for the server and the application controller.
4. `envsubst` on `common/` → `current/common/`. Components are rendered separately, in Step 6.
5. `kubectl apply` of `current/common/` (creating `TDP_NAMESPACE` if needed):
   - `argo-gitops-appproject.yaml` — the TDP AppProject
   - `tdp-devops-repo-secret.yaml` — git credential for ArgoCD
   - `tdp-registry-secret.yaml` — Helm OCI registry credential for ArgoCD
   - `tdp-image-pull-secret.yaml` — the `tdp-registry` image pull secret in `TDP_NAMESPACE`. An existing `tdp-registry` is kept unless you pass `--force`.
   - `argo-gitops-app-of-apps.yaml` — the App of Apps

> **Using an ArgoCD you installed yourself?** Skip `--install` and run `./deploy.sh -c -v variables.env.local` instead. Make sure that ArgoCD manages Applications in `TDP_PROJECT_NAMESPACE`:
>
> ```bash
> kubectl patch configmap argocd-cm -n <argocd-namespace> --type merge \
>   -p '{"data":{"application.namespaces":"<TDP_PROJECT_NAMESPACE>"}}'
> kubectl rollout restart deployment argocd-server -n <argocd-namespace>
> kubectl rollout restart statefulset argocd-application-controller -n <argocd-namespace>
> ```

### Step 4 — Expose the ArgoCD UI (optional)

`tdp-argo` installs without an Ingress. Enable one, and set ArgoCD's own URL to the same host so redirects and SSO callbacks work:

```bash
helm upgrade tdp-argo oci://registry.tecnisys.com.br/tdp/charts/tdp-argo \
  --version 3.0.2 -n tdp-system --reuse-values \
  --set TDP-Settings.gateway.ingress.enabled=true \
  --set tdp-argo.server.ingress.enabled=true \
  --set tdp-argo.server.ingress.ingressClassName=nginx \
  --set tdp-argo.server.ingress.hostname=argo.example.com \
  --set tdp-argo.configs.cm.url=https://argo.example.com
kubectl -n tdp-system rollout restart deploy/tdp-argocd-server
```

Without a TLS configuration the Ingress serves the controller's default certificate. Reinstalling `tdp-argo` drops these settings: keep the flags with your install notes.

### Step 5 — Publish the bootstrap and log in

The App of Apps reads `current/` **from the git repository**, so push it. The rendered Secrets are git-ignored and stay local.

```bash
git add current/
git commit -m "chore: bootstrap TDP GitOps"
git push origin main

# The App of Apps should report Synced
kubectl -n tdp-system get applications

# Initial admin password for the UI
kubectl -n tdp-system get secret tdp-argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Step 6 — Render the applications

Without component names, `deploy.sh` renders `current/common/` only. Name the components you want, or pass `--all-components`:

```bash
# A few components
./deploy.sh -p -v variables.env.local tdp-ozone tdp-hive-metastore tdp-trino

# Everything in available/, with hosts such as airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components
```

Each component lands in `current/<component>/`: its Application manifest plus up to three values files (see [Values files](#values-files)).

- Rendering only adds or refreshes files: components already in `current/` that you don't name are left alone, so the App of Apps doesn't prune them.
- An existing `current/<component>/values*.yaml` may hold your edits, so it is **kept** (with a warning) unless you pass `--force`. The Application manifest is always refreshed.
- `deploy.sh` warns if anything in `current/` points at a registry other than `registry.tecnisys.com.br`.

### Step 7 — Push and let ArgoCD sync

```bash
git add current/
git commit -m "feat: add tdp-ozone, tdp-hive-metastore, tdp-trino"
git push origin main

# Follow the Applications and their pods
kubectl -n tdp get applications            # Synced / Healthy
kubectl -n tdp get pods -w
```

The App of Apps creates each new Application; every Application installs its chart from `registry.tecnisys.com.br` with the values from your repository, with automated sync, self-heal and prune.

**Direct mode** applies an Application with `kubectl`, without going through the App of Apps — ArgoCD still reads its values files from git, so push them anyway:

```bash
./deploy.sh -a -v variables.env.local tdp-trino
```

### Suggested rollout order

ArgoCD can sync everything at once, but components wired together by `values-integration.yaml` come up cleanly when their dependencies are already running:

| Order | Components | Notes |
| --- | --- | --- |
| 1. Object storage | `tdp-ozone` | Create the buckets `warehouse` and `clickhouse-data` in Ozone's `/s3v` volume |
| 2. Metadata and engines | `tdp-hive-metastore`, `tdp-spark`, `tdp-iceberg`, `tdp-trino` | Use Ozone's S3 Gateway |
| 3. Serving and BI | `tdp-clickhouse`, `tdp-superset` | Superset imports the ClickHouse and Trino datasources |
| 4. Any order | `tdp-airflow`, `tdp-kafka`, `tdp-nifi`, `tdp-jupyter`, and the rest | Kafka and ClickHouse need `tdp-operator` |

---

## Values files

Each Application layers up to three values files from `current/<component>/`, in this order — later files win:

| File | Content | On a release sync |
| --- | --- | --- |
| `values.yaml` | Chart defaults (a copy of the chart's own `values.yaml`) | Replaced by the new chart defaults |
| `values-gitops.yaml` | GitOps defaults: ArgoCD-specific fixes (e.g. Airflow migration Jobs as Sync hooks), Ozone S3 auth off while Kerberos is off, the ingress/storage class from `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS`, production image mirrors | Kept |
| `values-integration.yaml` | Wiring to the other TDP components in `TDP_NAMESPACE`: Trino catalogs (hive, iceberg, clickhouse), Spark, Hive Metastore and ClickHouse on Ozone S3, Superset datasources | Kept |

- Maps merge key by key, so an overlay only holds the keys it changes. Lists and multi-line strings are replaced as a whole.
- An empty `TDP_INGRESS_CLASS`/`TDP_STORAGE_CLASS` renders as `null`, which removes the key: the chart default applies.
- The overlays are optional: delete one from `current/<component>/` to opt out of it (the Applications set `ignoreMissingValueFiles: true`).
- `values-integration.yaml` assumes the components it points at are deployed with their default names in `TDP_NAMESPACE`, and ships example passwords (`change-me-*`) that must be changed, consistently across ClickHouse, Trino and Superset, before real use.
- ArgoCD does not substitute variables: everything under `current/` must be rendered by `deploy.sh` before you push.

### Customizing values

Edit the files in `current/<component>/` — that is what ArgoCD reads, and `deploy.sh` keeps them on re-render. Prefer `values-gitops.yaml` (or a new overlay) for your own changes, so `values.yaml` can later be refreshed from a newer release with `--force`:

```bash
vim current/tdp-trino/values-gitops.yaml
git add current/tdp-trino/
git commit -m "chore: tune trino"
git push origin main
# ArgoCD syncs automatically
```

---

## Day-2 operations

| Task | How |
| --- | --- |
| Change a setting | Edit `current/<component>/values-gitops.yaml`, commit and push |
| Upgrade the charts | Set `HELM_CHART_VERSION`, then re-render the components already in `current/` (see below) |
| Take new chart defaults | Re-render the component with `--force` (overwrites its values files) |
| Add a component | Render it (Step 6), commit and push |
| Remove a component | Delete `current/<component>/` and push: ArgoCD prunes the Application and runs its cleanup hooks |
| Rotate registry credentials | Update `variables.env.local`, then `./deploy.sh -c -v variables.env.local --force` |

Upgrading the chart version:

```bash
# 1. Update HELM_CHART_VERSION in variables.env.local
vim variables.env.local

# 2. Re-render the Applications of the components already in current/
#    (don't use --all-components here: it would add every component)
./deploy.sh -v variables.env.local -p $(ls -d current/tdp-*/ | xargs -n1 basename)

# 3. Commit
git add current/
git commit -m "chore: bump chart version to X.Y.Z"
git push origin main
```

### Upgrading a repository created with an older kit

Older kits committed `current/common/*-secret.yaml` and rendered Applications that only read `values.yaml`. To move an existing repository to this layout:

1. Copy the new kit files (`deploy.sh`, `common/`, `available/`, `.gitignore`, `variables.env`) into your repository, and add the new variables to `variables.env.local`.
2. Apply the common resources first: `./deploy.sh -c -v variables.env.local`. This puts `Prune=false` on the repository Secrets before the new App of Apps (which excludes them) syncs, so ArgoCD never deletes them.
3. Stop tracking the rendered Secrets: `git rm --cached current/common/*-secret.yaml`.
4. Re-render the components you run (their Application manifests now list the overlays; your existing `values.yaml` is kept): `./deploy.sh -p -v variables.env.local $(ls -d current/tdp-*/ | xargs -n1 basename)`.
5. Commit and push. **Rotate the git and registry tokens**: they are still in the repository's history.

---

## deploy.sh reference

```
./deploy.sh [OPTIONS] [COMPONENTS... | --all-components]
```

| Flag | Description |
| --- | --- |
| `--install` | **First install**: helm login → tdp-crds → tdp-argo → wait ready → render → apply common |
| `-v FILE` | Use a custom variables file (default: `variables.env`) |
| `-p` | Only render → `current/` (no apply) |
| `-c` | Apply only common resources (`current/common/`) via kubectl |
| `-a` | Apply only the selected components' Applications via kubectl (not common) |
| `--all-components` | Select every component in `available/` (instead of naming them) |
| `-d DOMAIN` | Domain for Ingress/Gateway API hostnames; overrides `TDP_DOMAIN` |
| `-f`, `--force` | Overwrite existing `current/<component>/values*.yaml`, and replace an existing `tdp-registry` pull secret |
| `-h` | Show help |

- **No arguments** prints the help.
- **No components** renders (and, without `-p`, applies) `current/common/` only.
- Without `-p`, `-c` or `-a`, `deploy.sh` applies the common resources plus the selected components' Applications.

### Examples

```bash
# Full first-time setup (installs ArgoCD + bootstrap)
./deploy.sh --install -v variables.env.local

# Render components and publish (GitOps mode)
./deploy.sh -p -v variables.env.local tdp-ozone tdp-trino
git add current/ && git commit -m "chore: render" && git push

# Render every component, with hosts such as airflow.example.com
./deploy.sh -p -v variables.env.local -d example.com --all-components

# Re-apply only common resources (AppProject, Secrets, App of Apps)
./deploy.sh -c -v variables.env.local

# Direct deploy of one, several or every component (no git round trip for the Application)
./deploy.sh -a -v variables.env.local tdp-trino
./deploy.sh -a -v variables.env.local tdp-ozone tdp-trino
./deploy.sh -a -v variables.env.local --all-components
```

---

## Available Components

| Component | Description | Notes |
| --- | --- | --- |
| `tdp-airflow` | Apache Airflow | |
| `tdp-clickhouse` | ClickHouse | Needs `tdp-operator`; integration: Ozone S3 disk, `trino`/`superset` users |
| `tdp-cloudbeaver` | CloudBeaver UI | |
| `tdp-deltalake` | Delta Lake | |
| `tdp-hive-metastore` | Hive Metastore | Integration: warehouse on Ozone S3 |
| `tdp-iceberg` | Apache Iceberg | |
| `tdp-jupyter` | JupyterLab | |
| `tdp-kafka` | Apache Kafka (Strimzi) | Needs `tdp-operator` |
| `tdp-nifi` | Apache NiFi | |
| `tdp-openmetadata` | OpenMetadata | |
| `tdp-ozone` | Apache Ozone S3 | Ships with security off (S3 auth disabled) |
| `tdp-postgresql` | PostgreSQL | |
| `tdp-ranger` | Apache Ranger | |
| `tdp-spark` | Apache Spark | Integration: s3a on Ozone S3 |
| `tdp-superset` | Apache Superset | Integration: ClickHouse and Trino datasources |
| `tdp-trino` | Trino SQL engine | Integration: hive, iceberg and clickhouse catalogs |

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| App of Apps: `current: app path does not exist` | `current/` was never pushed | Render and push `current/` |
| Pods `Pending`: `unbound immediate PersistentVolumeClaims` | The PVC has no StorageClass and the cluster has no default | Set `TDP_STORAGE_CLASS` (or mark a default StorageClass), re-render with `--force`, push, then delete the StatefulSet and its unbound PVCs so ArgoCD recreates them |
| `ImagePullBackOff` on a `tdp/` image | No `tdp-registry` Secret in `TDP_NAMESPACE` | `./deploy.sh -c -v variables.env.local` |
| Sync stuck on `waiting for healthy state` | A sync waiting for pods that never become healthy has no timeout, so new commits wait | Fix the cause, then Terminate the operation in the ArgoCD UI; auto-sync starts over |
| Application `OutOfSync` after a push | Not refreshed yet | `kubectl annotate application <name> -n <TDP_PROJECT_NAMESPACE> argocd.argoproj.io/refresh=hard --overwrite` |
| Variables not substituted (`${VAR}` in the cluster) | A template from `available/` or `common/` was applied directly | Always apply or push `current/`, rendered by `deploy.sh` |
| Git or registry authentication errors | Wrong credentials, or an unquoted `$` in `variables.env.local` | Check `kubectl -n <ARGOCD_NAMESPACE> get secret tdp-devops-repo tdp-helm-oci-tdp`; re-run `./deploy.sh -c` |

Debugging a sync:

```bash
# Application events
kubectl describe application <name> -n <TDP_PROJECT_NAMESPACE>

# Application controller logs
kubectl logs -n <ARGOCD_NAMESPACE> -l app.kubernetes.io/name=tdp-argocd-application-controller --tail=100
```

---

## Security

- `variables.env.local` and the rendered `current/common/*-secret.yaml` are in `.gitignore` — never commit tokens or passwords.
- Several `values.yaml` files ship with example passwords (e.g. `tdp-ranger`, `tdp-cloudbeaver`, `tdp-jupyter`, `tdp-airflow`), and `values-integration.yaml` uses `change-me-*` passwords shared by ClickHouse, Trino and Superset — placeholders for local/demo use only. **Change them before deploying to any real environment.**
- `values-integration.yaml` points at Ozone's S3 Gateway with security off: the S3 keys there are not real credentials, and any client can read and write. Enable Ozone security (Kerberos) and real S3 secrets for anything beyond a demo.
- Add TLS to every Ingress, the ArgoCD UI included.
- Use a pull-only robot account for the registry, and rotate the git and registry tokens regularly.
- `TDP_PROJECT_NAMESPACE` should have restricted RBAC: Applications there can deploy anywhere the AppProject allows.
