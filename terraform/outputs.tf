output "discord_interactions_url" {
  description = "Paste into the Discord app's 'Interactions Endpoint URL'."
  value       = aws_lambda_function_url.discord.function_url
}

output "server_address" {
  description = "Direct-connect address once the server is running."
  value       = "${aws_eip.server.public_ip}:${local.game_port}"
}

output "instance_id" {
  value = aws_instance.server.id
}

output "config_bucket" {
  value = aws_s3_bucket.config.id
}

output "ssm_parameters_to_create" {
  description = "Create these by hand (SecureString); they never enter Terraform state."
  value = [
    "${local.param_prefix}/admin_password",
    "${local.param_prefix}/friends_password",
    "${local.param_prefix}/discord_webhook_url",
  ]
}
