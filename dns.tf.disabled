# -------------------------------------------------------------------
# Cloudflare DNS Automation
# -------------------------------------------------------------------

# 1. Root @ Record (A Record)
resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  value   = aws_instance.master.public_ip
  type    = "A"
  proxied = false  # We need direct access for arbitrary ports/protocols initially, usually K8s
}

# 2. Wildcard * Record (CNAME Record)
# Maps *.your-domain.com -> your-domain.com -> Master IP
resource "cloudflare_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  value   = var.domain_name
  type    = "CNAME"
  proxied = false
}

output "domain_name" {
  description = "The configured domain name"
  value       = var.domain_name
}
