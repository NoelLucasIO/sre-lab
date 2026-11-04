locals {
  fqdn = "${var.name}.${var.domain}"
  ip   = split("/", var.ipv4_cidr)[0]
  # Deterministic MAC (QEMU OUI) so the NIC, cloud-init match and any DHCP reservation never drift.
  h   = md5(var.name)
  mac = format("52:54:00:%s:%s:%s", substr(local.h, 0, 2), substr(local.h, 2, 2), substr(local.h, 4, 2))
}

resource "libvirt_cloudinit_disk" "this" {
  name = "${var.name}-cloudinit"

  meta_data = yamlencode({
    "instance-id"    = var.name
    "local-hostname" = var.name
  })

  user_data = join("\n", ["#cloud-config", yamlencode({
    hostname                  = var.name
    fqdn                      = local.fqdn
    prefer_fqdn_over_hostname = false
    manage_etc_hosts          = true
    ssh_pwauth                = false
    disable_root              = true
    users = [{
      name                = var.admin_user
      groups              = ["wheel"]
      shell               = "/bin/bash"
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      lock_passwd         = true
      ssh_authorized_keys = var.ssh_authorized_keys
    }]
    packages = ["qemu-guest-agent"]
    runcmd   = [["systemctl", "enable", "--now", "qemu-guest-agent"]]
  })])

  network_config = yamlencode({
    version = 2
    ethernets = {
      lan0 = {
        match       = { macaddress = local.mac }
        "set-name"  = "eth0"
        addresses   = [var.ipv4_cidr]
        routes      = [{ to = "default", via = var.gateway }]
        nameservers = { addresses = var.dns_servers, search = [var.domain] }
      }
    }
  })
}

resource "libvirt_volume" "cloudinit" {
  name = "${var.name}-cloudinit.iso"
  pool = var.pool
  target = {
    format = { type = "raw" }
  }
  create = {
    content = { url = libvirt_cloudinit_disk.this.path }
  }
}

resource "libvirt_volume" "root" {
  name          = "${var.name}-root.qcow2"
  pool          = var.pool
  capacity      = var.disk_gib
  capacity_unit = "GiB"
  target = {
    format = { type = "qcow2" }
  }
  backing_store = {
    path   = var.base_volume_path
    format = { type = "qcow2" }
  }
}

resource "libvirt_domain" "this" {
  name        = var.name
  type        = "kvm"
  description = jsonencode(var.tags) # libvirt has no tags; this is visible in `virsh desc`
  vcpu        = var.vcpu
  memory      = var.memory_mib
  memory_unit = "MiB"
  running     = true
  autostart   = true

  cpu = { mode = "host-passthrough" }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [{ dev = "hd" }]
  }

  devices = {
    disks = [
      {
        source = { volume = { pool = var.pool, volume = libvirt_volume.root.name } }
        target = { dev = "vda", bus = "virtio" }
        driver = { name = "qemu", type = "qcow2", discard = "unmap" }
      },
      {
        device    = "cdrom"
        read_only = true
        source    = { volume = { pool = var.pool, volume = libvirt_volume.cloudinit.name } }
        target    = { dev = "sda", bus = "sata" }
      },
    ]
    interfaces = [{
      source = { bridge = { bridge = var.bridge } }
      model  = { type = "virtio" }
      mac    = { address = local.mac }
    }]
    channels = [{
      source = { unix = { mode = "bind" } }
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
    }]
    rngs = [{
      model   = "virtio"
      backend = { random = "/dev/urandom" }
    }]
  }
}
