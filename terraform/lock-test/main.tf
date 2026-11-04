# Throwaway config whose only job is to hold the state lock for 20 seconds.
terraform {
  required_version = ">= 1.10"

  backend "pg" {
    schema_name = "locktest"
  }
}

resource "terraform_data" "hold_lock" {
  triggers_replace = timestamp()

  provisioner "local-exec" {
    command = "sleep 20"
  }
}
