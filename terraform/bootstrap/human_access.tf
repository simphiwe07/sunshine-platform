# Human access roles, assigned to Identity Center groups through
# Account Access Manager (IAM console > Account access manager).
#
#   - Everyone logs in read-only by default.
#   - Admin (AccountFullAccessRole, AWS-managed) is an explicit elevation.
#   - Terraform-managed resources are changed by CI, not by humans.
#
# Trust policy is reused from the AWS-provisioned AccountFullAccessRole,
# which is already assignable through Account Access Manager.

data "aws_iam_role" "account_access_reference" {
  name = var.account_access_reference_role
}

resource "aws_iam_role" "human_readonly" {
  name                 = "${var.prefix}-human-readonly"
  description          = "Humans: read-only access (default login). Assigned via Account Access Manager."
  assume_role_policy   = data.aws_iam_role.account_access_reference.assume_role_policy
  max_session_duration = 43200 # 12h - AWS Settings requests 12h sessions for custom roles
}

# ReadOnlyAccess can read data (e.g. s3:GetObject). Use ViewOnlyAccess for "config, not data".
resource "aws_iam_role_policy_attachment" "human_readonly" {
  role       = aws_iam_role.human_readonly.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

output "human_readonly_role_name" {
  description = "Role name to enter in Account Access Manager > Assign new access."
  value       = aws_iam_role.human_readonly.name
}
