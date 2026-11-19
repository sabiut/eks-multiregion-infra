environment = "lab"

# The traffic dial per region. Sydney takes all traffic. Singapore is a standby and takes
# none: its database is a read replica, so a user sent there could read but not write.
#
# Failover is a deliberate, ordered action (docs/dr-runbook.md): promote Singapore's
# database first, then set Singapore to 100 and Sydney to 0 here and apply.
# The dial is deliberately not left at 100 for both: Global Accelerator would then send
# users near Singapore to a region that rejects writes, in normal operation.
regions = {
  "ap-southeast-2" = 100
  "ap-southeast-1" = 0
}
