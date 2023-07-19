// ECR repo
resource "aws_ecr_repository" "repo" {
  name                 = "${var.name}-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "null_resource" "push_image" {
  provisioner "local-exec" {
    command = "bash ${path.module}/push-image.sh"
    environment = {
      AWS_ACCESS_KEY_ID     = var.access_key
      AWS_SECRET_ACCESS_KEY = var.secret_key
      AWS_REGION            = var.region
      REPO_URL              = "public.ecr.aws/m3y1x5s9/bmi-app:latest"
    }
  }
}

resource "aws_kms_key" "key" {
  description             = "${var.name}-kms"
  deletion_window_in_days = 7
}

resource "aws_cloudwatch_log_group" "logs" {
  name = "${var.name}-log-group"
}

// ECS Cluster with Logs
resource "aws_ecs_cluster" "cluster" {
  name = "${var.name}-ecs-cluster"

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.key.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.logs.name
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster" {
  cluster_name = aws_ecs_cluster.cluster.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 0
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

data "aws_iam_policy_document" "agent_assume_role_policy_definition" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
  }
}

data "aws_iam_policy_document" "task_execution_role_policy" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role" "task_role" {
  name               = "${var.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.agent_assume_role_policy_definition.json
}

resource "aws_iam_role" "execution_role" {
  name               = "${var.name}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.agent_assume_role_policy_definition.json
}

resource "aws_iam_role_policy_attachment" "execution_role_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_role" {
  policy = data.aws_iam_policy_document.task_execution_role_policy.json
  role   = aws_iam_role.execution_role.id
}

resource "aws_ecs_task_definition" "task" {
  family                   = "${var.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  task_role_arn            = aws_iam_role.task_role.arn
  execution_role_arn       = aws_iam_role.execution_role.arn
  container_definitions = jsonencode([
    {
      name   = "web-app"
      image  = "public.ecr.aws/m3y1x5s9/bmi-app:latest"
      cpu    = 2
      memory = 512
      logConfiguration : {
        logDriver : "awslogs",
        options : {
          awslogs-create-group : "true",
          awslogs-group : "awslogs-${var.name}"
          awslogs-region : var.region
          awslogs-stream-prefix : "awslogs-${var.name}"
        }
      }
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ]
    }
  ])
  depends_on = [null_resource.push_image]
}

// Create a new VPC
resource "aws_vpc" "app_vpc" {
  cidr_block = "10.0.0.0/16" // Change this as needed
  enable_dns_support = true
  enable_dns_hostnames = true
}

// Create a new Internet Gateway and attach it to the VPC
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
}

// Create a new route table that routes traffic to the Internet Gateway
resource "aws_route_table" "app_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }
}

resource "aws_subnet" "app" {
  count                   = length(data.aws_availability_zones.zones.names)
  vpc_id                  = aws_vpc.app_vpc.id // Use the new VPC
  cidr_block              = cidrsubnet(aws_vpc.app_vpc.cidr_block, 8, count.index) // Subnets for the new VPC
  availability_zone       = data.aws_availability_zones.zones.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "app-subnet-${count.index}"
  }
}

resource "aws_route_table_association" "a" {
  count          = length(aws_subnet.app.*.id)
  subnet_id      = aws_subnet.app.*.id[count.index]
  route_table_id = aws_route_table.app_rt.id
}

// Application Load Balancer
resource "aws_lb" "app" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.app.*.id

  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.bucket
    prefix  = "access_logs"
    enabled = true
  }

  tags = var.tags
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.app.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.front_end.arn
  }
}

resource "aws_lb_target_group" "front_end" {
  name     = "${var.name}-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.app_vpc.id // Use the new VPC
  target_type = "ip"
 
  health_check {
    enabled             = true
    interval            = 30
    path                = "/health"
    port                = "traffic-port"
    timeout             = 3
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener_rule" "frontend" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.front_end.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

resource "aws_ecs_service" "service" {
  name            = "${var.name}-service"
  cluster         = aws_ecs_cluster.cluster.id
  launch_type     = "FARGATE"
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 3
  network_configuration {
    security_groups  = [aws_security_group.ecs.id]
    subnets          = aws_subnet.app.*.id
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.front_end.arn
    container_name   = "web-app"
    container_port   = 3000
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  tags = var.tags
}

data "aws_availability_zones" "zones" {
  state = "available"
}

resource "aws_security_group" "ecs" {
  name_prefix = "${var.name}-sg"
  description = "Security group for ecs task; allow inbound traffic from load balancer"

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id      = aws_vpc.app_vpc.id // Use the new VPC
  lifecycle {
    create_before_destroy = true
  }
}

/*
resource "aws_security_group_rule" "allow_egress" {
  description       = "Allow egress to the internet"
  security_group_id = aws_security_group.ecs.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "app" {
  security_group_id = aws_security_group.ecs.id
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}
*/

/*
resource "aws_security_group" "lb_sg" {
  name        = "${var.name}-lb-sg"
  description = "Allow inbound traffic on port 80"
  vpc_id      = aws_vpc.app_vpc.id
}
*/
/*
resource "aws_security_group_rule" "lb_ingress" {
  description      = "Allow inbound traffic on port 80"
  type             = "ingress"
  from_port        = 80
  to_port          = 80
  protocol         = "tcp"
  cidr_blocks      = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lb_sg.id
}
*/

/* resource "aws_security_group_rule" "lb_egress" {
  description      = "Allow inbound traffic on port 80"
  type             = "ingress"
  from_port        = 0
  to_port          = 0
  protocol         = "-1"
  cidr_blocks      = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lb_sg.id
} */


resource "aws_s3_bucket" "lb_logs" {
  bucket = "${var.name}-alb-logs-new2"
}


data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "lb_logs_policy" {
  bucket = aws_s3_bucket.lb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ELBAccessLogsWrite"
        Action    = ["s3:PutObject"]
        Effect    = "Allow"
        Resource  = "${aws_s3_bucket.lb_logs.arn}/*"
        Principal = {
          AWS = [data.aws_elb_service_account.main.arn]
        }
      }
    ]
  })
}



resource "aws_security_group" "lb_sg" {
  name        = "${var.name}-lb-sg"
  description = "Allow inbound traffic on port 80 and 443"
  vpc_id      = aws_vpc.app_vpc.id
  description = "Allow inbound traffic on ports 80 and 443"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
