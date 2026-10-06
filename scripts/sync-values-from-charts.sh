#!/usr/bin/env bash
# Copies stack/charts/tdp/<component>/values.yaml into <target>/available/<component>/
# values.yaml and turns every "<name>.tdp.local" hostname into "<name>.${TDP_DOMAIN}",
# so deploy.sh can substitute the ingress/Gateway API domain at render time.
#
# publish-github.sh runs this on its snapshot before pushing the public mirror;
# run it by hand to refresh the kit in this repo after changing a chart's values.
#
# Only values.yaml is touched. The GitOps overlays (values-gitops.yaml,
# values-integration.yaml) and the Application templates are never overwritten,
# which is why the ${TDP_*_PASSWORD} placeholders (variables.env) live in those
# overlays: put them in values.yaml and the next sync replaces them with the
# chart defaults.
#
# Usage: sync-values-from-charts.sh [-t TARGET_DIR] [COMPONENT...]
#   -t TARGET_DIR  kit directory holding available/ (default: this script's kit)
#   COMPONENT      components to sync (default: every directory under available/)
set -euo pipefail

DEV_HOST="registry.engtecnisys.com.br"
PROD_HOST="registry.tecnisys.com.br"

GITOPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$GITOPS_DIR/../.." && pwd)"
TARGET_DIR="$GITOPS_DIR"

if [ "${1:-}" = "-t" ]; then
  TARGET_DIR="$2"
  shift 2
fi

components=("$@")
if [ ${#components[@]} -eq 0 ]; then
  while IFS= read -r dir; do
    components+=("$(basename "$dir")")
  done < <(find "$TARGET_DIR/available" -mindepth 1 -maxdepth 1 -type d -name 'tdp-*' | sort)
fi

for raw in "${components[@]}"; do
  comp="$(echo "$raw" | xargs)"
  [ -z "$comp" ] && continue

  src="$REPO_ROOT/stack/charts/tdp/$comp/values.yaml"
  dst_dir="$TARGET_DIR/available/$comp"

  if [ ! -d "$dst_dir" ]; then
    echo "Skipping $comp — not part of the available/ catalog (bootstrap prerequisite)."
    continue
  fi
  if [ ! -f "$src" ]; then
    echo "Skipping $comp — no stack/charts/tdp/$comp/values.yaml found." >&2
    continue
  fi

  # 1. Image refs: the kit only ever pulls from the production Harbor. Same rewrite
  #    as the Jenkins release pipeline (host+project together first, then the bare
  #    host; see tests/charts/render-regression/test.sh), so the kit in git already
  #    matches what a release publishes.
  # 2. Lowercase "<label>.tdp.local" only: Kerberos realms such as TDP.LOCAL stay as-is.
  # shellcheck disable=SC2016 # ${TDP_DOMAIN} is a literal placeholder for envsubst
  sed -E -e "s#${DEV_HOST}/tdp-dev/#${PROD_HOST}/tdp/#g" -e "s#${DEV_HOST}#${PROD_HOST}#g" \
    -e 's/([a-z0-9-]+)\.tdp\.local([^a-zA-Z0-9-]|$)/\1.${TDP_DOMAIN}\2/g' "$src" > "$dst_dir/values.yaml"
  echo "Updated available/$comp/values.yaml from stack/charts/tdp/$comp/values.yaml"

  # A split ref (registry: <host> + repository: tdp-dev/...) survives the rewrite
  # as registry.tecnisys.com.br/tdp-dev/..., which does not exist in production.
  if grep -nE "^[^#]*(^|[^a-z-])tdp-dev/" "$dst_dir/values.yaml" >&2; then
    echo "ERROR: available/$comp/values.yaml still references tdp-dev/ (see above): keep host and project in one string in the chart." >&2
    failed=1
  fi
done

exit "${failed:-0}"
