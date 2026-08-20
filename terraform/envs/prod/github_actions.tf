locals {
  github_oidc_url      = "https://token.actions.githubusercontent.com"
  github_deploy_sub    = "repo:${var.github_repository}:ref:refs/heads/${var.github_deploy_branch}"
  github_frontend_role = "${var.app_name}-${var.environment}-github-frontend-deploy"
  github_backend_role  = "${var.app_name}-${var.environment}-github-backend-deploy"
  opentofu_state_arn   = "arn:aws:s3:::${var.opentofu_state_bucket_name}"

  github_oidc_provider_arn = var.create_github_oidc_provider ? (
    aws_iam_openid_connect_provider.github_actions[0].arn
    ) : (
    data.aws_iam_openid_connect_provider.github_actions[0].arn
  )
}

# An AWS account holds at most one OIDC provider per issuer URL. If the
# aolf-warehouse stack already created it, reuse it -- creating a second one
# fails with EntityAlreadyExists.
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = {
    Name = "${var.app_name}-${var.environment}-github-actions"
  }
}

data "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = local.github_oidc_url
}

# Scoped to one repository AND one branch. Without the sub condition, any
# GitHub repository on the internet could assume these roles.
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_deploy_sub]
    }
  }
}

# Deploy scripts read resource names out of OpenTofu outputs, so CI needs read
# access to the state object -- and nothing more.
data "aws_iam_policy_document" "github_actions_state_read" {
  statement {
    sid = "ListOpenTofuStateBucket"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]

    resources = [local.opentofu_state_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        var.opentofu_state_key,
        "${var.opentofu_state_key}.tflock",
      ]
    }
  }

  statement {
    sid = "ReadOpenTofuState"

    actions = ["s3:GetObject"]

    resources = [
      "${local.opentofu_state_arn}/${var.opentofu_state_key}",
      "${local.opentofu_state_arn}/${var.opentofu_state_key}.tflock",
    ]
  }

  dynamic "statement" {
    for_each = var.opentofu_state_kms_key_arn == "" ? [] : [var.opentofu_state_kms_key_arn]

    content {
      sid       = "DecryptOpenTofuState"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
}

data "aws_iam_policy_document" "github_actions_frontend_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.github_actions_state_read.json]

  statement {
    sid = "PublishFrontendBuild"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.frontend.arn,
      "${aws_s3_bucket.frontend.arn}/*",
    ]
  }

  statement {
    sid = "RefreshCloudFront"

    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]

    resources = [aws_cloudfront_distribution.app.arn]
  }
}

resource "aws_iam_role" "github_actions_frontend" {
  name               = local.github_frontend_role
  description        = "Allows GitHub Actions on ${var.github_repository} ${var.github_deploy_branch} to publish frontend files."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

resource "aws_iam_role_policy" "github_actions_frontend" {
  name   = "${local.github_frontend_role}-policy"
  role   = aws_iam_role.github_actions_frontend.id
  policy = data.aws_iam_policy_document.github_actions_frontend_deploy.json
}

data "aws_iam_policy_document" "github_actions_backend_deploy" {
  source_policy_documents = [data.aws_iam_policy_document.github_actions_state_read.json]

  statement {
    sid = "AuthenticateToECR"

    # ecr:GetAuthorizationToken has no resource-level scoping; AWS requires "*".
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushBackendImage"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]

    resources = [aws_ecr_repository.backend.arn]
  }

  statement {
    sid = "RunBackendMigrationTask"

    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.backend_name}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [data.aws_ecs_cluster.shared.arn]
    }
  }

  statement {
    sid = "PassBackendTaskRoles"

    actions = ["iam:PassRole"]

    resources = [
      aws_iam_role.backend_execution.arn,
      aws_iam_role.backend_task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid = "RollBackendService"

    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]

    resources = [aws_ecs_service.backend.id]
  }

  statement {
    sid = "ReadBackendTasks"

    # ecs:DescribeTasks takes task ARNs that do not exist until run time, so
    # these two cannot be narrowed further.
    actions = [
      "ecs:DescribeTasks",
      "ecs:DescribeTaskDefinition",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role" "github_actions_backend" {
  name               = local.github_backend_role
  description        = "Allows GitHub Actions on ${var.github_repository} ${var.github_deploy_branch} to deploy the backend service."
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

resource "aws_iam_role_policy" "github_actions_backend" {
  name   = "${local.github_backend_role}-policy"
  role   = aws_iam_role.github_actions_backend.id
  policy = data.aws_iam_policy_document.github_actions_backend_deploy.json
}
