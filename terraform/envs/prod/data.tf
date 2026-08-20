data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_vpc" "app" {
  id = var.vpc_id
}

data "aws_subnet" "app" {
  for_each = var.app_subnet_ids
  id       = each.value
}

# Read-only. The RDS instance itself belongs to the aolf-warehouse state.
data "aws_security_group" "rds" {
  id = var.rds_security_group_id
}

# Restricts ALB ingress to CloudFront edge IPs so the load balancer cannot be
# reached directly, bypassing the distribution.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
