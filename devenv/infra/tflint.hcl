plugin "terraform" {
  enabled = true
  preset  = "all"
}

rule "terraform_unused_declarations" {
  enabled = false
}
