# Next-Steps Plan — Bringing MHBench up on CloudLab (2026-05-03)

Live state of work as of writing:
- **CloudLab experiment**: `mhbench-pg0` running, OpenStack install at minute ~19 of ~30-45.
- **Local repo**: has uncommitted changes (CLOUDLAB.md, CLAUDE.md, plan.md, openstack_setup/*.sh, memory entries).
- **GitHub identity**: `baljinnyamday` (baljinnyam.dayan@gmail.com).
- **Fork status**: not yet forked. `origin` still points to upstream `bsinger98/MHBench`.

---

## Phase 1 — Fork upstream on GitHub (manual, 2 minutes)

Done by **you** in the browser:

1. Go to https://github.com/bsinger98/MHBench
2. Click **Fork** → owner = `baljinnyamday` → keep default branch `main` → **Create fork**
3. Confirm the fork exists at https://github.com/baljinnyamday/MHBench
4. Tell me when done.

---

## Phase 2 — Repoint `origin` to your fork (I'll do this)

```bash
git remote rename origin upstream                        # keep upstream for pulls
git remote add origin https://github.com/baljinnyamday/MHBench.git
git remote -v                                            # verify
```

This way:
- `origin` = your fork (where you push changes)
- `upstream` = `bsinger98/MHBench` (where you pull bug fixes from)

---

## Phase 3 — Commit local changes (I'll prepare; you confirm)

Files to commit:
- `CLAUDE.md` — architecture overview for future Claude sessions
- `CLOUDLAB.md` — full replication workflow with Phase 7 dataset persistence
- `plan.md` — this file (intentionally committed; living plan for the summer)
- `openstack_setup/bootstrap_cloudlab.sh` — flavors / images / SSH key / config.json template
- `openstack_setup/save_to_dataset.sh` — Glance → /image-dataset
- `openstack_setup/restore_from_dataset.sh` — /image-dataset → Glance

Files **NOT** to commit (sensitive):
- Any `config/config.json` (contains OS_PASSWORD)
- `~/.ssh/*` (no risk here, but mention)

Suggested commit message:

```
docs: CloudLab setup guide, bootstrap scripts, persistent-dataset workflow

- CLOUDLAB.md: 7-phase guide for instantiating emulab-ops/OpenStack profile,
  bootstrapping flavors/images, running MHBench, and persisting Glance
  snapshots across experiments via image-backed CloudLab datasets.
- bootstrap_cloudlab.sh: idempotent setup for a fresh ctl node.
- save_to_dataset.sh / restore_from_dataset.sh: cross-experiment snapshot
  persistence to skip the 1-3 hour 'compile' on every reset.
- CLAUDE.md: architecture reference for future Claude Code sessions.
- plan.md: living next-steps checklist for the summer iteration cycle.
```

I'll prepare this for review before pushing.

---

## Phase 4 — Push to your fork (I'll do this on your confirmation)

```bash
git push -u origin main
```

After this, the `ctl` node can clone from `https://github.com/baljinnyamday/MHBench.git` and have everything we need.

---

## Phase 5 — Wait for OpenStack install to finish (~10-15 min from now)

Periodically check:
```bash
ssh dayan@c220g2-010803.wisc.cloudlab.us 'sudo tail -5 /root/setup/setup-controller.log'
```

Cluster is "ready" when:
- The CloudLab portal shows both `ctl` and `cp-1` rows green
- `openstack service list` on ctl returns a populated table without errors
- `openstack network list --external` returns at least one network

---

## Phase 6 — Live setup on ctl (I'll execute step-by-step, verifying each)

```bash
# 6.1 Confirm OpenStack is healthy
ssh dayan@c220g2-010803.wisc.cloudlab.us
source <(sudo cat /root/setup/admin-openrc.sh)
openstack service list
openstack network list --external
openstack compute service list

# 6.2 Clone your fork into /local (writable, big disk on c220g2)
cd /local
git clone https://github.com/baljinnyamday/MHBench.git mhbench
cd mhbench

# 6.3 Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.cargo/env

# 6.4 Run bootstrap (creates flavors, downloads + uploads Ubuntu20 + Kali,
#     registers SSH key, generates pre-filled config template)
./openstack_setup/bootstrap_cloudlab.sh

# 6.5 Use the generated config
cp ~/mhbench-bootstrap/config.template.json config/config.json
chmod 600 config/config.json

# 6.6 Verify config is valid
uv sync
uv run python -c "from config.config_service import ConfigService; print(ConfigService('config/config.json').get_config())"
```

Expected output: a populated `Config` object with the right OpenStack credentials.

---

## Phase 7 — First-run validation with Chain2Hosts (smallest env, ~30 min)

`Chain2Hosts` is the smallest environment (2 workload VMs + manager + attacker = 4 total). Use it as the smoke test before committing 1-3 hours to EquifaxSmall.

```bash
uv run python main.py --type Chain2Hosts compile
```

Watch for these failure modes:
- **Terraform fails on first apply** → check that `external` network and flavor names match
- **Ansible cannot reach VMs** → security group rules wrong, or floating IP not assigned
- **Image not found** → bootstrap script didn't upload Ubuntu20/KaliLinux correctly
- **Snapshot fails / Glance full** → `Glance Logical Volume Size` needs to be bigger

If anything fails, I'll patch the script + guide and re-run.

After success:
```bash
uv run python main.py --type Chain2Hosts setup     # verify snapshot restore works
```

---

## Phase 8 — Compile EquifaxSmall (the real workload, 1-3 hours)

Only after Chain2Hosts validates the pipeline:

```bash
uv run python main.py --type EquifaxSmall compile
```

Run this in a `tmux` session so SSH disconnects don't kill it:
```bash
tmux new -s mhbench
# inside tmux:
uv run python main.py --type EquifaxSmall compile
# Ctrl+B then D to detach; reattach later with: tmux attach -t mhbench
```

---

## Phase 9 — Set up the persistent dataset (deferred — do this BEFORE the next experiment expires)

In the CloudLab portal:
1. `Storage → Create Dataset`
2. Name: `mhbench-snapshots`, Image-backed, 300 GB, ext4
3. Note the URN

Currently we **cannot** attach a dataset to a running experiment — it must be set at instantiation time. So:
- This time: do the full `compile` (we already started)
- Before the experiment expires (or when forced to reset): create the dataset, save snapshots **manually** by `scp`-ing them out, OR re-instantiate with the dataset attached and re-do compile once on the new experiment to populate the dataset
- Going forward: every instantiation includes the dataset → every reset is ~55 min instead of 3 hours

The cleanest sequence:
1. Today: complete `compile EquifaxSmall` (1-3 hrs, already running soon)
2. Today / tomorrow: create the CloudLab dataset
3. Re-instantiate **once more** with the dataset attached
4. `compile` again, then `save_to_dataset.sh` — this is the last "slow" reset of the summer
5. Every future reset: `restore_from_dataset.sh` + `setup --skip_network` ≈ 5-10 min

---

## Phase 10 — Document any deviations

If anything in this plan diverges from reality during execution, update:
- `CLOUDLAB.md` — for permanent operational notes
- `openstack_setup/*.sh` — for any script fixes
- `plan.md` — for the rest of today's work and next session's resume point

---

## Open questions / decisions to make

- [ ] **Your model repo**: where does it live? Does it run on `ctl` alongside MHBench, or remotely against the cluster's floating IPs? Affects `external_ip` config and SSH-tunnel needs.
- [ ] **Dataset size**: 300 GB enough? EquifaxSmall is ~80 GB, EquifaxLarge would be ~500 GB. Start with 300 GB unless you know you'll go big quickly.
- [ ] **Experiment duration default**: keep at 16 hr (default) or extend immediately to 7 days? I recommend extending immediately so you don't lose state to expiration.

---

## Quick command reference (after everything is set up)

```bash
# Connect
ssh dayan@<ctl-host>.wisc.cloudlab.us
cd /local/mhbench

# Daily iteration loop
uv run python main.py --type EquifaxSmall setup
# ... run your model ...
uv run python main.py --type EquifaxSmall setup     # reset state

# After topology changes:
uv run python main.py --type EquifaxSmall compile
./openstack_setup/save_to_dataset.sh                 # update dataset

# After CloudLab forced reset:
./openstack_setup/bootstrap_cloudlab.sh
./openstack_setup/restore_from_dataset.sh
uv run python main.py --type EquifaxSmall deploy_network
uv run python main.py --type EquifaxSmall setup --skip_network
```
