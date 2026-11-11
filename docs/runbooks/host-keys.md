# Runbook: k3s VM host keys

The k3s VMs' SSH host keys are generated and kept by Terraform in `envs/lab-base` and handed to the VMs by cloud-init ([ADR 0011](../decisions/0011-managed-host-keys.md)). `ci/runner/known_hosts` is `envs/lab`'s `known_hosts` output, committed. A rebuild of `envs/lab` keeps the keys, so nothing here is part of a normal rebuild.

All commands on fedora as `nlucas`, from `~/sre-lab`, with `set -a; . ~/.config/terraform/pg.env; set +a`.

## Drift check failed: "ci/runner/known_hosts differs"

Compare the two:
```bash
diff <(grep -v '^#' ci/runner/known_hosts | grep . | sort) \
     <(terraform -chdir=terraform/envs/lab output -raw known_hosts | sort)
```
If Terraform is right (a key was rotated on purpose, or this is the first rollout), re-render the file and commit it through a PR:
```bash
{ echo "# Rendered from: terraform -chdir=terraform/envs/lab output -raw known_hosts (ADR 0011). Do not edit."
  terraform -chdir=terraform/envs/lab output -raw known_hosts; } > ci/runner/known_hosts
```
If the file is right and Terraform changed unexpectedly, stop: something rotated a key without a PR. Check `envs/lab-base` state history before anything else.

## SSH says "REMOTE HOST IDENTIFICATION HAS CHANGED"

With managed keys this should not happen. Check, in order:
1. Does the VM serve the managed key? `ssh-keyscan -t ed25519 <host> | ssh-keygen -lf -` against `terraform -chdir=terraform/envs/lab output -raw known_hosts | ssh-keygen -lf -`.
2. If the VM serves a different key, read the key from its disk without trusting the network:
   ```bash
   sudo LIBGUESTFS_BACKEND=direct virt-cat --format=qcow2 -a /990/VM/<vm>-root.qcow2 \
     /etc/ssh/ssh_host_ed25519_key.pub | ssh-keygen -lf -
   ```
   (The default libvirt backend fails on the running VM's image lock. There is no console login, and Rocky's guest agent blocks file reads.)
3. If the disk has the managed key but the network serves another, treat it as an incident: something else answers on that address.

## Rotate a key

```bash
terraform -chdir=terraform/envs/lab-base state list | grep tls_private_key   # find the address
```
Remove `prevent_destroy` for that resource in a PR, `-replace` it in `envs/lab-base`, apply `envs/lab` (the VM is recreated on its existing disk and cloud-init writes the new key), re-render `ci/runner/known_hosts` as above, and restore `prevent_destroy`.

## First rollout (one time, 2026-11)

1. Merge the PR. Its `terraform` run creates the keys in `envs/lab-base`; `envs/lab` plans no change yet (it read `lab_base` before the apply) and warns `host_keys_managed`.
2. Dispatch the `terraform` workflow and approve `lab`: the three VMs are recreated on their existing disks and boot with the managed keys. The copy restarts (expect its pages).
3. Re-render `ci/runner/known_hosts` as above and merge that PR.
4. Dispatch the `k3s` workflow: it installs the new file on the runner and converges. Run `ci/nightscout/seed-secret.sh` to prove the `nlucas` path too.

Between steps 2 and 3, anything that SSHes to the VMs fails strict host-key checking. Keep the gap short.
