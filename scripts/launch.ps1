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
Write-Info "VM: $($specData['vm_name']) | Memory: $($specData['memory']) | CPUs: $($specData['cpus']) | Disk: $($specData['disk'])"

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
$baseConfig = @{
    gateway = @{
        mode = "local"
        bind = "loopback"
        auth = @{
            mode = "token"
            token = $gatewayToken
        }
    }
    session = @{
        dmScope = "per-channel-peer"
    }
    agents = @{
        defaults = @{
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
    # User can override/extend in their openclaw.config block (future merge improvement)
    # or after launch. xAI is expected to be added via native OAuth post-boot.
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
    agent = @{
        model = "google/gemini-2.0-flash"
    }
}

# User openclaw.config block (from the spec) is captured for future richer merging.
# Today the launcher guarantees the critical security defaults + gateway token + a
# working google provider (for your free-tier GOOGLE_API_KEY from secrets).
# xAI is added via the post-launch `openclaw models auth login --provider xai --method oauth`.
# You can always edit /home/openclaw/.openclaw/openclaw.json as the openclaw user after boot.
if ($specData['openclaw_config_raw']) {
    Write-Info "User openclaw.config block detected in spec (will be available for manual review/merge inside the VM)."
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

  # Native install as the dedicated user (best practice)
  - sudo -u openclaw bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --install-method npm'

  - ln -sf /home/openclaw/.openclaw/bin/openclaw /usr/local/bin/openclaw || true

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

__TAILSCALE_BLOCK__

  # Best-effort health
  - sleep 8
  - sudo -u openclaw openclaw gateway status || echo "Gateway may still be starting — check with 'sudo -u openclaw openclaw gateway status'"

final_message: |
  🦞 OpenClaw VM is ready (or starting).

  Shell in:
    multipass shell __VM_NAME__

  As the dedicated user:
    sudo -u openclaw openclaw gateway status
    sudo -u openclaw openclaw doctor
    sudo -u openclaw openclaw security audit

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

# --- Launch -----------------------------------------------------------------------
Write-Info "Launching Multipass VM (this can take a couple of minutes)..."

$launchArgs = @(
    "launch",
    "--name", $specData['vm_name'],
    "--memory", $specData['memory'],
    "--cpus", $specData['cpus'],
    "--disk", $specData['disk'],
    "--cloud-init", $ciPath,
    "ubuntu"
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
Write-Host "  sudo -u openclaw openclaw gateway status"
Write-Host "  sudo -u openclaw openclaw channels login   # for WhatsApp etc."
Write-Host ""
Write-Host "Happy (isolated) clawing. 🦞" -ForegroundColor Green
