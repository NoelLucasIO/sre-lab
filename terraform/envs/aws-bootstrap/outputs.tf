output "plan_role_arn" {
  description = "Role the terraform plan job assumes (read-only)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role the terraform apply job assumes (lab environment only)."
  value       = aws_iam_role.apply.arn
}
