# Run from terraform/ (not the repo root, which would also lint the deliberately bad Checkov fixtures):
#   cd terraform && tflint --recursive --config "$PWD/../.tflint.hcl"
config {
  call_module_type = "local" # lint module calls in envs/ against modules/
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
