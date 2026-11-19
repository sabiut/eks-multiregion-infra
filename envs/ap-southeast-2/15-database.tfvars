environment = "lab"
region      = "ap-southeast-2"

# Sydney holds the primary database.
primary_region = ""

# LAB PROFILE: one instance. Production: true.
multi_az = false

# Failover controls (docs/dr-runbook.md). Leave both false in normal operation.
fenced              = false # true: close this database to every client
deletion_protection = false # true: refuse to delete it. Set on a database once it is promoted
