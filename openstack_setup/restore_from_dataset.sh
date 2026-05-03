#!/usr/bin/env bash
# Re-import qcow2 files from /image-dataset into a fresh OpenStack's Glance.
# Run on the ctl node of a NEW experiment after bootstrap_cloudlab.sh.
#
# After this completes, you can run:
#   uv run python main.py --type EquifaxSmall deploy_network
#   uv run python main.py --type EquifaxSmall setup --skip_network
# to skip the 1-3 hour 'compile' step entirely.

set -euo pipefail

DATASET_DIR="${DATASET_DIR:-/image-dataset}"
WORKDIR="${HOME}/mhbench-bootstrap"
OPENRC="${WORKDIR}/admin-openrc.sh"

if [[ ! -d "${DATASET_DIR}" ]] || ! mountpoint -q "${DATASET_DIR}"; then
    echo "ERROR: ${DATASET_DIR} not mounted — did you attach the dataset?" >&2
    exit 1
fi

if [[ ! -f "${OPENRC}" ]]; then
    echo "ERROR: openrc not found at ${OPENRC} — run bootstrap_cloudlab.sh first" >&2
    exit 1
fi

# shellcheck disable=SC1091
source "${OPENRC}"

mapfile -t QCOWS < <(find "${DATASET_DIR}" -maxdepth 1 -name '*.qcow2' -type f)

if [[ ${#QCOWS[@]} -eq 0 ]]; then
    echo "ERROR: no .qcow2 files in ${DATASET_DIR}" >&2
    exit 1
fi

echo "==> Importing ${#QCOWS[@]} images from ${DATASET_DIR} into Glance"

for f in "${QCOWS[@]}"; do
    name=$(basename "$f" .qcow2)
    if openstack image show "${name}" >/dev/null 2>&1; then
        echo "    [skip] ${name} already in Glance"
        continue
    fi
    echo "    [load] ${f} -> ${name}"
    openstack image create "${name}" \
        --file "${f}" \
        --disk-format qcow2 \
        --container-format bare \
        --public
done

echo "==> Done. Glance contents:"
openstack image list

cat <<EOF

Next steps (skipping the slow 'compile'):
  cd ~/mhbench
  uv run python main.py --type EquifaxSmall deploy_network
  uv run python main.py --type EquifaxSmall setup --skip_network
EOF
