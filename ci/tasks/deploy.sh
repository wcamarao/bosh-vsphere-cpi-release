#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os
check_param network_type_to_test
check_param DIRECTOR_IP
check_param BOSH_VSPHERE_VCENTER
check_param BOSH_VSPHERE_VCENTER_USER
check_param BOSH_VSPHERE_VCENTER_PASSWORD
check_param BOSH_VSPHERE_VCENTER_DC
check_param BOSH_VSPHERE_VCENTER_CLUSTER
check_param BOSH_VSPHERE_VCENTER_VM_FOLDER
check_param BOSH_VSPHERE_VCENTER_TEMPLATE_FOLDER
check_param BOSH_VSPHERE_VCENTER_DATASTORE_PATTERN
check_param BOSH_VSPHERE_VCENTER_DISK_PATH
check_param BOSH_VSPHERE_VCENTER_VLAN
check_param BOSH_VSPHERE_VCENTER_CIDR
check_param BOSH_VSPHERE_VCENTER_GATEWAY

source /etc/profile.d/chruby.sh
chruby 2.1.2

semver=`cat version-semver/number`
cpi_release_name="bosh-vsphere-cpi"
working_dir=$PWD
manifest_prefix=${base_os}-${network_type_to_test}-director
manifest_dir="${working_dir}/director-state-file"
manifest_filename=${manifest_prefix}-manifest.yml

cat > "${manifest_dir}/${manifest_filename}" <<EOF
---
name: bosh

releases:
- name: bosh
  url: file://${working_dir}/bosh-release/release.tgz
- name: ${cpi_release_name}
  url: file://${working_dir}/bosh-cpi-dev-artifacts/${cpi_release_name}-${semver}.tgz

resource_pools:
- name: vms
  network: private
  stemcell:
    url: file://${working_dir}/stemcell/stemcell.tgz
  cloud_properties:
    cpu: 2
    ram: 4_096
    disk: 20_000

disk_pools:
- name: disks
  disk_size: 20_000

networks:
- name: private
  type: manual
  subnets:
  - range: ${BOSH_VSPHERE_VCENTER_CIDR}
    gateway: ${BOSH_VSPHERE_VCENTER_GATEWAY}
    dns: [8.8.8.8]
    cloud_properties: {name: ${BOSH_VSPHERE_VCENTER_VLAN}}

jobs:
- name: bosh
  instances: 1

  templates:
  - {name: nats, release: bosh}
  - {name: redis, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: cpi, release: ${cpi_release_name}}

  resource_pool: vms
  persistent_disk_pool: disks

  networks:
  - {name: private, static_ips: [${DIRECTOR_IP}]}

  properties:
    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password

    redis:
      listen_addresss: 127.0.0.1
      address: 127.0.0.1
      password: redis-password

    postgres: &db
      host: 127.0.0.1
      user: postgres
      password: postgres-password
      database: bosh
      adapter: postgres

    blobstore:
      address: ${DIRECTOR_IP}
      port: 25250
      provider: dav
      director: {user: director, password: director-password}
      agent: {user: agent, password: agent-password}

    director:
      address: 127.0.0.1
      name: my-bosh
      db: *db
      cpi_job: cpi

    hm:
      http: {user: hm, password: hm-password}
      director_account: {user: admin, password: admin}
      resurrector_enabled: true

    agent: {mbus: "nats://nats:nats-password@${DIRECTOR_IP}:4222"}

    vcenter: &vcenter
      address: ${BOSH_VSPHERE_VCENTER}
      user: ${BOSH_VSPHERE_VCENTER_USER}
      password: ${BOSH_VSPHERE_VCENTER_PASSWORD}
      datacenters:
      - name: ${BOSH_VSPHERE_VCENTER_DC}
        vm_folder: ${BOSH_VSPHERE_VCENTER_VM_FOLDER}
        template_folder: ${BOSH_VSPHERE_VCENTER_TEMPLATE_FOLDER}
        datastore_pattern: ${BOSH_VSPHERE_VCENTER_DATASTORE_PATTERN}
        persistent_datastore_pattern: ${BOSH_VSPHERE_VCENTER_DATASTORE_PATTERN}
        disk_path: ${BOSH_VSPHERE_VCENTER_DISK_PATH}
        clusters: [${BOSH_VSPHERE_VCENTER_CLUSTER}]

cloud_provider:
  template: {name: cpi, release: ${cpi_release_name}}

  mbus: "https://mbus:mbus-password@${DIRECTOR_IP}:6868"

  properties:
    vcenter: *vcenter
    agent: {mbus: "https://mbus:mbus-password@0.0.0.0:6868"}
    blobstore: {provider: local, path: /var/vcap/micro_bosh/data/cache}
    ntp: [0.pool.ntp.org, 1.pool.ntp.org]
EOF

export BOSH_INIT_LOG_LEVEL=debug

initver=$(cat bosh-init/version)
initexe="$PWD/bosh-init/bosh-init-${initver}-linux-amd64"
chmod +x $initexe

echo "deleting existing BOSH Director VM..."
$initexe delete ${manifest_dir}/${manifest_filename}

echo "verifying no BOSH deployed VM exists at target IP: $DIRECTOR_IP"
check_for_rogue_vm $DIRECTOR_IP

echo "deploying BOSH..."
$initexe deploy ${manifest_dir}/${manifest_filename}
