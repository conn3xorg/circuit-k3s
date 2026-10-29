# Three servers and an agent, in containers that up.sh started on ports 2221
# to 2224. Three, because etcd needs an odd number of servers to keep quorum. CI passes the first server's container address as server_ip.
variable "server_ip" {
  type = string
}

module "k3s" {
  source = "../.."

  servers = {
    s1 = { address = "127.0.0.1", port = 2221 }
    s2 = { address = "127.0.0.1", port = 2222 }
    s3 = { address = "127.0.0.1", port = 2223 }
  }
  agents               = { a1 = { address = "127.0.0.1", port = 2224 } }
  server_url           = "https://${var.server_ip}:6443"
  token                = "ci-only-token"
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}
