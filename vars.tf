variable "packet_api_key" {
  default = "YOUR-API-KEY"
}

variable "packet_org_id" {
  default = "YOUR_PACKET_ORG_ID"
}

variable "project" {
  default = "talos"
}

variable "packet_facility" {
  default = "ewr1"
}

// All server type slugs are available via the API endpoint /plans

// The Packet server type to use as your talos workers
variable "packet_worker_type" {
  default = "baremetal_0"
}

// The Packet server type to use as your talos masters
variable "packet_master_type" {
  default = "baremetal_0"
}

// The Packet server type to use as your talos bootstrap server
variable "packet_boot_type" {
  default = "baremetal_0"
}

variable "talos_master_count" {
  default = "1"
}

variable "talos_worker_count" {
  default = "1"
}

// Github usernames to pull pub ssh keys for
variable "github_users" {
  default = []
}

variable "talos_version" {
  default = "v0.1.0-alpha.13"
}

variable "talos_boot_args" {
  default = [
    "random.trust_cpu=on",
    "serial",
    "console=tty0",
    "console=ttyS1,115200n8",
    "ip=dhcp",
    "printk.devkmsg=on",
  ]
}

variable "talos_platform" {
  default = "bare-metal"
}

variable "cluster_name" {
  default = ""
}

variable "container_network_interface" {
  default = ""
}

variable "control_plane_endpoint" {
  default = ""
}

variable "dns_domain" {
  default = ""
}

variable "labels" {
  default = ""
}

variable "pod_subnet" {
  default = ""
}

variable "service_subnet" {
  default = ""
}

variable "taints" {
  default = ""
}
