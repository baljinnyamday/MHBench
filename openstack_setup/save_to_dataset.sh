#!/usr/bin/env bash
# Export every Glance image to /image-dataset for cross-experiment persistence.
# Run on the ctl node after a successful `compile`.
#
# Requires: image-backed CloudLab dataset attached at /image-dataset
#           (see CLOUDLAB.md Phase 7).

set -euo pipefail

DATASET_DIR="${DATASET_DIR:-/image-dataset}"
WORKDIR="${HOME}/mhbench-bootstrap"
OPENRC="${WORKDIR}/admin-openrc.sh"

if [[ ! -d "${DATASET_DIR}" ]]; then
    echo "ERROR: ${DATASET_DIR} does not exist." >&2
    echo "  Did you attach the image-backed dataset on profile instantiation?" >&2
    echo "  See CLOUDLAB.md Phase 7." >&2
    exit 1
fi

if ! mountpoint -q "${DATASET_DIR}"; then
    echo "ERROR: ${DATASET_DIR} is not a mount point — dataset not attached." >&2
    exit 1
fi

if [[ ! -w "${DATASET_DIR}" ]]; then
    echo "ERROR: ${DATASET_DIR} is not writable." >&2
    echo "  Re-instantiate with 'Mount Image-Backed Dataset Read-only' = OFF." >&2
    exit 1
fi

if [[ -f "${OPENRC}" ]]; then
    # shellcheck disable=SC1091
    source "${OPENRC}"
else
    # Fall back to fetching openrc fresh
    sudo cat /root/setup/admin-openrc.sh > "${WORKDIR}/admin-openrc.sh"
    sudo chown "$(id -u)":"$(id -g)" "${WORKDIR}/admin-openrc.sh"
    chmod 600 "${WORKDIR}/admin-openrc.sh"
    # shellcheck disable=SC1091
    source "${WORKDIR}/admin-openrc.sh"
fi

echo "==> Disk usage on dataset:"
df -h "${DATASET_DIR}" | tail -n1

echo "==> Exporting Glance images to ${DATASET_DIR}"
mapfile -t IMAGES < <(openstack image list -f value -c Name)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "    no images in Glance — did you run 'compile'?"
    exit 0
fi

for img in "${IMAGES[@]}"; do
    out="${DATASET_DIR}/${img}.qcow2"
    if [[ -f "${out}" ]]; then
        # Compare modification times — re-export if Glance image is newer
        glance_updated=$(openstack image show "${img}" -c updated_at -f value)
        echo "    [skip] ${img} already in dataset (Glance updated_at: ${glance_updated})"
        continue
    fi
    echo "    [save] ${img} -> ${out}"
    if ! openstack image save --file "${out}" "${img}"; then
        echo "    ERROR exporting ${img}, removing partial file"
        rm -f "${out}"
    fi
done

echo "==> Done. Dataset contents:"
ls -lh "${DATASET_DIR}/"
echo
echo "Disk usage after export:"
df -h "${DATASET_DIR}" | tail -n1
