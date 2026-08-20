# Secret containers only -- values are written outside OpenTofu so they never
# land in the state file. See the deploy-aws skill for the CLI commands.

resource "aws_secretsmanager_secret" "app" {
  for_each = var.app_secret_names

  name        = "/${var.app_name}/${var.environment}/${each.key}"
  description = "Runtime secret for the ${var.app_name} ${var.environment} app: ${each.key}."

  # Zero means immediate deletion on destroy. Anything higher blocks recreating
  # a secret of the same name until the recovery window elapses, which turns a
  # routine re-apply into a multi-day wait.
  recovery_window_in_days = 7

  tags = {
    Name          = "/${var.app_name}/${var.environment}/${each.key}"
    SecretPurpose = each.key
  }
}

resource "aws_ssm_parameter" "app_config" {
  for_each = var.app_config_parameters

  name        = "/${var.app_name}/${var.environment}/${each.key}"
  description = "Non-secret runtime config for the ${var.app_name} ${var.environment} app: ${each.key}."
  type        = "String"
  value       = each.value

  tags = {
    Name          = "/${var.app_name}/${var.environment}/${each.key}"
    ConfigPurpose = each.key
  }
}
