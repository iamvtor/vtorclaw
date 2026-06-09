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

### Using your existing subscriptions (Google AI Pro + X Premium+)

- **Google AI Pro (Gemini)**: Go to https://aistudio.google.com/app/apikey while logged in with the account that has AI Pro. Create an API key there. Put it in your secrets file as `GOOGLE_API_KEY`. This works great with OpenClaw's tool use and browser features.
- **X Premium+ / Grok**: Chat access is excellent, but generating a real API key for external agents like OpenClaw is not always exposed with just Premium+. Many users need the standalone SuperGrok plan for a usable `XAI_API_KEY`. You can leave it commented out and use Gemini as primary for now.

The example spec above is already set up for this. Just drop your key in `secrets.yaml` and run the launcher.

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

## LiteLLM for Unified Model Access (Recommended)

See the detailed section below ("Using Google AI Pro or X Premium+ with OpenClaw (via LiteLLM)") for why and how to run LiteLLM inside the VM. It turns your various subscriptions (Google AI Pro, X Premium+/SuperGrok, NVIDIA free models) into a single clean OpenAI-compatible endpoint that OpenClaw talks to.

I have pre-wired the example spec to use the LiteLLM pattern by default (`http://127.0.0.1:4000`).

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

If you later want a single OpenAI-compatible endpoint + easy fallbacks/logging across more providers, you can add LiteLLM inside the VM. It sits between OpenClaw and your actual providers (free Google key, NVIDIA, etc.). For your current 2–3, direct is simpler.

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

#### How to hook up LiteLLM to your providers

1. **Get the keys** (matching your plan)
   - Free-tier Google account (for free Gemini models/quota): Create a completely separate free Google account (don't use your paid one). Then go to https://aistudio.google.com/app/apikey while logged into the *free* account and create a key → `GOOGLE_API_KEY`. This gives you access to the free-tier models (e.g. gemini-2.0-flash with free quotas).
   - X Premium+ for Grok: Preferred is native OAuth (no separate key — see the Grok OAuth section below for the device-code command you run inside the VM). If you can obtain an xAI API key (via grok.com settings or standalone SuperGrok), put it here as `XAI_API_KEY`.
   - NVIDIA free models (optional): Usually at https://build.nvidia.com or integrate.api.nvidia.com. Create a key → `NVIDIA_API_KEY`.

2. **Add to your secrets.yaml**
   ```yaml
   # From your separate *free* Google account (for free Gemini models)
   GOOGLE_API_KEY: "AIzaSyYourFreeAccountKeyHere..."

   # For Grok — prefer native OAuth (no key). Only fill this if using the API-key path.
   # XAI_API_KEY: "xai-..."

   # Optional
   NVIDIA_API_KEY: "nvapi-..."
   LITELLM_MASTER_KEY: "sk-1234"   # optional but recommended for LiteLLM auth
   ```

3. **LiteLLM config example** (create `litellm_config.yaml` inside the VM or via the launcher)

   This example focuses on your **Google AI Pro** (paid Gemini) + **NVIDIA free-tier** models. Grok is handled natively via OAuth (see section above), but you can also proxy it through LiteLLM if you prefer a single endpoint.

   ```yaml
   model_list:
     # Paid Gemini from your Google AI Pro subscription
     - model_name: google/gemini-2.0-flash
       litellm_params:
         model: gemini/gemini-2.0-flash
         api_key: os.environ/GOOGLE_API_KEY

     - model_name: google/gemini-2.0-pro
       litellm_params:
         model: gemini/gemini-2.0-pro
         api_key: os.environ/GOOGLE_API_KEY

     # NVIDIA free / low-cost models (via their platform credits)
     - model_name: nvidia/llama-3.1-8b
       litellm_params:
         model: nvidia_nim/meta/llama-3.1-8b-instruct
         api_base: https://integrate.api.nvidia.com/v1
         api_key: os.environ/NVIDIA_API_KEY

     - model_name: nvidia/llama-3.1-70b
       litellm_params:
         model: nvidia_nim/meta/llama-3.1-70b-instruct
         api_base: https://integrate.api.nvidia.com/v1
         api_key: os.environ/NVIDIA_API_KEY

     # Optional: proxy Grok too (if you want everything behind one endpoint)
     # - model_name: xai/grok-3
     #   litellm_params:
     #     model: xai/grok-3
     #     api_key: os.environ/XAI_API_KEY   # only if using API key path

   litellm_settings:
     drop_params: true
     request_timeout: 600

   general_settings:
     master_key: os.environ/LITELLM_MASTER_KEY   # optional
   ```

   Then in OpenClaw you can use the aliases directly (or through the LiteLLM openai provider).

4. **Run LiteLLM**
   - Install: `pip install litellm[proxy]`
   - Start: `litellm --config litellm_config.yaml --port 4000 --host 0.0.0.0`
   - For production in the VM: run it as a systemd service (the launcher can do this).

5. **Point OpenClaw at LiteLLM** (in your `vtorclaw.yaml` or directly in the VM)

   ```yaml
   models:
     providers:
       openai:
         apiBase: "http://127.0.0.1:4000"
         apiKey:
           source: "env"
           provider: "default"
           id: "LITELLM_MASTER_KEY"

   agent:
     model: "google/gemini-2.0-flash"   # or "xai/grok-3" or your nvidia alias
   ```

Now OpenClaw only talks to localhost:4000. Switch models by just changing the `model:` string.

I have already updated `vtorclaw.example.yaml` to default to the LiteLLM pattern. If you want me to also add automatic LiteLLM installation + systemd service + sample `litellm_config.yaml` generation into the cloud-init/launcher, just say the word and I'll implement it.

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
