#####
# Cloudwatch
#####
resource "aws_cloudwatch_log_group" "main" {
  count = var.enable_logs ? 1 : 0

  name = var.name_prefix

  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.logs_kms_key

  tags = var.tags
}

#####
# IAM - Task execution role, needed to pull ECR images etc.
#####
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy" "task_execution" {
  name   = "${var.name_prefix}-task-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.task_execution_permissions.json
}

resource "aws_iam_role_policy" "read_repository_credentials" {
  count = var.create_repository_credentials_iam_policy ? 1 : 0

  name   = "${var.name_prefix}-read-repository-credentials"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_repository_credentials[0].json
}

resource "aws_iam_role_policy" "get_environment_files" {
  count = length(var.task_container_environment_files) != 0 ? 1 : 0

  name   = "${var.name_prefix}-read-repository-credentials"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.get_environment_files[0].json
}

#####
# IAM - Task role, basic. Append policies to this role for S3, DynamoDB etc.
#####
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy" "log_agent" {
  name   = "${var.name_prefix}-log-permissions"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_permissions.json
}

resource "aws_iam_role_policy" "ecs_exec_inline_policy" {
  count = var.enable_execute_command ? 1 : 0

  name   = "${var.name_prefix}-ecs-exec-permissions"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_ecs_exec_policy[0].json
}

#####
# Security groups
#####
resource "aws_security_group" "ecs_service" {
  vpc_id      = var.vpc_id
  name_prefix = var.sg_name_prefix == "" ? "${var.name_prefix}-ecs-service-sg-" : "${var.sg_name_prefix}-"
  description = "Fargate service security group"
  tags = merge(
    var.tags,
    {
      Name = var.sg_name_prefix == "" ? "${var.name_prefix}-ecs-service-sg" : var.sg_name_prefix
    },
  )

  revoke_rules_on_delete = true

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "egress_service" {
  count             = var.deny_egress_to_anywhere ? 0 : 1
  security_group_id = aws_security_group.ecs_service.id
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

#####
# Load Balancer Target group
#####
resource "aws_lb_target_group" "task" {
  for_each = var.load_balanced ? { for tg in var.target_groups : tg.target_group_name => tg } : {}

  # tflint-ignore: terraform_deprecated_lookup
  name                 = lookup(each.value, "target_group_name")
  vpc_id               = var.vpc_id
  protocol             = var.task_container_protocol
  port                 = lookup(each.value, "container_port", var.task_container_port)
  deregistration_delay = lookup(each.value, "deregistration_delay", null)
  # awsvpc network mode (required for the AWS Fargate launch type), IP must be the target type.
  target_type = "ip"


  dynamic "health_check" {
    for_each = [var.health_check]
    content {
      enabled             = lookup(health_check.value, "enabled", true)
      interval            = lookup(health_check.value, "interval", 30)
      path                = lookup(health_check.value, "path", "/")
      port                = lookup(health_check.value, "port", "traffic-port")
      protocol            = lookup(health_check.value, "protocol", "HTTP")
      timeout             = lookup(health_check.value, "timeout", 5)
      healthy_threshold   = lookup(health_check.value, "healthy_threshold", 5)
      unhealthy_threshold = lookup(health_check.value, "unhealthy_threshold", 2)
      matcher             = lookup(health_check.value, "matcher", null)
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.tags,
    {
      # tflint-ignore: terraform_deprecated_lookup
      Name = lookup(each.value, "target_group_name")
    },
  )
}

#####
# ECS Task/Service
#####
locals {
  task_environment = [
    for k, v in var.task_container_environment : {
      name  = k
      value = v
    }
  ]

  target_group_portMaps = length(var.target_groups) > 0 ? distinct([
    for tg in var.target_groups : {
      containerPort = contains(keys(tg), "container_port") ? tg.container_port : var.task_container_port
      protocol      = contains(keys(tg), "protocol") ? lower(tg.protocol) : "tcp"
    }
  ]) : []

  task_environment_files = [
    for file in var.task_container_environment_files : {
      value = file
      type  = "s3"
    }
  ]
}

resource "aws_ecs_task_definition" "task" {
  family                   = var.name_prefix
  execution_role_arn       = aws_iam_role.execution.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_definition_cpu
  memory                   = var.task_definition_memory
  task_role_arn            = aws_iam_role.task.arn

  dynamic "ephemeral_storage" {
    for_each = var.task_definition_ephemeral_storage == 0 ? [] : [var.task_definition_ephemeral_storage]
    content {
      size_in_gib = var.task_definition_ephemeral_storage
    }
  }

  container_definitions = local.container_definitions

  runtime_platform {
    operating_system_family = var.operating_system_family
    cpu_architecture        = var.cpu_architecture
  }

  dynamic "placement_constraints" {
    for_each = var.placement_constraints
    content {
      expression = lookup(placement_constraints.value, "expression", null)
      type       = placement_constraints.value.type
    }
  }

  dynamic "proxy_configuration" {
    for_each = var.proxy_configuration
    content {
      container_name = proxy_configuration.value.container_name
      properties     = lookup(proxy_configuration.value, "properties", null)
      type           = lookup(proxy_configuration.value, "type", null)
    }
  }

  dynamic "volume" {
    for_each = var.volume
    content {
      name      = volume.value.name
      host_path = lookup(volume.value, "host_path", null)

      dynamic "docker_volume_configuration" {
        for_each = lookup(volume.value, "docker_volume_configuration", [])
        content {
          scope         = lookup(docker_volume_configuration.value, "scope", null)
          autoprovision = lookup(docker_volume_configuration.value, "autoprovision", null)
          driver        = lookup(docker_volume_configuration.value, "driver", null)
          driver_opts   = lookup(docker_volume_configuration.value, "driver_opts", null)
          labels        = lookup(docker_volume_configuration.value, "labels", null)
        }
      }

      dynamic "efs_volume_configuration" {
        for_each = lookup(volume.value, "efs_volume_configuration", [])
        content {
          file_system_id          = lookup(efs_volume_configuration.value, "file_system_id", null)
          root_directory          = lookup(efs_volume_configuration.value, "root_directory", null)
          transit_encryption      = lookup(efs_volume_configuration.value, "transit_encryption", null)
          transit_encryption_port = lookup(efs_volume_configuration.value, "transit_encryption_port", null)

          dynamic "authorization_config" {
            for_each = length(lookup(efs_volume_configuration.value, "authorization_config", {})) == 0 ? [] : [lookup(efs_volume_configuration.value, "authorization_config", {})]
            content {
              access_point_id = lookup(authorization_config.value, "access_point_id", null)
              iam             = lookup(authorization_config.value, "iam", null)
            }
          }
        }
      }
    }
  }

  tags = merge(
    var.tags,
    {
      Name = var.container_name != "" ? var.container_name : var.name_prefix
    },
  )
}

resource "aws_ecs_service" "service" {
  name = var.name_prefix

  cluster         = var.cluster_id
  task_definition = "${aws_ecs_task_definition.task.family}:${max(aws_ecs_task_definition.task.revision, data.aws_ecs_task_definition.task.revision)}"

  desired_count  = var.desired_count
  propagate_tags = var.propagate_tags

  platform_version = var.platform_version
  launch_type      = length(var.capacity_provider_strategy) == 0 ? "FARGATE" : null

  force_new_deployment    = var.force_new_deployment
  wait_for_steady_state   = var.wait_for_steady_state
  enable_execute_command  = var.enable_execute_command
  enable_ecs_managed_tags = var.enable_ecs_managed_tags

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.load_balanced ? var.health_check_grace_period_seconds : null

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = var.task_container_assign_public_ip
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = lookup(capacity_provider_strategy.value, "base", null)
    }
  }

  dynamic "alarms" {
    for_each = var.deployment_alarms != null ? var.deployment_alarms : []
    content {
      alarm_names = try(alarms.value.alarm_names, [])
      enable      = try(alarms.value.enable, false)
      rollback    = try(alarms.value.rollback, false)
    }
  }

  dynamic "load_balancer" {
    # tflint-ignore: terraform_deprecated_lookup
    for_each = var.load_balanced ? var.target_groups : []
    content {
      # tflint-ignore: terraform_deprecated_lookup
      container_name = try(load_balancer.value, "container_name") != "" ? lookup(load_balancer.value, "container_name") : var.name_prefix
      container_port = lookup(load_balancer.value, "container_port", var.task_container_port)
      # tflint-ignore: terraform_deprecated_lookup
      target_group_arn = aws_lb_target_group.task[lookup(load_balancer.value, "target_group_name")].arn
    }
  }

  deployment_circuit_breaker {
    enable   = var.enable_deployment_circuit_breaker
    rollback = var.enable_deployment_circuit_breaker_rollback
  }

  deployment_controller {
    type = var.deployment_controller_type # CODE_DEPLOY or ECS or EXTERNAL
  }

  dynamic "service_registries" {
    for_each = var.service_registry_arn == "" ? [] : [1]
    content {
      registry_arn   = var.service_registry_arn
      container_name = var.container_name != "" ? var.container_name : var.name_prefix
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-service"
    },
  )
}
