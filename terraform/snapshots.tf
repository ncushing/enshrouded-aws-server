# Snapshot the data volume every time the instance reaches "stopped" (idle
# shutdown, /enshrouded stop, or the uptime cap). A stopped instance means a
# clean copy. The daily DLM policy in backup.tf stays as a second layer.

data "archive_file" "snapshot" {
  type        = "zip"
  source_file = "${path.module}/../lambda/snapshot.mjs"
  output_path = "${path.module}/.build/snapshot_handler.zip"
}

resource "aws_cloudwatch_log_group" "snapshot" {
  name              = "/aws/lambda/${var.name_prefix}-snapshot"
  retention_in_days = 14
}

data "aws_iam_policy_document" "snapshot" {
  statement {
    sid     = "SnapshotTheDataVolume"
    actions = ["ec2:CreateSnapshot"]
    resources = [
      aws_ebs_volume.data.arn,
      "arn:aws:ec2:${var.region}::snapshot/*",
    ]
  }

  statement {
    sid       = "TagOnlyNewSnapshots"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}::snapshot/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSnapshot"]
    }
  }

  # Describe* does not support resource-level permissions.
  statement {
    sid       = "ListSnapshots"
    actions   = ["ec2:DescribeSnapshots"]
    resources = ["*"]
  }

  statement {
    sid       = "DeleteOnlyOurPostShutdownSnapshots"
    actions   = ["ec2:DeleteSnapshot"]
    resources = ["arn:aws:ec2:${var.region}::snapshot/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/SnapshotKind"
      values   = ["post-shutdown"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.name_prefix]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.snapshot.arn}:*"]
  }
}

resource "aws_iam_role" "snapshot" {
  name                 = "${var.name_prefix}-snapshot-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary
}

resource "aws_iam_role_policy" "snapshot" {
  name   = "snapshot-and-prune"
  role   = aws_iam_role.snapshot.id
  policy = data.aws_iam_policy_document.snapshot.json
}

resource "aws_lambda_function" "snapshot" {
  function_name    = "${var.name_prefix}-snapshot"
  role             = aws_iam_role.snapshot.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "snapshot.handler"
  filename         = data.archive_file.snapshot.output_path
  source_code_hash = data.archive_file.snapshot.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      VOLUME_ID      = aws_ebs_volume.data.id
      PROJECT        = var.name_prefix
      RETENTION_DAYS = tostring(var.shutdown_snapshot_retention_days)
      MIN_KEEP       = tostring(var.shutdown_snapshot_min_keep)
    }
  }

  depends_on = [aws_cloudwatch_log_group.snapshot, aws_iam_role_policy.snapshot]
}

resource "aws_cloudwatch_event_rule" "stopped" {
  name        = "${var.name_prefix}-instance-stopped"
  description = "Fires when the Enshrouded instance reaches the stopped state"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      state         = ["stopped"]
      "instance-id" = [aws_instance.server.id]
    }
  })
}

resource "aws_cloudwatch_event_target" "stopped" {
  rule = aws_cloudwatch_event_rule.stopped.name
  arn  = aws_lambda_function.snapshot.arn
}

resource "aws_lambda_permission" "events_invoke_snapshot" {
  statement_id  = "AllowEventBridgeStoppedRule"
  function_name = aws_lambda_function.snapshot.function_name
  action        = "lambda:InvokeFunction"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stopped.arn
}
