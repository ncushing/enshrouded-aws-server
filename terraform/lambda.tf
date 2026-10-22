data "archive_file" "discord" {
  type        = "zip"
  source_file = "${path.module}/../lambda/index.mjs"
  output_path = "${path.module}/.build/discord_handler.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-discord"
  retention_in_days = 14
}

resource "aws_lambda_function" "discord" {
  function_name    = "${var.name_prefix}-discord"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.discord.output_path
  source_code_hash = data.archive_file.discord.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      INSTANCE_ID        = aws_instance.server.id
      DISCORD_PUBLIC_KEY = var.discord_public_key
      ALLOWED_GUILD_ID   = var.discord_guild_id
      ALLOWED_CHANNEL_ID = var.discord_channel_id
      PLAYER_ROLE_IDS    = join(",", var.discord_player_role_ids)
      ADMIN_ROLE_IDS     = join(",", var.discord_admin_role_ids)
      SERVER_ADDRESS     = aws_eip.server.public_ip
      SERVER_PORT        = tostring(local.game_port)
      IDLE_MINUTES       = tostring(var.idle_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# Discord must be able to call this without AWS credentials. The handler
# rejects anything whose Ed25519 signature does not verify against Discord's
# public key. Since Oct 2025 a public URL needs BOTH permissions below.
resource "aws_lambda_function_url" "discord" {
  function_name      = aws_lambda_function.discord.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_url" {
  statement_id           = "AllowPublicFunctionUrl"
  function_name          = aws_lambda_function.discord.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_function" {
  statement_id             = "AllowPublicInvokeViaFunctionUrl"
  function_name            = aws_lambda_function.discord.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}
