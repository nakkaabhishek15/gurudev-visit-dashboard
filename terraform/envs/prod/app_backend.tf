locals {
  backend_name       = "${var.app_name}-${var.environment}-backend"
  backend_image      = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
  backend_log_group  = "/ecs/${local.backend_name}"
  backend_subnet_ids = sort(tolist(var.app_subnet_ids))
}

resource "aws_ecr_repository" "backend" {
  name                 = var.backend_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 20 backend images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = local.backend_log_group
  retention_in_days = var.backend_log_retention_days
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# The execution role is used by the ECS agent to pull the image and resolve
# secrets. The task role is what the application code itself runs as.
resource "aws_iam_role" "backend_execution" {
  name               = "${local.backend_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "backend_execution_managed" {
  role       = aws_iam_role.backend_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "backend_execution_secrets" {
  statement {
    sid = "ReadRuntimeSecretsForECS"

    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameters",
    ]

    resources = concat(
      [for secret in aws_secretsmanager_secret.app : secret.arn],
      [for parameter in aws_ssm_parameter.app_config : parameter.arn],
    )
  }
}

resource "aws_iam_role_policy" "backend_execution_secrets" {
  name   = "${local.backend_name}-runtime-secrets"
  role   = aws_iam_role.backend_execution.id
  policy = data.aws_iam_policy_document.backend_execution_secrets.json
}

# Deliberately has no policies attached: this app talks only to Postgres, and
# the connection string arrives as an environment variable. Attach a policy here
# the day the code calls an AWS API itself.
resource "aws_iam_role" "backend_task" {
  name               = "${local.backend_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_security_group" "backend_tasks" {
  name        = "${local.backend_name}-tasks"
  description = "Allows ALB traffic to the ${var.app_name} FastAPI tasks."
  vpc_id      = data.aws_vpc.app.id
}

# One rule per security group on the shared load balancer. Reading them from the
# data source rather than naming one keeps this correct if the aolf stack ever
# adds a second.
resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  for_each = data.aws_lb.shared.security_groups

  security_group_id            = aws_security_group.backend_tasks.id
  description                  = "FastAPI traffic from the shared application load balancer."
  referenced_security_group_id = each.value
  from_port                    = var.backend_container_port
  ip_protocol                  = "tcp"
  to_port                      = var.backend_container_port
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend_tasks.id
  description       = "Allow backend tasks to reach AWS APIs and RDS."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The one write this stack makes to shared network state. It adds a rule to the
# RDS security group rather than replacing it, so the aolf-warehouse rules are
# untouched.
resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = data.aws_security_group.rds.id
  description                  = "Postgres access from ${var.app_name} backend ECS tasks."
  referenced_security_group_id = aws_security_group.backend_tasks.id
  from_port                    = var.rds_port
  ip_protocol                  = "tcp"
  to_port                      = var.rds_port
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.app_name}-${var.environment}-backend"
  port        = var.backend_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.app.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }
}

# A host-header rule on the shared load balancer, rather than a load balancer of
# our own. The listener's default action still sends everything else to the aolf
# backend, so this adds a branch without altering existing routing.
#
# The match is on the CloudFront domain because the /api/* behaviour forwards the
# viewer Host (see the AllViewer policy in app_frontend.tf). With the stock
# AllViewerExceptHostHeader policy every app behind this load balancer would
# arrive with the same Host and could not be told apart.
resource "aws_lb_listener_rule" "backend" {
  listener_arn = data.aws_lb_listener.shared_http.arn
  priority     = var.alb_listener_rule_priority

  condition {
    host_header {
      values = compact([
        aws_cloudfront_distribution.app.domain_name,
        var.app_hostname,
      ])
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ecs_task_definition" "backend" {
  family                   = local.backend_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.backend_task_cpu)
  memory                   = tostring(var.backend_task_memory)
  execution_role_arn       = aws_iam_role.backend_execution.arn
  task_role_arn            = aws_iam_role.backend_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = local.backend_image
      essential = true

      portMappings = [
        {
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_ENV", value = var.environment },
        { name = "AUTH_COOKIE_SECURE", value = "true" },
        # CloudFront serves the site and /api/* from one origin, so browser calls
        # are same-origin and this list stays empty in AWS. It exists for local
        # development, where the Vite dev server is a separate origin.
        { name = "CORS_ALLOWED_ORIGINS", value = var.app_hostname == "" ? "" : "https://${var.app_hostname}" },
      ]

      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.app["database-url"].arn
        },
        {
          name      = "WAREHOUSE_DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.app["warehouse-database-url"].arn
        },
        {
          name      = "SESSION_SECRET"
          valueFrom = aws_secretsmanager_secret.app["auth/session-secret"].arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "backend"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "backend" {
  name            = local.backend_name
  cluster         = data.aws_ecs_cluster.shared.arn
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  # A task that never passes its health check rolls back instead of leaving the
  # service stuck mid-deploy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = var.backend_container_port
  }

  # Public subnets with a public IP, matching the existing AOLF setup: the tasks
  # need outbound access to ECR and Secrets Manager, and there is no NAT gateway.
  # Inbound is still closed to everything except the ALB security group.
  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.backend_tasks.id]
    subnets          = local.backend_subnet_ids
  }

  depends_on = [
    aws_lb_listener_rule.backend,
    aws_iam_role_policy_attachment.backend_execution_managed,
    aws_iam_role_policy.backend_execution_secrets,
  ]
}
