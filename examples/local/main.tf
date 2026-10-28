variable "port" {
  type    = number
  default = 2222
}

variable "token" {
  type      = string
  ephemeral = true
  default   = "example-token-change-me"
}

module "k3s" {
  source = "../.."

  servers              = { server1 = "127.0.0.1" }
  token                = var.token
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}
