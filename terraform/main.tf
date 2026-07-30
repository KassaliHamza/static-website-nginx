# Latest Ubuntu 22.04 LTS AMI from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Pinning the AZ keeps the default subnet — and therefore the instance —
  # stable across applies instead of drifting between zones.
  availability_zone = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
}

data "aws_subnet" "default" {
  availability_zone = local.availability_zone
  default_for_az    = true
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = var.public_key
}

resource "aws_security_group" "web" {
  name        = "${var.project}-sg"
  description = "Allow SSH, HTTP, HTTPS"

  # Empty by default. The CI deploy job authorizes the runner's own /32 for the
  # length of the deploy and revokes it afterwards, so no standing SSH exposure
  # is required. Populate ssh_ingress_cidrs for interactive access.
  dynamic "ingress" {
    for_each = var.ssh_ingress_cidrs
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
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

  tags = {
    Name    = "${var.project}-sg"
    Project = var.project
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.web.id]
  subnet_id              = data.aws_subnet.default.id

  # Only runs on first boot. Ansible owns configuration from then on; this just
  # guarantees the box answers on port 80 before the first playbook run.
  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    systemctl enable --now nginx
  EOF

  tags = {
    Name    = "${var.project}-web"
    Project = var.project
  }
}

resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project}-eip"
    Project = var.project
  }
}
