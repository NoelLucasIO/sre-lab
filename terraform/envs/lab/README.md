# envs/lab

```bash
set -a; source ~/.config/terraform/pg.env; source ~/.config/terraform/technitium.env; set +a
terraform init
terraform plan
```

**Plan and apply this root through CI only.** The libvirt provider caches cloud-init ISOs in the
runner's private `/tmp`; planned as any other user, every VM shows as needing replacement
(DR drill 2026-11-11, finding 4). Reading outputs by hand (`terraform output`) is fine.
