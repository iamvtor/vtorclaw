# vtorclaw — Declarative, Zero-Touch OpenClaw VM on Windows (Hyper-V)

Automated, best-practice deployment of OpenClaw in an isolated Ubuntu Linux VM on a Windows host.

**Goals (in priority order)**
- Strong isolation from the Windows host (the VM is the primary trust boundary).
- Best practices inside the guest: dedicated low-privilege `openclaw` user, systemd **system** service, least-privilege Docker access only where required for sandboxes.
- Highly declarative configuration (single `vtorclaw.yaml` spec drives VM resources + OpenClaw config + secrets).
- As close to zero-touch as possible: one PowerShell command after editing the spec.
- Full support for browser tools (requires Docker sandbox backend inside the VM).
- Configurable resources (default 8 GB RAM, easily changed).
- Reproducible and auditable automation.

## Architecture (Recommended Hybrid)

- **Host**: Windows (Hyper-V).
- **Guest**: Ubuntu 24.04 LTS VM (launched via Multipass for excellent Windows integration).
- **Gateway**: Installed natively, runs as a dedicated system user (`openclaw`) under a hardened systemd **system** service.
- **Sandboxes & Browser Tools**: Docker backend inside the same VM (the only practical way to get full browser tool + observer support today). The `openclaw` user is added to the `docker` group (inner trust boundary acknowledged; the VM still protects your Windows host).
- **Declarative Layer**: A `vtorclaw.yaml` spec + cloud-init (rendered at launch time). All important settings (VM size, gateway token, sandbox/browser config, tool policies, model provider, etc.) are expressed declaratively.
- **Access**: `multipass shell`, Tailscale (optional but recommended for zero-touch), or SSH. Control UI and CLI work from inside the guest.

This sits between "pure Docker gateway in VM" and "pure native with offloaded sandboxes". It gives you strong outer isolation + native operational feel + full browser tool support.

### Why not other approaches?
- Native on Windows or Docker Desktop on host: too much direct access to your Windows user profile and files.
- Full OpenShell/SSH sandbox offload: loses browser tools (currently unsupported on non-Docker backends).
- NixOS guest (possible later): excellent declarative story (you already use Nix elsewhere), but adds friction for Windows Hyper-V provisioning and still needs Docker inside the guest for browser sandboxes.

## Quick Start (Zero-Touch Lean)

1. Install Multipass on Windows (recommended):
   ```powershell
   winget install --id Canonical.Multipass -e
   ```

2. Copy the example spec and edit it:
   ```powershell
   Copy-Item vtorclaw.example.yaml vtorclaw.yaml
   # Edit vtorclaw.yaml with your values (model key, optional Tailscale key, RAM, etc.)
   ```

3. Launch (one command):
   ```powershell
   .\scripts\launch.ps1 -Spec vtorclaw.yaml
   # Or with overrides:
   # .\scripts\launch.ps1 -Spec vtorclaw.yaml -Memory 12G -Cpus 4
   ```

4. The script:
   - Generates a strong random gateway token.
   - Renders a secure-by-default `openclaw.json` (sandbox non-main + browser enabled, pairing policies, etc.).
   - Launches the VM with cloud-init that creates the dedicated user, installs everything, builds sandbox images, writes the systemd service, starts it.
   - Prints final instructions (how to shell in, dashboard URL, next steps for channels).

5. Connect and finish the last mile (unavoidable for channels):
   ```powershell
   multipass shell openclaw
   sudo -u openclaw openclaw gateway status
   sudo -u openclaw openclaw channels add --channel telegram --token "..."
   # WhatsApp QR, etc.
   ```

The VM is now your isolated OpenClaw instance with browser tools available.

## Declarative Spec (`vtorclaw.yaml`)

Everything important lives in one file (or passed as CLI overrides). Example structure (see `vtorclaw.example.yaml`):

```yaml
vm:
  name: openclaw
  memory: "8G"      # Configurable, default 8G
  cpus: 2
  disk: "30G"
  ubuntu: "24.04"

openclaw:
  channel: "stable"   # stable | beta | main
  config:             # Merged into the generated openclaw.json
    agents:
      defaults:
        sandbox:
          mode: "non-main"
          browser:
            autoStart: true
    # Add your model, tools policy overrides, etc. here

secrets:
  file: "secrets.yaml"   # Optional; keys like ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN etc. are written securely during provisioning
  # Or inline values (not recommended for committed files)

tailscale:
  auth_key: ""           # Optional reusable or one-time key for zero-touch networking inside the VM
```

The launcher renders cloud-init from this spec + a template, so the entire VM + OpenClaw state is driven declaratively.

## Best Practices Implemented

- Dedicated `openclaw` system user (no unnecessary root, restricted home, owns its state).
- Systemd **system** service (more reliable on headless VMs than user services; common recommendation for VPS/VM deployments).
- Generated strong gateway auth token at provision time.
- Sandbox enabled by default for non-main sessions + full browser sandbox configuration.
- Secure channel defaults (pairing, per-channel-peer, mention gating where sensible).
- Docker access limited to the `openclaw` user (only for sandbox creation).
- Persistence on the VM disk (easy to snapshot the whole guest).
- `openclaw security audit` can be run post-provision.
- Resource limits and VM specs are explicit and overridable.
- Cloud-init + spec = auditable, version-controllable deployment.

## Provisioning Choices (Multipass + Cloud-Init vs Packer)

We default to **Multipass + cloud-init** (with a declarative spec) because it delivers the best zero-touch experience on Windows today while remaining highly declarative for this use case.

**Multipass + cloud-init (current primary path)**
- Pros: Native Windows experience (Hyper-V), cloud-init is purpose-built for exactly this (users, packages, systemd units, write_files, runcmd), extremely fast iteration and feedback, simple one-binary dependency, easy to make RAM/CPU/disk fully configurable via the spec or CLI, great `multipass` management commands (shell, delete, snapshot, etc.).
- Cons: Some imperative steps live in `runcmd` (cloud-init is "declarative enough" but not pure like Nix), each launch re-runs the provisioning steps (acceptable for this workload).

**Packer (golden images)**
- Pros: True reproducible golden images (pre-install OpenClaw, pre-build browser images, pre-configure service and user), versionable artifacts, faster subsequent launches, more "infrastructure-as-code" feel, can be used directly with Hyper-V or fed into Multipass.
- Cons: Heavier upfront (Packer + Hyper-V builder config can be fiddly on Windows), longer build times when you change something, still needs a launcher script for per-user secrets/config (you end up with a hybrid anyway), extra tool to install.

**Hybrid (recommended evolution path)**
- Use Packer to build a base "openclaw-golden" image (everything baked except user-specific secrets and final config overrides).
- Use Multipass + a thin cloud-init layer (driven by your `vtorclaw.yaml`) for the final declarative customization and secrets injection.
- This gives you both golden-image speed/reproducibility and easy per-deployment configuration.

If you prefer starting with Packer (or the hybrid), say the word and we'll add a `packer/` directory and adjust the launcher. Current scaffolding focuses on the Multipass + cloud-init path for fastest progress toward zero-touch.

## Configurable Resources

- RAM: default 8 GB (as you requested), fully overridable in `vtorclaw.yaml` or via launcher flags (`-Memory 12G`).
- CPUs and disk size are also first-class in the spec.
- The cloud-init and service respect the allocated resources (browser sandboxes can be memory-hungry; 8 GB is a reasonable starting point for moderate use).

## Security Notes (Important)

- The VM is the primary isolation boundary from Windows. Treat the `openclaw` user + Docker group inside the VM as the next boundary.
- Browser tools are powerful. They run in their own sandboxed containers with the usual OpenClaw hardening (dedicated network, blocked dangerous binds, `workspaceAccess` controls, etc.).
- Keep channel policies tight (`dmPolicy: pairing` or strict allowlists, `session.dmScope: per-channel-peer`).
- Run `openclaw security audit` after changes.
- Never commit real secrets into the spec or repo.

## Next Steps & Customization

After the first launch you can:
- Edit the running config inside the VM (`sudo -u openclaw nano /home/openclaw/.openclaw/openclaw.json` then restart the service).
- Add channels, skills, etc.
- Update OpenClaw (`sudo -u openclaw openclaw update` or the provided helper).
- Snapshot the VM for easy rollback/experiments.

The automation is designed to be re-runnable / idempotent-ish for updates.

## Contributing / Extending

This repo is the automation toolkit. PRs that improve declarativity, add Packer support, improve secret handling, or add monitoring are welcome.

---

Run `./scripts/launch.ps1 -Help` (or read the script) for current flags.

Happy clawing — in a properly isolated box. 🦞
