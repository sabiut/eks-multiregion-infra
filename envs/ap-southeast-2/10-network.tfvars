environment = "lab"
region      = "ap-southeast-2"
vpc_cidr    = "10.40.0.0/16"

# LAB PROFILE: one NAT gateway. Production: false, so losing an AZ does not cut the others off.
single_nat_gateway = true
