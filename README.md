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

   The launcher will automatically run `multipass find` (quietly) for you the first time to fetch the image catalog and register the official remotes. You don't need to run it manually.

2. Copy the example spec + secrets template and edit them:
   ```powershell
   Copy-Item vtorclaw.example.yaml vtorclaw.yaml
   Copy-Item secrets.example.yaml secrets.yaml
   # Edit vtorclaw.yaml (VM size, Tailscale etc.)
   # Edit secrets.yaml with your GOOGLE_API_KEY from a free Google account (aistudio.google.com)
   ```

3. Launch **with PowerShell 7+ only** (`pwsh`), **not** legacy Windows PowerShell 5.1 (`powershell`).

   Windows has two PowerShell engines:
   - Old v5.1 (`powershell.exe`) — the script will now detect it at the top and exit with a clear message + the exact command to use your 7.5.5 instead.
   - Modern 7+ (`pwsh.exe` — you have 7.5.5) — **use this one**.

   ```powershell
   pwsh -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml
   # Or with overrides:
   # pwsh -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml -Memory 12G -Cpus 4
   ```

   If the `pwsh` command isn't in your PATH, use the full path to your 7.5.5 installation:
   ```powershell
   & "C:\\Program Files\\PowerShell\\7\\pwsh.exe" -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml
   ```

4. The script (must be run with pwsh 7+):
   - Checks that you're using PowerShell 7+ (exits with instructions if you're accidentally using the old v5.1).
   - Generates a strong random gateway token.
   - Renders a secure-by-default `openclaw.json` (sandbox non-main + browser enabled, pairing policies, etc.).
   - Launches the VM with cloud-init that creates the dedicated user, installs everything, builds sandbox images, writes the systemd service, starts it.
   - Prints final instructions (how to shell in, dashboard URL, next steps for channels).

5. Connect and finish the last mile (OAuth for Grok + channels):

After launch, shell in and run as the dedicated low-privilege user:

   ```powershell
   multipass shell openclaw
   sudo -u openclaw openclaw gateway status

   # One-time: authenticate Grok via X Premium+ (device code flow — no API key required in most cases)
   sudo -u openclaw openclaw models auth login --provider xai --method oauth

   # Then add channels (WhatsApp will show a QR, Telegram needs a bot token, etc.)
   sudo -u openclaw openclaw channels login
   # or for a specific channel:
   # sudo -u openclaw openclaw channels add --channel telegram --token "..."
   ```

The VM is now your isolated OpenClaw instance with browser tools available (via the pre-built docker sandbox). All model auth and channels are owned by the `openclaw` user.

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
    # Model providers example (Google AI Pro + optional xAI)
    models:
      providers:
        google:
          apiKey:
            source: "env"
            provider: "default"
            id: "GOOGLE_API_KEY"
    agent:
      model: "google/gemini-2.0-flash"

secrets:
  file: "secrets.yaml"   # Optional; keys like GOOGLE_API_KEY, TELEGRAM_BOT_TOKEN etc. are written securely during provisioning
  # Or inline values (not recommended for committed files)

tailscale:
  auth_key: ""           # Optional reusable or one-time key for zero-touch networking inside the VM
```

The launcher renders cloud-init from this spec + a template, so the entire VM + OpenClaw state is driven declaratively.

### Using a free-tier Google account + X Premium+ (direct, recommended for your case)

- **Google (free tier)**: Create a **separate free Google account** (do not use a paid AI Pro one — paid keys are routed to paid models only). Go to https://aistudio.google.com/app/apikey while logged into the free account and create a key. Put it in `secrets.yaml` as `GOOGLE_API_KEY`. This gives you real free Gemini quotas (gemini-2.0-flash etc.) that work with tools and the browser sandbox.
- **X Premium+ / Grok**: Use native OAuth (device-code flow). No `XAI_API_KEY` is usually needed. After the VM is up, run the login command inside as the dedicated user (see "After launch" below). This is the path that works with Premium+ chat access for agents.

`secrets.example.yaml` + `vtorclaw.example.yaml` are set up for exactly this combination. Copy, fill the free Google key, launch, then do the one-time OAuth.

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

## Model Providers for Your Setup (Direct — No LiteLLM Needed)

For the combination you are using (separate free Google account for Gemini + X Premium+ for Grok via native OAuth + optional NVIDIA), direct multi-provider configuration in OpenClaw is simpler and sufficient.

- Put `GOOGLE_API_KEY` (from a **free** Google account at aistudio.google.com) into `secrets.yaml`.
- After the VM boots, run the one-time OAuth login for Grok as the dedicated user (device code flow, no console key required for Premium+ in most cases).
- Set your agent model to `google/gemini-2.0-flash` (or `xai/grok-3` after OAuth).

LiteLLM is only useful later if you want one unified endpoint + fallbacks when adding many more providers. It is **not** required for your current 2–3. The `vtorclaw.example.yaml` now shows the direct style by default.

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

### LiteLLM (optional later)

If you later want a single OpenAI-compatible endpoint + easy fallbacks/logging across more providers, you can add LiteLLM inside the VM. It sits between OpenClaw and your actual providers (free Google key, NVIDIA, etc.). For your current 2–3, direct multi-provider config is simpler and what the examples now default to.

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

### Using a free-tier Google account + X Premium+ (direct, no LiteLLM needed)

Since you're using:
- A separate **free Google account** for Gemini (to get the actual free-tier models/quota)
- Your **X Premium+** for Grok (via native OAuth)

...you can configure OpenClaw **directly** with multiple providers. This is simpler and what your current `vtorclaw.example.yaml` is set up for.

LiteLLM is still available as an optional layer later (for one endpoint + easy fallbacks), but it's not required for just these 2–3 providers.

**Important Google note**
Paid Google AI Pro keys do not give free-tier Gemini access. That's why a separate free Google account + key from aistudio.google.com is the correct approach here.

#### Why LiteLLM helps
- OpenClaw works best when pointed at a single OpenAI-compatible endpoint.
- LiteLLM translates calls for 100+ providers (Gemini, xAI/Grok, NVIDIA NIM, Ollama, etc.) behind one local server (`http://127.0.0.1:4000`).
- You configure your real keys *once* in a `litellm_config.yaml` (using env vars from your secrets).
- Easy model switching, fallbacks (e.g. try Gemini first, fall back to Grok), logging, caching, and spend tracking — all inside the isolated VM.
- Perfect for your setup: keep keys out of OpenClaw config, support "free" NVIDIA models, and keep everything declarative.

#### LiteLLM (only if you add more providers later)

If you later want a single OpenAI-compatible endpoint + easy fallbacks/logging across many providers (beyond free Google + X + optional NVIDIA), you can run LiteLLM inside the VM as an optional proxy.

For your current setup the direct `google:` provider + native xai OAuth is simpler and what the examples are configured for. See the "LiteLLM (optional later)" notes higher up if you want to go that route in the future.

The example now defaults to direct providers (matching your free Google + X Premium+ OAuth plan). LiteLLM can be added later as an optional layer only if you expand beyond these providers.

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
