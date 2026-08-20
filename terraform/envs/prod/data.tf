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

# Shared with the aolf stack, which owns all three. This stack only reads them:
# it adds one target group, one listener rule, and one service. An ECS cluster is
# a logical grouping that costs nothing, and a second load balancer would be ~$20
# a month for an internal dashboard, so neither is worth duplicating.
data "aws_ecs_cluster" "shared" {
  cluster_name = var.ecs_cluster_name
}

data "aws_lb" "shared" {
  name = var.shared_alb_name
}

data "aws_lb_listener" "shared_http" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 80
}
