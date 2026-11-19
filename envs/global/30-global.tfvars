environment = "lab"

# The regions registered with the accelerator, and the traffic dial for each.
#
# Only a region whose database accepts writes belongs here. Singapore is a standby with a
# read-only database, so it is NOT listed: a dial of 0 would not be enough, because Global
# Accelerator ignores the dial when it fails over from an unhealthy region, and Singapore's
# frontend reports healthy even though its database rejects writes.
#
# Failover (docs/dr-runbook.md): after Singapore's database is promoted and a write has been
# verified there, replace the entry below with  "ap-southeast-1" = 100  and apply.
regions = {
  "ap-southeast-2" = 100
}
