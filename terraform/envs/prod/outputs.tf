# The deploy scripts read these with `tofu output -raw <name>`. Renaming one
# breaks terraform/scripts/*.sh -- update both together.

output "aws_region" {
  description = "Region the app resources live in."
  value       = data.aws_region.current.region
}

output "backend_ecr_repository_url" {
  description = "Image repository the backend deploy pushes to."
  value       = aws_ecr_repository.backend.repository_url
}

output "backend_ecs_cluster_name" {
  description = "ECS cluster running the backend service. Shared with the aolf stack."
  value       = data.aws_ecs_cluster.shared.cluster_name
}

output "backend_ecs_service_name" {
  description = "ECS service to roll on deploy."
  value       = aws_ecs_service.backend.name
}

output "backend_task_definition_arn" {
  description = "Task definition used for one-off tasks such as migrations."
  value       = aws_ecs_task_definition.backend.arn
}

output "backend_security_group_id" {
  description = "Security group for one-off backend tasks."
  value       = aws_security_group.backend_tasks.id
}

output "backend_subnet_ids" {
  description = "Subnets for one-off backend tasks."
  value       = sort(tolist(var.app_subnet_ids))
}

output "backend_log_group_name" {
  description = "CloudWatch log group holding backend task logs."
  value       = aws_cloudwatch_log_group.backend.name
}

output "frontend_bucket_name" {
  description = "Bucket the frontend build is synced to."
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "Distribution to invalidate after a frontend deploy."
  value       = aws_cloudfront_distribution.app.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name. Point the app_hostname DNS record here."
  value       = aws_cloudfront_distribution.app.domain_name
}

output "app_url" {
  description = "Public URL for the app. The CloudFront domain until app_hostname is set."
  value       = "https://${var.app_hostname == "" ? aws_cloudfront_distribution.app.domain_name : var.app_hostname}"
}

output "app_secret_arns" {
  description = "Secrets Manager entries whose values must be written outside OpenTofu."
  value       = { for name, secret in aws_secretsmanager_secret.app : name => secret.arn }
}

output "github_actions_frontend_role_arn" {
  description = "Role ARN for the frontend deploy workflow."
  value       = aws_iam_role.github_actions_frontend.arn
}

output "github_actions_backend_role_arn" {
  description = "Role ARN for the backend deploy workflow."
  value       = aws_iam_role.github_actions_backend.arn
}
