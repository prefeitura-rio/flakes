terragrunt_version_constraint = ">= 1.1.0, < 2.0.0"
terraform_version_constraint  = ">= 1.10.0, < 2.0.0"

locals {
  project_dir = dirname(find_in_parent_folders(".project.json"))
  units_dir   = "${local.project_dir}/units"
  project     = jsondecode(file("${local.project_dir}/.project.json"))

  segments    = split("/", trimprefix(get_terragrunt_dir(), "${local.units_dir}/"))
  module      = local.segments[0]
  key         = try(local.segments[1], "default")
  environment = local.key == "stg" ? "staging" : local.key
  settings    = local.project.env[local.key]

  module_dir   = "${local.project_dir}/modules/${local.module}"
  declared     = flatten([for name in fileset(local.module_dir, "*.tf") : regexall("(?m)^variable\\s+\"([^\"]+)\"", file("${local.module_dir}/${name}"))])
  secrets_file = fileexists("${get_terragrunt_dir()}/default.tfvars.sops.json") ? "${get_terragrunt_dir()}/default.tfvars.sops.json" : "${local.units_dir}/${local.key}.tfvars.sops.json"
  secrets      = jsondecode(sops_decrypt_file(local.secrets_file))

  candidates = merge(local.secrets, {
    environment = local.environment
    project_id  = local.settings.project
    region      = local.settings.region
  })

  state_prefix = length(local.segments) > 1 ? "${local.project.state_prefix}/${local.environment}/${local.module}" : "${local.project.state_prefix}/${local.module}"
}

remote_state {
  backend = "gcs"

  config = {
    bucket               = "iplanrio-terraform-state"
    prefix               = local.state_prefix
    skip_bucket_creation = true
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

terraform {
  source = local.module_dir
}

inputs = { for key, value in local.candidates : key => value if contains(local.declared, key) }
