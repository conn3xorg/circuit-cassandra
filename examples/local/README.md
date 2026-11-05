# Local example

Applies circuit-cassandra to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman, and about 1.5 GB of memory free for Cassandra.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The apply waits for Cassandra to take CQL connections, which takes a minute or so. The second plan says `No changes.` Cassandra listens on `127.0.0.1:9042` inside the container, with a 512 MB heap. To log in:

```sh
ssh -t -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  cqlsh --credentials /etc/conn3x/cassandra/credentials
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
