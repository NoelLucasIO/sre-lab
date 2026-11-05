# ADR 0006: Configuration management for the k3s nodes

**Status:** Accepted, 2026-11-05

## Context

Terraform (`envs/lab`) builds three Rocky 9 VMs. Something has to install and configure k3s on them, repeatably, with the same change control as the infrastructure. There was no Ansible controller left after the lab rebuild (the old Semaphore container is gone).

## Decision

- **Ansible runs only in CI**, on the fedora runner, as `gh-runner`, behind the `lab` environment approval. It shares the `tf-apply` concurrency group with Terraform, so only one change hits the lab at a time.
- **Terraform provisions, Ansible configures, and the hand-off is data:** the inventory is generated from `terraform output -json k3s_nodes` at run time (`ansible/inventory/tf-inventory.py`). It is never hand-edited and cannot drift from what Terraform built.
- **The official `k3s.orchestration` collection** (k3s-io/k3s-ansible), pinned to its `1.2.2` git tag, with `ansible.posix` 2.2.2 and `community.general` 14.0.0 pinned exactly. No token is stored: the first server generates it and the agents read it from there.
- **ansible-core 2.21.6**, chosen from the published support matrix rather than "latest": 2.21 documents controller Python 3.12–3.14 (fedora has 3.14) and target Python 3.9–3.14 (Rocky 9 ships 3.9), with support to Nov 2027. 2.22 is newer, but its target range is not in the matrix yet.
- **k3s v1.37.2+k3s1**, the `stable` channel on 2026-11-05.
- **SELinux stays enforcing.** The collection installs `policycoreutils` and the k3s installer adds the `k3s-selinux` policy RPM.
- The runner keeps the toolchain in a virtualenv under its home, keyed by a hash of the pin files, so a pin change rebuilds it and nothing is installed system-wide.

## Consequences

- PRs get a syntax check on a GitHub-hosted runner against a committed sample of the Terraform output; only `main` touches the VMs.
- The job verifies the result (every node `Ready`), not just that the playbook exited 0.
- The runner has no `kubectl` yet, so the collection skips copying the kubeconfig to the controller. The Nightscout deploy step will add a pinned `kubectl` and a kubeconfig for `gh-runner`.
- The VM nodes reach `get.k3s.io`, GitHub releases and `rpm.rancher.io` during install; an offline install would need the collection's airgap role.

## Amendment 2026-11-05: undeclared collection dependency

The first converge installed the server, then failed on both agents: `No filter named 'ansible.utils.ipwrap'`. `k3s.orchestration` 1.2.2 uses that filter but does not declare `ansible.utils` in its `galaxy.yml` (its README asks only for the `netaddr` Python library the filter needs). `--syntax-check` passed because filters resolve only when a template renders. Fix: pin `ansible.utils` 6.1.1. Prevention: the PR syntax job now resolves every module, filter and test FQCN the collection's roles reference (35 at 1.2.2) and fails on any that is missing.
