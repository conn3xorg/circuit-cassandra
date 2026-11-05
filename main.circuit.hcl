# Facts give each host's distribution, which picks Adoptium's repository and
# the Java package, and its architecture, which Debian and Ubuntu put in the
# Java directory's name.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  # Cassandra 5.0 runs on Java 11 or 17. Of the supported distributions only
  # Ubuntu 24.04 still packages 17, so every host gets Temurin 17 from
  # Adoptium instead, which builds it for all of them. Adoptium names its apt
  # suites by codename, and os-release on Debian and Ubuntu gives only the
  # number.
  temurin_suites = { "12" = "bookworm", "13" = "trixie", "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute" }
  debian_arch    = { x86_64 = "amd64", aarch64 = "arm64" }
  java_package   = { debian = "temurin-17-jre", redhat = "temurin-17-jre-headless" }
  java_home = { for name, f in local.family : name => f == "debian" ?
    "/usr/lib/jvm/temurin-17-jre-${lookup(local.debian_arch, data.conn3x_host.facts[name].arch, data.conn3x_host.facts[name].arch)}" :
    "/usr/lib/jvm/temurin-17-jre-headless"
  }

  # cqlsh 5.0 runs on Python 3.6 to 3.13, and Fedora 45's python3 is newer,
  # so Fedora gets its python3.13 package too.
  python       = { for name, o in local.os : name => o == "fedora" ? "python3.13" : "python3" }
  fedora_hosts = { for name, h in var.hosts : name => h if local.os[name] == "fedora" }

  v       = var.cassandra_version
  base    = "/opt/cassandra"
  home    = "${local.base}/${local.v}"
  tarball = "${local.base}/apache-cassandra-${local.v}-bin.tar.gz"
  data    = "/var/lib/cassandra"
  logs    = "/var/log/cassandra"
  etc     = "/etc/cassandra"
  config  = "${local.etc}/cassandra.yaml"

  credentials = "/etc/conn3x/cassandra/credentials"

  listen   = { for name, h in var.hosts : name => try(h.listen_address, var.listen_address) }
  cql_port = tonumber(try(var.settings.native_transport_port, 9042))

  # Defaults from the cassandra.yaml Cassandra ships, which settings can
  # change. The keys after them are the circuit's own inputs.
  yaml = { for name in keys(var.hosts) : name => yamlencode(merge(
    {
      num_tokens                                   = 16
      allocate_tokens_for_local_replication_factor = 3
      partitioner                                  = "org.apache.cassandra.dht.Murmur3Partitioner"
      endpoint_snitch                              = "SimpleSnitch"
      commitlog_sync                               = "periodic"
      commitlog_sync_period                        = "10000ms"
    },
    var.settings,
    {
      cluster_name          = var.cluster_name
      listen_address        = local.listen[name]
      rpc_address           = var.rpc_address
      broadcast_rpc_address = contains(["0.0.0.0", "::"], var.rpc_address) ? local.listen[name] : null
      seed_provider = [{
        class_name = "org.apache.cassandra.locator.SimpleSeedProvider"
        parameters = [{ seeds = join(",", length(var.seeds) > 0 ? var.seeds : [local.listen[name]]) }]
      }]
      authenticator          = "PasswordAuthenticator"
      authorizer             = "CassandraAuthorizer"
      data_file_directories  = ["${local.data}/data"]
      commitlog_directory    = "${local.data}/commitlog"
      saved_caches_directory = "${local.data}/saved_caches"
      hints_directory        = "${local.data}/hints"
      cdc_raw_directory      = "${local.data}/cdc_raw"
    },
  )) }

  # Cassandra has no command that only checks its configuration, but
  # sstableutil loads cassandra.yaml the way a start does, and stops at a
  # setting Cassandra doesn't know or a value of the wrong type. A good file
  # gets as far as looking for the table it was asked about, which doesn't
  # exist, and exits 1 for that. It runs as cassandra, in a copy of the
  # release's conf directory with the new file in it, so nothing it creates
  # belongs to root.
  config_test = { for name in keys(var.hosts) : name => join("; ", [
    "cd /",
    "d=$(mktemp -d)",
    "trap 'rm -rf \"$d\"' EXIT",
    "cp -r ${local.home}/conf/. \"$d\"",
    "cp %s \"$d/cassandra.yaml\"",
    "chown -R cassandra:cassandra \"$d\"",
    "out=$(runuser -u cassandra -- env JAVA_HOME=${local.java_home[name]} CASSANDRA_CONF=\"$d\" ${local.home}/bin/sstableutil conn3x_check none 2>&1) || true",
    "if echo \"$out\" | grep -q '^Unknown keyspace/table conn3x_check.none'; then exit 0; fi",
    "echo \"$out\" | grep -v '^\\s*at ' >&2",
    "exit 1",
  ]) }

  # Where the circuit itself talks to Cassandra. 0.0.0.0 and :: listen on
  # loopback too.
  cql_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "::1" }, var.rpc_address, var.rpc_address)

  # The password only goes to a CQL port held by the cassandra user.
  held  = <<-EOT
    held() { p=$(printf ':%04X$' ${local.cql_port}); u=$(id -u cassandra); cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$p" -v u="$u" '$4 == "0A" && $2 ~ p { n++; if ($8 != u) b = 1 } END { exit !(n && !b) }'; }
  EOT
  cqlsh = "CQLSH_PYTHON=%s ${local.base}/current/bin/cqlsh ${local.cql_host} ${local.cql_port}"
}

# cqlsh 5.0 runs on Python 3.6 to 3.13, and Fedora 45's python3 is newer.
circuit "cassandra_fedora" {
  hosts = local.fedora_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "python" {
    package {
      name = "python3.13"
    }
  }
}

circuit "cassandra" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # curl, tar and gzip fetch and unpack the release. Cassandra's scripts
  # need ps, and cqlsh needs Python.
  step "tools" {
    for_each = toset(["curl", "tar", "gzip", "python3"])
    package {
      name = item.value
    }
    depends_on = [conn3x_package.cassandra_fedora__python]
  }

  step "procps" {
    package {
      name = local.family[each.key] == "debian" ? "procps" : "procps-ng"
    }
  }

  # Adoptium builds one rpm repository for Fedora and one for RHEL, which
  # Rocky Linux and AlmaLinux use too. Its signing key has no expiry date.
  step "adoptium" {
    repository {
      name   = "adoptium"
      url    = local.family[each.key] == "debian" ? "https://packages.adoptium.net/artifactory/deb" : "https://packages.adoptium.net/artifactory/rpm/${local.os[each.key] == "fedora" ? "fedora" : "rhel"}/$releasever/$basearch"
      key    = file("${path.module}/files/adoptium.asc")
      suites = local.family[each.key] == "debian" ? [local.temurin_suites[data.conn3x_host.facts[each.key].os_version]] : null
    }
  }

  step "java" {
    package {
      name = local.java_package[local.family[each.key]]
    }
  }

  step "user" {
    user {
      name   = "cassandra"
      system = true
      home   = local.data
      shell  = "/usr/sbin/nologin"
    }
  }

  # Data and logs live outside the versioned install, so an upgrade keeps
  # them.
  step "dirs" {
    for_each = toset([local.data, local.logs])
    directory {
      path  = item.value
      owner = "cassandra"
      group = "cassandra"
      mode  = "0750"
    }
  }

  # cassandra.yaml belongs to root, and cassandra can only read it.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "cassandra"
      mode  = "0750"
    }
  }

  step "tarball" {
    download {
      url    = "https://archive.apache.org/dist/cassandra/${local.v}/apache-cassandra-${local.v}-bin.tar.gz"
      sha256 = var.cassandra_sha256
      dest   = local.tarball
    }
  }

  # Unpacked by hand rather than with an archive step, so the files belong
  # to root instead of the uid that built the release.
  step "unpack" {
    command {
      command = "cd ${local.base} && rm -rf .unpack && mkdir .unpack && tar --no-same-owner -xzf ${local.tarball} -C .unpack && rm -rf ${local.v} && mv .unpack/apache-cassandra-${local.v} ${local.v} && rmdir .unpack"
      creates = "${local.home}/bin/cassandra"
    }
  }

  step "current" {
    link {
      path   = "${local.base}/current"
      target = local.v
    }
  }

  # A bad file fails the apply here, and the one Cassandra started with
  # stays for the next restart.
  step "config" {
    file {
      path     = local.config
      content  = local.yaml[each.key]
      owner    = "root"
      group    = "cassandra"
      mode     = "0640"
      validate = local.config_test[each.key]
    }
  }

  # cqlsh reads the password from this file, so it never shows in ps.
  # Write-only: the plan and state record only an HMAC of the content.
  step "credentials_dir" {
    directory {
      path = dirname(local.credentials)
      mode = "0700"
    }
  }

  step "credentials" {
    file {
      path       = local.credentials
      content_wo = "[plain_text_auth]\nusername = cassandra\npassword = ${var.admin_password}\n"
      mode       = "0600"
    }
  }

  # cassandra-env.sh sizes the heap from the host's memory unless
  # MAX_HEAP_SIZE is set. With G1, the collector Cassandra 5.0 uses on Java
  # 17, it needs no HEAP_NEWSIZE.
  step "unit" {
    file {
      path    = "/etc/systemd/system/cassandra.service"
      content = <<-EOT
        [Unit]
        Description=Apache Cassandra
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=cassandra
        Group=cassandra
        Environment=JAVA_HOME=${local.java_home[each.key]}
        Environment=CASSANDRA_LOG_DIR=${local.logs}
        Environment=JVM_EXTRA_OPTS=-Dcassandra.config=file://${local.config}
        ${var.heap_size == null ? "" : "Environment=MAX_HEAP_SIZE=${var.heap_size}"}
        ExecStart=${local.base}/current/bin/cassandra -f
        # The JVM exits with 143 when systemd stops it with SIGTERM.
        SuccessExitStatus=143
        Restart=on-failure
        TimeoutStartSec=300
        TimeoutStopSec=180
        LimitNOFILE=1048576
        LimitNPROC=32768
        LimitMEMLOCK=infinity
        LimitAS=infinity

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # cqlsh and nodetool on the PATH, with the Java and Python they need.
  step "cqlsh" {
    file {
      path    = "/usr/local/bin/cqlsh"
      content = "#!/bin/sh\nexport CQLSH_PYTHON=\"$${CQLSH_PYTHON:-${local.python[each.key]}}\"\nexec ${local.base}/current/bin/cqlsh \"$@\"\n"
      mode    = "0755"
    }
  }

  step "nodetool" {
    file {
      path    = "/usr/local/bin/nodetool"
      content = "#!/bin/sh\nexport JAVA_HOME=\"$${JAVA_HOME:-${local.java_home[each.key]}}\"\nexec ${local.base}/current/bin/nodetool \"$@\"\n"
      mode    = "0755"
    }
  }

  # Cassandra's docs ask for this many memory map areas. The unless only
  # raises it: a host that already allows more keeps its value.
  step "max_map_count" {
    command {
      command = "echo vm.max_map_count=1048575 > /etc/sysctl.d/90-conn3x-cassandra.conf && sysctl -q -p /etc/sysctl.d/90-conn3x-cassandra.conf"
      unless  = "[ \"$(sysctl -n vm.max_map_count)\" -ge 1048575 ]"
    }
  }

  # A step rather than a handler, so the step below finds Cassandra running
  # the new release and settings. On a first apply it's what starts it.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart cassandra"
      triggers = {
        current = conn3x_link.cassandra__current[each.key].revision
        config  = conn3x_file.cassandra__config[each.key].revision
        unit    = conn3x_file.cassandra__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "cassandra"
      state   = "started"
      enabled = true
    }
  }

  # Cassandra creates the cassandra superuser, with the password cassandra,
  # a few seconds after its first start. This waits for CQL, then logs in
  # with admin_password, or with the default once and changes it. A later
  # change to admin_password fails the apply until it's made in Cassandra
  # too. The new password reaches cqlsh on stdin. unless is checked at plan
  # time, before the restart, so the restart's revision makes the apply
  # check again.
  step "admin_password" {
    command {
      command = <<-EOT
        ${local.held}
        cd /
        d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
        printf '[plain_text_auth]\nusername = cassandra\npassword = cassandra\n' > "$d/default"; chmod 600 "$d/default"
        for _ in $(seq 150); do
          if held; then
            ${format(local.cqlsh, local.python[each.key])} --credentials ${local.credentials} -e 'SELECT role FROM system_auth.roles LIMIT 1' >/dev/null 2>&1 && exit 0
            if ${format(local.cqlsh, local.python[each.key])} --credentials "$d/default" -e 'SELECT role FROM system_auth.roles LIMIT 1' >/dev/null 2>&1; then
              sed -n 's/^password = //p' ${local.credentials} | sed "s/'/''/g" | { IFS= read -r pw; printf "ALTER ROLE cassandra WITH PASSWORD = '%s';\n" "$pw"; } > "$d/alter.cql"
              ${format(local.cqlsh, local.python[each.key])} --credentials "$d/default" -f "$d/alter.cql" || exit 1
            fi
          fi
          sleep 2
        done
        echo 'Cassandra did not accept admin_password, or the default password, for the cassandra role within 5 minutes. If you changed admin_password, change it in Cassandra first. See journalctl -u cassandra.' >&2
        exit 1
      EOT
      unless  = "${local.held} held && ${format(local.cqlsh, local.python[each.key])} --credentials ${local.credentials} -e 'SELECT role FROM system_auth.roles LIMIT 1' >/dev/null 2>&1"
      triggers = {
        credentials = conn3x_file.cassandra__credentials[each.key].revision
        restart     = conn3x_command.cassandra__restart[each.key].revision
      }
    }
  }
}
