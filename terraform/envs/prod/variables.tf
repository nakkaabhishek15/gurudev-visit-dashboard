variable "aws_region" {
  description = "AWS region for the app resources. Must match the region of the existing RDS instance."
  type        = string
  default     = "ca-central-1"
}

variable "project" {
  description = "Project name used in tags."
  type        = string
  default     = "gurudev-visit-dashboard"
}

variable "app_name" {
  description = "Short name used as the prefix for every resource. Keep it under 12 characters: ALB and target group names cap at 32."
  type        = string
  default     = "gurudev"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Extra tags added to every managed resource."
  type        = map(string)
  default = {
    Owner = "aolf"
  }
}

# ---------------------------------------------------------------------------
# Existing network and database.
#
# This stack does NOT manage the RDS instance -- aolf-warehouse's OpenTofu state
# already owns it, and two states managing one resource will fight. Everything
# here is read-only apart from one security group ingress rule that lets these
# tasks reach Postgres.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC containing the RDS instance this app connects to."
  type        = string
  default     = "vpc-0fb8fac134273e760"
}

variable "app_subnet_ids" {
  description = "Subnets for the ALB and the Fargate tasks. Must be in at least two availability zones."
  type        = set(string)
  default = [
    "subnet-0745a7bfad355d019",
    "subnet-08c592984c8847b6e",
    "subnet-0627a15f599ebfb1a",
  ]
}

variable "rds_security_group_id" {
  description = "Security group attached to the RDS instance. This stack adds one ingress rule to it."
  type        = string
  default     = "sg-09467b39f074b63e3"
}

variable "rds_port" {
  description = "Postgres port on the RDS instance."
  type        = number
  default     = 5432
}

# ---------------------------------------------------------------------------
# Runtime configuration.
# ---------------------------------------------------------------------------

variable "app_secret_names" {
  description = "Secrets Manager entries created empty here. Write the values with the AWS CLI, never through OpenTofu -- values in OpenTofu end up in state."
  type        = set(string)
  default = [
    "database-url",
    "warehouse-database-url",
    "auth/session-secret",
  ]
}

variable "app_config_parameters" {
  description = "Non-secret runtime config kept in SSM Parameter Store. These values are visible in OpenTofu state, so do not put credentials here."
  type        = map(string)
  default     = {}
}

variable "backend_ecr_repository_name" {
  description = "Container image repository for the FastAPI backend."
  type        = string
  default     = "gurudev-backend"
}

variable "backend_image_tag" {
  description = "Image tag ECS should run. The deploy script pushes this tag before rolling the service."
  type        = string
  default     = "latest"
}

variable "backend_container_port" {
  description = "Port exposed by the FastAPI container."
  type        = number
  default     = 8000
}

variable "backend_task_cpu" {
  description = "CPU units for the backend Fargate task."
  type        = number
  default     = 256
}

variable "backend_task_memory" {
  description = "Memory in MiB for the backend Fargate task. Must be a valid pairing with backend_task_cpu."
  type        = number
  default     = 512
}

variable "backend_desired_count" {
  description = "Number of backend tasks to keep running."
  type        = number
  default     = 1
}

variable "backend_log_retention_days" {
  description = "CloudWatch log retention for backend task logs."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Public surface.
# ---------------------------------------------------------------------------

variable "frontend_bucket_name" {
  description = "Private S3 bucket for the static frontend build. Bucket names are globally unique."
  type        = string
}

variable "app_hostname" {
  description = <<-EOT
    Public hostname served by CloudFront, for example site.example.com. Leave
    empty to skip the custom domain: the distribution then answers on its own
    dxxxxxxxx.cloudfront.net name with the free CloudFront certificate, which
    needs no ACM request and no DNS record. Set it once DNS is ready.
  EOT
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "Issued ACM certificate ARN IN us-east-1 covering app_hostname. CloudFront rejects certificates from any other region. Required only when app_hostname is set."
  type        = string
  default     = ""

  validation {
    condition     = var.acm_certificate_arn == "" || can(regex("^arn:aws:acm:us-east-1:", var.acm_certificate_arn))
    error_message = "CloudFront only accepts certificates issued in us-east-1."
  }
}

# ---------------------------------------------------------------------------
# CI deploy identity.
# ---------------------------------------------------------------------------

variable "github_repository" {
  description = "GitHub repository allowed to deploy, as owner/name."
  type        = string
}

variable "github_deploy_branch" {
  description = "Branch allowed to assume the deploy roles."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. An AWS account can hold only one provider for token.actions.githubusercontent.com, and the aolf-warehouse stack already created it -- leave this false and the existing provider is reused."
  type        = bool
  default     = false
}

variable "github_oidc_thumbprints" {
  description = "Certificate thumbprints for GitHub's OIDC issuer. Only read when create_github_oidc_provider is true."
  type        = list(string)
  default = [
    "22ff89586561fc2d52f77491e9f1eff1b80be33e",
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

variable "opentofu_state_bucket_name" {
  description = "S3 bucket holding this stack's OpenTofu state. CI needs read access to it."
  type        = string
  default     = "aolf-opentofu-state-716156543359-ca-central-1"
}

variable "opentofu_state_key" {
  description = "S3 object key for this stack's state file."
  type        = string
  default     = "gurudev/prod/terraform.tfstate"
}

variable "opentofu_state_kms_key_arn" {
  description = "KMS key encrypting the state file. Leave empty when the bucket uses SSE-S3 rather than SSE-KMS."
  type        = string
  default     = "arn:aws:kms:ca-central-1:716156543359:key/0bf60b64-bf63-4a01-a88f-e01e906cafa8"
}

# ---------------------------------------------------------------------------
# Shared infrastructure owned by the aolf stack.
# ---------------------------------------------------------------------------

variable "ecs_cluster_name" {
  description = "Existing ECS cluster to run the service in. Clusters are a free logical grouping, so this stack joins the aolf one rather than creating a second."
  type        = string
  default     = "aolf-prod"
}

variable "shared_alb_name" {
  description = "Existing application load balancer to attach a listener rule to. Its default action is left alone -- only traffic matching this app's host header is diverted."
  type        = string
  default     = "aolf-prod-app"
}

variable "alb_listener_rule_priority" {
  description = "Priority for this app's rule on the shared listener. Must not collide with a rule the aolf stack already owns; lower numbers evaluate first."
  type        = number
  default     = 100
}
