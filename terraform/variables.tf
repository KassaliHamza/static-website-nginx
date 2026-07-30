variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix applied to every created resource"
  type        = string
  default     = "static-site"
}

variable "instance_type" {
  description = "EC2 instance type (t2.micro/t3.micro are free-tier eligible in most regions)"
  type        = string
  default     = "t2.micro"
}

variable "availability_zone" {
  description = "AZ to pin the instance to. Empty picks the first available AZ in the region."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Root domain to serve, e.g. example.com (no scheme, no trailing dot)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.domain_name))
    error_message = "domain_name must be a bare domain such as example.com."
  }
}

variable "public_key" {
  description = "SSH public key material authorized on the instance, e.g. \"ssh-ed25519 AAAA... you@host\""
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ", var.public_key))
    error_message = "public_key must be the key material itself, not a file path."
  }
}

variable "ssh_ingress_cidrs" {
  description = <<-DESC
    CIDRs allowed to reach port 22. Empty (the default) keeps SSH closed to the
    internet; the CI deploy job opens it to the runner's own IP just in time and
    revokes it afterwards. Add your own /32 for interactive access.
  DESC
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_ingress_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open SSH to the entire internet."
  }
}
