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

resource "aws_security_group" "alb" {
  name        = "${var.app_name}-${var.environment}-alb"
  description = "Allows CloudFront to reach the ${var.app_name} load balancer."
  vpc_id      = data.aws_vpc.app.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront origin-facing edge locations only."
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow load balancer egress to backend tasks."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "backend_tasks" {
  name        = "${local.backend_name}-tasks"
  description = "Allows ALB traffic to the ${var.app_name} FastAPI tasks."
  vpc_id      = data.aws_vpc.app.id
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend_tasks.id
  description                  = "FastAPI traffic from the application load balancer."
  referenced_security_group_id = aws_security_group.alb.id
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

resource "aws_lb" "app" {
  name               = "${var.app_name}-${var.environment}-app"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.backend_subnet_ids
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

# Plain HTTP is correct here: this listener is only reachable from CloudFront,
# and CloudFront terminates TLS for viewers.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_ecs_cluster" "app" {
  name = "${var.app_name}-${var.environment}"
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
        { name = "CORS_ALLOWED_ORIGINS", value = "https://${var.app_hostname}" },
      ]

      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.app["database-url"].arn
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
  cluster         = aws_ecs_cluster.app.id
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
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.backend_execution_managed,
    aws_iam_role_policy.backend_execution_secrets,
  ]
}
