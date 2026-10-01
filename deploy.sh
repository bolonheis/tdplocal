#!/bin/bash

# TDP GitOps Deployment Script
# This script reads variables from variables.env and replaces them in YAML files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIABLES_FILE="${SCRIPT_DIR}/variables.env"
BACKUP_DIR="${SCRIPT_DIR}/.backup"
COMMON_DIR="${SCRIPT_DIR}/common"
AVAILABLE_DIR="${SCRIPT_DIR}/available"
CURRENT_DIR="${SCRIPT_DIR}/current"

# Set from the command line (see main)
DOMAIN_OVERRIDE=""       # -d/--domain: overrides TDP_DOMAIN from the variables file
EXPOSE_OVERRIDE=""       # -e/--expose: overrides TDP_EXPOSE from the variables file
FORCE_VALUES=false       # --force: overwrite existing current/<component>/values*.yaml

# Variables substituted in templates besides the ones declared in the variables file
OPTIONAL_VARS=(TDP_DOMAIN TDP_INGRESS_CLASS TDP_STORAGE_CLASS
    TDP_INGRESS_ENABLED TDP_GATEWAYAPI_ENABLED TDP_GATEWAY_NAME TDP_GATEWAY_NAMESPACE)

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if required tools are installed
# skip_kubectl=true  → skip kubectl check (render-only mode)
# need_helm=true     → also require helm (--install mode)
check_dependencies() {
    local skip_kubectl="${1:-false}"
    local need_helm="${2:-false}"
    local missing_tools=()
    
    if [ "$skip_kubectl" != "true" ] && ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v envsubst &> /dev/null; then
        missing_tools+=("envsubst")
    fi

    if [ "$need_helm" = "true" ] && ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install the missing tools and try again."
        exit 1
    fi
}

# Function to validate variables file
validate_variables_file() {
    if [ ! -f "$VARIABLES_FILE" ]; then
        print_error "Variables file not found: $VARIABLES_FILE"
        print_info "Please copy variables.env.example to variables.env and customize it."
        exit 1
    fi
    
    print_info "Reading variables from: $VARIABLES_FILE"

    # Source (and export, for envsubst) the variables file with error handling
    set -a
    if ! source "$VARIABLES_FILE"; then
        set +a
        print_error "Failed to source variables file"
        exit 1
    fi
    set +a

    # Optional variables, so an older variables.env.local keeps working.
    # -d/--domain wins over the file.
    if [ -n "$DOMAIN_OVERRIDE" ]; then
        TDP_DOMAIN="$DOMAIN_OVERRIDE"
    elif [ -z "${TDP_DOMAIN:-}" ]; then
        TDP_DOMAIN="tdp.local"
        print_warning "TDP_DOMAIN not set — using ${TDP_DOMAIN}"
    fi
    export TDP_DOMAIN
    export TDP_INGRESS_CLASS="${TDP_INGRESS_CLASS:-}"
    export TDP_STORAGE_CLASS="${TDP_STORAGE_CLASS:-}"
    print_info "Ingress/Gateway API domain: ${TDP_DOMAIN}"

    # Exposure: TDP_EXPOSE (or -e/--expose) → the mutually exclusive
    # TDP-Settings.gateway.{ingress,gatewayApi}.enabled switches in values-gitops.yaml
    [ -n "$EXPOSE_OVERRIDE" ] && TDP_EXPOSE="$EXPOSE_OVERRIDE"
    case "$(echo "${TDP_EXPOSE:-none}" | tr '[:upper:]' '[:lower:]')" in
        ingress)    TDP_INGRESS_ENABLED=true;  TDP_GATEWAYAPI_ENABLED=false ;;
        gatewayapi) TDP_INGRESS_ENABLED=false; TDP_GATEWAYAPI_ENABLED=true ;;
        none|"")    TDP_INGRESS_ENABLED=false; TDP_GATEWAYAPI_ENABLED=false ;;
        *)
            print_error "TDP_EXPOSE must be ingress, gatewayapi or none (got: ${TDP_EXPOSE})"
            exit 1
            ;;
    esac
    export TDP_INGRESS_ENABLED TDP_GATEWAYAPI_ENABLED
    export TDP_GATEWAY_NAME="${TDP_GATEWAY_NAME:-}"
    export TDP_GATEWAY_NAMESPACE="${TDP_GATEWAY_NAMESPACE:-}"
    if [ "$TDP_GATEWAYAPI_ENABLED" = "true" ] && [ -z "$TDP_GATEWAY_NAME" ]; then
        print_error "Gateway API exposure needs TDP_GATEWAY_NAME (the Gateway the HTTPRoutes attach to)"
        exit 1
    fi
    print_info "Exposure: ${TDP_EXPOSE:-none}$([ "$TDP_GATEWAYAPI_ENABLED" = "true" ] && echo " (Gateway ${TDP_GATEWAY_NAMESPACE:+$TDP_GATEWAY_NAMESPACE/}${TDP_GATEWAY_NAME})")"

    # Validate required variables
    local required_vars=(
        "ARGOCD_NAMESPACE"
        "TDP_NAMESPACE"
        "TDP_PROJECT_NAMESPACE"
        "GIT_REPO_URL"
        "HELM_CHART_REPO_URL"
        "HELM_CHART_VERSION"
        "KUBERNETES_SERVER"
        "TECNISYS_HELM_REGISTRY_USER"
        "TECNISYS_HELM_REGISTRY_TOKEN"
        "TDP_APPLICATIONS"
    )
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        print_error "Missing required variables: ${missing_vars[*]}"
        print_info "Please update your variables.env file with the missing variables."
        exit 1
    fi
    
    print_success "All required variables are set"
}

# Function to create backup of original files
create_backup() {
    print_info "Creating backup of original YAML files..."
    
    if [ -d "$BACKUP_DIR" ]; then
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        print_warning "Backup directory exists, creating timestamped backup: backup_${timestamp}"
        mv "$BACKUP_DIR" "${SCRIPT_DIR}/backup_${timestamp}"
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup common files
    if [ -d "$COMMON_DIR" ]; then
        while IFS= read -r -d '' file; do
            relative="${file#$SCRIPT_DIR/}"
            dest="$BACKUP_DIR/$relative"
            mkdir -p "$(dirname "$dest")"
            cp "$file" "$dest"
        done < <(find "$COMMON_DIR" -name "*.yaml" -print0)
    fi
    
    # Backup available files
    if [ -d "$AVAILABLE_DIR" ]; then
        while IFS= read -r -d '' file; do
            relative="${file#$SCRIPT_DIR/}"
            dest="$BACKUP_DIR/$relative"
            mkdir -p "$(dirname "$dest")"
            cp "$file" "$dest"
        done < <(find "$AVAILABLE_DIR" -name "*.yaml" -print0)
    fi
    
    print_success "Backup created in: $BACKUP_DIR"
}

# Function to install ArgoCD (tdp-crds + tdp-argo) via Helm OCI registry
install_argocd() {
    print_info "=== Installing ArgoCD ==="

    # Ensure namespace
    if ! kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        print_info "Creating namespace: ${ARGOCD_NAMESPACE}"
        kubectl create namespace "${ARGOCD_NAMESPACE}"
    fi

    # Authenticate to OCI registry
    # helm registry login requires only the hostname, not the full path
    local registry_host
    registry_host=$(echo "${HELM_CHART_REPO_URL}" | cut -d'/' -f1)
    print_info "Logging into Helm OCI registry: ${registry_host}"
    if ! helm registry login "${registry_host}" \
            --username "${TECNISYS_HELM_REGISTRY_USER}" \
            --password-stdin <<< "${TECNISYS_HELM_REGISTRY_TOKEN}"; then
        print_error "Failed to authenticate to Helm registry"
        exit 1
    fi

    # Step 1: Install CRDs (skip if ArgoCD CRDs already exist)
    if kubectl get crd applications.argoproj.io &>/dev/null; then
        print_warning "ArgoCD CRDs already installed — skipping tdp-crds (upgrade if needed: helm upgrade tdp-crds ...)"
    else
        print_info "Installing tdp-crds v${HELM_CHART_VERSION}..."
        if ! helm upgrade --install tdp-crds \
                "oci://${HELM_CHART_REPO_URL}/tdp-crds" \
                --version "${HELM_CHART_VERSION}" \
                --namespace "${ARGOCD_NAMESPACE}" \
                --wait --timeout 120s; then
            print_error "Failed to install tdp-crds"
            exit 1
        fi
        print_success "tdp-crds installed"
    fi

    # Step 2: Install ArgoCD, exposed like the components: argo.${TDP_DOMAIN}
    # through TDP_EXPOSE, so no helm upgrade is needed afterwards
    local argo_host="argo.${TDP_DOMAIN}"
    local argo_args=(
        --set-string "tdp-argo.global.domain=${argo_host}"
        --set-string "tdp-argo.configs.cm.url=https://${argo_host}"
        --set "TDP-Settings.gateway.ingress.enabled=${TDP_INGRESS_ENABLED}"
        --set "TDP-Settings.gateway.gatewayApi.enabled=${TDP_GATEWAYAPI_ENABLED}"
    )
    if [ "$TDP_INGRESS_ENABLED" = "true" ]; then
        argo_args+=(
            --set "tdp-argo.server.ingress.enabled=true"
            --set-string "tdp-argo.server.ingress.hostname=${argo_host}"
        )
        # Empty TDP_INGRESS_CLASS keeps the chart default, as for the components
        if [ -n "$TDP_INGRESS_CLASS" ]; then
            argo_args+=(--set-string "tdp-argo.server.ingress.ingressClassName=${TDP_INGRESS_CLASS}")
        fi
    elif [ "$TDP_GATEWAYAPI_ENABLED" = "true" ]; then
        # The HTTPRoute lives in ARGOCD_NAMESPACE, so an empty TDP_GATEWAY_NAMESPACE
        # has to be spelled out as TDP_NAMESPACE (what it means for the components).
        # gatewayApi.gateway.enabled=false: use the shared Gateway, not one per
        # release; the chart also fails without it when Gateway API is on.
        argo_args+=(
            --set "gatewayApi.gateway.enabled=false"
            --set-string "gatewayApi.parentRefs[0].name=${TDP_GATEWAY_NAME}"
            --set-string "gatewayApi.parentRefs[0].namespace=${TDP_GATEWAY_NAMESPACE:-$TDP_NAMESPACE}"
            --set-string "gatewayApi.server.hostnames[0]=${argo_host}"
        )
    fi

    print_info "Installing tdp-argo v${HELM_CHART_VERSION}..."
    if ! helm upgrade --install tdp-argo \
            "oci://${HELM_CHART_REPO_URL}/tdp-argo" \
            --version "${HELM_CHART_VERSION}" \
            --namespace "${ARGOCD_NAMESPACE}" \
            --set skipCrdCheck=false \
            "${argo_args[@]}" \
            --wait --timeout 300s; then
        print_error "Failed to install tdp-argo"
        exit 1
    fi
    print_success "ArgoCD (tdp-argo) installed"

    # Step 3: Wait for ArgoCD server and controller to be fully ready
    print_info "Waiting for ArgoCD components to be ready..."
    kubectl rollout status deployment/tdp-argocd-server \
        -n "${ARGOCD_NAMESPACE}" --timeout=180s
    kubectl rollout status statefulset/tdp-argocd-application-controller \
        -n "${ARGOCD_NAMESPACE}" --timeout=180s

    print_success "ArgoCD is running in namespace: ${ARGOCD_NAMESPACE}"
    case "$TDP_INGRESS_ENABLED/$TDP_GATEWAYAPI_ENABLED" in
        true/*) print_info "ArgoCD UI: ${argo_host} (Ingress)" ;;
        */true) print_info "ArgoCD UI: ${argo_host} (HTTPRoute on Gateway ${TDP_GATEWAY_NAMESPACE:-$TDP_NAMESPACE}/${TDP_GATEWAY_NAME}; its listener must allow routes from ${ARGOCD_NAMESPACE})" ;;
        *)      print_info "ArgoCD UI not exposed (TDP_EXPOSE=none): kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/tdp-argocd-server 8080:80" ;;
    esac
    print_info "Admin password: kubectl -n ${ARGOCD_NAMESPACE} get secret tdp-argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

# Function to restore from backup
restore_backup() {
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "No backup directory found: $BACKUP_DIR"
        exit 1
    fi
    
    print_info "Restoring files from backup..."
    
    # Restore common files
    if [ -d "${BACKUP_DIR}/common" ]; then
        cp -r "${BACKUP_DIR}/common/"* "$COMMON_DIR/"
    fi
    
    # Restore available files
    if [ -d "${BACKUP_DIR}/available" ]; then
        cp -r "${BACKUP_DIR}/available/"* "$AVAILABLE_DIR/"
    fi
    
    print_success "Files restored from backup"
}

# Function to render a single template file to an output path (never modifies source)
render_yaml_file() {
    local src="$1"
    local dst="$2"
    
    mkdir -p "$(dirname "$dst")"

    # Variables are already exported by validate_variables_file (re-sourcing the
    # file here would undo -d/--domain).
    # Build substitution list from only the variables defined in the variables file
    # (plus OPTIONAL_VARS). This prevents envsubst from replacing ArgoCD-specific
    # references like $values, or ${HOME} inside chart values.
    local var_list
    var_list=$( { grep -v '^#' "$VARIABLES_FILE" | grep -v '^[[:space:]]*$' | cut -d= -f1; printf '%s\n' "${OPTIONAL_VARS[@]}"; } \
        | sort -u | sed 's/^/\${/' | sed 's/$/}/' | tr '\n' ' ')

    # Use envsubst to replace only the declared variables
    if envsubst "$var_list" < "$src" > "$dst"; then
        return 0
    else
        print_error "Failed to render: $src"
        rm -f "$dst"
        return 1
    fi
}

# Function to render available/ templates into current/ (App of Apps flow)
render_to_current() {
    process_yaml_files "$@"
}

# Function to process all YAML files
process_yaml_files() {
    local selected_components=()
    [ $# -gt 0 ] && selected_components=("$@")
    local yaml_files=()
    local processed_files=0
    local failed_files=0
    
    print_info "Rendering templates to current/ ..."
    mkdir -p "$CURRENT_DIR"
    
    # Always process common files
    if [ -d "$COMMON_DIR" ]; then
        while IFS= read -r -d '' src; do
            local rel="${src#"$COMMON_DIR/"}"
            local dst="${CURRENT_DIR}/common/${rel}"
            if render_yaml_file "$src" "$dst"; then
                processed_files=$((processed_files + 1))
            else
                failed_files=$((failed_files + 1))
            fi
        done < <(find "$COMMON_DIR" -name "*.yaml" -print0)
    fi
    
    # Process available files only for the selected components (none → common only).
    # Other components already in current/ are left alone: removing them would make
    # the App of Apps prune their Applications.
    if [ ${#selected_components[@]} -eq 0 ]; then
        print_info "No components selected — rendered current/common/ only (name components or use --all-components)"
    fi
    for component in ${selected_components[@]+"${selected_components[@]}"}; do
        while IFS= read -r -d '' file; do
            yaml_files+=("$file")
        done < <(find "${AVAILABLE_DIR}/${component}" -name "*.yaml" -print0 2>/dev/null)
    done

    local skipped_files=0
    for file in ${yaml_files[@]+"${yaml_files[@]}"}; do
        local rel="${file#"$AVAILABLE_DIR/"}"
        local dst="${CURRENT_DIR}/${rel}"
        # values*.yaml in current/ may hold hand edits: keep them unless --force.
        # The Application manifest is always refreshed.
        if [[ "$(basename "$file")" == values*.yaml ]] && [ -f "$dst" ] && [ "$FORCE_VALUES" != "true" ]; then
            print_warning "  Kept existing current/${rel} (use --force to overwrite)"
            skipped_files=$((skipped_files + 1))
            continue
        fi
        if render_yaml_file "$file" "$dst"; then
            processed_files=$((processed_files + 1))
        else
            failed_files=$((failed_files + 1))
        fi
    done

    # The kit only uses registry.tecnisys.com.br: flag dev-registry refs (comments aside)
    local dev_refs
    dev_refs=$(grep -rnE 'registry\.engtecnisys\.com\.br|/tdp-dev/' "$CURRENT_DIR" --include='*.yaml' 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    if [ -n "$dev_refs" ]; then
        print_warning "current/ references the dev registry; the kit must only use registry.tecnisys.com.br:"
        echo "$dev_refs" | head -10
    fi

    print_success "Rendered $processed_files files to current/"
    [ $skipped_files -gt 0 ] && print_info "Kept $skipped_files existing values files"
    [ $failed_files -gt 0 ] && print_warning "Failed to render $failed_files files"
    return $failed_files
}

# Function to list every component in the available/ catalog
list_components() {
    find "$AVAILABLE_DIR" -mindepth 1 -maxdepth 1 -type d -name "tdp-*" -exec basename {} \; | sort
}

# Function to apply manifests to Kubernetes
# Reads from current/ (rendered) if available, otherwise renders on the fly from available/
apply_manifests() {
    local apply_common="${1:-true}"
    local apply_available="${2:-false}"
    local selected_components=()
    [ $# -ge 3 ] && selected_components=("${@:3}")
    
    print_info "Applying manifests to Kubernetes..."
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_info "Please check your kubectl configuration"
        exit 1
    fi
    
    # Apply common resources (rendered to current/common/ or from common/ directly)
    if [ "$apply_common" = "true" ]; then
        local common_src="${CURRENT_DIR}/common"
        [ ! -d "$common_src" ] && common_src="$COMMON_DIR"
        print_info "Applying common resources from: $common_src"
        # The image pull secret lives in the components' namespace
        if ! kubectl get namespace "${TDP_NAMESPACE}" &>/dev/null; then
            print_info "Creating namespace: ${TDP_NAMESPACE}"
            kubectl create namespace "${TDP_NAMESPACE}"
        fi
        # The App of Apps goes last: applied before the AppProject and the repo
        # Secrets, ArgoCD reports "project ... does not exist" / auth errors on it.
        local app_of_apps="$common_src/argo-gitops-app-of-apps.yaml"
        local common_files=()
        for file in "$common_src"/*.yaml; do
            [ -f "$file" ] && [ "$file" != "$app_of_apps" ] && common_files+=("$file")
        done
        [ -f "$app_of_apps" ] && common_files+=("$app_of_apps")
        for file in ${common_files[@]+"${common_files[@]}"}; do
            # Don't replace a tdp-registry Secret someone created by hand (it may
            # cover more registries) unless --force.
            if [ "$(basename "$file")" = "tdp-image-pull-secret.yaml" ] && [ "$FORCE_VALUES" != "true" ] \
                && kubectl -n "${TDP_NAMESPACE}" get secret tdp-registry &>/dev/null; then
                print_warning "  Kept existing secret ${TDP_NAMESPACE}/tdp-registry (use --force to replace it)"
                continue
            fi
            kubectl apply -f "$file" && print_info "  ✓ $(basename "$file")"
        done
    fi
    
    # Apply Application manifests (from current/ if rendered, else render on-the-fly)
    if [ "$apply_available" = "true" ]; then
        if [ ${#selected_components[@]} -eq 0 ]; then
            print_warning "No components selected — nothing to apply (name components or use --all-components)"
        else
            print_info "Applying selected components: ${selected_components[*]}"
            for component in "${selected_components[@]}"; do
                local rendered="${CURRENT_DIR}/${component}/${component}.yaml"
                local template="${AVAILABLE_DIR}/${component}/${component}.yaml"
                
                if [ -f "$rendered" ]; then
                    print_info "  Applying (rendered): $rendered"
                    kubectl apply -f "$rendered"
                elif [ -f "$template" ]; then
                    print_info "  Applying (on-the-fly): $template"
                    local tmp
                    tmp=$(mktemp)
                    render_yaml_file "$template" "$tmp" && kubectl apply -f "$tmp"
                    rm -f "$tmp"
                else
                    print_warning "  Component not found: $component"
                fi
            done
        fi
    fi
    
    print_success "Manifests applied successfully"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMPONENTS... | --all-components]

Renders common/ (and the selected components from available/) into current/,
then applies them with kubectl unless -p is given. Without arguments, prints
this help. Without components, only current/common/ is rendered.

Options:
  -h, --help              Show this help message
  --install               Install ArgoCD (tdp-crds + tdp-argo) then apply common resources;
                          the UI is exposed at argo.DOMAIN per -e/TDP_EXPOSE
  -p, --render-only       Render templates to current/ only (no apply)
  -c, --common-only       Apply common resources only (AppProject + Secrets + App of Apps)
  -a, --available-only    Apply the selected components' Application manifests only
  --all-components        Select every component in available/
  -d, --domain DOMAIN     Domain for Ingress/Gateway API hostnames (<component>.DOMAIN);
                          overrides TDP_DOMAIN from the variables file
  -e, --expose MODE       How components are exposed: ingress, gatewayapi or none;
                          overrides TDP_EXPOSE (gatewayapi needs TDP_GATEWAY_NAME)
  -v, --variables FILE    Use custom variables file (default: variables.env)
  -f, --force             Overwrite existing current/<component>/values*.yaml
                          (kept by default, as they may hold local edits) and
                          replace an existing tdp-registry pull secret in TDP_NAMESPACE
  -r, --restore           Legacy no-op
  -b, --no-backup         Legacy no-op

Rendering only adds or refreshes files: components already in current/ but not
selected are left alone, so the App of Apps does not prune them.

Deployment Modes:

  FIRST TIME SETUP — installs ArgoCD and bootstraps GitOps:
    $0 --install -v variables.env.local   # Install ArgoCD + apply common resources
    git add current/ && git push          # Publish rendered manifests for App of Apps

  GITOPS (after bootstrap) — App of Apps reads current/ from git automatically:
    $0 -p -v variables.env.local tdp-postgresql tdp-trino   # Render components, then git push
    $0 -p -v variables.env.local --all-components            # Render every component
    $0 -c -v variables.env.local                             # Re-apply common resources only

  DIRECT — apply Applications directly via kubectl (no git push needed):
    $0 -a -v variables.env.local tdp-postgresql              # Render + apply one component
    $0 -a -v variables.env.local --all-components            # Render + apply every component

Examples:
  $0 --install -v variables.env.local                        # Full first-time setup
  $0 -p -v variables.env.local -d example.com --all-components  # Hosts like airflow.example.com
  $0 -p -v variables.env.local -e ingress --force tdp-trino      # Expose Trino through an Ingress
  $0 -p -v variables.env.local && git add current/ && git push  # Refresh current/common only

Components:
EOF
    
    if [ -d "$AVAILABLE_DIR" ]; then
        list_components
    fi
}

# Main script execution
main() {
    local render_only=false
    local apply_common=true
    local apply_available=false
    local install_mode=false
    local all_components=false
    local common_only=false
    local selected_components=()

    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -r|--restore)
                print_warning "--restore is a legacy no-op. Templates in available/ are never modified."
                exit 0
                ;;
            --install)
                install_mode=true
                shift
                ;;
            -p|--render-only|--process-only)
                render_only=true
                shift
                ;;
            -c|--common-only)
                common_only=true
                apply_common=true
                apply_available=false
                shift
                ;;
            -a|--available-only)
                apply_common=false
                apply_available=true
                shift
                ;;
            --all-components)
                all_components=true
                shift
                ;;
            -d|--domain)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    print_error "$1 needs a domain (e.g. $1 example.com)"
                    exit 1
                fi
                DOMAIN_OVERRIDE="$2"
                shift 2
                ;;
            -e|--expose)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    print_error "$1 needs a mode: ingress, gatewayapi or none"
                    exit 1
                fi
                EXPOSE_OVERRIDE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_VALUES=true
                shift
                ;;
            -b|--no-backup)
                shift
                ;;
            -v|--variables)
                if [ -z "${2:-}" ]; then
                    print_error "$1 needs a file"
                    exit 1
                fi
                VARIABLES_FILE="$2"
                [[ "$VARIABLES_FILE" != /* ]] && VARIABLES_FILE="$(pwd)/$VARIABLES_FILE"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                selected_components+=("$1")
                shift
                ;;
        esac
    done

    if [ "$all_components" = "true" ]; then
        if [ ${#selected_components[@]} -gt 0 ]; then
            print_error "Use either component names or --all-components, not both"
            exit 1
        fi
        while IFS= read -r component; do
            selected_components+=("$component")
        done < <(list_components)
    fi

    local component
    for component in ${selected_components[@]+"${selected_components[@]}"}; do
        if [ ! -d "${AVAILABLE_DIR}/${component}" ]; then
            print_error "Unknown component: $component (see $0 --help for the list)"
            exit 1
        fi
    done
    
    print_info "TDP GitOps Deployment Script"
    print_info "============================"
    
    check_dependencies "$render_only" "$install_mode"
    validate_variables_file

    # --install: install ArgoCD (CRDs + tdp-argo) before applying common resources
    if [ "$install_mode" = "true" ]; then
        install_argocd
        # After install, fall through to render + apply common
    fi
    
    # Render common/ + selected components → current/ (templates stay untouched)
    render_to_current ${selected_components[@]+"${selected_components[@]}"}

    # Apply manifests if not process-only. Plain runs (no -c/-a) apply common
    # resources plus any selected components.
    if [ "$render_only" = "false" ]; then
        if [ "$common_only" = "false" ] && [ ${#selected_components[@]} -gt 0 ]; then
            apply_available=true
        fi
        apply_manifests "$apply_common" "$apply_available" ${selected_components[@]+"${selected_components[@]}"}
    else
        print_info "Processing completed. Run without -p to apply manifests."
    fi
    
    print_success "Deployment completed successfully!"

    print_warning "Some values files ship with example passwords (tdp-ranger, tdp-cloudbeaver, tdp-jupyter, tdp-airflow, and the change-me-* ones in */values-integration.yaml) — change them before using this in a real environment."

    cat << EOF

Next steps:
1. Check application status:
   kubectl get applications -n ${ARGOCD_NAMESPACE:-argocd}

2. Monitor deployment:
   kubectl get pods -n ${TDP_NAMESPACE:-tdp-testes}

3. Check ArgoCD UI for detailed status

EOF
}

# Run main function with all arguments
main "$@"