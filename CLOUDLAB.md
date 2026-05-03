# Running MHBench on CloudLab

End-to-end guide for spinning up an OpenStack cluster on CloudLab and running MHBench against it. Optimised for the **iterate-many-times** dev loop used during the summer 2026 dissertation work.

## TL;DR — three workflows

```
1. Daily iteration (within a live experiment)   ~5-10 min
   ssh ctl → setup EquifaxSmall → run model

2. Forced reset, snapshots saved (Phase 7)      ~55 min
   instantiate → bootstrap → restore-from-dataset → setup

3. First-ever setup on a fresh project          ~3-4 hours
   instantiate → bootstrap → compile → export-to-dataset
```

You pay #3 **once this summer**. After that, you live in #1, with #2 only on forced resets.

### Cost breakdown

| Step | Time | When |
|---|---|---|
| CloudLab OpenStack install | 30-45 min | Every fresh experiment (unavoidable) |
| Bootstrap (flavors, image upload) | 5-15 min | Every fresh experiment |
| `compile EquifaxSmall` | 1-3 hours | First time ever, or topology change |
| Restore from persistent dataset | 5-10 min | Every fresh experiment after first |
| `setup EquifaxSmall` (snapshot rebuild) | 5-10 min | Every model iteration |
| Extend experiment | 30 sec | Every 5-6 days |

---

## Phase 1 — CloudLab cluster (every fresh experiment)

CloudLab experiments expire (default 16 hours, max 7 days). Each new experiment is a clean slate, so this whole phase repeats.

### Profile

**`emulab-ops/OpenStack`** — https://www.cloudlab.us/show-profile.php?project=emulab-ops&profile=OpenStack

### Parameters that worked (May 2026 baseline)

| Parameter | Value | Why |
|---|---|---|
| OpenStack Release | **Zed** | Recent, supported by `openstacksdk>=4.5.0` |
| Number of compute nodes (Site 1) | **1** | Enough for EquifaxSmall–EquifaxMedium |
| Hardware Type | **`c220g2`** (Wisconsin) | 20 cores, 160 GB RAM, SSD; falls back to `c220g5` or `m510` |
| Experiment Link Speed | Any | |
| ML2 Plugin | OpenVSwitch | |
| Number of public IPs | 4 | 1 manager + 1 attacker + 2 spare |
| Flat Data Networks | 1 | |
| GRE Tunnel Networks | 1 | |
| **Glance Logical Volume Size** | **200** GB | ⚠️ Default 32 is too small — snapshots overflow |
| **Unlimit Default Quotas** | **on** | Avoids quota errors on bigger envs |
| **Enable Inbound SSH and ICMP** | **on** | Required for laptop → cluster access |
| Make Public API Endpoints Reachable | off | Run MHBench from the `ctl` node directly |
| Everything else | default | |

For larger benchmarks, scale `Number of compute nodes`:

| Target env | Compute nodes | Glance LV |
|---|---|---|
| `EquifaxSmall` | 1 | 200 GB |
| `EquifaxMedium` / `EnterpriseA` | 2 | 300 GB |
| `EnterpriseB` / `EquifaxLarge` | 3 | 500 GB |

### Schedule + finalize

- **Duration**: 16 hours for an active dev session, extend on the experiment page if needed
- **Name**: `mhbench-<env>-<YYYYMMDD>` (e.g., `mhbench-equifax-small-20260503`) — easy to reference later

### Wait for ready

Status flips from `changing` → `ready` (~30-45 min). Both `ctl` and `cp-1` rows must be green before continuing.

---

## Phase 2 — Bootstrap the cluster (every fresh experiment)

SSH to the controller node:

```bash
ssh dayan@<ctl-hostname>.wisc.cloudlab.us
```

`<ctl-hostname>` comes from the experiment's **List View** tab (e.g., `c220g2-010803`).

### What the bootstrap script does

`openstack_setup/bootstrap_cloudlab.sh` (in this repo) creates the OpenStack resources MHBench expects:

1. Sources the admin `openrc` from `/local/setup/admin-openrc.sh` (placed there by the CloudLab profile)
2. Creates flavors `p2.tiny` (1 vCPU / 1 GB / 5 GB) and `m1.small` (1 vCPU / 2 GB / 20 GB)
3. Downloads + uploads `Ubuntu20` cloud image from cloud-images.ubuntu.com
4. Downloads + uploads `KaliLinux` image
5. Verifies an `external` network exists (the profile creates one — script just checks naming)
6. Registers the SSH keypair `perry_key` from `~/.ssh/id_rsa.pub` (or whichever key you specify)

### Run it

```bash
# On the ctl node:
cd ~
git clone https://github.com/bsinger98/MHBench.git mhbench
cd mhbench
./openstack_setup/bootstrap_cloudlab.sh
```

The script is idempotent — safe to re-run if a step fails.

### Verify

```bash
source /local/setup/admin-openrc.sh
openstack flavor list                # should list p2.tiny, m1.small
openstack image list                 # should list Ubuntu20, KaliLinux
openstack network list               # should list external
openstack keypair list               # should list perry_key
```

---

## Phase 3 — MHBench setup (every fresh experiment)

Still on the `ctl` node:

```bash
# Install uv if not already present
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.cargo/env  # or restart shell

cd ~/mhbench
uv sync
```

### Write `config/config.json`

```bash
cp config/config_example.json config/config.json
```

Fill in the OpenStack section using values from `/root/setup/admin-openrc.sh` (read with `sudo cat`):

```bash
sudo cat /root/setup/admin-openrc.sh
```

Output looks like:
```
export OS_PROJECT_NAME=admin
export OS_USERNAME=adminapi          # ← username is `adminapi`, not `admin`
export OS_PASSWORD=<random>
export OS_AUTH_URL=http://ctl:5000/v3
```

Use those in `config/config.json`:

```jsonc
{
  "elastic_config":  { "api_key": "unused", "port": 9200 },
  "openstack_config": {
    "ssh_key_name":      "perry_key",
    "ssh_key_path":      "~/.ssh/id_rsa",       // private key matching the registered keypair
    "project_name":      "admin",
    "openstack_username": "adminapi",            // from OS_USERNAME above
    "openstack_password": "<OS_PASSWORD value>",
    "openstack_region":   "RegionOne",
    "openstack_auth_url": "http://ctl:5000/v3",
    "perry_key_name":     "perry_key"
  },
  "external_ip": "<floating-IP-range-gateway>",  // see below
  "experiment_timeout_minutes": 75
}
```

Get the floating IP gateway:

```bash
openstack subnet list --external -f value -c Subnet | xargs -I{} openstack subnet show {} -c gateway_ip -f value
```

---

## Phase 4 — First compile (one-time per topology)

```bash
uv run python main.py --type EquifaxSmall compile
```

What happens:
1. Terraform deploys the network + 6 workload VMs + 1 attacker + 1 manager (~5-10 min)
2. Ansible installs base packages on every host (~30-60 min)
3. Sets up Apache Struts vulnerability, users, SSH keys, decoy data (~15-30 min)
4. **Snapshots every VM** to Glance — this is the magic; lets you `setup` quickly later

**Total: 1-3 hours.** Get coffee. Logs go to `output/misc/<timestamp>/`.

If a step fails partway, you can resume:

```bash
# Skip network deploy if it already succeeded
uv run python main.py --type EquifaxSmall compile --skip_network

# Skip host setup (re-snapshot only)
uv run python main.py --type EquifaxSmall compile --skip_host
```

---

## Phase 5 — Daily iteration (the fast path)

Once `compile` is done and snapshots exist, every subsequent run is a **snapshot restore** — ~5-10 minutes, not hours:

```bash
uv run python main.py --type EquifaxSmall setup
```

This rebuilds all VMs from their saved snapshots. The state is identical to right after `compile` finished, every time.

### Typical model-iteration loop

```bash
# 1. Reset the range to clean snapshot state
uv run python main.py --type EquifaxSmall setup

# 2. Run your attacker/defender model against the cluster
#    (point your model at attacker host's floating IP, etc.)
python ~/my-model/run.py --target-cluster mhbench

# 3. Inspect results, iterate

# 4. When state is dirty, go back to step 1
```

### Switching environments

You can have snapshots for multiple topologies in the same experiment, but only one network deployed at a time:

```bash
uv run python main.py --type EquifaxSmall teardown      # Clean network
uv run python main.py --type Chain2Hosts compile        # First time on Chain2Hosts
# ... or ...
uv run python main.py --type Chain2Hosts setup          # If snapshots exist
```

---

## Phase 6 — Extending and ending experiments

### Extend, don't terminate

CloudLab experiments default to 16 hours but **you can extend repeatedly up to 7 days at a time**, indefinitely:

1. Open the experiment page on cloudlab.us
2. Click **Extend**
3. Enter a brief justification (e.g., "ongoing dissertation experiments")
4. +7 days

**Best practice for summer dev**: extend every 5-6 days. Your snapshots stay live in Glance the whole time, no re-bootstrapping. This is the cheapest path — never let a working experiment die.

### When you must reset

Forced resets happen for:
- CloudLab maintenance windows (rare)
- You need to change profile parameters (e.g., scale to 2 compute nodes for a bigger env)
- You hit a broken state that's faster to nuke than debug

Before terminating, **export your snapshots** (see Phase 7) so the next instantiation skips `compile`.

### End-of-day clean shutdown (optional)

```bash
# Just stop iterating — leave the experiment running
# The next session you can pick up immediately with:
uv run python main.py --type EquifaxSmall setup
```

You don't need to "tear down" anything between sessions within the same experiment. `setup` resets state from snapshots in 5-10 min.

---

## Phase 7 — Persistent snapshots across experiments (the big time saver)

Without this, every forced reset costs ~3 hours (OpenStack install + compile). With this, ~55 min (just OpenStack install + import).

### One-time setup: create a CloudLab dataset

A CloudLab **image-backed dataset** is a block device that survives experiment teardown. We use it as a vault for Glance qcow2 files.

1. **In the CloudLab portal**, go to `Storage → Create Dataset`
2. Settings:
   - **Name**: `mhbench-snapshots`
   - **Type**: Image-backed dataset
   - **Size**: `300 GB` (covers EquifaxSmall + a couple of other small envs; bump to 500 GB if you'll snapshot larger benchmarks)
   - **Filesystem**: `ext4`
   - **Expiration**: longest your project allows; renew before it lapses
3. Click **Create** and wait a few minutes for allocation
4. **Note the dataset URN** — looks like `urn:publicid:IDN+wisc.cloudlab.us:dayan+imdataset+mhbench-snapshots`

You only do this once. The dataset persists across all future experiments.

### Attach the dataset on profile instantiation

When instantiating the OpenStack profile (Phase 1), set these parameters:

| Parameter | Value |
|---|---|
| Image-backed Dataset URN | `urn:publicid:IDN+wisc.cloudlab.us:dayan+imdataset+mhbench-snapshots` |
| Image-backed Dataset Mount Node | `ctl` |
| Image-Backed Dataset Mount Point | `/image-dataset` |
| Mount Image-Backed Dataset Read-only | **off** (need write access to save new snapshots) |

After ready, on `ctl`:

```bash
ls /image-dataset/
# First time: empty
# Subsequent times: shows your saved qcow2 files
```

### Export snapshots after first compile

Once you've done your initial `compile EquifaxSmall` and snapshots exist in Glance:

```bash
source /local/setup/admin-openrc.sh

# Export every Glance image to the dataset
for img in $(openstack image list -f value -c Name); do
    if [[ ! -f "/image-dataset/${img}.qcow2" ]]; then
        echo "Exporting ${img}..."
        openstack image save --file "/image-dataset/${img}.qcow2" "${img}"
    fi
done

ls -lh /image-dataset/
```

This includes Ubuntu20, KaliLinux, and every `<host>_image` snapshot. Disk cost: ~80 GB for EquifaxSmall.

### Re-import on a fresh experiment

After Phase 1-2 on the next experiment, before doing Phase 4:

```bash
source /local/setup/admin-openrc.sh

for f in /image-dataset/*.qcow2; do
    name=$(basename "$f" .qcow2)
    if ! openstack image show "$name" >/dev/null 2>&1; then
        echo "Importing ${name}..."
        openstack image create "$name" \
            --file "$f" \
            --disk-format qcow2 \
            --container-format bare \
            --public
    fi
done
```

### Restore the EquifaxSmall environment from saved snapshots

```bash
# 1. Deploy the network + create empty VMs (Terraform, ~5 min)
uv run python main.py --type EquifaxSmall deploy_network

# 2. Rebuild VMs from saved snapshots (no compile needed — ~5 min)
uv run python main.py --type EquifaxSmall setup --skip_network
```

You skipped the 1-3 hour compile. Done.

### Updating the dataset later

Whenever you modify the topology (e.g., change a vulnerability, add data), do another `compile`, then re-export:

```bash
# Overwrite stale snapshots in the dataset
for img in $(openstack image list -f value -c Name); do
    rm -f "/image-dataset/${img}.qcow2"
    openstack image save --file "/image-dataset/${img}.qcow2" "${img}"
done
```

### Time math summary

| Scenario | Without dataset | With dataset |
|---|---|---|
| First-ever experiment | 3-4 hr | 4 hr (one-time export adds 15 min) |
| Re-instantiate same setup | 3-4 hr | **~55 min** |
| Daily iteration | 5-10 min | 5-10 min (unchanged) |

---

## Resource sizing reference

VM math is in `CLAUDE.md`. Quick view:

| Env | VMs | Compute nodes needed | Glance LV |
|---|---|---|---|
| `Chain2Hosts` | 4 | 1 | 100 GB |
| `EquifaxSmall` | 8 | 1 | 200 GB |
| `generated_mini` | 13 | 1 | 200 GB |
| `Star` / `Dumbbell` | 17 | 1 | 250 GB |
| `EquifaxMedium` | 28 | 2 | 300 GB |
| `EnterpriseA` | 32 | 2 | 350 GB |
| `EnterpriseB` | 42 | 3 | 450 GB |
| `EquifaxLarge` | 52 | 3 | 500 GB |

---

## Troubleshooting

**`compile` hangs on Ansible step**
Probably a transient SSH timeout. The `AnsibleRunner` retries 3× automatically. If all 3 fail, run `compile --skip_network` to resume from where it failed.

**`Image '<name>_image' does not exist` during setup**
You ran `setup` before any `compile` succeeded — there are no snapshots yet. Run `compile` first.

**`Host already exists` / `Network already exists` errors**
Stale state from a previous run. Run `teardown` first, then retry.

**Snapshots filling Glance**
Check `df -h /var/lib/glance` on `ctl`. If full, increase `Glance Logical Volume Size` next instantiation, or `clean_snapshots()` runs at the start of each `compile`.

**Dataset mount point empty after instantiation**
Confirm the URN is exactly correct (case-sensitive). Try `mount | grep image-dataset` and `ls -la /image-dataset` on `ctl`. If unmounted, `sudo mount /image-dataset` and check `dmesg` for errors.

**`image save` produces 0-byte file**
The Glance backend may not support direct download for that image format. Workaround: `glance image-download --file out.qcow2 <id>` instead of `openstack image save`. Or restart `ctl`'s glance-api service: `sudo systemctl restart glance-api`.

**Floating IP exhausted**
You picked too few public IPs. Re-instantiate with more (each manager + attacker uses 1).

**Can't SSH to attacker / manager from my laptop**
Public API endpoints are off in our default profile params — that's intentional. Either:
- Run MHBench from `ctl` (recommended), or
- SSH-tunnel from laptop to `ctl`, then to the floating IP

---

## Notes for next time

- Imperial may grant access to a persistent OpenStack project — if so, skip Phases 1-2 entirely and just point `config.json` at it.
- The `_pe` variants (`PEChain`, `StarPE`, `DumbbellPE`) add privilege escalation paths to the same topologies — same VM count, harder benchmark.
- Generated networks (`generated_network_0` through `_29`) live in `src/environments/generated/` and don't require Terraform — they go through `EnvGenDeployer` directly.
