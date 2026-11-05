variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts, os or listen_address."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }

  validation {
    condition     = alltrue([for h in var.hosts : can(cidrhost("${try(h.listen_address, "127.0.0.1")}/${strcontains(try(h.listen_address, ""), ":") ? 128 : 32}", 0))])
    error_message = "A host object's listen_address must be one IPv4 or IPv6 address, such as \"10.0.0.5\"."
  }
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


variable "cassandra_version" {
  type        = string
  default     = "5.0.9"
  description = "Apache Cassandra 5.0 release to install, such as \"5.0.9\". Change cassandra_sha256 with it. Raising it installs the new release beside the old one and restarts Cassandra on it."

  validation {
    condition     = can(regex("^5\\.0\\.[0-9]+$", var.cassandra_version))
    error_message = "cassandra_version must be a 5.0 release, such as \"5.0.9\"."
  }
}

variable "cassandra_sha256" {
  type        = string
  default     = "eee1460b47ebe188a29521207230617f22aad7f9e1674f5ea454f10c8f344d61"
  description = "SHA-256 of apache-cassandra-VERSION-bin.tar.gz, from the .sha256 file Apache publishes beside it. Change it with cassandra_version."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.cassandra_sha256))
    error_message = "cassandra_sha256 must be a SHA-256 in lowercase hex."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for Cassandra's cassandra superuser, which the circuit changes from the default on the first apply. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  # cqlsh reads it from an ini file, which trims spaces at either end.
  validation {
    condition     = length(var.admin_password) >= 12 && var.admin_password != "cassandra" && !can(regex("[\\r\\n]", var.admin_password)) && trimspace(var.admin_password) == var.admin_password
    error_message = "admin_password must be at least 12 characters, with no line breaks and no spaces at either end."
  }
}

variable "cluster_name" {
  type        = string
  default     = "Conn3x Cluster"
  description = "cluster_name. Every node in a cluster needs the same one, and Cassandra refuses to start on data from a cluster with another name."

  validation {
    condition     = can(regex("^[A-Za-z0-9 ._-]+$", var.cluster_name))
    error_message = "cluster_name may use letters, digits, spaces, ., _ and -."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "IP address nodes talk to each other on, its listen_address. A host object's own listen_address wins over it, which a cluster needs since each node has its own."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0)) && !contains(["0.0.0.0", "::"], var.listen_address)
    error_message = "listen_address must be one IPv4 or IPv6 address, such as \"10.0.0.5\". Cassandra can't listen on 0.0.0.0 between nodes."
  }
}

variable "rpc_address" {
  type        = string
  default     = "127.0.0.1"
  description = "IP address CQL clients connect to, its rpc_address. \"0.0.0.0\" listens on every address and tells clients the node's listen_address."

  validation {
    condition     = can(cidrhost("${var.rpc_address}/${strcontains(var.rpc_address, ":") ? 128 : 32}", 0))
    error_message = "rpc_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\", \"10.0.0.5\" or \"0.0.0.0\"."
  }
}

variable "seeds" {
  type        = list(string)
  default     = []
  description = "listen_address of the seed nodes new nodes contact to join, such as [\"10.0.0.5\", \"10.0.0.6\"]. When empty, each node is its own seed, which suits a single node."

  validation {
    condition     = alltrue([for s in var.seeds : can(regex("^[A-Za-z0-9.:\\[\\]-]+$", s))])
    error_message = "Each seed must be an address, such as \"10.0.0.5\" or \"10.0.0.5:7000\"."
  }
}

variable "heap_size" {
  type        = string
  default     = null
  description = "JVM heap, its MAX_HEAP_SIZE, such as \"2G\" or \"512M\". When null, Cassandra picks it from the host's memory: half of it up to 1G, or a quarter up to 8G, whichever is more."

  validation {
    condition     = var.heap_size == null || can(regex("^[1-9][0-9]*[MG]$", coalesce(var.heap_size, "1G")))
    error_message = "heap_size must be a whole number of megabytes or gigabytes, such as \"512M\" or \"4G\"."
  }
}

variable "settings" {
  type        = any
  default     = {}
  description = "More cassandra.yaml settings, such as { concurrent_writes = 64, num_tokens = 8 }. Values can be maps and lists. The apply checks them before they replace the old file, and changing them restarts Cassandra."

  validation {
    condition     = can(keys(var.settings)) && alltrue([for k in keys(var.settings) : can(regex("^[a-z][a-z0-9_]*$", k))])
    error_message = "settings must be a map of cassandra.yaml keys, which use lowercase letters, digits and _."
  }

  validation {
    condition = alltrue([for k in keys(var.settings) : !contains([
      "cluster_name", "listen_address", "listen_interface", "rpc_address", "rpc_interface", "broadcast_rpc_address", "seed_provider",
      "authenticator", "authorizer", "data_file_directories", "commitlog_directory", "saved_caches_directory", "hints_directory", "cdc_raw_directory",
    ], k)])
    error_message = "settings can't set cluster_name, listen_address, rpc_address, seed_provider, authenticator, authorizer, their _interface forms or the data directories. Use the circuit's own inputs for the first four."
  }

  validation {
    condition     = can(tonumber(lookup(var.settings, "native_transport_port", 9042)))
    error_message = "native_transport_port must be a number."
  }
}
