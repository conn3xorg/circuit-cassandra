output "config_file" {
  description = "Path of the cassandra.yaml the circuit writes on each host."
  value       = "/etc/cassandra/cassandra.yaml"
}

output "cql_port" {
  description = "Port CQL clients connect to."
  value       = local.cql_port
}
