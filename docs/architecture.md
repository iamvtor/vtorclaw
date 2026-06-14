# Architecture & Best Practices

## High-Level
Windows (Hyper-V) → Ubuntu VM (via Multipass) → dedicated `openclaw` system user → native gateway (systemd system service) → Docker (only for sandboxes + browser tools).

The VM is the hard isolation boundary from your Windows host and personal files.

Inside the VM the `openclaw` user + docker group membership is the next (acknowledged) trust boundary required to deliver full browser tool support.

## Why Native Gateway + Docker Sandboxes (not full containerized gateway)
- Operational simplicity and best-practice service management on a headless VM.
- Avoids extra DooD surface for the control plane itself.
- Still gets full sandbox + browser tool support (the reason we chose this hybrid).

## Dedicated User
- System user `openclaw` (created declaratively in cloud-init).
- Owns `/home/openclaw` (or equivalent) and all OpenClaw state.
- Runs the gateway via a hardened systemd **system** unit (more reliable than user services on many VPS/VM images).
- Added to the `docker` group only because the Docker sandbox backend needs it.

## Declarative Configuration
- Single `vtorclaw.yaml` drives:
  - VM resources (memory is first-class and overridable).
  - OpenClaw channel / high-level settings.
  - A `config:` block that is merged into the generated `openclaw.json`.
  - Secrets file path.
  - Optional Tailscale auto-join.
- The launcher renders the final cloud-init and injects generated secrets (gateway token, provider keys) at launch time only.

## Browser Tools
Enabled by default via `agents.defaults.sandbox.browser.autoStart: true` and the pre-built sandbox-browser image.
The browser runs in its own hardened container with the usual OpenClaw protections (dedicated network, blocked dangerous paths, etc.).

## Zero-Touch Goals
- One PowerShell command after editing the spec.
- Gateway token auto-generated.
- Service starts automatically.
- Sandbox + browser images pre-built so first use is fast.
- Optional Tailscale for seamless access from Windows without thinking about networking.

## Future / Optional Improvements
- Packer golden image (base layer) + thin cloud-init overlay via native Hyper-V (New-VM + CIDATA seed disk) — now implemented in `packer/` + `scripts/new-cidata-drive.ps1`. This path completely removes Multipass while preserving the declarative spec and "openclaw as default user + injected host key" behavior.
- Nix inside the guest (via nix-openclaw) for even more declarative management of the gateway binary + plugins on top of the Docker sandbox layer.
- Post-launch verification step that runs `openclaw security audit --fix`.
- Snapshot / golden VM export helpers.

This design prioritizes your stated preferences: dedicated user, declarative spec-driven automation, near zero-touch, configurable resources, and full browser tool support.
