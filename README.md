# circuit-cassandra

[![Conn3x grade](https://conn3x.org/circuits/cassandra/grade.svg)](https://conn3x.org/circuits/cassandra/grade)

A Conn3x circuit that installs Apache Cassandra 5.0 from Apache's release tarball, runs it under systemd as its own user, and turns on password login straight away. You get one node, or a cluster when you give it seeds, with `cassandra.yaml` written from your inputs and checked before it replaces the old one.

Cassandra 5.0 runs on Java 11 or 17, and of the distributions here only Ubuntu 24.04 still packages 17. So every host gets Eclipse Temurin 17 from Adoptium's repository, the same build everywhere, and the circuit points Cassandra, `cqlsh` and `nodetool` at it. Your own `java` stays as it was.

A fresh Cassandra lets anyone in as `cassandra` with the password `cassandra`. The first apply changes that password to yours. It never lands in state: you pass it in at run time through an ephemeral variable.

## Usage

```hcl
variable "cassandra_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "cassandra" {
  source = "github.com/conn3xorg/circuit-cassandra?ref=v0.2.1"

  hosts                = { db = "192.168.1.40" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.cassandra_password
  heap_size      = "2G"
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_cassandra_password='...'
conn3x apply
```

The first apply downloads about 75 MB and waits for Cassandra to come up, which takes a minute or so. A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

For a cluster, give each host its own `listen_address`, the address the nodes reach each other on, and name two or three of them as seeds. Clients connect on `rpc_address`; `"0.0.0.0"` takes every address:

```hcl
module "cassandra" {
  source = "github.com/conn3xorg/circuit-cassandra?ref=v0.2.1"

  hosts = {
    cass1 = { address = "203.0.113.10", listen_address = "10.0.0.10" }
    cass2 = { address = "203.0.113.11", listen_address = "10.0.0.11" }
    cass3 = { address = "203.0.113.12", listen_address = "10.0.0.12" }
  }
  seeds        = ["10.0.0.10", "10.0.0.11"]
  rpc_address  = "0.0.0.0"
  cluster_name = "prod"

  admin_password = var.cassandra_password
  settings       = { endpoint_snitch = "GossipingPropertyFileSnitch" }
}
```

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks Adoptium's repository and the Java package by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.cass : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Installs `curl`, `tar`, `gzip`, `python3` and `ps`, which the download, Cassandra's scripts and `cqlsh` need. Fedora gets `python3.13` too: `cqlsh` 5.0 runs on Python 3.6 to 3.13, and Fedora 45's own Python is newer.
2. Adds Adoptium's repository and installs Temurin 17's runtime, `temurin-17-jre` on Debian and Ubuntu, `temurin-17-jre-headless` on the Red Hat family.
3. Creates a `cassandra` system user, and `/var/lib/cassandra` and `/var/log/cassandra` for it.
4. Downloads `apache-cassandra-VERSION-bin.tar.gz` from archive.apache.org and keeps it only if its SHA-256 matches `cassandra_sha256`. It unpacks into `/opt/cassandra/VERSION`, owned by root, and points `/opt/cassandra/current` at it.
5. Writes `/etc/cassandra/cassandra.yaml` from your inputs, owned by root and readable by `cassandra`. The new file is tested before it replaces the old one: `sstableutil` loads it the way a start does, as the `cassandra` user. A misspelt setting or a value of the wrong type fails the apply with Cassandra's own message, such as `Please remove properties [concurent_writes] from your cassandra.yaml`, and the old file stays, so a restart or a reboot keeps what it had.
6. Writes the password to `/etc/conn3x/cassandra/credentials` (root only, mode 0600), in the format `cqlsh --credentials` reads, so it never shows in `ps`.
7. Writes a systemd unit, `cassandra.service`, that runs `cassandra -f` as `cassandra` on Temurin 17 with the limits Cassandra's docs ask for, and `cqlsh` and `nodetool` wrappers in `/usr/local/bin` that find the right Java and Python.
8. Raises `vm.max_map_count` to 1048575, through `/etc/sysctl.d`, if it's lower.
9. Restarts Cassandra when the release, `cassandra.yaml` or the unit changed, and keeps it running and enabled at boot.
10. Waits for CQL, up to five minutes, then logs in as `cassandra` with `admin_password`. On a fresh node that fails, so it logs in with the default password once and changes it. The password only goes to a CQL port held by the `cassandra` user.

If someone edits `cassandra.yaml` by hand, the next plan shows the difference and the apply puts yours back, restarting Cassandra.

### What goes in cassandra.yaml

The circuit writes the whole file. Cassandra 5.0 has a default for every setting it leaves out. These come from the inputs, and `settings` can't set them:

| Setting | From |
| --- | --- |
| `cluster_name` | `cluster_name` |
| `listen_address` | the host object's `listen_address`, or `listen_address` |
| `rpc_address`, `broadcast_rpc_address` | `rpc_address`. With `"0.0.0.0"` or `"::"`, `broadcast_rpc_address` is the node's `listen_address`. |
| `seed_provider` | `seeds`, or the node itself |
| `authenticator`, `authorizer` | Always `PasswordAuthenticator` and `CassandraAuthorizer`. |
| Data, commit log, hints, saved caches and CDC directories | Under `/var/lib/cassandra`. |

These match the `cassandra.yaml` Cassandra ships, and `settings` can change them: `num_tokens: 16`, `allocate_tokens_for_local_replication_factor: 3`, `partitioner: Murmur3Partitioner`, `endpoint_snitch: SimpleSnitch`, `commitlog_sync: periodic` every `10000ms`. Anything else in `settings` goes in as it is, maps and lists included, so `{ concurrent_writes = 64 }` or `{ server_encryption_options = { internode_encryption = "all", ... } }` both work.

### Upgrades

Set `cassandra_version` and `cassandra_sha256` to a newer 5.0 release, which Apache publishes beside each tarball as `.sha256`. The circuit unpacks it next to the old one, moves `current` and restarts Cassandra. On a cluster, apply to one node at a time with `-target` or one host per apply, so the others stay up. The old release stays in `/opt/cassandra` until you remove it.

### What it doesn't cover

- **Other roles and keyspaces.** The circuit manages the `cassandra` superuser's password and nothing else in the database. Create your roles and keyspaces in CQL. On a cluster, raise the replication of `system_auth` too, or a node that's down can stop logins.
- **Password changes after the first.** Cassandra only takes the default password once. Change the password with `ALTER ROLE` first, then here. Until you do, the apply fails and says so.
- **TLS.** Client and internode encryption are `settings` like any other, and the keystores are yours to put on the host.
- **Firewall.** The circuit opens no ports. Nodes talk on 7000, clients on 9042, and `nodetool` uses JMX on 7199 on localhost only.
- **Cassandra 4.1 or 6.0.** The inputs are 5.0's. 6.0 is still an alpha.
- **Removal.** Taking the module out leaves Cassandra installed and its data in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts`, `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs, and `listen_address`, that node's own. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string, ephemeral | Required | Password for the `cassandra` superuser. At least 12 characters, no line breaks and no spaces at either end. |
| `cassandra_version` | string | `"5.0.9"` | Cassandra 5.0 release to install. Change `cassandra_sha256` with it. |
| `cassandra_sha256` | string | The SHA-256 of 5.0.9 | SHA-256 of `apache-cassandra-VERSION-bin.tar.gz`. |
| `cluster_name` | string | `"Conn3x Cluster"` | Every node in a cluster needs the same one, and Cassandra refuses to start on data from a cluster with another name. |
| `listen_address` | string | `"127.0.0.1"` | Address nodes talk to each other on. A host object's own `listen_address` wins over it. |
| `rpc_address` | string | `"127.0.0.1"` | Address CQL clients connect to. `"0.0.0.0"` takes every address. |
| `seeds` | list(string) | `[]` | `listen_address` of the seed nodes, such as `["10.0.0.10", "10.0.0.11"]`. When empty, each node is its own seed, which suits a single node. |
| `heap_size` | string | `null` | JVM heap, such as `"2G"` or `"512M"`. When null, Cassandra picks it from the host's memory. |
| `settings` | any | `{}` | More `cassandra.yaml` settings, such as `{ concurrent_writes = 64 }`. Changing them restarts Cassandra. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of `cassandra.yaml` on each host, `/etc/cassandra/cassandra.yaml`. |
| `cql_port` | Port CQL clients connect to, 9042 unless `settings` sets `native_transport_port`. |

## Requirements

Requires Conn3x v0.7.0 or later, systemd on each host, and outbound HTTPS to archive.apache.org, packages.adoptium.net and your distribution's mirrors. Cassandra wants at least 2 GB of memory; with less, set `heap_size` to `"512M"` or so. Each release takes about 150 MB of disk, tarball included. amd64 and arm64.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with Cassandra 5.0.9 on Temurin 17. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes and that the password isn't in the state. It then logs in with the new password, creates a keyspace and table, writes a row and reads it back, checks the default password is refused and `nodetool status` shows the node up, restarts the host, reads the row again and plans again with no changes. The same checks passed in arm64 containers of all four by hand.

Also by hand, in containers: a misspelt setting, which failed the apply with Cassandra's message and left the old file and the running node alone; and a change to `admin_password` without changing it in Cassandra first, which failed the apply with the message above.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, each with 1 vCPU, 2 GB of memory and `heap_size = "512M"`, the same apply passed, the second plan had no changes, and a row written over CQL read back. On Rocky Linux, Cassandra ran as `unconfined_service_t`, and the audit log had no denials. After a reboot both came back with the row, and the plan had no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). Apache Cassandra is Apache-2.0, and Temurin is GPL-2.0 with the Classpath Exception.
