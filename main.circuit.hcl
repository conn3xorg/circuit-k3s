# Facts give each host's architecture, which picks the k3s binary.
data "conn3x_host" "facts" {
  for_each = merge(var.servers, var.agents)

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  # The first server by name starts the cluster. The others join it.
  first      = coalesce(var.first_server, sort(keys(var.servers))[0])
  server_url = coalesce(var.server_url, "https://${try(var.servers[local.first].address, var.servers[local.first])}:6443")
  # Pod traffic to services needs br_netfilter. Rocky Linux 10 and other
  # EL10 images ship it in kernel-modules-extra, which they don't install.
  # A container can't load modules, so a module its host loaded counts.
  br_netfilter = {
    command = "command -v dnf >/dev/null || { echo 'br_netfilter is missing and this host has no dnf to install kernel-modules-extra' >&2; exit 1; }; dnf -y install \"kernel-modules-extra-$(uname -r)\""
    unless  = "test -d /sys/module/br_netfilter || modprobe -n br_netfilter"
  }

  pi = var.raspberry_pi ? toset(["cmdline"]) : toset([])
  pi_cgroups = {
    command = "sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt"
    unless  = "grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt"
  }

  binary = { x86_64 = "k3s", aarch64 = "k3s-arm64" }
  url    = { for name, f in data.conn3x_host.facts : name => "https://github.com/k3s-io/k3s/releases/download/${urlencode(var.k3s_version)}/${local.binary[f.arch]}" }
  sha256 = { for name, f in data.conn3x_host.facts : name => var.checksums[local.binary[f.arch]] }

  server_config = merge({
    token-file = "/etc/rancher/k3s/token"
    tls-san    = [for s in var.servers : try(s.address, s)]
  }, var.server_config)

  # k3s leaves out the Helm CRDs when its Helm controller is off.
  crds             = concat(["addons.k3s.cattle.io", "etcdsnapshotfiles.k3s.cattle.io"], try(var.server_config["disable-helm-controller"], false) ? [] : ["helmcharts.helm.cattle.io", "helmchartconfigs.helm.cattle.io"])
  crds_established = "/usr/local/bin/k3s kubectl wait --for=condition=Established ${join(" ", [for c in local.crds : "crd/${c}"])} --timeout=5s >/dev/null 2>&1"

  # Taken from the unit k3s's install script writes, with a start timeout
  # so a node that can't join fails the apply instead of hanging it.
  unit = <<-EOT
    [Unit]
    Description=Lightweight Kubernetes
    Documentation=https://k3s.io
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=notify
    EnvironmentFile=-/etc/default/%N
    KillMode=process
    Delegate=yes
    User=root
    LimitNOFILE=1048576
    LimitNPROC=infinity
    LimitCORE=infinity
    TasksMax=infinity
    TimeoutStartSec=5min
    Restart=always
    RestartSec=5s
    ExecStartPre=-/sbin/modprobe br_netfilter
    ExecStartPre=-/sbin/modprobe overlay
    ExecStart=/usr/local/bin/k3s %ROLE%

    [Install]
    WantedBy=multi-user.target
  EOT
}

circuit "k3s_first" {
  hosts = { (local.first) = var.servers[local.first] }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack curl, which the download needs.
  step "curl" {
    package {
      name = "curl"
    }
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
    }
  }

  # Raspberry Pi OS boots with the memory cgroup off, and k3s needs it.
  step "pi_cgroups" {
    for_each = local.pi
    command {
      command = local.pi_cgroups.command
      unless  = local.pi_cgroups.unless
    }
  }

  step "pi_reboot" {
    for_each = local.pi
    reboot {
      triggers = { cmdline = local.pi_cgroups.command }
    }
  }

  step "binary" {
    download {
      url    = local.url[each.key]
      sha256 = local.sha256[each.key]
      dest   = "/usr/local/bin/k3s"
      mode   = "0755"
    }
    notify = [handler.restart]
  }

  step "config_dir" {
    directory {
      path = "/etc/rancher/k3s"
    }
  }

  step "token" {
    file {
      path       = "/etc/rancher/k3s/token"
      content_wo = var.token
    }
    notify = [handler.restart]
  }

  step "config" {
    file {
      path    = "/etc/rancher/k3s/config.yaml"
      content = yamlencode(merge(local.server_config, length(var.servers) > 1 ? { cluster-init = true } : {}))
    }
    notify = [handler.restart]
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/k3s.service"
      content = replace(local.unit, "%ROLE%", "server")
    }
    notify = [handler.restart]
  }

  # Enabled, not started: on a new host the handler below is the first start.
  # Starting here too would have it restart k3s while k3s creates its CRDs,
  # and a CRD interrupted there stays Established=False for good.
  step "enabled" {
    service {
      name    = "k3s"
      enabled = true
    }
  }

  # One server at a time: two etcd members down at once loses quorum.
  handler "restart" {
    service {
      name   = "k3s"
      serial = true
    }
  }
}

# Handlers run after a circuit's steps, so what comes after the first start
# needs a circuit of its own.
circuit "k3s_first_up" {
  hosts = { (local.first) = var.servers[local.first] }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "running" {
    service {
      name  = "k3s"
      state = "started"
    }
    depends_on = [conn3x_service_action.k3s_first__restart]
  }

  step "api" {
    wait_for {
      port = 6443
    }
  }

  # The apply fails here rather than leave a cluster that crash-loops.
  step "crds" {
    command {
      command = "for _ in $(seq 36); do ${local.crds_established} && exit 0; sleep 5; done; echo 'k3s CRDs did not become Established. See Troubleshooting in the circuit-k3s README.' >&2; exit 1"
      unless  = local.crds_established
    }
  }
}

circuit "k3s_servers" {
  hosts = { for name, h in var.servers : name => h if name != local.first }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [conn3x_command.k3s_first_up__crds]
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
    }
  }

  # Raspberry Pi OS boots with the memory cgroup off, and k3s needs it.
  step "pi_cgroups" {
    for_each = local.pi
    command {
      command = local.pi_cgroups.command
      unless  = local.pi_cgroups.unless
    }
  }

  step "pi_reboot" {
    for_each = local.pi
    reboot {
      triggers = { cmdline = local.pi_cgroups.command }
    }
  }

  step "binary" {
    download {
      url    = local.url[each.key]
      sha256 = local.sha256[each.key]
      dest   = "/usr/local/bin/k3s"
      mode   = "0755"
    }
    notify = [handler.restart]
  }

  step "config_dir" {
    directory {
      path = "/etc/rancher/k3s"
    }
  }

  step "token" {
    file {
      path       = "/etc/rancher/k3s/token"
      content_wo = var.token
    }
    notify = [handler.restart]
  }

  step "config" {
    file {
      path    = "/etc/rancher/k3s/config.yaml"
      content = yamlencode(merge(local.server_config, { server = local.server_url }))
    }
    notify = [handler.restart]
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/k3s.service"
      content = replace(local.unit, "%ROLE%", "server")
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "k3s"
      state   = "started"
      enabled = true
    }
  }

  # One server at a time: two etcd members down at once loses quorum.
  handler "restart" {
    service {
      name   = "k3s"
      serial = true
    }
  }
}

circuit "k3s_agents" {
  hosts = var.agents

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Agents join once every server is up. While a server joins embedded
  # etcd, or restarts, a two-server cluster has no quorum, and an agent
  # starting then can outlast its start timeout.
  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [conn3x_command.k3s_first_up__crds, conn3x_service_action.k3s_servers__restart]
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
    }
  }

  # Raspberry Pi OS boots with the memory cgroup off, and k3s needs it.
  step "pi_cgroups" {
    for_each = local.pi
    command {
      command = local.pi_cgroups.command
      unless  = local.pi_cgroups.unless
    }
  }

  step "pi_reboot" {
    for_each = local.pi
    reboot {
      triggers = { cmdline = local.pi_cgroups.command }
    }
  }

  step "binary" {
    download {
      url    = local.url[each.key]
      sha256 = local.sha256[each.key]
      dest   = "/usr/local/bin/k3s"
      mode   = "0755"
    }
    notify = [handler.restart]
  }

  step "config_dir" {
    directory {
      path = "/etc/rancher/k3s"
    }
  }

  step "token" {
    file {
      path       = "/etc/rancher/k3s/token"
      content_wo = var.token
    }
    notify = [handler.restart]
  }

  step "config" {
    file {
      path = "/etc/rancher/k3s/config.yaml"
      content = yamlencode(merge({
        server     = local.server_url
        token-file = "/etc/rancher/k3s/token"
      }, var.agent_config))
    }
    notify = [handler.restart]
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/k3s-agent.service"
      content = replace(local.unit, "%ROLE%", "agent")
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "k3s-agent"
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = "k3s-agent"
    }
  }
}
