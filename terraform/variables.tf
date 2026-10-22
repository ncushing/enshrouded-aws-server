variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name. The deploy-role policy in bootstrap/ is scoped to this prefix."
  type        = string
  default     = "enshrouded"
}

variable "instance_type" {
  description = "4 vCPU / 16 GB is the comfortable size for up to ~16 players."
  type        = string
  default     = "m6i.xlarge"
}

variable "data_volume_size_gb" {
  description = "Game files (~13 GB), saves and update headroom."
  type        = number
  default     = 50
}

variable "allowed_cidrs" {
  description = "Who may reach the game port. Restrict to your friends' IPs if they are static."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "server_name" {
  type    = string
  default = "Enshrouded Server"
}

variable "slot_count" {
  type    = number
  default = 8
}

variable "idle_minutes" {
  description = "Minutes with zero players before the instance shuts itself down."
  type        = number
  default     = 30
}

variable "max_uptime_hours" {
  description = "Hard cap on a single run, in case the idle watcher misbehaves."
  type        = number
  default     = 12
}

variable "snapshot_retention_days" {
  type    = number
  default = 7
}

variable "monthly_budget_usd" {
  type    = number
  default = 40
}

variable "budget_email" {
  description = "Email for budget alerts."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional. ARN of the boundary policy from bootstrap/; applied to every IAM role this stack creates."
  type        = string
  default     = ""
}

# --- Discord ---------------------------------------------------------------
variable "discord_public_key" {
  description = "Application public key (hex) from the Discord developer portal. Not secret."
  type        = string
}

variable "discord_guild_id" {
  type = string
}

variable "discord_channel_id" {
  description = "The only channel where the slash command is honoured."
  type        = string
}

variable "discord_player_role_ids" {
  description = "Roles allowed to run /enshrouded start and status. Empty list = any member of the channel."
  type        = list(string)
  default     = []
}

variable "discord_admin_role_ids" {
  description = "Roles allowed to run /enshrouded stop (they can also start)."
  type        = list(string)
}

variable "shutdown_snapshot_retention_days" {
  description = "How long to keep the snapshots taken after each shutdown."
  type        = number
  default     = 14
}

variable "shutdown_snapshot_min_keep" {
  description = "Always keep at least this many post-shutdown snapshots, regardless of age."
  type        = number
  default     = 3
}
