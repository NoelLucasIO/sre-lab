locals {
  pool = "990Flash"
}

# Rocky 9 GenericCloud. Upstream SHA256 at time of adoption (2026-11-04):
# 92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8 (image dated 2026-05-25)
resource "libvirt_volume" "rocky9" {
  name = "rocky-9-genericcloud-base.qcow2"
  pool = local.pool
  target = {
    format = { type = "qcow2" }
  }
  create = {
    content = {
      url = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
    }
  }
}
