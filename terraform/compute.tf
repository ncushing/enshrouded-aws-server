data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = var.name_prefix }
}

# Persistent world + game files. Survives instance replacement.
resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name   = "${var.name_prefix}-data"
    Backup = var.name_prefix
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "server" {
  ami                                  = data.aws_ssm_parameter.ubuntu_ami.insecure_value
  instance_type                        = var.instance_type
  subnet_id                            = aws_subnet.public.id
  vpc_security_group_ids               = [aws_security_group.server.id]
  iam_instance_profile                 = aws_iam_instance_profile.server.name
  instance_initiated_shutdown_behavior = "stop"
  monitoring                           = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach IMDS
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    bucket           = aws_s3_bucket.config.id
    region           = var.region
    param_prefix     = local.param_prefix
    volume_id_nodash = replace(aws_ebs_volume.data.id, "-", "")
  })

  tags = { Name = var.name_prefix }

  # user_data only matters on first boot; the AMI parameter moves over time.
  # Ignoring both stops a routine plan from proposing to replace the server.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_s3_object.instance_files,
    aws_s3_object.server_env,
    aws_s3_object.idle_env,
  ]
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.server.id
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id

  depends_on = [aws_internet_gateway.main]
}
