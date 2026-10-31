# circuit-k3s

A Conn3x circuit that turns your hosts into a [k3s](https://k3s.io) Kubernetes cluster: one or more servers, and as many agents as you give it. It installs a pinned k3s release, checks its SHA-256 before using it, and runs k3s under systemd with its settings in `/etc/rancher/k3s/config.yaml`. x86_64 and arm64 hosts each get the right build.

It replaces the usual hand-off where Terraform makes the VMs and an Ansible playbook runs k3s's install script on them. The VMs and the cluster go in one configuration, and one `conn3x apply` builds both.

## Usage

```hcl
module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.3"

  servers = { cp1 = "203.0.113.10" }
  agents = {
    worker1 = "203.0.113.20"
    worker2 = "203.0.113.21"
  }
  token                = var.k3s_token
  ssh_private_key_file = "~/.ssh/id_ed25519"
}

variable "k3s_token" {
  type      = string
  ephemeral = true
}
```

Pass the token at run time, with `-var k3s_token=...` or `TF_VAR_k3s_token`, and keep it the same for the life of the cluster. `openssl rand -hex 32` makes a good one. It is ephemeral, so it never goes into state or a plan. On the hosts it lives in `/etc/rancher/k3s/token`, mode `0600`.

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

For a highly available control plane, give three servers. The first by name starts the cluster with embedded etcd and the others join it. To add a server later whose name sorts first, set `first_server` to the one that started the cluster, or the new server would start a cluster of its own:

```hcl
module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.3"

  servers = {
    cp1 = "10.0.0.10"
    cp2 = "10.0.0.11"
    cp3 = "10.0.0.12"
  }
  agents = { for name, d in digitalocean_droplet.worker : name => d.ipv4_address_private }
  token  = var.k3s_token
}
```

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
servers = {
  for name, d in digitalocean_droplet.cp : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Raspberry Pi

Raspberry Pi OS boots with the memory cgroup turned off, and k3s won't start without it. Set `raspberry_pi = true` and the circuit adds `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt`, then reboots each host once, before installing k3s. Every host in the cluster must be a Pi, since the reboot happens on all of them. The arm64 build of k3s is picked for you.

```hcl
module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.3"

  servers      = { pi1 = "192.168.1.31" }
  agents       = { pi2 = "192.168.1.32", pi3 = "192.168.1.33" }
  token        = var.k3s_token
  raspberry_pi = true
}
```

### Getting a kubeconfig

k3s writes one for the cluster admin to `/etc/rancher/k3s/k3s.yaml` on each server, pointing at `127.0.0.1`. Copy it and swap in the server's address:

```sh
ssh root@203.0.113.10 cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/203.0.113.10/' > ~/.kube/k3s.yaml
KUBECONFIG=~/.kube/k3s.yaml kubectl get nodes
```

### More k3s settings

`server_config` and `agent_config` go into `config.yaml` as they are, with k3s's flag names minus the dashes:

```hcl
server_config = {
  disable               = ["traefik"]
  write-kubeconfig-mode = "0644"
  node-taint            = ["CriticalAddonsOnly=true:NoExecute"]
}
agent_config = {
  node-label = ["role=worker"]
}
```

A change to either restarts k3s on the hosts it affects, after the circuit's other steps.

## What it does

The first server by name runs first. On it, in order:

1. Installs `curl` if it's missing.
2. With `raspberry_pi`, turns on the memory cgroup and reboots once.
3. Makes sure the kernel has `br_netfilter`, which pod traffic to services needs. Rocky Linux 10 and other EL10 images ship it in `kernel-modules-extra`, which they don't install, so on those hosts the circuit installs `kernel-modules-extra` for the running kernel with `dnf`.
4. Downloads the k3s binary for the host's architecture to `/usr/local/bin/k3s`. If the checksum doesn't match `checksums`, the apply fails and the old binary stays.
5. Writes the token to `/etc/rancher/k3s/token`, mode `0600`.
6. Writes `/etc/rancher/k3s/config.yaml`: the token file, every server's address as a `tls-san`, `cluster-init` when there's more than one server, and `server_config`.
7. Writes `/etc/systemd/system/k3s.service`, the unit k3s's install script writes, with a five-minute start timeout so a node that can't start fails the apply instead of hanging it.
8. Enables k3s at boot and starts it, once, with the settings above already in place.
9. Waits for the Kubernetes API to listen on port 6443 and for k3s's CRDs to be Established. If they aren't, the apply fails rather than leave a cluster that crash-loops. See [Troubleshooting](#troubleshooting).

Once that's done, the other servers do the same with `server` set to `server_url`, and the agents do the same with `k3s-agent.service` and the agent settings. A change to the binary, the token, the settings or the unit restarts k3s. Servers restart one at a time, each waiting until the last is back, so a cluster of three never has two etcd members down at once.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH. `x86_64` and `aarch64` are supported; others fail the plan.

The circuit doesn't open firewall ports. Between nodes, k3s needs TCP 6443 to the servers, UDP 8472 for flannel's VXLAN, TCP 10250 for the kubelet, and TCP 2379-2380 between servers with embedded etcd. On firewalld hosts, put the nodes' network in the `trusted` zone with a `firewalld` step of your own, or follow k3s's [requirements](https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes).

### Upgrading

Set `k3s_version` and `checksums` together. Take the checksums for `k3s` and `k3s-arm64` from the release's `sha256sum-amd64.txt` and `sha256sum-arm64.txt`. Conn3x replaces the binary and restarts k3s on each host, the servers one at a time. k3s supports moving up one minor version at a time.

## Troubleshooting

If k3s exits about once a minute with `failed waiting on CRD` and the API comes and goes, one of k3s's CRDs is stuck at `Established=False`, reason `Installing`. k3s was stopped while it was creating that CRD, and Kubernetes won't finish it after a restart. Versions of this circuit before v0.1.4 could cause it on the first start. A CRD in that state can't hold any objects, so it's safe to delete, and k3s creates it again when it starts. This deletes only the ones showing `False`:

```sh
for c in addons.k3s.cattle.io etcdsnapshotfiles.k3s.cattle.io helmcharts.helm.cattle.io helmchartconfigs.helm.cattle.io; do
  [ "$(k3s kubectl get crd "$c" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')" = False ] && k3s kubectl delete crd "$c"
done
systemctl restart k3s
```

Don't delete an Established one. That deletes every object of its kind, such as your HelmCharts.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `servers` | any | Required | Server nodes, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The first name in sorted order starts the cluster. |
| `first_server` | string | `null` | Server that starts the cluster. When null, the first name in sorted order. Keep it the same for the life of the cluster. |
| `agents` | any | `{}` | Agent nodes, by name, in the same form. A name can't be both a server and an agent. |
| `token` | string, ephemeral | Required | Shared secret nodes join with. Keep it the same for the life of the cluster. |
| `raspberry_pi` | bool | `false` | Turn on the memory cgroup in `/boot/firmware/cmdline.txt` and reboot once, for Raspberry Pi OS. |
| `server_url` | string | `null` | URL the other nodes join through. When null, `https://FIRST_SERVER_ADDRESS:6443`. Set it when the nodes reach the first server on a private address, or through a load balancer. |
| `server_config` | any | `{}` | More k3s server settings for `config.yaml`. |
| `agent_config` | any | `{}` | More k3s agent settings for `config.yaml`. |
| `k3s_version` | string | `"v1.37.1+k3s1"` | k3s release to install, as its tag. |
| `checksums` | map(string) | The v1.37.1+k3s1 checksums | SHA-256 of the `k3s` and `k3s-arm64` binaries. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

## Outputs

| Name | Description |
| --- | --- |
| `server_url` | URL of the Kubernetes API the nodes join through, such as `"https://203.0.113.10:6443"`. |

## Requirements

Requires Conn3x v0.6.9 or later, systemd on each host, and outbound HTTPS to github.com. k3s itself needs 2 GB of memory on a server and 512 MB on an agent.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, that the node is Ready, that k3s's CRDs are Established and that Traefik is running, and builds a cluster of three servers and an agent from [test/cluster](test/cluster). Three etcd members in containers on one shared runner are slow to agree, so that job skips etcd's fsync and still fails now and then. A server on a Rocky Linux 10 droplet with SELinux enforcing and an agent on Ubuntu 24.04 were also checked by hand. So was `raspberry_pi`, on a Debian 13 droplet with a stand-in `cmdline.txt`, which checks the edit and the reboot but not a Pi's kernel.

The high-availability layout was also run on four Ubuntu 24.04 droplets, three servers and an agent on a private network, with etcd's fsync on. The cluster came up with all four nodes Ready and three healthy etcd members, and the second plan had no changes. Changing `server_config` restarted the servers one at a time, and the API on the first server answered throughout the other two restarts. Upgrading k3s from v1.37.0 to v1.37.1 did the same, servers one at a time and then the agent, and at every moment at least one server's API answered. Rebooting the first server moved etcd's leader to another, the API kept answering there, and the plan stayed clean.

The first start was run 26 times on fresh droplets, 14 on Ubuntu 24.04 and 12 on Rocky Linux 10, plus four clusters of three servers and an agent, three on Ubuntu 24.04 and one on Rocky Linux 10. Every run started k3s once on the first server, and every CRD was Established with Traefik running. Upgrading a running cluster from v0.1.3 left k3s running without a restart on both systems.

## License

MPL-2.0. See [LICENSE](LICENSE). k3s itself is Apache-2.0.
