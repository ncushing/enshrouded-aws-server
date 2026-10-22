# Daily snapshots of the data volume (world + game files).
resource "aws_dlm_lifecycle_policy" "data" {
  description        = "${var.name_prefix} daily data snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = var.name_prefix }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["08:00"] # UTC
      }

      retain_rule {
        count = var.snapshot_retention_days
      }

      copy_tags = true
    }
  }
}
