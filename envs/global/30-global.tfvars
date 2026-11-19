environment = "lab"

# Both regions accept traffic, and each user is sent to the nearest healthy one. From
# Australia that is Sydney, so Singapore is the standby for you, and takes over if Sydney
# has no healthy targets.
# Failover drill: change Sydney to 0 and apply. All traffic then goes to Singapore.
regions = {
  "ap-southeast-2" = 100
  "ap-southeast-1" = 100
}
