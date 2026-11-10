variable "region" {
  description = "Home region for sre-lab AWS resources."
  type        = string
  default     = "us-east-2"
}

# Repositories created after 2026-07-15 get GitHub's immutable OIDC subject format:
#   repo:OWNER@OWNER_ID/REPO@REPO_ID:<context>
# The numeric IDs never change or get reused, so a deleted-and-recreated repo with the same name
# cannot match these trust policies. IDs: `curl -s https://api.github.com/repos/OWNER/REPO`
# (.owner.id, .id).
variable "github_repo" {
  description = "Owner, repository and their immutable numeric IDs; the workflows of this repository may assume the CI roles."
  type = object({
    owner    = string
    owner_id = number
    name     = string
    id       = number
  })
  default = {
    owner    = "NoelLucasIO"
    owner_id = 352547848
    name     = "sre-lab"
    id       = 1445998674
  }
}

variable "apply_environment" {
  description = "GitHub environment (with a required reviewer) whose jobs may assume the apply role."
  type        = string
  default     = "lab"
}

variable "backup_environment" {
  description = "GitHub environment (main only, no reviewer: scheduled) whose jobs may assume the backup writer role."
  type        = string
  default     = "backup"
}

variable "restore_environment" {
  description = "GitHub environment (main only, no reviewer: scheduled) whose jobs may assume the restore reader role."
  type        = string
  default     = "restore"
}

variable "backup_prefix" {
  description = "Key prefix in the backup bucket that the backup roles may reach."
  type        = string
  default     = "nightscout/live/"
}
