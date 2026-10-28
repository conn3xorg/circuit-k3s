variable "servers" {
  type        = any
  description = "Server nodes, by name: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts. The first name in sorted order starts the cluster."

  validation {
    condition     = length(var.servers) > 0
    error_message = "Give at least one server."
  }
}

variable "agents" {
  type        = any
  default     = {}
  description = "Agent nodes, by name, in the same form as servers. A name can't be both a server and an agent."

  validation {
    condition     = length(setintersection(keys(var.servers), keys(var.agents))) == 0
    error_message = "A name can't be both a server and an agent."
  }
}

variable "token" {
  type        = string
  ephemeral   = true
  description = "Shared secret nodes use to join the cluster, such as the output of openssl rand -hex 32. Keep it the same for the life of the cluster."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "k3s_version" {
  type        = string
  default     = "v1.37.1+k3s1"
  description = "k3s release to install, as its tag."
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the k3s binary for each architecture, from the release's sha256sum-ARCH.txt files. Change these with k3s_version."
  default = {
    k3s         = "92b94582eb7b34a8cf532e6006842b9ed215a6783cf56a3dd6271fd35243b2c0"
    "k3s-arm64" = "a1561ca4aef8b99f5588a840d4468ac39c8c1cd92470bbcb9634823fa221741a"
  }
}

variable "server_url" {
  type        = string
  default     = null
  description = "URL the other nodes join through. When null, https://FIRST_SERVER_ADDRESS:6443."
}

variable "server_config" {
  type        = any
  default     = {}
  description = "More k3s server settings for /etc/rancher/k3s/config.yaml, as k3s's flag names without the dashes, such as { disable = [\"traefik\"] }."
}

variable "agent_config" {
  type        = any
  default     = {}
  description = "More k3s agent settings for /etc/rancher/k3s/config.yaml, such as { node-label = [\"role=worker\"] }."
}
