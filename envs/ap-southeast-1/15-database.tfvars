environment = "lab"
region      = "ap-southeast-1"

# Singapore holds a read replica of Sydney's database. Apply Sydney's database first.
primary_region = "ap-southeast-2"

multi_az = false

# Failover controls (docs/dr-runbook.md). Leave both false in normal operation.
fenced              = false # true: close this database to every client
deletion_protection = false # true: refuse to delete it. Set on a database once it is promoted
