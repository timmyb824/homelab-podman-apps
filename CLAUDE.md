# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

GitOps repository for a personal homelab running rootless Podman containers. Each app in `gitops/` has its own directory with a `docker-compose.yaml` and optional encrypted environment files. The `deploy/deploy-agent.sh` script pulls this repo, detects changed app directories, and redeploys affected services via `podman-compose`.

## Deployment

The deploy agent runs automatically via systemd timer (every 5 minutes). To manually trigger deployment:

```bash
# Deploy all apps with changes detected via git diff
./deploy/deploy-agent.sh

# Force redeploy all configured apps
./deploy/deploy-agent.sh --force

# Deploy a single specific app
./deploy/deploy-agent.sh --app semaphore
./deploy/deploy-agent.sh --app gitops/semaphore
```

Apps must be listed in `gitops-apps.conf` to be managed by the deploy agent. Each line is a path relative to the repo root, optionally followed by extra config files that need SOPS decryption (e.g., `gitops/proxmox-exporter pve.yml`).

## Pre-commit Hooks

Pre-commit runs YAML validation, secret scanning (ripsecrets, TruffleHog, Gitleaks), and SOPS encryption verification. Install and run with:

```bash
pre-commit install
pre-commit run --all-files
```

Secret files must be SOPS-encrypted before committing — the hook in `.sops-required-files` enforces this for listed paths (currently `gitops/manyfold/.app.env`).

## Architecture

### Directory Structure

- `gitops/` — Active apps managed by the deploy agent
- `gitops-archive/` — Inactive/retired apps kept for reference
- `deploy/` — Deploy agent script and systemd unit files
- `podman/` — Podman system configuration (registries, port permissions)
- `scripts/` — Utility scripts (e.g., env file migration)

### Adding a New App

1. Create `gitops/<app-name>/docker-compose.yaml`
2. If secrets are needed, create `gitops/<app-name>/.app.env` and encrypt with SOPS: `sops --encrypt --in-place gitops/<app-name>/.app.env`
3. Add `gitops/<app-name>` to `gitops-apps.conf`
4. The deploy agent decrypts `.app.env` → `.env` at deploy time; `.env` is gitignored

### Environment / Secrets Pattern

- Secrets live in `.app.env` files encrypted with SOPS (Age key at `~/.sops/age-master-key.txt`)
- The deploy agent decrypts these to `.env` before running `podman-compose`
- Never commit `.env`, `.decrypted*`, or any file matching `.gitignore` patterns
- Some apps have additional config files requiring decryption listed in `gitops-apps.conf`

### Podman-Specific Conventions

All `docker-compose.yaml` files target rootless Podman. Common patterns:

```yaml
# Podman socket (instead of /var/run/docker.sock)
volumes:
  - /run/user/1000/podman/podman.sock:/var/run/docker.sock:z

# SELinux label for container runtime access
security_opt:
  - "label=type:container_runtime_t"

# Auto-update label (used by podman auto-update)
labels:
  io.containers.autoupdate: "registry"

# SELinux volume relabeling
volumes:
  - ./data:/app/data:Z
```

### Renovate

Renovate bot automatically opens PRs to update container image tags in `gitops/**/*.yaml` files. The `kubernetes` manager detects image references in YAML. Merging these PRs triggers the deploy agent on the next git pull.
