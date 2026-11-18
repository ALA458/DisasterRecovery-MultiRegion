data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --------------------------------------------------------------------------
# Security Groups (ALB y EC2)
# --------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Reglas de firewall para el balanceador ALB publico"
  vpc_id      = var.vpc_id

  ingress {
    description = "Trafico HTTP publico"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Salida hacia instancias EC2"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-alb-sg"
      Environment = var.environment
    }
  )
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Reglas de firewall para instancias EC2 de aplicacion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Trafico de la API desde el balanceador ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida a internet via NAT GW para Docker y servicios AWS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-ec2-sg"
      Environment = var.environment
    }
  )
}

# --------------------------------------------------------------------------
# Application Load Balancer (ALB) y Target Group
# --------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-alb"
      Environment = var.environment
    }
  )
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-${var.environment}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # Health Check HTTP cada 10 segundos según la propuesta técnica
  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = tostring(var.app_port)
    protocol            = "HTTP"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-tg"
      Environment = var.environment
    }
  )
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --------------------------------------------------------------------------
# IAM Role para instancias EC2 (Acceso a SSM, DynamoDB y S3)
# --------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-ec2-role"
      Environment = var.environment
    }
  )
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lectura de imágenes desde ECR (docker pull de la API)
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_policy" "app_permissions" {
  name        = "${var.project_name}-${var.environment}-app-policy"
  description = "Permisos para DynamoDB, S3 y lectura del secreto de RDS en SSM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:DescribeTable"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.db_pass_ssm_parameter}"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject",
          "s3:ListBucket"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_permissions" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.app_permissions.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# --------------------------------------------------------------------------
# Launch Template y Auto Scaling Group (ASG)
# --------------------------------------------------------------------------
resource "aws_launch_template" "this" {
  name_prefix   = "${var.project_name}-${var.environment}-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              set -ex

              # 1. Docker. Sin "dnf update": la AMI AL2023 se resuelve a la más reciente en cada apply,
              #    y actualizar paquetes al arrancar alarga el failover (RTO).
              dnf install -y docker
              systemctl enable --now docker

              # 2. Descargar la imagen ya construida desde ECR de ESTA región (sin build en la instancia).
              #    Reintenta ~10 min por si la imagen aún no existe o no terminó de replicarse.
              for i in $(seq 1 30); do
                aws ecr get-login-password --region ${var.aws_region} \
                  | docker login --username AWS --password-stdin ${split("/", var.app_image)[0]} \
                  && docker pull ${var.app_image} && break
                echo "docker pull falló (intento $i), reintentando en 20 s"
                sleep 20
              done
              docker image inspect ${var.app_image} > /dev/null

              # 3. Leer la contraseña desde SSM y levantar el contenedor.
              #    set +x evita que la contraseña quede en /var/log/cloud-init-output.log
              set +x
              DB_PASS=$(aws ssm get-parameter --name "${var.db_pass_ssm_parameter}" --with-decryption --query Parameter.Value --output text --region ${var.aws_region})
              docker run -d --restart always \
                -p ${var.app_port}:8000 \
                -e DB_HOST="${var.db_host}" \
                -e DB_PORT="${var.db_port}" \
                -e DB_USER="${var.db_user}" \
                -e DB_PASS="$DB_PASS" \
                -e DB_NAME="${var.db_name}" \
                -e DYNAMO_TABLE="${var.dynamo_table}" \
                -e S3_BUCKET="${var.s3_bucket}" \
                -e AWS_REGION="${var.aws_region}" \
                --name dr-api-service ${var.app_image}
              set -x
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name        = "${var.project_name}-${var.environment}-instance"
        Environment = var.environment
      }
    )
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = "${var.project_name}-${var.environment}-asg-"
  vpc_zone_identifier = var.private_subnet_ids

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-asg-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity, min_size]
  }
}
