#!/usr/bin/env python3
"""Build the Ansible inventory from Terraform: terraform output -json k3s_nodes | tf-inventory.py > hosts.json

Terraform provisions, Ansible configures: hosts come from envs/lab's own output, so the
inventory can never drift from what Terraform built. Nodes named *server* form the `server`
group; the rest are `agent`. Both sit under `k3s_cluster` (the k3s.orchestration layout).
"""
import json
import sys

nodes = json.load(sys.stdin)
if not nodes:
    sys.exit("tf-inventory: k3s_nodes output is empty")

server, agent = {}, {}
for name, n in sorted(nodes.items()):
    (server if "server" in name else agent)[n["fqdn"]] = {"ansible_host": n["fqdn"], "node_ip": n["ip"]}
if not server:
    sys.exit("tf-inventory: no server node in k3s_nodes")

json.dump({"k3s_cluster": {"children": {"server": {"hosts": server}, "agent": {"hosts": agent}}}},
          sys.stdout, indent=2)
print()
