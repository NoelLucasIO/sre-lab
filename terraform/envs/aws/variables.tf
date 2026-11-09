variable "region" {
  description = "Home region for sre-lab AWS resources."
  type        = string
  default     = "us-east-2"
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD (credits excluded, so it tracks real usage)."
  type        = number
  default     = 5
}

# Kept out of this public repo: set TF_VAR_budget_email in ~/.config/terraform/aws.env.
variable "budget_email" {
  description = "Address that receives budget alerts."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_email))
    error_message = "budget_email must be an email address."
  }
}

variable "glacier_after_days" {
  description = "Days before backup objects move to S3 Glacier Flexible Retrieval."
  type        = number
  default     = 30
}

variable "expire_after_days" {
  description = "Days before backup objects are deleted."
  type        = number
  default     = 365

  validation {
    # Glacier Flexible Retrieval bills a 90-day minimum; deleting sooner after transition is paid anyway.
    condition     = var.expire_after_days >= var.glacier_after_days + 90
    error_message = "expire_after_days must be at least glacier_after_days + 90."
  }
}
