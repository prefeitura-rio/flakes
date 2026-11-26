let version = (complexipy --version | str trim)

if ($version | is-empty) {
  error make { msg: "complexipy did not report its version" }
}

print $"complexipy: ($version)"
