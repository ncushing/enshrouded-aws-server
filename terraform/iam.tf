locals {
  boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
}

# ---------------------------------------------------------------- instance
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name                 = "${var.name_prefix}-instance"
  assume_role_policy   = data.aws_iam_policy_document.ec2_trust.json
  permissions_boundary = local.boundary
}

resource "aws_iam_role_policy_attachment" "server_ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "server" {
  statement {
    sid       = "ReadConfig"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.config.arn}/instance/*"]
  }

  statement {
    sid       = "ListConfig"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.config.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["instance/*", "instance"]
    }
  }

  # SecureString parameters use the AWS-managed aws/ssm key, which needs no
  # separate kms:Decrypt grant for principals in this account.
  statement {
    sid       = "ReadSecrets"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.param_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "server" {
  name   = "config-and-secrets"
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.server.name
}

# ------------------------------------------------------------------ lambda
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${var.name_prefix}-discord-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "StartStopThisServerOnly"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.server.arn]
  }

  # Describe* does not support resource-level permissions.
  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "start-stop-describe"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# --------------------------------------------------------------------- dlm
data "aws_iam_policy_document" "dlm_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name                 = "${var.name_prefix}-snapshots"
  assume_role_policy   = data.aws_iam_policy_document.dlm_trust.json
  permissions_boundary = local.boundary
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
