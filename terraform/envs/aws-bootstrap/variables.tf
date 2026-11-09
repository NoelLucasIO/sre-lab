variable "region" {
  description = "Home region for sre-lab AWS resources."
  type        = string
  default     = "us-east-2"
}

variable "github_repo" {
  description = "owner/name of the repository whose workflows may assume the CI roles."
  type        = string
  default     = "NoelLucasIO/sre-lab"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must be owner/name."
  }
}

variable "apply_environment" {
  description = "GitHub environment (with a required reviewer) whose jobs may assume the apply role."
  type        = string
  default     = "lab"
}
