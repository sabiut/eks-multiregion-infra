# An IAM role that GitHub Actions can assume with OIDC. No AWS keys are stored in GitHub.
#
# How it works: a workflow asks GitHub for a short-lived token. The token says which
# repository, branch or environment the job runs in (the "sub" claim). AWS checks the token
# against the trust policy below and hands back temporary credentials for the role.

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs whose "sub" claim matches one of these may assume the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json
  # Building a region (network, then EKS) can take longer than the default one hour.
  max_session_duration = 7200
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy == null ? 0 : 1
  role   = aws_iam_role.this.id
  policy = jsonencode({ Version = "2012-10-17", Statement = var.inline_policy })
}
