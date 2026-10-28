# Local example

Applies circuit-k3s to a throwaway Rocky Linux 10 container with systemd, as a one-node cluster. You need Conn3x and Podman.

k3s runs containers of its own, so the host container runs privileged, and rootless Podman can't give it the cpuset cgroup k3s needs. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 k3s kubectl get nodes
```

The container can't load kernel modules, so its host needs `br_netfilter` and `overlay` loaded. A Podman machine has both. On Linux, run `sudo modprobe -a br_netfilter overlay` first.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volume, the key and the state.
