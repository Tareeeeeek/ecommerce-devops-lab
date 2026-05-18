terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                   = "us-east-1"
  shared_credentials_files = ["./credentials"]
}

# =========================
# Availability Zones
# =========================

data "aws_availability_zones" "available" {}

# =========================
# VPC
# =========================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "VPC-Lab"
  }
}

# =========================
# Internet Gateway
# =========================

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# =========================
# Public Subnets
# =========================

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index * 2}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "Public-Subnet-${count.index + 1}"
  }
}

# =========================
# Private Subnets
# =========================

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index * 2 + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "Private-Subnet-${count.index + 1}"
  }
}

# =========================
# Security Group ALB
# =========================

resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

# =========================
# Security Group WEB
# =========================

resource "aws_security_group" "web_sg" {
  name   = "web-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
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

# =========================
# Load Balancer
# =========================

resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_sg.id]
  subnets         = aws_subnet.public[*].id
}

# =========================
# Launch Template
# =========================

data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "web" {
  name_prefix   = "web-config"
  image_id      = data.aws_ssm_parameter.amazon_linux.value
  instance_type = "t3.micro"

  iam_instance_profile {
    name = "LabInstanceProfile"
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
dnf update -y
dnf install -y httpd
systemctl start httpd
systemctl enable httpd
echo "Hello from Terraform" > /var/www/html/index.html
EOF
  )
}

# =========================
# Auto Scaling Group
# =========================

resource "aws_autoscaling_group" "web_asg" {
  vpc_zone_identifier = aws_subnet.private[*].id

  desired_capacity = 2
  max_size         = 4
  min_size         = 2

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
}
