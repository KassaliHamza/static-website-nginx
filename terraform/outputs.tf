output "public_ip" {
  value = aws_eip.web.public_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_eip.web.public_ip}"
}

output "nameservers" {
  value = aws_route53_zone.main.name_servers
}

output "security_group_id" {
  value = aws_security_group.web.id
}