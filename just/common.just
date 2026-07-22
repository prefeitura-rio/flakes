set quiet
set shell := ["bash", "-euo", "pipefail", "-c"]

info    := '\033[36m[>]\033[0m'
success := '\033[32m[ok]\033[0m'
error   := '\033[31m[x]\033[0m'
warning := '\033[33m[!]\033[0m'
tfdir   := env("TF_DIR", ".")

[private]
validate-env:
    [[ "{{ env }}" == "staging" || "{{ env }}" == "prod" ]] \
      || { echo -e "{{ error }} ENV must be 'staging' or 'prod', got '{{ env }}'"; exit 1; }

# Format Terraform files
fmt:
    echo -e "{{ info }} Formatting Terraform files..."
    terraform -chdir={{ tfdir }} fmt -recursive
    echo -e "{{ success }} Formatting completed"

# Validate Terraform configuration
validate: ensure-init
    echo -e "{{ info }} Validating Terraform configuration..."
    terraform -chdir={{ tfdir }} validate
    echo -e "{{ success }} Validation completed"
