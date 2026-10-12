output "state_bucket" {
  description = "Remote state bucket. Set as GitHub variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.tfstate.id
}

output "plan_role_arn" {
  description = "Set as GitHub variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as GitHub variable AWS_APPLY_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}

output "github_variables" {
  description = "Paste into GitHub > Settings > Secrets and variables > Actions > Variables."

  value = {
    AWS_REGION         = var.region
    TF_STATE_BUCKET    = aws_s3_bucket.tfstate.id
    AWS_PLAN_ROLE_ARN  = aws_iam_role.plan.arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.apply.arn
  }
}
