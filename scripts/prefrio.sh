info()    { echo -e "\033[36m[>]\033[0m $*"; }
success() { echo -e "\033[32m[ok]\033[0m $*"; }
error()   { echo -e "\033[31m[x]\033[0m $*" >&2; }
warning() { echo -e "\033[33m[!]\033[0m $*"; }

usage() {
  cat <<'EOF'
Usage: prefrio <command> [args]

Commands:
  auth          Authenticate with Google Cloud
  fmt           Format Terraform files
  validate      Validate Terraform configuration
  validate-env  Check ENV is staging or prod
  init          Force Terraform backend init
  plan          Run Terraform plan
  apply         Run Terraform apply
  destroy       Run Terraform destroy
  import        Import a resource into Terraform state
  check-tfvars  Fail if unencrypted tfvars are staged
  edit-tfvars   Edit SOPS-encrypted tfvars
  k8s           Fetch Kubernetes credentials
  clean         Remove local Terraform files
EOF
}

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

run_tofu() {
  # Internal: run any tofu subcommand, routing through SOPS when TF_SOPS_FILE is set.
  # Uses printf '%q' to safely quote every interpolated value in the SOPS shell string.
  #
  # Arguments:
  #   $1     - tofu subcommand
  #   $@[2:] - extra tofu arguments (flags, addresses, ids, …)
  #
  # Environment:
  #   TF_SOPS_FILE   - SOPS-encrypted tfvars path (optional)
  #   TF_VARS_FILE   - plain tfvars path (optional)
  #   TF_ENVIRONMENT - value for -var=environment=... (optional; falls back to ENV)
  #   ENV            - fallback environment name when TF_ENVIRONMENT is unset (optional)
  #   TF_DIR         - tofu working directory (default: .)
  local subcommand="${1:?subcommand required}"
  shift
  local dir="${TF_DIR:-.}"
  local env="${TF_ENVIRONMENT:-${ENV:-}}"

  if [[ -z "${TF_SOPS_FILE:-}" ]]; then
    local args=()
    [[ -n "${TF_VARS_FILE:-}" ]] && args+=(-var-file "$TF_VARS_FILE")
    tofu -chdir="$dir" "$subcommand" "${args[@]}" "$@"
    return 0
  fi

  local tf_cmd
  tf_cmd="tofu -chdir=$(printf '%q' "$dir") $subcommand -var-file={}"
  [[ -n "$env" ]] && tf_cmd+=" -var=environment=$(printf '%q' "$env")"
  for arg in "$@"; do
    tf_cmd+=" $(printf '%q' "$arg")"
  done
  sops exec-file --output-type json --filename tfvars.json "$TF_SOPS_FILE" "$tf_cmd"
}

plan() {
  # Run tofu plan and write the result to tofu.tfplan.
  #
  # Environment: TF_SOPS_FILE, TF_VARS_FILE, TF_ENVIRONMENT, ENV, TF_DIR
  info "Running Terraform plan..."
  run_tofu plan -out tofu.tfplan
  success "Plan completed"
}

apply() {
  # Run tofu apply.
  #
  # Environment: TF_SOPS_FILE, TF_VARS_FILE, TF_ENVIRONMENT, ENV, TF_AUTO_APPROVE, TF_DIR
  info "Running Terraform apply..."
  local args=()
  [[ -n "${TF_AUTO_APPROVE:-}" ]] && args+=(--auto-approve)
  run_tofu apply "${args[@]}"
  success "Apply completed"
}

destroy() {
  # Run tofu destroy.
  #
  # Environment: TF_SOPS_FILE, TF_VARS_FILE, TF_ENVIRONMENT, ENV, TF_DIR
  warning "Running Terraform destroy..."
  run_tofu destroy
  success "Destroy completed"
}

import() {
  # Import an existing resource into Terraform state.
  #
  # Arguments:
  #   $1 - resource address (e.g. module.foo.google_compute_instance.bar)
  #   $2 - resource id
  #
  # Environment: TF_SOPS_FILE, TF_VARS_FILE, TF_ENVIRONMENT, ENV, TF_DIR
  local address="${1:?address required}"
  local id="${2:?id required}"
  info "Importing ${address}..."
  run_tofu import "$address" "$id"
  success "Import completed"
}

check_tfvars() {
  # Fail if any staged file matches the given pattern.
  # Intended as a pre-commit guard against committing unencrypted tfvars.
  #
  # Arguments:
  #   $1 - extended regex pattern matching unencrypted tfvars filenames
  local pattern="${1:?pattern required}"
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
  #   $1  - cluster name
  #   $2  - GCP region
  #   $3  - GCP project
  #   $4+ - extra flags passed to gcloud (e.g. --dns-endpoint application)
  local cluster="${1:?cluster required}"
  local region="${2:?region required}"
  local project="${3:?project required}"

  info "Fetching Kubernetes credentials..."
  gcloud container clusters get-credentials "$cluster" --region="$region" --project="$project" "${@:4}"
  success "Credentials configured"
}

clean() {
  # Remove local Terraform files and plugin cache.
  #
  # Environment:
  #   TF_DIR - tofu working directory (default: .)
  info "Cleaning local Terraform files..."
  rm -rf "${TF_DIR:-.}/.terraform" \
         "${TF_DIR:-.}/terraform.tfstate"* \
         "${TF_DIR:-.}/tofu.tfplan"
  warning "Removing global Terraform plugin cache (~/.terraform.d/plugin-cache)..."
  rm -rf ~/.terraform.d/plugin-cache
  success "Terraform environment cleaned"
}

case "${1:-}" in
  "" | -h | --help)  usage;     exit 0 ;;
  auth)              auth ;;
  fmt)               fmt ;;
  validate)          validate ;;
  validate-env)      validate_env ;;
  init)              init ;;
  plan)              plan ;;
  apply)             apply ;;
  destroy)           destroy ;;
  import)            import "${@:2}" ;;
  check-tfvars)      check_tfvars "${@:2}" ;;
  edit-tfvars)       edit_tfvars ;;
  k8s)               k8s "${@:2}" ;;
  clean)             clean ;;
  *)                 usage >&2; exit 2 ;;
esac
