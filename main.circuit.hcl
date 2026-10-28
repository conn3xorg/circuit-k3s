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
  first      = sort(keys(var.servers))[0]
  server_url = coalesce(var.server_url, "https://${try(var.servers[local.first].address, var.servers[local.first])}:6443")
  # Pod traffic to services needs br_netfilter. Rocky Linux 10 and other
  # EL10 images ship it in kernel-modules-extra, which they don't install.
  # A container can't load modules, so a module its host loaded counts.
  br_netfilter = {
    command = "dnf -y install \"kernel-modules-extra-$(uname -r)\""
    unless  = "test -d /sys/module/br_netfilter || modprobe -n br_netfilter"
  }

  binary = { x86_64 = "k3s", aarch64 = "k3s-arm64" }
  url    = { for name, f in data.conn3x_host.facts : name => "https://github.com/k3s-io/k3s/releases/download/${urlencode(var.k3s_version)}/${local.binary[f.arch]}" }
  sha256 = { for name, f in data.conn3x_host.facts : name => var.checksums[local.binary[f.arch]] }

  server_config = merge({
    token-file = "/etc/rancher/k3s/token"
    tls-san    = [for s in var.servers : try(s.address, s)]
  }, var.server_config)

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

  step "running" {
    service {
      name    = "k3s"
      state   = "started"
      enabled = true
    }
  }

  step "api" {
    wait_for {
      port = 6443
    }
  }

  handler "restart" {
    service {
      name = "k3s"
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
    depends_on = [conn3x_wait_for.k3s_first__api]
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
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

  handler "restart" {
    service {
      name = "k3s"
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

  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [conn3x_wait_for.k3s_first__api]
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
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
