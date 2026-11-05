# Forward + reverse records for every k3s node, driven by the same map as the VMs.
module "k3s_dns" {
  source   = "../../modules/dns-record"
  for_each = local.k3s_nodes

  name = each.key
  ipv4 = each.value.ip
}
