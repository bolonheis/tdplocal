#!/usr/bin/env bash
# Publishes gitops/tdp-gitops as a new commit + tag on top of the public GitHub
# mirror (Tecnisys-OSS/tdp-k8s-gitops), then creates (or updates) the matching
# GitHub Release with a standard body. Before snapshotting, available/<component>/
# values.yaml is overwritten with stack/charts/tdp/<component>/values.yaml from
# this same checkout (already sed-processed by the "Preparar Charts" stage), so
# the public mirror always ships the current chart defaults — see
# sync-values-from-charts.sh. The values-gitops.yaml/values-integration.yaml
# overlays next to it are kept as they are in this repo. *-DEV.md files and
# this scripts/ directory (internal-only) are left out of the snapshot. Internal
# git history is not carried over, but each run adds one commit on top of the
# mirror's existing history — only main is pushed, tagged with SYNC_TAG.
set -euo pipefail

GITOPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$GITOPS_DIR/../.." && pwd)"

: "${SYNC_TAG:?SYNC_TAG must be set (e.g. v3.0.2-beta)}"
: "${SELECTED_COMPONENTS:?SELECTED_COMPONENTS must be set (comma-separated component names)}"

if [ -n "${GITHUB_USERNAME:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_URL="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/Tecnisys-OSS/tdp-k8s-gitops.git"
else
  echo "GITHUB_USERNAME/GITHUB_TOKEN must be set (this script pushes non-interactively)." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Snapshot of gitops/tdp-gitops, without internal-only files.
SNAPSHOT="$WORKDIR/snapshot"
mkdir -p "$SNAPSHOT"
cp -a "$GITOPS_DIR/." "$SNAPSHOT/"
find "$SNAPSHOT" -maxdepth 1 -type f -name '*-DEV.md' -delete
rm -rf "$SNAPSHOT/scripts"

# Refresh each component's values.yaml from the chart actually built this run
# (also turns *.tdp.local hostnames into the ${TDP_DOMAIN} placeholder).
IFS=',' read -ra COMPONENTS <<< "$SELECTED_COMPONENTS"
"$GITOPS_DIR/scripts/sync-values-from-charts.sh" -t "$SNAPSHOT" "${COMPONENTS[@]}"

git clone "$AUTH_URL" "$WORKDIR/mirror"
(
  cd "$WORKDIR/mirror"

  git config user.name "tecnisys-admin"
  git config user.email "tool@tecnisys.com.br"

  # Replace tracked content with the new snapshot, preserving upstream history.
  find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -a "$SNAPSHOT/." .

  git add -A
  if git diff --cached --quiet; then
    echo "No content changes since last sync."
  else
    git commit -m "Sync gitops with tdp-k8s ${SYNC_TAG}"
  fi

  git tag -f "$SYNC_TAG"
  git push origin main
  git push origin "refs/tags/${SYNC_TAG}" --force
  echo "Synced tdp-k8s ${SYNC_TAG} to Tecnisys-OSS/tdp-k8s-gitops (main + tag ${SYNC_TAG})."
)

# Create (or update, if this tag was already released) the GitHub Release.
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to create the GitHub release." >&2
  exit 1
fi

API_URL="https://api.github.com/repos/Tecnisys-OSS/tdp-k8s-gitops"
RELEASE_NAME="TDP GitOps — ${SYNC_TAG}"

# Standard release body template — __SYNC_TAG__ is substituted below.
# Keep this in sync with README.md's "What's included" if the component
# catalog or bootstrap prerequisites change.
RELEASE_BODY_TEMPLATE=$(cat <<'EOF'
ArgoCD App-of-Apps templates for deploying the Tecnisys Data Platform (TDP) on Kubernetes. This release tracks tdp-k8s `__SYNC_TAG__` — `available/*/values.yaml` reflect the chart defaults shipped in that version.

### Getting started

```bash
git clone https://github.com/Tecnisys-OSS/tdp-k8s-gitops.git my-tdp-gitops
cd my-tdp-gitops
cp variables.env variables.env.local   # edit with your cluster/registry/git values
./deploy.sh --install -v variables.env.local
```

Full instructions in [README.md](https://github.com/Tecnisys-OSS/tdp-k8s-gitops/blob/main/README.md).

### What's included

**Bootstrap prerequisites** (installed once via `helm install`, ahead of everything else):
- `tdp-crds` — cluster-wide CRDs (ArgoCD + TDP custom resources)
- `tdp-argo` — ArgoCD itself
- `tdp-license` — license enforcement subsystem
- `tdp-operator` — shared ClickHouse/Kafka operators

**Available components** (deployed via the App-of-Apps, `available/<component>/`):

| Category | Components |
|---|---|
| Data Processing | `tdp-spark`, `tdp-airflow`, `tdp-nifi` |
| Data Storage | `tdp-postgresql`, `tdp-clickhouse`, `tdp-deltalake`, `tdp-iceberg`, `tdp-kafka`, `tdp-ozone` |
| Data Catalog & Governance | `tdp-hive-metastore`, `tdp-openmetadata`, `tdp-ranger` |
| Analytics & Visualization | `tdp-jupyter`, `tdp-superset`, `tdp-trino`, `tdp-cloudbeaver` |

### Requirements

- Kubernetes 1.32+ / OpenShift 4.19+ / Rancher 2.10.x+
- `kubectl`, `envsubst`, `git`
- ArgoCD ≥ 2.5

### Notes

- This repo is the **distribution source** — clone or fork it as the base for your own GitOps repo (see [Getting Started](https://github.com/Tecnisys-OSS/tdp-k8s-gitops#getting-started) in the README). `GIT_REPO_URL` must point at your own copy, not at this upstream repo.
- Some `values.yaml` files ship with example passwords for local/demo use — change them before deploying to a real environment (see the Security section in the README).
EOF
)
RELEASE_BODY="${RELEASE_BODY_TEMPLATE//__SYNC_TAG__/$SYNC_TAG}"

# Mark as a pre-release when the tag has a suffix (e.g. v3.0.2-beta).
case "$SYNC_TAG" in
  *-*) PRERELEASE=true ;;
  *)   PRERELEASE=false ;;
esac

PAYLOAD="$(jq -n \
  --arg tag "$SYNC_TAG" \
  --arg name "$RELEASE_NAME" \
  --arg body "$RELEASE_BODY" \
  --argjson prerelease "$PRERELEASE" \
  '{tag_name: $tag, name: $name, body: $body, prerelease: $prerelease}')"

EXISTING_ID="$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL}/releases/tags/${SYNC_TAG}" | jq -r '.id // empty')"

if [ -n "$EXISTING_ID" ]; then
  curl -sS --fail -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL}/releases/${EXISTING_ID}" -d "$PAYLOAD" >/dev/null
  echo "Updated existing GitHub release for ${SYNC_TAG}."
else
  curl -sS --fail -X POST -H "Authorization: token ${GITHUB_TOKEN}" "${API_URL}/releases" -d "$PAYLOAD" >/dev/null
  echo "Created GitHub release for ${SYNC_TAG}."
fi
