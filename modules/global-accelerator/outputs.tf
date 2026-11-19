output "dns_name" {
  value = aws_globalaccelerator_accelerator.this.dns_name
}

output "static_ips" {
  value = flatten(aws_globalaccelerator_accelerator.this.ip_sets[*].ip_addresses)
}
