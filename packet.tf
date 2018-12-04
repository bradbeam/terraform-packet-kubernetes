provider "packet" {
  auth_token = "${var.packet_api_key}"
}

# Create a project
resource "packet_project" "talos" {
  name            = "${var.project}"
  organization_id = "${var.packet_org_id}"
}

data "http" "githubsshkey" {
  url   = "https://github.com/${var.github_users[count.index]}.keys"
  count = "${length(var.github_users)}"
}

locals {
  public_keys    = "${compact(split("\n",join("\n",flatten(data.http.githubsshkey.*.body))))}"
  talos_userdata = "talos.autonomy.io/userdata=${var.talos_userdata_path}"
  talos_platform = "talos.autonomy.io/platform=${var.talos_platform}"
}

resource "packet_ssh_key" "users" {
  name       = "${format("user-%02d", count.index + 1)}"
  count      = "${length(local.public_keys)}"
  public_key = "${local.public_keys[count.index]}"
}

data "template_file" "matchbox_worker_group" {
  template = "${file("${path.module}/templates/matchbox_default_group.tmpl")}"

  vars {
    profile = "talos-worker"
  }
}

data "template_file" "matchbox_init_group" {
  template = "${file("${path.module}/templates/matchbox_host_group.tmpl")}"

  vars {
    hostname = "${format("talosm-%02d.example.com", 1)}"
    profile  = "talos-init"
  }
}

data "template_file" "matchbox_master_group" {
  template = "${file("${path.module}/templates/matchbox_host_group.tmpl")}"

  // Skip first master since it is init node
  count = "${var.talos_master_count - 1}"

  vars {
    hostname = "${format("talosm-%02d.example.com", count.index + 2)}"
    profile  = "talos-master"
  }
}

resource "packet_device" "talos_bootstrap" {
  hostname         = "${format("talos-ipxe-%02d.example.com", count.index + 1)}"
  operating_system = "ubuntu_18_04"
  plan             = "${var.packet_boot_type}"
  facility         = "${var.packet_facility}"
  project_id       = "${packet_project.talos.id}"
  billing_cycle    = "hourly"
}

data "template_file" "matchbox_master_profile" {
  template = "${file("${path.module}/templates/matchbox_profile.tmpl")}"

  vars {
    id            = "talos-master"
    talos_version = "${var.talos_version}"
    talos_args    = "${jsonencode(concat(var.talos_boot_args, list(local.talos_platform, "talos.autonomy.io/userdata=http://${packet_device.talos_bootstrap.network.0.address}:8080/assets/talos/${var.talos_version}/userdata-master.yaml")))}"
  }
}

data "template_file" "matchbox_worker_profile" {
  template = "${file("${path.module}/templates/matchbox_profile.tmpl")}"

  vars {
    id            = "talos-worker"
    talos_version = "${var.talos_version}"
    talos_args    = "${jsonencode(concat(var.talos_boot_args, list(local.talos_platform, "talos.autonomy.io/userdata=http://${packet_device.talos_bootstrap.network.0.address}:8080/assets/talos/${var.talos_version}/userdata-worker.yaml")))}"
  }
}

data "template_file" "matchbox_init_profile" {
  template = "${file("${path.module}/templates/matchbox_profile.tmpl")}"

  vars {
    id            = "talos-init"
    talos_version = "${var.talos_version}"
    talos_args    = "${jsonencode(concat(var.talos_boot_args, list(local.talos_platform, "talos.autonomy.io/userdata=http://${packet_device.talos_bootstrap.network.0.address}:8080/assets/talos/${var.talos_version}/userdata-init.yaml")))}"
  }
}

resource "null_resource" "matchbox_profiles" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    initprofile   = "${data.template_file.matchbox_init_profile.rendered}"
    workerprofile = "${data.template_file.matchbox_worker_profile.rendered}"
    masterprofile = "${data.template_file.matchbox_master_profile.rendered}"
    bootstrap     = "${packet_device.talos_bootstrap.id}"

    // TODO add additional groups here for matchers
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host = "${packet_device.talos_bootstrap.network.0.address}"
  }

  // Install Matchbox
  provisioner "remote-exec" {
    inline = [
      "wget https://github.com/coreos/matchbox/releases/download/v0.7.1/matchbox-v0.7.1-linux-amd64.tar.gz",
      "tar xzvf matchbox-v0.7.1-linux-amd64.tar.gz",
      "mv matchbox-v0.7.1-linux-amd64/matchbox /usr/local/bin",
      "id matchbox || useradd -U matchbox",
      "mkdir -p /var/lib/matchbox/assets/talos/${var.talos_version}",
      "mkdir -p /var/lib/matchbox/groups",
      "mkdir -p /var/lib/matchbox/profiles",
      "chown -R matchbox:matchbox /var/lib/matchbox",
      "cp matchbox-v0.7.1-linux-amd64/contrib/systemd/matchbox-local.service /etc/systemd/system/matchbox.service",
      "systemctl daemon-reload",
      "systemctl enable matchbox",
      "systemctl start matchbox",
    ]
  }

  provisioner "file" {
    content     = "${data.template_file.matchbox_worker_group.rendered}"
    destination = "/var/lib/matchbox/groups/talos-worker.json"
  }

  provisioner "file" {
    content     = "${data.template_file.matchbox_init_group.rendered}"
    destination = "/var/lib/matchbox/groups/talos-init.json"
  }

  // Download talos assets
  provisioner "remote-exec" {
    inline = [
      "cd /var/lib/matchbox/assets/talos/${var.talos_version}",
      "[[ -f /var/lib/matchbox/assets/talos/${var.talos_version}/vmlinuz ]] || wget https://github.com/autonomy/talos/releases/download/${var.talos_version}/vmlinuz",
      "[[ -f /var/lib/matchbox/assets/talos/${var.talos_version}/initramfs.xz ]] || wget https://github.com/autonomy/talos/releases/download/${var.talos_version}/initramfs.xz",
    ]
  }

  provisioner "file" {
    content     = "${data.template_file.matchbox_worker_profile.rendered}"
    destination = "/var/lib/matchbox/profiles/talos-worker.json"
  }

  provisioner "file" {
    content     = "${data.template_file.matchbox_init_profile.rendered}"
    destination = "/var/lib/matchbox/profiles/talos-init.json"
  }

  provisioner "file" {
    content     = "${data.template_file.matchbox_master_profile.rendered}"
    destination = "/var/lib/matchbox/profiles/talos-master.json"
  }
}

resource "null_resource" "matchbox_master_groups" {
  triggers {
    mastergroups = "${join(",", data.template_file.matchbox_master_group.*.rendered)}"
    bootstrap    = "${packet_device.talos_bootstrap.id}"
  }

  // Bootstrap script can run on any instance of the cluster
  // So we just choose the first in this case
  connection {
    host = "${packet_device.talos_bootstrap.network.0.address}"
  }

  count = "${var.talos_master_count}"

  provisioner "file" {
    content     = "${element(data.template_file.matchbox_master_group.*.rendered, count.index)}"
    destination = "${format("%s-%02d%s", "/var/lib/matchbox/groups/talos-master", count.index+1, ".json")}"
  }
}

resource "packet_device" "talos_master" {
  hostname         = "${format("talosm-%02d.example.com", count.index + 1)}"
  operating_system = "custom_ipxe"
  plan             = "${var.packet_master_type}"
  count            = "${var.talos_master_count}"

  // public network.0 
  // private network.1
  // atm need to use public addr due to bootstrap limitations
  ipxe_script_url = "http://${packet_device.talos_bootstrap.network.0.address}:8080/boot.ipxe"

  // user_data = "#!ipxe\nchain http://${packet_device.talos_bootstrap.network.0.address}:8080/ipxe?profile=talos"

  always_pxe    = "true"
  facility      = "${var.packet_facility}"
  project_id    = "${packet_project.talos.id}"
  billing_cycle = "hourly"
}

data "packet_precreated_ip_block" "talos" {
  facility       = "${var.packet_facility}"
  project_id     = "${packet_project.talos.id}"
  address_family = 4
  public         = false
}

# Assign /32 subnet (single address) from reserved block to a device
resource "packet_ip_attachment" "master" {
  #device_id = "${packet_device.talos_master.id}"
  device_id = "${element(packet_device.talos_master.*.id, count.index)}"

  // Random calc, but by default each device is provisioned a /31 ( 2 addrs )
  // so we need to account for 2*master ips used, and giving 6ips buffer space
  cidr_notation = "${cidrhost(data.packet_precreated_ip_block.talos.cidr_notation,(var.talos_master_count * 2 + 6 + count.index))}/32"

  count = "${var.talos_master_count}"
}

/*
data "template_file" "init_userdata" {
  template = "${file("${path.module}/templates/userdata-init.yaml.tmpl")}"

  vars {
    api_server_cert_sans        = "${var.api_server_cert_sans}"
    cluster_name                = "${var.cluster_name}"
    container_network_interface = "${var.container_network_interface}"
    control_plane_endpoint      = "${var.control_plane_endpoint}"
    dns_domain                  = "${var.dns_domain}"
    kubernetes_ca_crt           = "${var.kubernetes_ca_crt}"
    kubernetes_ca_key           = "${var.kubernetes_ca_key}"
    labels                      = "${var.labels}"
    os_ca_crt                   = "${var.os_ca_crt}"
    os_ca_key                   = "${var.os_ca_key}"
    os_identity_crt             = "${var.os_identity_crt}"
    os_identity_key             = "${var.os_identity_key}"
    pod_subnet                  = "${var.pod_subnet}"
    service_subnet              = "${var.service_subnet}"
    taints                      = "${var.taints}"
    token                       = "${var.token}"
    trustd_endpoints            = "${var.trustd_endpoints}"
    trustd_password             = "${var.trustd_password}"
    trustd_username             = "${var.trustd_username}"
  }
}

data "template_file" "master_userdata" {
  template = "${file("${path.module}/templates/userdata-master.yaml.tmpl")}"

  vars {
    api_server_cert_sans        = "${var.api_server_cert_sans}"
    container_network_interface = "${var.container_network_interface}"
    control_plane_endpoint      = "${var.control_plane_endpoint}"
    kubernetes_ca_crt           = "${var.kubernetes_ca_crt}"
    kubernetes_ca_key           = "${var.kubernetes_ca_key}"
    labels                      = "${var.labels}"
    os_ca_crt                   = "${var.os_ca_crt}"
    os_ca_key                   = "${var.os_ca_key}"
    os_identity_crt             = "${var.os_identity_crt}"
    os_identity_key             = "${var.os_identity_key}"
    taints                      = "${var.taints}"
    token                       = "${var.token}"
    trustd_endpoints            = "${var.trustd_endpoints}"
    trustd_password             = "${var.trustd_password}"
    trustd_username             = "${var.trustd_username}"
  }
}

data "template_file" "worker_userdata" {
  template = "${file("${path.module}/templates/userdata-worker.yaml.tmpl")}"

  vars {
    container_network_interface = "${var.container_network_interface}"
    labels                      = "${var.labels}"
    master_ip                   = "${var.master_ip}"
    os_ca_crt                   = "${var.os_ca_crt}"
    taints                      = "${var.taints}"
    token                       = "${var.token}"
    trustd_endpoints            = "${var.trustd_endpoints}"
    trustd_password             = "${var.trustd_password}"
    trustd_username             = "${var.trustd_username}"
  }
}

resource "null_resource" "userdata" {
  # Changes to any instance of the cluster requires re-provisioning
  triggers {
    inituserdata   = "${data.template_file.init_userdata.rendered}"
    workeruserdata = "${data.template_file.worker_userdata.rendered}"
    masteruserdata = "${data.template_file.master_userdata.rendered}"
  }

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    host = "${packet_device.talos_bootstrap.network.0.address}"
  }

  provisioner "file" {
    content     = "${data.template_file.worker_userdata.rendered}"
    destination = "/var/lib/matchbox/assets/talos/${var.talos_version}/userdata-worker.json"
  }

  provisioner "file" {
    content     = "${data.template_file.master_userdata.rendered}"
    destination = "/var/lib/matchbox/assets/talos/${var.talos_version}/userdata-master.json"
  }

  provisioner "file" {
    content     = "${data.template_file.init_userdata.rendered}"
    destination = "/var/lib/matchbox/assets/talos/${var.talos_version}/userdata-init.json"
  }
}

resource "packet_device" "talos_worker" {
  hostname         = "${format("talosw-%02d.example.com", count.index + 1)}"
  operating_system = "custom_ipxe"
  plan             = "${var.packet_worker_type}"
  count            = "${var.talos_worker_count}"

  // public network.0 
  // private network.1
  // atm need to use public addr due to bootstrap limitations
  ipxe_script_url = "http://${packet_device.talos_bootstrap.network.0.address}:8080/boot.ipxe"

  // user_data = "#!ipxe\nchain http://${packet_device.talos_bootstrap.network.0.address}:8080/ipxe?profile=talos"

  always_pxe    = "true"
  facility      = "${var.packet_facility}"
  project_id    = "${packet_project.talos.id}"
  billing_cycle = "hourly"
}
*/

