output "url" {
  value = "http://${module.front_door.dns_name}"
}

output "static_ips" {
  value = module.front_door.static_ips
}
