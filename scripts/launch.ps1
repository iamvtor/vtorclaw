<#
.SYNOPSIS
    Zero-touch (as close as we can get) launcher for an isolated OpenClaw VM on Windows (Hyper-V via Multipass).

.DESCRIPTION
    Reads a declarative vtorclaw.yaml spec, generates a strong gateway token,
    renders a secure-by-default openclaw.json (with browser sandbox support),
    produces a cloud-init that creates a dedicated `openclaw` system user,
    installs Docker + OpenClaw natively, sets up a hardened systemd *system* service,
    pre-builds sandbox + browser images, and starts everything.

    The VM is the primary isolation boundary from your Windows host.
    Inside the VM we follow best practices: dedicated user + system service.

.PARAMETER Spec
    Path to your vtorclaw.yaml (or .example.yaml).

.PARAMETER Memory
    Override VM memory (e.g. "12G"). Defaults to value in spec (or 8G).

.PARAMETER Cpus
    Override vCPU count.

.PARAMETER Name
    Override VM name.

.EXAMPLE
    .\scripts\launch.ps1 -Spec .\vtorclaw.yaml

.EXAMPLE
    .\scripts\launch.ps1 -Spec .\vtorclaw.yaml -Memory 12G -Cpus 4
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Spec = "vtorclaw.yaml",

    [Parameter(Mandatory=$false)]
    [string]$Memory,

    [Parameter(Mandatory=$false)]
    [int]$Cpus,

    [Parameter(Mandatory=$false)]
    [string]$Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Require PowerShell 7+ (the script uses modern syntax and the generated cloud-init
# is for a Linux guest; running under Windows PowerShell 5.1 can cause parser
# errors on || / here-strings etc.)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: This script requires PowerShell 7+. You appear to be running Windows PowerShell 5.1." -ForegroundColor Red
    Write-Host "Please run it with the pwsh executable instead:" -ForegroundColor Yellow
    Write-Host "    pwsh -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If you have PS 7.5.5 installed, you can also use the full path, e.g.:" -ForegroundColor Yellow
    Write-Host "    & 'C:\\Program Files\\PowerShell\\7\\pwsh.exe' -File .\\scripts\\launch.ps1 -Spec vtorclaw.yaml" -ForegroundColor Yellow
    exit 1
}

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

# --- Load & validate spec ---------------------------------------------------------
if (-not (Test-Path $Spec)) {
    Write-Err "Spec file not found: $Spec"
    Write-Host "Copy vtorclaw.example.yaml to vtorclaw.yaml and edit it first."
    exit 1
}

$specContent = Get-Content $Spec -Raw

# Lightweight parsing (no external modules). Good enough for our declarative spec.
# For the complex openclaw.config we will treat the whole block as text and
# let the launcher build a proper openclaw.json using PowerShell objects + ConvertTo-Json.
$specData = @{}
$inOpenclawConfig = $false
$openclawConfigLines = @()
$inTailscale = $false

foreach ($line in ($specContent -split "`n")) {
    $trim = $line.Trim()
    if ($trim -match '^vm:') { $inOpenclawConfig = $false; continue }
    if ($trim -match '^openclaw:') { $inOpenclawConfig = $false; continue }
    if ($trim -match '^  channel:\s*["'']?([^"''#]+)') { $specData['openclaw_channel'] = $Matches[1].Trim(); continue }
    if ($trim -match '^  config:') { $inOpenclawConfig = $true; continue }
    if ($inOpenclawConfig -and $line -match '^\s{4}') {
        $openclawConfigLines += $line
        continue
    } else {
        $inOpenclawConfig = $false
    }

    if ($trim -match '^  name:\s*["'']?([^"''#]+)') { $specData['vm_name'] = $Matches[1].Trim() }
    if ($trim -match '^  memory:\s*["'']?([^"''#]+)') { $specData['memory'] = $Matches[1].Trim() }
    if ($trim -match '^  cpus:\s*(\d+)') { $specData['cpus'] = [int]$Matches[1] }
    if ($trim -match '^  disk:\s*["'']?([^"''#]+)') { $specData['disk'] = $Matches[1].Trim() }
    if ($trim -match '^  ubuntu:\s*["'']?([^"''#]+)') { $specData['ubuntu'] = $Matches[1].Trim() }
    if ($trim -match '^tailscale:') { $inTailscale = $true; continue }
    if ($inTailscale -and $trim -match '^\s*auth_key:\s*["'']?([^"''#]+)') { $specData['tailscale_key'] = $Matches[1].Trim(); $inTailscale = $false }
    if ($trim -match '^\s*file:\s*["'']?([^"''#]+)') { $specData['secrets_file'] = $Matches[1].Trim() }
}

# Store raw config lines for later JSON merging if user put a full block
$specData['openclaw_config_raw'] = ($openclawConfigLines -join "`n").Trim()

if (-not $specData['vm_name']) { $specData['vm_name'] = "openclaw" }
if (-not $specData['memory'])  { $specData['memory'] = "8G" }
if (-not $specData['cpus'])    { $specData['cpus'] = 2 }
if (-not $specData['disk'])    { $specData['disk'] = "30G" }
if (-not $specData['ubuntu'])  { $specData['ubuntu'] = "24.04" }
if (-not $specData['openclaw_channel']) { $specData['openclaw_channel'] = "stable" }

# Apply CLI overrides (index syntax for strict mode safety)
if ($Memory) { $specData['memory'] = $Memory }
if ($Cpus)   { $specData['cpus']   = $Cpus }
if ($Name)   { $specData['vm_name'] = $Name }

# Defensive guard immediately after parsing to catch corrupted script files early
# (prevents cryptic "Unable to index into an object of type "System.String"." when
# the $specData initialization or parsing was skipped due to file corruption).
if (-not $specData -or $specData -isnot [hashtable]) {
    Write-Err "Internal error: `$specData is not a hashtable (type: $(if ($specData) { $specData.GetType().FullName } else { 'null' }))."
    Write-Host "This almost always means your local copy of launch.ps1 is from an old/bad state (previous mangled pull or edit)."
    Write-Host "Run this to get the clean current version (bypasses git):"
    Write-Host "  Invoke-WebRequest https://raw.githubusercontent.com/iamvtor/vtorclaw/main/scripts/launch.ps1 -OutFile .\scripts\launch.ps1"
    Write-Host "Then run the script again."
    exit 1
}

Write-Info "Using spec: $Spec"
Write-Info "VM: $($specData['vm_name']) | Image: $($specData['ubuntu']) | Memory: $($specData['memory']) | CPUs: $($specData['cpus']) | Disk: $($specData['disk'])"

# --- Generate strong gateway token ------------------------------------------------
$gatewayToken = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }))
Write-Info "Generated strong gateway token (will be injected into the VM only)."

# --- Load optional secrets file ---------------------------------------------------
$secrets = @{}
if ($specData['secrets_file'] -and (Test-Path $specData['secrets_file'])) {
    Write-Info "Loading secrets from $($specData['secrets_file'])"
    $secretsContent = Get-Content $specData['secrets_file'] -Raw
    # Again, naive extraction for common keys (expand as needed)
    foreach ($line in ($secretsContent -split "`n")) {
        if ($line -match '^\s*([A-Z_]+_API_KEY|[A-Z_]+_TOKEN)\s*:\s*["'']?([^"''#]+)') {
            $secrets[$Matches[1]] = $Matches[2].Trim()
        }
    }
} else {
    Write-Warn "No secrets file found (or not specified). You will configure model keys and channels after launch."
}

# --- Build secure openclaw.json from declarative spec + best-practice defaults ---
# The shape here is aligned with the official config reference for the openclaw
# package (pnpm add -g openclaw) so that `gateway run` (the subcommand our system
# unit executes) accepts the file as a properly configured local gateway and does
# not hit the "Missing config / resolving authentication" guard (status 78/CONFIG).
# See docs.openclaw.ai/gateway/configuration-reference and the CLI "gateway" page:
# the binary refuses to start `gateway run` unless gateway.mode=local is present
# (and the surrounding auth/controlUi/etc. shape looks like a completed local setup).
# We also guarantee a strong per-launch token and the google env provider.
$baseConfig = @{
    gateway = @{
        mode = "local"
        port = 18789
        bind = "loopback"
        auth = @{
            mode = "token"
            token = $gatewayToken
            allowTailscale = $true
            rateLimit = @{
                maxAttempts = 10
                windowMs = 60000
                lockoutMs = 300000
                exemptLoopback = $true
            }
        }
        tailscale = @{
            mode = "off"
            resetOnExit = $false
        }
        controlUi = @{
            enabled = $true
            basePath = "/openclaw"
        }
    }
    session = @{
        dmScope = "per-channel-peer"
    }
    agents = @{
        defaults = @{
            model = "google/gemini-2.0-flash"
            sandbox = @{
                mode = "non-main"
                backend = "docker"
                scope = "session"
                workspaceAccess = "rw"
                browser = @{
                    autoStart = $true
                    autoStartTimeoutMs = 30000
                }
            }
        }
    }
    tools = @{
        profile = "messaging"
    }
    channels = @{
        telegram = @{ dmPolicy = "pairing" }
        whatsapp = @{ dmPolicy = "pairing" }
    }
    # Direct google provider support for free-tier key (injected via secrets Environment).
    # User openclaw.config block (from spec) can override/extend other sections.
    # xAI is expected to be added via native OAuth post-boot inside the VM.
    models = @{
        providers = @{
            google = @{
                apiKey = @{
                    source = "env"
                    provider = "default"
                    id = "GOOGLE_API_KEY"
                }
            }
        }
    }
}

# User openclaw.config block (the text under openclaw.config: in the spec) is now
# given a best-effort merge: if it parses as a JSON object we take top-level keys
# from it (except gateway, which we always force to our secured local+token shape
# so the pnpm-installed binary's guard for `gateway run` is satisfied).
# This makes the declarative spec actually control channels, models, agents etc.
# while the launcher still owns the security-critical gateway bits and the token.
if ($specData['openclaw_config_raw']) {
    try {
        $overlay = $specData['openclaw_config_raw'] | ConvertFrom-Json -ErrorAction Stop
        foreach ($k in $overlay.PSObject.Properties.Name) {
            if ($k -eq 'gateway') { continue }
            if ($k -eq 'agent') {
                # Remap singular "agent" (from example specs) into agents.defaults.model
                # so the schema for 2026.6.x accepts it (top-level "agent" is unrecognized).
                if ($overlay.agent.model) {
                    if (-not $baseConfig.ContainsKey('agents')) { $baseConfig['agents'] = @{} }
                    if (-not $baseConfig.agents.ContainsKey('defaults')) { $baseConfig.agents['defaults'] = @{} }
                    $baseConfig.agents.defaults['model'] = $overlay.agent.model
                }
                continue
            }
            $baseConfig[$k] = $overlay.$k
        }
        Write-Info "Merged user openclaw.config block from spec (top-level keys except gateway; remapped singular agent if present)."
    } catch {
        Write-Warn "User openclaw.config block in spec was not valid JSON and could not be merged (it is still written as a comment in the TEMP cloud-init for review). Use JSON syntax under the config: block or edit ~/.openclaw/openclaw.json after launch."
    }
}

# Always (re)apply the secured gateway section last so our token + documented
# local shape wins even if the user tried to supply a gateway stanza.
$baseConfig['gateway'] = @{
    mode = "local"
    port = 18789
    bind = "loopback"
    auth = @{
        mode = "token"
        token = $gatewayToken
        allowTailscale = $true
        rateLimit = @{
            maxAttempts = 10
            windowMs = 60000
            lockoutMs = 300000
            exemptLoopback = $true
        }
    }
    tailscale = @{
        mode = "off"
        resetOnExit = $false
    }
    controlUi = @{
        enabled = $true
        basePath = "/openclaw"
    }
}

$openclawJson = $baseConfig | ConvertTo-Json -Depth 10

# Build secret Environment lines for the systemd unit
$secretEnvLines = ""
if ($secrets.Count -gt 0) {
    $secretEnvLines = ($secrets.GetEnumerator() | ForEach-Object { "      Environment=$($_.Key)=$($_.Value)" }) -join "`n"
}

# Tailscale block (injected into runcmd as plain text with newlines)
$tailscaleBlock = if ($specData['tailscale_key']) {
    "  - curl -fsSL https://tailscale.com/install.sh | sh`n  - tailscale up --authkey=$($specData['tailscale_key']) --hostname=$($specData['vm_name']) --accept-dns=true --accept-routes=true || true"
} else {
    "  - echo 'Tailscale not configured in spec' > /dev/null || true"
}

# Properly indent the JSON for the YAML literal block scalar (content: |).
# Do NOT escape quotes - the | block is literal text.
$indentedOpenClawJson = if ($openclawJson) {
    ($openclawJson -split "`n" | ForEach-Object { "      $_" }) -join "`n"
} else {
    ""
}

# Raw (no extra indent) version for use inside shell heredocs in the runcmd
# (e.g. the defensive re-write of the config as the dedicated user).
$rawOpenClawJson = $openclawJson

# Indented version (6 spaces) for the placeholder inside the YAML literal block
# scalar for the adoption heredoc. This keeps all content lines at consistent
# indentation so yaml-cpp doesn't see a premature "end of map".
# The heredoc in the generated script will pipe through sed to strip the prefix
# so the on-disk openclaw.json is clean (no leading whitespace before {).
$indentedRawOpenClawJson = if ($rawOpenClawJson) {
    ($rawOpenClawJson -split "`n" | ForEach-Object { "      $_" }) -join "`n"
} else {
    ""
}

# --- Clean cloud-init template with placeholders (easy to maintain) ----------------
$cloudInitTemplate = @'
#cloud-config
# Generated by vtorclaw launcher from declarative spec.
# Do not edit by hand — re-run the launcher to regenerate.

users:
  - name: openclaw
    gecos: "OpenClaw Gateway"
    system: true
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [docker]

package_update: true
packages:
  - docker.io
  - curl
  - jq
  - ca-certificates
  - gnupg
  # nodejs/npm deliberately omitted here — we install a modern version (22+) via NodeSource below
  # because the openclaw CLI (as of 2026.6.5+) requires Node >=22.19 and uses ES2023 features
  # (e.g. Array.prototype.toSorted) in its postinstall script. The stock Ubuntu 24.04 nodejs is v18.

write_files:
  - path: /etc/systemd/system/openclaw-gateway.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=OpenClaw Gateway (dedicated user)
      After=network-online.target docker.service
      Wants=network-online.target
      Requires=docker.service

      [Service]
      Type=simple
      User=openclaw
      Group=openclaw
      WorkingDirectory=/home/openclaw
      Environment=OPENCLAW_GATEWAY_TOKEN=__GATEWAY_TOKEN__
__SECRET_ENV_LINES__
      ExecStart=/home/openclaw/.openclaw/bin/openclaw gateway run
      Restart=on-failure
      RestartSec=5s

      # Best-practice hardening for a tool-using agent service
      ProtectSystem=strict
      ProtectHome=read-only
      ReadWritePaths=/home/openclaw/.openclaw
      PrivateTmp=true
      NoNewPrivileges=true

      [Install]
      WantedBy=multi-user.target

  - path: /home/openclaw/.openclaw/openclaw.json
    owner: openclaw:openclaw
    permissions: "0600"
    content: |
__OPENCLAW_CONFIG_JSON__

runcmd:
  - systemctl enable --now docker
  - usermod -aG docker openclaw

  # Early root-level ownership fix + dir creation.
  # cloud-init + "system: true" user creation can leave /home/openclaw (and files under it)
  # owned by root at the moment the first runcmd items execute. Any immediate "sudo -u openclaw"
  # that tries to mkdir or write ~/.openclaw or ~/.bashrc will get EACCES / Permission denied.
  # We fix it as root *before* any sudo -u write attempts. The big install block below also
  # reinforces this defensively at the top of its payload.
  - chown -R openclaw:openclaw /home/openclaw || true
  - mkdir -p /home/openclaw/.openclaw/bin || true
  - chown -R openclaw:openclaw /home/openclaw || true

  # Install Node 24 (via NodeSource) + enable pnpm via corepack.
  # The openclaw CLI requires a recent Node (we target 24) and we now use pnpm for the
  # global install step (instead of npm) for better performance/reproducibility.
  - |
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y nodejs
    corepack enable
    corepack prepare pnpm@latest --activate || true

  # One atomic, fully-logged native CLI install + force-link step.
  # Everything (set -x, echoes, inner sudo output) is captured via exec redirection at the top of this block.
  # This guarantees:
  #   - /tmp/openclaw-install.log is *always* created
  #   - We use the official simple `pnpm add -g openclaw` (after Node 24 + corepack).
  #     (The external install.sh was unreliable; pnpm puts the binary in its own global layout.)
  #   - Unconditional find + force ln -sf (after the install) to *both* the location the systemd
  #     unit ExecStart hard-codes (/home/openclaw/.openclaw/bin/openclaw) and /usr/local/bin
  #     (the /usr/local link is done as root, since sudo -u cannot write there).
  #   - Loud SUCCESS / VERIFIED markers that are easy to find even when tailscale + node package noise
  #     floods the main cloud-init-output.log.
  - |
    exec > /tmp/openclaw-install.log 2>&1
    set -x
    echo "=== OPENCLAW INSTALL START $(date -u) ==="

    # As root (this block runs as root), ensure the dedicated user's home and our target dirs
    # are owned by it *before* we do any sudo -u openclaw that creates files (mkdir, npm writes,
    # appending to .bashrc/.profile, etc.). This defeats the common cloud-init + system-user
    # timing/ownership race.
    chown -R openclaw:openclaw /home/openclaw 2>/dev/null || true
    mkdir -p /home/openclaw/.openclaw/bin /home/openclaw/.openclaw/state /home/openclaw/.openclaw/logs/stability 2>/dev/null || true
    chown -R openclaw:openclaw /home/openclaw 2>/dev/null || true

    # 1. Reinforce PATH for the dedicated user (covers sudo -u and future login shells).
    # Include /usr/local/bin (for the bare name after we symlink) and pnpm's global bin dir
    # (so that later node invocations in the user's context, including the discovery script
    # run via bash -l, can resolve packages installed with `pnpm add -g`).
    sudo -u openclaw bash -c '
      mkdir -p ~/.openclaw/bin
      for f in ~/.bashrc ~/.profile; do
        if [ -f "$f" ] || [ ! -e "$f" ]; then
          grep -q "export PATH=/usr/local/bin:\$PATH" "$f" 2>/dev/null || echo "export PATH=/usr/local/bin:\$PATH" >> "$f"
          grep -q "pnpm/bin" "$f" 2>/dev/null || echo "export PATH=\"\$HOME/.local/share/pnpm/bin:\$PATH\"" >> "$f"
        fi
      done
    ' || true

    # 2. Direct controlled pnpm global install (official simple command).
    # pnpm will place the "openclaw" binary/shim somewhere under the user's home
    # (typically in its global store + bin dir). We then use the robust discovery/find
    # (below) + force links to put a symlink at the exact location the systemd unit
    # hard-codes (/home/openclaw/.openclaw/bin/openclaw) and at /usr/local/bin.
    # This avoids fighting pnpm's global layout and PATH checks.
    echo "Running direct pnpm add -g openclaw ..."
    sudo -u openclaw bash -l -c '
      corepack prepare pnpm@latest --activate || true
      export PATH="$HOME/.local/share/pnpm/bin:$PATH"
      pnpm add -g openclaw
      pnpm rebuild -g openclaw || true
    ' || {
      echo "Primary pnpm add returned non-zero; attempting fallback global install for discovery..."
      sudo -u openclaw bash -l -c '
        export PATH="$HOME/.local/share/pnpm/bin:$PATH"
        pnpm add -g openclaw
        pnpm rebuild -g openclaw || true
      ' 2>&1 | tail -10 || true
    }

    # 3. Unconditional robust discovery + force symlinks to the two canonical locations.
    # The sudo -u portion ensures the user's private copy under ~/.openclaw/bin is present
    # (the user must own their own files). The /usr/local/bin link must be done as root
    # (a sudo -u openclaw ln into /usr/local/bin will always get "Permission denied").
    echo "Running discovery and force-linking..."
    # Write a small script that creates a stable wrapper at the canonical location.
    # The wrapper ensures the pnpm global bin dir is in PATH (so the pnpm-installed
    # openclaw shim can run and resolve its internal modules from the store), then
    # execs the real pnpm shim at its standard location (~/.local/share/pnpm/bin/openclaw).
    # This avoids ever directly symlinking or executing the pnpm .bin shim from our
    # canonical or /usr/local/bin locations (the shim's store-link requires break
    # when the shim is invoked through extra symlinks or from the service context).
    cat > /tmp/openclaw-link.sh << 'LINKSCRIPT'
    set -e
    mkdir -p /home/openclaw/.openclaw/bin
    CANDIDATE="/home/openclaw/.openclaw/bin/openclaw"
    # Create the stable wrapper. The real pnpm shim is at the standard global bin
    # location after our `pnpm add -g` (we exported the PATH during that step so pnpm
    # used ~/.local/share/pnpm/bin).
    cat > "$CANDIDATE" << 'WRAPPER' | sed 's/^    //'
    #!/usr/bin/env sh
    export PATH="$HOME/.local/share/pnpm/bin:$PATH"
    exec "$HOME/.local/share/pnpm/bin/openclaw" "$@"
    WRAPPER
    chmod +x "$CANDIDATE"
    chown openclaw:openclaw "$CANDIDATE"
    echo "  created stable wrapper at $CANDIDATE"
    LINKSCRIPT
    chmod +x /tmp/openclaw-link.sh
    chown openclaw:openclaw /tmp/openclaw-link.sh || true
    # Run as the user with login shell (so .profile with pnpm bin is sourced if needed).
    # The wrapper itself also sets the PATH explicitly for robustness when exec'ed
    # by the service or via the /usr/local/bin symlink.
    sudo -u openclaw bash -l /tmp/openclaw-link.sh || echo "User-home linking script exited non-zero (non-fatal)"

    # Ensure a stable wrapper is at the canonical location (belt-and-suspenders in case the /tmp script took fallback or resolution failed).
    # The wrapper sets the pnpm bin in PATH and execs the real pnpm shim.
    CANDIDATE="/home/openclaw/.openclaw/bin/openclaw"
    cat > "$CANDIDATE" << 'WRAPPER' | sed 's/^    //'
    #!/usr/bin/env sh
    export PATH="$HOME/.local/share/pnpm/bin:$PATH"
    exec "$HOME/.local/share/pnpm/bin/openclaw" "$@"
    WRAPPER
    chmod +x "$CANDIDATE"
    chown openclaw:openclaw "$CANDIDATE" || true
    echo "  ensured stable wrapper at $CANDIDATE"

    # Root-level link for /usr/local/bin (bare "openclaw" under sudo -u openclaw relies on this
    # being in secure_path). We link the stable wrapper we created above (a small sh script
    # that sets the pnpm bin in PATH and execs the real pnpm-installed openclaw shim).
    # This ensures the shim runs with the environment it expects.
    ln -sf /home/openclaw/.openclaw/bin/openclaw /usr/local/bin/openclaw 2>/dev/null || true
    chmod +x /usr/local/bin/openclaw 2>/dev/null || true
    ls -l /usr/local/bin/openclaw 2>/dev/null || true
    echo "Root /usr/local/bin link step complete"

    # 4. Final verification. These lines are the ones you can grep for in cloud-init-output.log
    #    even when the rest of the log is full of apt "Get:" / "node-..." and tailscale output.
    echo "=== VERIFICATION ==="
    if [ -x /home/openclaw/.openclaw/bin/openclaw ]; then
      echo "VERIFIED: /home/openclaw/.openclaw/bin/openclaw is executable"
      /home/openclaw/.openclaw/bin/openclaw --version 2>/dev/null || echo "(version probe non-zero is acceptable pre-onboard)"
    else
      echo "VERIFICATION FAILED: /home/openclaw/.openclaw/bin/openclaw missing or not executable"
    fi
    if [ -x /usr/local/bin/openclaw ]; then
      echo "VERIFIED: /usr/local/bin/openclaw is executable (bare name will work under sudo -u openclaw)"
    else
      echo "VERIFICATION FAILED: /usr/local/bin/openclaw missing or not executable"
    fi
    echo "=== OPENCLAW INSTALL END $(date -u) ==="

  # Surface the just-captured install log in the main cloud-init log (so a simple
  # `sudo cat /var/log/cloud-init-output.log | grep -E '(VERIFIED|SUCCESS|OPENCLAW INSTALL)'`
  # is usually sufficient to see what happened, even on a successful boot).
  - cat /tmp/openclaw-install.log | tail -25 || true

  # Pre-build sandbox images (critical for browser tools)
  - |
    sudo -u openclaw bash -c 'docker build -t openclaw-sandbox:bookworm-slim - << "DOCKERFILE"
    FROM debian:bookworm-slim
    ENV DEBIAN_FRONTEND=noninteractive
    RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git jq python3 ripgrep && rm -rf /var/lib/apt/lists/*
    RUN useradd --create-home --shell /bin/bash sandbox
    USER sandbox
    WORKDIR /home/sandbox
    CMD ["sleep", "infinity"]
    DOCKERFILE'

  - |
    sudo -u openclaw bash -c 'docker build -t openclaw-sandbox-browser:bookworm-slim - << "DOCKERFILE"
    FROM mcr.microsoft.com/playwright:v1.44.0-jammy
    RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*
    ENTRYPOINT ["/usr/bin/tini", "--"]
    CMD ["sleep", "infinity"]
    DOCKERFILE'

  - chown -R openclaw:openclaw /home/openclaw || true

  - systemctl daemon-reload
  - systemctl enable --now openclaw-gateway.service

  # Clean up any user-level services the openclaw CLI may have installed (it sometimes
  # does "onboard" style user daemon setup on first run). Our design uses a system
  # service for the dedicated user; disable the user ones so status and management
  # are consistent with the system unit we wrote.
  - sudo -u openclaw systemctl --user disable --now openclaw-gateway.service openclaw.service 2>/dev/null || true
  - systemctl daemon-reload

  # Adopt the pre-written declarative config using the binary itself.
  # This makes `sudo -u openclaw openclaw status --all` and `gateway status` report
  # "Config (cli)" / "Config (service)" as present (instead of "(missing)") and
  # improves the local connectivity probe. We also export the gateway token into
  # the openclaw user's shell rc files so interactive CLI use can authenticate
  # locally without extra flags.
  # We also defensively re-write the config file from the authoritative declarative
  # content (in case write_files timing/ownership for the system user left it
  # missing or clobbered during the long pnpm + docker steps).
  - |
    sudo -u openclaw bash -l -c '
      set -x
      export PATH="$HOME/.local/share/pnpm/bin:$PATH"
      mkdir -p ~/.openclaw
      # The JSON should have been written by cloud-init write_files.
      # We defensively ensure ownership/perms (early chowns may race with write_files).
      # Then let the binary's doctor adopt/fix the config for CLI view, create needed
      # dirs (state, sessions, etc.), and we restart the system service afterwards.
      if [ -f ~/.openclaw/openclaw.json ]; then
        chmod 600 ~/.openclaw/openclaw.json || true
        chown openclaw:openclaw ~/.openclaw/openclaw.json || true
        echo "=== declarative config file (sanitized) ==="
        jq "if .gateway and .gateway.auth then .gateway.auth.token = \"REDACTED\" else . end" ~/.openclaw/openclaw.json 2>/dev/null || cat ~/.openclaw/openclaw.json
        echo "size: $(wc -c < ~/.openclaw/openclaw.json) bytes"
      else
        echo "WARNING: ~/.openclaw/openclaw.json not present after write_files + early chowns"
      fi
      echo "=== openclaw config validate ==="
      openclaw config validate 2>&1 || true
      echo "=== openclaw doctor --fix (adopt the declarative config for CLI view) ==="
      openclaw doctor --fix 2>&1 | tail -15 || true
      # Idempotent sets for the fields the binary cares about for local gateway
      openclaw config set gateway.mode local 2>&1 || true
      openclaw config set gateway.bind loopback 2>&1 || true
      # Export token for the user'\''s interactive shells (CLI probes can use it)
      TOKEN=$(jq -r ".gateway.auth.token // empty" ~/.openclaw/openclaw.json 2>/dev/null)
      if [ -n "$TOKEN" ]; then
        for rc in ~/.profile ~/.bashrc; do
          if [ -f "$rc" ] || [ ! -e "$rc" ]; then
            grep -q "OPENCLAW_GATEWAY_TOKEN" "$rc" 2>/dev/null || echo "export OPENCLAW_GATEWAY_TOKEN=\"$TOKEN\"" >> "$rc"
          fi
        done
        echo "exported OPENCLAW_GATEWAY_TOKEN to user rc files"
      fi
      # Restart the system service so it picks up the final (adopted) config.
      # This ensures the gateway process is running under our hardened unit
      # with a schema-valid config for this pnpm-installed version.
      systemctl restart openclaw-gateway.service || true
      echo "Restarted system openclaw-gateway.service after config adoption"
    ' || true
  - systemctl daemon-reload

__TAILSCALE_BLOCK__

  # Best-effort health check (exercises the /usr/local/bin symlink + the PATH we set up).
  # On any failure, dump the install log so the full transcript is in cloud-init-output.log.
  - sleep 8
  - sudo -u openclaw /usr/local/bin/openclaw gateway status || (echo "Gateway status probe failed or still starting"; cat /tmp/openclaw-install.log | tail -40 || true)
  # Also show the system unit status (the real one we manage) so the cloud-init log
  # and final_message have clear evidence the hardened system service is up.
  - sudo systemctl status openclaw-gateway.service --no-pager -l | tail -15 || true
  - ss -tlnp | grep 18789 || echo "Port 18789 not yet listening (may still be starting)" || true

final_message: |
  🦞 OpenClaw VM is ready (or starting).

  Shell in:
    multipass shell __VM_NAME__

  As the dedicated user:
    sudo -u openclaw /usr/local/bin/openclaw gateway status
    sudo -u openclaw /usr/local/bin/openclaw doctor
    sudo -u openclaw /usr/local/bin/openclaw security audit

  (The bare 'openclaw' name also works under sudo -u once /usr/local/bin is linked during provisioning.)

  Browser tools are pre-provisioned via the Docker sandbox backend.

  Next (channels & final config):
    sudo -u openclaw openclaw channels add ...

  Re-provision or destroy:
    multipass delete --purge __VM_NAME__
'@

# Perform safe replacements
$cloudInit = $cloudInitTemplate `
    -replace '__GATEWAY_TOKEN__', $gatewayToken `
    -replace '__SECRET_ENV_LINES__', $secretEnvLines `
    -replace '__OPENCLAW_CONFIG_JSON__', $indentedOpenClawJson `
    -replace '__RAW_OPENCLAW_CONFIG_JSON__', $indentedRawOpenClawJson `
    -replace '__TAILSCALE_BLOCK__', $tailscaleBlock `
    -replace '__VM_NAME__', $specData['vm_name']

# Write for inspection / re-use (deduped)
$ciPath = Join-Path $env:TEMP "openclaw-cloud-init-$($specData['vm_name']).yaml"
$cloudInit | Out-File -FilePath $ciPath -Encoding utf8
Write-Info "Cloud-init written to $ciPath (inspect or reuse if needed)"

# --- Check Multipass --------------------------------------------------------------
if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
    Write-Err "multipass not found in PATH. Install it first (winget install Canonical.Multipass)."
    exit 1
}

# On a brand new Multipass install the image catalog / "ubuntu" remote may not be populated yet.
# We run `multipass find` (quietly) automatically — it is the documented one-time step
# that downloads the catalog and registers the official remotes. This keeps things
# as close to zero-touch as possible.
Write-Info "Ensuring Multipass image catalog is populated (one-time on fresh installs)..."
& multipass find >$null 2>&1

# --- Launch -----------------------------------------------------------------------
Write-Info "Launching Multipass VM (this can take a couple of minutes)..."

$launchArgs = @(
    "launch",
    "--name", $specData['vm_name'],
    "--memory", $specData['memory'],
    "--cpus", $specData['cpus'],
    "--disk", $specData['disk'],
    "--cloud-init", $ciPath,
    $specData['ubuntu']
)

& multipass $launchArgs

if ($LASTEXITCODE -ne 0) {
    Write-Err "Multipass launch failed. Check the output above and the cloud-init at $ciPath."
    exit $LASTEXITCODE
}

Write-Info "VM launched successfully."
Write-Host ""
Write-Host "Next commands:" -ForegroundColor Green
Write-Host "  multipass shell $($specData['vm_name'])"
Write-Host "  multipass info $($specData['vm_name'])"
Write-Host ""
Write-Host "Inside the VM (as dedicated user):" -ForegroundColor Green
Write-Host "  sudo -u openclaw /usr/local/bin/openclaw gateway status"
Write-Host "  sudo -u openclaw /usr/local/bin/openclaw channels login   # for WhatsApp etc."
Write-Host ""
Write-Host "Happy (isolated) clawing. 🦞" -ForegroundColor Green
