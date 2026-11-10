output "plan_role_arn" {
  description = "Role the terraform plan job assumes (read-only)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role the terraform apply job assumes (lab environment only)."
  value       = aws_iam_role.apply.arn
}

output "backup_writer_role_arn" {
  description = "Role the nightly offsite job assumes (backup environment only, PutObject on the prefix)."
  value       = aws_iam_role.backup_writer.arn
}

output "restore_reader_role_arn" {
  description = "Role the weekly restore test assumes (restore environment only, read-only on the prefix)."
  value       = aws_iam_role.restore_reader.arn
}
