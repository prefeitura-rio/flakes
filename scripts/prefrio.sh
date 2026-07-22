info()    { echo -e "\033[36m[>]\033[0m $*"; }
success() { echo -e "\033[32m[ok]\033[0m $*"; }
error()   { echo -e "\033[31m[x]\033[0m $*" >&2; }
warning() { echo -e "\033[33m[!]\033[0m $*"; }

auth() {
  # Authenticate with Google Cloud and set the quota project.
  #
  # Environment:
  #   (none)
  info "Authenticating with Google Cloud..."
  gcloud auth login
  gcloud auth application-default login
  gcloud auth application-default set-quota-project rj-iplanrio-dia
  success "Authentication completed"
}

fmt() {
  # Format Terraform files recursively.
  #
  # Environment:
  #   TF_DIR - tofu working directory (default: .)
  info "Formatting Terraform files..."
  tofu -chdir="${TF_DIR:-.}" fmt -recursive
  success "Formatting completed"
}

validate() {
  # Validate Terraform configuration.
  #
  # Environment:
  #   TF_DIR - tofu working directory (default: .)
  info "Validating Terraform configuration..."
  tofu -chdir="${TF_DIR:-.}" validate
  success "Validation completed"
}

validate_env() {
  # Check that ENV is set to a valid value.
  #
  # Environment:
  #   ENV - must be 'staging' or 'prod'
  if [[ "${ENV:-}" != "staging" && "${ENV:-}" != "prod" ]]; then
    error "ENV must be 'staging' or 'prod', got '${ENV:-}'"
    exit 1
  fi
}

init() {
  # Force Terraform backend initialisation.
  #
  # Environment:
  #   TF_BACKEND_CONFIG - backend-config argument (e.g. prefix=foo/bar) (optional)
  #   TF_DIR            - tofu working directory (default: .)
  local args=()
  [[ -n "${TF_BACKEND_CONFIG:-}" ]] && args+=(-backend-config "$TF_BACKEND_CONFIG")

  info "Initializing Terraform..."
  tofu -chdir="${TF_DIR:-.}" init "${args[@]}" -upgrade -reconfigure
  success "Terraform initialized"
}

ensure_init() {
  # Initialise Terraform only if the backend is not already configured correctly.
  # When TF_BACKEND_CONFIG is set, the expected value is derived from it by
  # stripping the key prefix (e.g. prefix=foo/bar -> foo/bar).
  # When neither TF_BACKEND_EXPECTED nor TF_BACKEND_CONFIG is set, falls back
  # to checking whether the .terraform/terraform.tfstate file exists.
  #
  # Environment:
  #   TF_BACKEND_CONFIG   - backend-config argument (optional)
  #   TF_BACKEND_EXPECTED - expected value in tfstate backend config (optional)
  #   TF_DIR              - tofu working directory (default: .)
  local state="${TF_DIR:-.}/.terraform/terraform.tfstate"
  local expected="${TF_BACKEND_EXPECTED:-${TF_BACKEND_CONFIG#*=}}"

  if [[ -n "$expected" ]]; then
    local current
    current=$(jq -r '.backend.config.prefix // .backend.config.bucket // empty' "$state" 2>/dev/null || true)
    [[ "$current" == "$expected" ]] && info "Terraform already initialized, skipping" && return 0
    init
    return 0
  fi

  [[ -f "$state" ]] && info "Terraform already initialized, skipping" && return 0

  init
}

plan() {
  # Run tofu plan and write the result to tofu.tfplan.
  # Uses sops exec-file when TF_SOPS_FILE is set, plain tofu otherwise.
  #
  # Environment:
  #   TF_SOPS_FILE   - path to SOPS-encrypted tfvars (optional)
  #   TF_VARS_FILE   - path to plain tfvars (optional)
  #   TF_ENVIRONMENT - value for -var=environment=... (optional)
  #   TF_DIR         - tofu working directory (default: .)
  info "Running Terraform plan..."

  if [[ -z "${TF_SOPS_FILE:-}" ]]; then
    local args=()
    [[ -n "${TF_VARS_FILE:-}" ]] && args+=(-var-file "$TF_VARS_FILE")
    tofu -chdir="${TF_DIR:-.}" plan "${args[@]}" -out tofu.tfplan
    success "Plan completed"
    return 0
  fi

  local tf_cmd="tofu -chdir='${TF_DIR:-.}' plan -var-file={}"
  [[ -n "${TF_ENVIRONMENT:-}" ]] && tf_cmd+=" -var=environment=${TF_ENVIRONMENT}"
  tf_cmd+=" -out tofu.tfplan"
  sops exec-file --output-type json --filename tfvars.json "$TF_SOPS_FILE" "$tf_cmd"
  success "Plan completed"
}

apply() {
  # Run tofu apply.
  # Uses sops exec-file when TF_SOPS_FILE is set, plain tofu otherwise.
  #
  # Environment:
  #   TF_SOPS_FILE    - path to SOPS-encrypted tfvars (optional)
  #   TF_VARS_FILE    - path to plain tfvars (optional)
  #   TF_ENVIRONMENT  - value for -var=environment=... (optional)
  #   TF_AUTO_APPROVE - set to any non-empty value to pass --auto-approve (optional)
  #   TF_DIR          - tofu working directory (default: .)
  info "Running Terraform apply..."

  if [[ -z "${TF_SOPS_FILE:-}" ]]; then
    local args=()
    [[ -n "${TF_VARS_FILE:-}" ]]    && args+=(-var-file "$TF_VARS_FILE")
    [[ -n "${TF_AUTO_APPROVE:-}" ]] && args+=(--auto-approve)
    tofu -chdir="${TF_DIR:-.}" apply "${args[@]}"
    success "Apply completed"
    return 0
  fi

  local tf_cmd="tofu -chdir='${TF_DIR:-.}' apply -var-file={}"
  [[ -n "${TF_ENVIRONMENT:-}" ]]  && tf_cmd+=" -var=environment=${TF_ENVIRONMENT}"
  [[ -n "${TF_AUTO_APPROVE:-}" ]] && tf_cmd+=" --auto-approve"
  sops exec-file --output-type json --filename tfvars.json "$TF_SOPS_FILE" "$tf_cmd"
  success "Apply completed"
}

destroy() {
  # Run tofu destroy.
  # Uses sops exec-file when TF_SOPS_FILE is set, plain tofu otherwise.
  #
  # Environment:
  #   TF_SOPS_FILE   - path to SOPS-encrypted tfvars (optional)
  #   TF_VARS_FILE   - path to plain tfvars (optional)
  #   TF_ENVIRONMENT - value for -var=environment=... (optional)
  #   TF_DIR         - tofu working directory (default: .)
  warning "Running Terraform destroy..."

  if [[ -z "${TF_SOPS_FILE:-}" ]]; then
    local args=()
    [[ -n "${TF_VARS_FILE:-}" ]] && args+=(-var-file "$TF_VARS_FILE")
    tofu -chdir="${TF_DIR:-.}" destroy "${args[@]}"
    success "Destroy completed"
    return 0
  fi

  local tf_cmd="tofu -chdir='${TF_DIR:-.}' destroy -var-file={}"
  [[ -n "${TF_ENVIRONMENT:-}" ]] && tf_cmd+=" -var=environment=${TF_ENVIRONMENT}"
  sops exec-file --output-type json --filename tfvars.json "$TF_SOPS_FILE" "$tf_cmd"
  success "Destroy completed"
}

import() {
  # Import an existing resource into Terraform state.
  # Uses sops exec-file when TF_SOPS_FILE is set, plain tofu otherwise.
  #
  # Arguments:
  #   $2 - resource address (e.g. module.foo.google_compute_instance.bar)
  #   $3 - resource id
  #
  # Environment:
  #   TF_SOPS_FILE   - path to SOPS-encrypted tfvars (optional)
  #   TF_VARS_FILE   - path to plain tfvars (optional)
  #   TF_ENVIRONMENT - value for -var=environment=... (optional)
  #   TF_DIR         - tofu working directory (default: .)
  local address="${2:?address required}"
  local id="${3:?id required}"

  info "Importing ${address}..."

  if [[ -z "${TF_SOPS_FILE:-}" ]]; then
    local args=()
    [[ -n "${TF_VARS_FILE:-}" ]] && args+=(-var-file "$TF_VARS_FILE")
    tofu -chdir="${TF_DIR:-.}" import "${args[@]}" "$address" "$id"
    success "Import completed"
    return 0
  fi

  local tf_cmd="tofu -chdir='${TF_DIR:-.}' import -var-file={}"
  [[ -n "${TF_ENVIRONMENT:-}" ]] && tf_cmd+=" -var=environment=${TF_ENVIRONMENT}"
  tf_cmd+=" '${address}' '${id}'"
  sops exec-file --output-type json --filename tfvars.json "$TF_SOPS_FILE" "$tf_cmd"
  success "Import completed"
}

check_tfvars() {
  # Fail if any staged file matches the given pattern.
  # Intended as a pre-commit guard against committing unencrypted tfvars.
  #
  # Arguments:
  #   $2 - extended regex pattern matching unencrypted tfvars filenames
  local pattern="${2:?pattern required}"
  if git diff --cached --name-only | grep -qE "$pattern"; then
    error "Plaintext tfvars staged - encrypt with: prefrio edit-tfvars"
    exit 1
  fi
}

edit_tfvars() {
  # Open the SOPS-encrypted tfvars file for editing.
  #
  # Environment:
  #   TF_SOPS_FILE - path to SOPS-encrypted tfvars (required)
  [[ -z "${TF_SOPS_FILE:-}" ]] && error "TF_SOPS_FILE is not set" && exit 1
  sops edit --input-type json --output-type json "$TF_SOPS_FILE"
}

k8s() {
  # Fetch GKE credentials for a cluster.
  #
  # Arguments:
  #   $2  - cluster name
  #   $3  - GCP region
  #   $4  - GCP project
  #   $5+ - extra flags passed to gcloud (e.g. --dns-endpoint application)
  local cluster="${2:?cluster required}"
  local region="${3:?region required}"
  local project="${4:?project required}"

  info "Fetching Kubernetes credentials..."
  gcloud container clusters get-credentials "$cluster" --region="$region" --project="$project" "${@:5}"
  success "Credentials configured"
}

clean() {
  # Remove local Terraform files and plugin cache.
  #
  # Environment:
  #   TF_DIR - tofu working directory (default: .)
  info "Cleaning local Terraform files..."
  pkill -f tofu || true
  rm -rf "${TF_DIR:-.}/.terraform" \
         "${TF_DIR:-.}/terraform.tfstate"* \
         "${TF_DIR:-.}/tofu.tfplan"
  rm -rf ~/.terraform.d/plugin-cache
  success "Terraform environment cleaned"
}

case "${1:-}" in
  auth)         auth ;;
  fmt)          fmt ;;
  validate)     validate ;;
  validate-env) validate_env ;;
  ensure-init)  ensure_init ;;
  init)         init ;;
  plan)         plan ;;
  apply)        apply ;;
  destroy)      destroy ;;
  import)       import "$@" ;;
  check-tfvars) check_tfvars "$@" ;;
  edit-tfvars)  edit_tfvars ;;
  k8s)          k8s "$@" ;;
  clean)        clean ;;
  *)
    error "Usage: prefrio <command>"
    info  "Commands:"
    info  "  auth          Authenticate with Google Cloud"
    info  "  fmt           Format Terraform files"
    info  "  validate      Validate Terraform configuration"
    info  "  validate-env  Check ENV is staging or prod"
    info  "  ensure-init   Idempotent Terraform backend init"
    info  "  init          Force Terraform backend init"
    info  "  plan          Run Terraform plan"
    info  "  apply         Run Terraform apply"
    info  "  destroy       Run Terraform destroy"
    info  "  import        Import a resource into Terraform state"
    info  "  check-tfvars  Fail if unencrypted tfvars are staged"
    info  "  edit-tfvars   Edit SOPS-encrypted tfvars"
    info  "  k8s           Fetch Kubernetes credentials"
    info  "  clean         Remove local Terraform files"
    exit 1
    ;;
esac
