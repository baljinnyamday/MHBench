# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MHBench builds multi-host cyber ranges on OpenStack to evaluate autonomous attackers vs. autonomous defenders. It deploys network topologies, configures vulnerabilities and goals via Ansible, and snapshots VMs so experiments can be reset cheaply.

Python 3.13+, dependencies managed with `uv`. There is no test suite, lint config, or CI in the repo — `uv run` is the only build/run path.

## Common commands

```bash
# install deps
uv sync

# config (must exist before any command)
cp config/config_example.json config/config.json
# fill in openstack_config, external_ip, elastic/c2 settings

# compile a hand-tuned environment (deploys network → installs packages → snapshots; hours)
uv run python main.py --type EquifaxSmall compile
uv run python main.py --type EquifaxSmall compile --skip_network   # network already built
uv run python main.py --type EquifaxSmall compile --skip_host      # only redo network

# fast restart from existing snapshots
uv run python main.py --type EquifaxSmall setup
uv run python main.py --type EquifaxSmall setup --skip_network

# deploy just the network layer
uv run python main.py --type EquifaxSmall deploy_network

# tear everything down
uv run python main.py --type EquifaxSmall teardown

# run a generated environment (json file in src/environments/generated/)
uv run python main.py --type generated_network_3 compile
```

`--config-file` overrides the default `config/config.json`. Run logs and Ansible output go to `./output/misc/<timestamp>/`.

## Architecture: two deployment paths

`main.py` resolves `--type` by **first** trying to import a class from `src.environments.terraform.specifications`; on `AttributeError` it falls back to loading `src/environments/generated/<type>.json` as a `NetworkTopology`. This produces two parallel orchestration paths that share Ansible plumbing but nothing else:

### Path A — hand-tuned (Terraform-backed)

For the named environments (`EquifaxLarge/Medium/Small`, `ICSEnvironment`, `Chain`, `PEChain`, `Star`, `StarPE`, `Dumbbell`, `DumbbellPE`, `EnterpriseA/B`, `Chain2Hosts`, `Dev*`):

- `src/environments/terraform/specifications/*.py` — one class per environment, all subclassing `TerraformDeployer` (`src/terraform_deployer.py`). Each class names a `topology` (folder under `src/environments/terraform/topologies/`) and overrides `parse_network()` / `compile_setup()` to wire vulnerabilities, users, SSH keys, and goals into specific subnets.
- `src/environments/terraform/topologies/<name>/*.tf` — HCL that calls shared modules (`modules/perry_manager`, `modules/attacker`) plus per-env networks/subnets/security-groups/instances.
- `src/terraform_helpers.deploy_network()` writes a temporary `.tfvars` from `Config.terraform_vars` and runs `terraform init` + `terraform apply` in the topology directory.
- These specs use the **legacy** model classes in `src/legacy_models/` (`Host`, `Subnet`, `Network`) — strings, not Pydantic. Don't confuse with `src/models/`.

### Path B — programmatically generated (OpenStack SDK)

For JSON-defined topologies:

- `src/models/network.py` — Pydantic `NetworkTopology` (the canonical model: `Network` → `Subnet` → `Host`, plus `SubnetConnection`, `AttackPath`, `AttackGraph`, `Goal`).
- `src/topology_generator/` — generators that emit those JSON files (`network_generator.py` builds topology, `attack_path_generator.py` builds attack paths, `vulnerability_assignment.py` populates vulns).
- `src/env_gen_deployer.EnvGenDeployer` orchestrates deployment by composing single-purpose deployers in `src/openstack/`:
  - `network_deployer` — networks, subnets, router, per-subnet security groups derived from `subnet_connections`.
  - `manage_network_deployer` / `attacker_network_deployer` — separate management and attacker subnets with floating IPs.
  - `host_deployer` — VM instances (maps `OSType` → image name, `FlavorType` → flavor name).
  - `ansible_host_builder` — translates `topology` users/vulns/goals into Ansible playbook calls.
  - `imager` / `cleaner` — snapshot save/restore and full project teardown.

### Shared layer

- `ansible/ansible_runner.py` — wraps `ansible-runner`. Every playbook call goes through `AnsibleRunner.run_playbook(AnsiblePlaybook)`. `manage_ip` and `ssh_key_path` are injected as default extravars; per-playbook params merge on top. SSH traffic is bounced through the management host found by `find_manage_server()` (looks for any server with a floating IP). Retries up to 3× on failure with a 5s backoff.
- `ansible/<role>/*.py` — Python wrappers around `ansible/<role>/*.yml` playbooks. Adding a new playbook means: write the YAML, add a small Python class that sets `name` and `params`, and import it from the deployment code.
- `config/config.py` — Pydantic `Config` with `OpenstackConfig`, `ElasticSearchConfig`, optional `C2Config`. `OpenstackConfig.to_terraform_vars()` is the bridge between the Python config and the Terraform variable file.

## When modifying things

- **Adding a hand-tuned environment**: create a Terraform topology directory, then a `*Instance`-style class in `src/environments/terraform/specifications/` and re-export it via `specifications/__init__.py`. `main.py` looks up classes by `getattr` on that module.
- **Adding a generated environment**: write/generate a `NetworkTopology` JSON into `src/environments/generated/`. Don't modify `EnvGenDeployer` for one-offs — encode it in the topology.
- **Adding a vulnerability or goal**: write the Ansible playbook under `ansible/vulnerabilities/` or `ansible/goals/`, add the Python wrapper, then wire it in either the `compile_setup()` of a Terraform spec or `OpenstackAnsibleHostBuilder` for the generated path.
- **Two model packages exist on purpose**: `src/models/` (Pydantic, used by Path B and any new code) and `src/legacy_models/` (plain classes, only used by Path A specifications via `parse_network()`). Don't try to unify them as part of unrelated work.
- **OpenStack SDK typing** is poor; the codebase uses `cast(Any, conn.network)` / `cast(Any, conn.compute)`. Match that pattern rather than fighting types.
- **Snapshots**: image names are `<host_name>_image`. `compile` always cleans then re-snapshots. `setup` rebuilds servers from those snapshots; orphaned `decoy*` hosts without snapshots are deleted rather than failing.

## OpenStack expectations

The deployer assumes an `external` network exists, named flavors `p2.tiny|small|medium|large`, and images `Ubuntu20` and `KaliLinux` (mapping in `src/openstack/host_deployer.py` and the Terraform modules — change both if your cluster uses different names). `openstack_setup/setup_devstack.sh` and `setup_kolla.sh` bootstrap a local cluster if needed.
