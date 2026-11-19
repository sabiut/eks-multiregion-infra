# One front door, in front of whichever region is live.
#
# The load balancers are not created by Terraform: the AWS Load Balancer Controller creates
# one in each cluster when Argo CD applies the application's Ingress. So this runs last, and
# finds them by the tags the controller puts on them.
#
# Global Accelerator gives two static IP addresses and one DNS name. Traffic enters the AWS
# network at the nearest edge location and goes to a registered region. Moving traffic to
# the other region means changing which region is registered: it takes effect in seconds,
# with no DNS change for clients to wait on.
#
# Only regions that can take writes are registered. When every endpoint in a region is
# unhealthy, the accelerator fails over to any other registered region and ignores that
# region's traffic dial, so a read-only standby must not be registered at all. Route 53 failover records do the same job with
# DNS (and need a domain), which is the more common choice when you own one.

data "aws_lb" "ingress" {
  for_each = var.regions
  region   = each.key
  tags = {
    "elbv2.k8s.aws/cluster"    = "${var.cluster_name_prefix}-${each.key}"
    "ingress.k8s.aws/stack"    = var.ingress_stack
    "ingress.k8s.aws/resource" = "LoadBalancer"
  }
}

resource "aws_globalaccelerator_accelerator" "this" {
  name            = var.name
  ip_address_type = "IPV4"
  enabled         = true
}

resource "aws_globalaccelerator_listener" "http" {
  accelerator_arn = aws_globalaccelerator_accelerator.this.arn
  protocol        = "TCP"
  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_endpoint_group" "region" {
  for_each = var.regions

  listener_arn          = aws_globalaccelerator_listener.http.arn
  endpoint_group_region = each.key

  # The traffic dial: the share of a region's traffic that is let through. Useful for
  # shifting load gradually between regions that can both take writes. It is not a
  # failover control.
  traffic_dial_percentage = each.value

  # For a load balancer endpoint, health comes from the load balancer's own target health,
  # which comes from the pods' readiness probes.
  endpoint_configuration {
    endpoint_id = data.aws_lb.ingress[each.key].arn
    weight      = 100
    # Off: otherwise Global Accelerator puts network interfaces in the VPC, and they delay
    # deleting the VPC afterwards.
    client_ip_preservation_enabled = false
  }
}
