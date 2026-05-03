#!/usr/bin/env bash
# Bootstrap an MHBench-ready OpenStack cluster on a freshly-provisioned
# CloudLab `emulab-ops/OpenStack` profile.
#
# Run on the controller (`ctl`) node after the experiment is `ready`.
#
#   ssh dayan@<ctl>.wisc.cloudlab.us
#   cd ~/mhbench
#   ./openstack_setup/bootstrap_cloudlab.sh
#
# Idempotent — safe to re-run if a step fails.

set -euo pipefail

# ---------- Configuration ----------
UBUNTU20_IMAGE_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
UBUNTU20_IMAGE_NAME="Ubuntu20"

# Kali official cloud image. Use `current/` to always get the latest release;
# Kali drops old versions from the mirror, so pinning a version is brittle.
# The archive contains a single qcow2 file.
KALI_IMAGE_URL="https://kali.download/cloud-images/current/kali-linux-2026.1-cloud-genericcloud-amd64.tar.xz"
KALI_IMAGE_NAME="KaliLinux"

KEY_NAME="perry_key"
PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"

WORKDIR="${HOME}/mhbench-bootstrap"
mkdir -p "${WORKDIR}"

# ---------- Source admin credentials ----------
# CloudLab's OpenStack profile drops admin-openrc.sh in /root/setup/.
# It contains the admin password in plaintext, so the file is root-only.
OPENRC_LOCATIONS=(
    /local/setup/admin-openrc.sh
    /root/setup/admin-openrc.sh
)
OPENRC_FOUND=""
for path in "${OPENRC_LOCATIONS[@]}"; do
    if sudo test -f "$path"; then
        OPENRC_FOUND="$path"
        break
    fi
done

if [[ -z "$OPENRC_FOUND" ]]; then
    echo "ERROR: cannot find admin-openrc.sh in any of: ${OPENRC_LOCATIONS[*]}" >&2
    echo "Search the filesystem: sudo find / -name 'admin-openrc*' 2>/dev/null" >&2
    exit 1
fi

# Copy to a user-readable location and source from there
sudo cat "$OPENRC_FOUND" | sudo tee "${WORKDIR}/admin-openrc.sh" >/dev/null
sudo chown "$(id -u)":"$(id -g)" "${WORKDIR}/admin-openrc.sh"
chmod 600 "${WORKDIR}/admin-openrc.sh"
# shellcheck disable=SC1091
source "${WORKDIR}/admin-openrc.sh"

echo "==> Authenticated as ${OS_USERNAME:-?} on ${OS_AUTH_URL:-?}"
echo "    (project: ${OS_PROJECT_NAME:-?})"

# ---------- Helpers ----------
have_flavor()  { openstack flavor show "$1" >/dev/null 2>&1; }
have_image()   { openstack image show "$1" >/dev/null 2>&1; }
have_keypair() { openstack keypair show "$1" >/dev/null 2>&1; }
have_network() { openstack network show "$1" >/dev/null 2>&1; }

# ---------- Flavors ----------
echo "==> Creating flavors"
if ! have_flavor "p2.tiny"; then
    openstack flavor create p2.tiny --vcpus 1 --ram 1024 --disk 5 --public
    echo "    created p2.tiny"
else
    echo "    p2.tiny already exists"
fi

if ! have_flavor "m1.small"; then
    openstack flavor create m1.small --vcpus 1 --ram 2048 --disk 20 --public
    echo "    created m1.small"
else
    echo "    m1.small already exists"
fi

# Optional larger flavors used by some envs
for spec in "p2.small:1:2048:10" "p2.medium:2:4096:20" "p2.large:4:8192:40"; do
    name=${spec%%:*}; rest=${spec#*:}
    cpu=${rest%%:*}; rest=${rest#*:}
    ram=${rest%%:*}; disk=${rest#*:}
    if ! have_flavor "$name"; then
        openstack flavor create "$name" --vcpus "$cpu" --ram "$ram" --disk "$disk" --public
        echo "    created $name"
    fi
done

# ---------- Ubuntu 20.04 image ----------
echo "==> Ubuntu 20.04 image"
if ! have_image "${UBUNTU20_IMAGE_NAME}"; then
    cd "${WORKDIR}"
    if [[ ! -f focal-server-cloudimg-amd64.img ]]; then
        echo "    downloading ${UBUNTU20_IMAGE_URL}"
        curl -fLO "${UBUNTU20_IMAGE_URL}"
    fi
    openstack image create "${UBUNTU20_IMAGE_NAME}" \
        --file focal-server-cloudimg-amd64.img \
        --disk-format qcow2 \
        --container-format bare \
        --public
    echo "    uploaded ${UBUNTU20_IMAGE_NAME}"
else
    echo "    ${UBUNTU20_IMAGE_NAME} already in Glance"
fi

# ---------- Kali Linux image ----------
echo "==> Kali Linux image"
if ! have_image "${KALI_IMAGE_NAME}"; then
    cd "${WORKDIR}"
    KALI_TAR=$(basename "${KALI_IMAGE_URL}")
    KALI_QCOW="kali.qcow2"
    if [[ ! -f "${KALI_QCOW}" ]]; then
        if [[ ! -f "${KALI_TAR}" ]]; then
            echo "    downloading ${KALI_IMAGE_URL}"
            curl -fLO "${KALI_IMAGE_URL}"
        fi
        echo "    extracting ${KALI_TAR}"
        tar -xf "${KALI_TAR}"
        # The archive contains a single .qcow2 — find and rename it
        extracted=$(find . -maxdepth 2 -name '*.qcow2' | head -n1)
        mv "${extracted}" "${KALI_QCOW}"
    fi
    openstack image create "${KALI_IMAGE_NAME}" \
        --file "${KALI_QCOW}" \
        --disk-format qcow2 \
        --container-format bare \
        --public
    echo "    uploaded ${KALI_IMAGE_NAME}"
else
    echo "    ${KALI_IMAGE_NAME} already in Glance"
fi

# ---------- External network ----------
echo "==> External network"
# CloudLab's OpenStack profile usually creates a network named `ext-net` or
# `external`. MHBench expects `external`. If the existing one has a different
# name, alias it.
if have_network "external"; then
    echo "    external already exists"
else
    candidate=$(openstack network list --external -f value -c Name | head -n1 || true)
    if [[ -n "${candidate}" ]]; then
        echo "    found external network '${candidate}', renaming to 'external'"
        openstack network set --name external "${candidate}"
    else
        echo "ERROR: no external network found. Check the CloudLab profile output."
        echo "  openstack network list --external"
        exit 1
    fi
fi

# ---------- SSH keypair ----------
echo "==> SSH keypair"
if [[ ! -f "${PUBKEY_PATH}" ]]; then
    echo "    no key at ${PUBKEY_PATH}; generating one"
    ssh-keygen -t rsa -b 4096 -N "" -f "${HOME}/.ssh/id_rsa"
fi

if ! have_keypair "${KEY_NAME}"; then
    openstack keypair create --public-key "${PUBKEY_PATH}" "${KEY_NAME}"
    echo "    registered ${KEY_NAME}"
else
    echo "    ${KEY_NAME} already registered"
fi

# ---------- Quotas ----------
# The CloudLab profile's "Unlimit Default Quotas" parameter handles this,
# but bump key quotas explicitly in case it didn't take effect for `admin`.
echo "==> Quotas"
PROJECT_ID=$(openstack project show "${OS_PROJECT_NAME:-admin}" -c id -f value)
openstack quota set --instances 100 --cores 200 --ram 204800 \
    --floating-ips 20 --secgroups 100 --secgroup-rules 1000 \
    "${PROJECT_ID}" || true
echo "    quotas bumped for project ${OS_PROJECT_NAME:-admin}"

# ---------- Done ----------
# ---------- Generate config.json template ----------
EXTERNAL_GW=$(openstack subnet list --external -f value -c Subnet 2>/dev/null \
    | head -n1 \
    | xargs -r -I{} openstack subnet show {} -c gateway_ip -f value 2>/dev/null \
    || echo "FILL_IN_MANUALLY")

CONFIG_OUT="${WORKDIR}/config.template.json"
cat > "${CONFIG_OUT}" <<JSON
{
  "elastic_config": { "api_key": "unused", "port": 9200 },
  "openstack_config": {
    "ssh_key_name":      "${KEY_NAME}",
    "ssh_key_path":      "~/.ssh/id_rsa",
    "project_name":      "${OS_PROJECT_NAME:-admin}",
    "openstack_username": "${OS_USERNAME}",
    "openstack_password": "${OS_PASSWORD}",
    "openstack_region":   "${OS_REGION_NAME:-RegionOne}",
    "openstack_auth_url": "${OS_AUTH_URL}",
    "perry_key_name":     "${KEY_NAME}"
  },
  "external_ip": "${EXTERNAL_GW}",
  "experiment_timeout_minutes": 75
}
JSON
chmod 600 "${CONFIG_OUT}"

# ---------- Done ----------
cat <<EOF

====================================================================
Bootstrap complete.

A pre-filled config template was written to:
  ${CONFIG_OUT}

Next steps:
  cd ~/mhbench   (or wherever your MHBench checkout lives)
  cp ${CONFIG_OUT} config/config.json
  uv sync
  uv run python main.py --type EquifaxSmall compile

If you have saved snapshots in /image-dataset, skip 'compile' and run:
  ./openstack_setup/restore_from_dataset.sh
  uv run python main.py --type EquifaxSmall deploy_network
  uv run python main.py --type EquifaxSmall setup --skip_network
====================================================================
EOF
