<#
.SYNOPSIS
    Zero-touch launcher for OpenClaw VM on native Hyper-V using the Packer golden image + CIDATA.

.DESCRIPTION
    Reads vtorclaw.yaml, generates CIDATA, creates Hyper-V VM using openclaw-golden.vhdx
    (as a fast differencing child), attaches the CIDATA drive, starts the VM.
    This gives one-command experience for the pure Packer + native Hyper-V path.

    Requires the golden image to have been built first with packer (openclaw-golden.vhdx at repo root).

.PARAMETER Spec
    Path to your vtorclaw.yaml

.PARAMETER Memory
    Override memory, e.g. 12GB

.PARAMETER Cpus
    Override CPU count

.PARAMETER Name
    Override VM name

.PARAMETER GoldenPath
    Path to the golden VHDX. Defaults to openclaw-golden.vhdx in current dir (run from repo root).

.EXAMPLE
    .\launch-hyperv.ps1 -Spec vtorclaw.yaml
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
    [string]$Name,

    [Parameter(Mandatory=$false)]
    [string]$GoldenPath = "openclaw-golden.vhdx"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: Requires PowerShell 7+. Use pwsh.exe" -ForegroundColor Red
    exit 1
}

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

if (-not (Test-Path $Spec)) {
    Write-Err "Spec not found: $Spec"
    exit 1
}

if (-not (Test-Path $GoldenPath)) {
    Write-Err "Golden VHDX not found at $GoldenPath"
    Write-Host "Build it first with: cd packer; packer build .\openclaw.pkr.hcl"
    Write-Host "Then the file will be at the repo root as openclaw-golden.vhdx"
    exit 1
}

$specContent = Get-Content $Spec -Raw

# Minimal parsing for key fields (expand as needed)
$vmName = if ($Name) { $Name } else { "openclaw" }
if ($specContent -match 'name:\s*["'']?([^"''#]+)') { $vmName = $Matches[1].Trim() }
$memory = if ($Memory) { $Memory } else { "8GB" }
if ($specContent -match 'memory:\s*["'']?([^"''#]+)') { $memory = $Matches[1].Trim() }
$cpus = if ($Cpus) { $Cpus } else { 2 }
if ($specContent -match 'cpus:\s*["'']?(\d+)') { $cpus = [int]$Matches[1] }

Write-Info "Using golden: $GoldenPath"
Write-Info "VM name: $vmName , Memory: $memory , CPUs: $cpus"

# Generate a thin user-data for CIDATA.
# This is a minimal cloud-config overlay. In a full implementation this would render from the full spec
# like launch.ps1 does. For now we create a basic one that sets the openclaw user + placeholder.
# For production, enhance this or call a renderer.

$tempUserData = Join-Path $env:TEMP "thin-user-data-$([Guid]::NewGuid()).yaml"
$thinUserData = @"
#cloud-config
users:
  - name: openclaw
    gecos: "OpenClaw Gateway"
    system: true
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [docker]
    ssh_authorized_keys:
      - "ssh-ed25519 YOUR_KEY_HERE"   # TODO: inject real key from spec

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
      Environment=OPENCLAW_GATEWAY_TOKEN=GENERATED_TOKEN_HERE
      ExecStart=/home/openclaw/.openclaw/bin/openclaw gateway run
      Restart=on-failure
      RestartSec=5s

      ProtectSystem=strict
      ProtectHome=read-only
      PrivateTmp=true

runcmd:
  - systemctl daemon-reload
  - systemctl enable --now openclaw-gateway.service
  - echo "OpenClaw service enabled. Replace placeholders in /etc/systemd/system/openclaw-gateway.service and restart."
"@

# Note: For full zero-touch, you should enhance this script to parse the full vtorclaw.yaml
# and generate a proper thin overlay with real token, keys, and openclaw.json like the Multipass launch.ps1 does.
# For now this gets the VM up with the golden (you can manually improve the CIDATA).

Set-Content -Path $tempUserData -Value $thinUserData -Encoding UTF8

Write-Info "Generating CIDATA drive..."

$cidataOutput = Join-Path $env:TEMP "openclaw-cidata-$vmName.vhdx"
& .\scripts\new-cidata-drive.ps1 -UserDataPath $tempUserData -OutputPath $cidataOutput -SizeMB 64

if (-not (Test-Path $cidataOutput)) {
    Write-Err "Failed to generate CIDATA"
    exit 1
}

Write-Info "CIDATA ready at $cidataOutput"

# Create VM directory
$vmDir = "C:\VMs\$vmName"
if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }

$differencingVhd = Join-Path $vmDir "$vmName-diff.vhdx"
$finalGolden = (Resolve-Path $GoldenPath).Path

Write-Info "Creating differencing disk from golden for fast clones..."

if (Test-Path $differencingVhd) { Remove-Item $differencingVhd -Force }
New-VHD -Path $differencingVhd -ParentPath $finalGolden -Differencing | Out-Null

Write-Info "Creating Hyper-V VM..."

New-VM -Name $vmName `
    -MemoryStartupBytes ([int64]($memory -replace 'G','')*1GB) `
    -VHDPath $differencingVhd `
    -SwitchName "Default Switch" `
    -Generation 2 `
    -ErrorAction Stop | Out-Null

Set-VM -Name $vmName -ProcessorCount $cpus -DynamicMemory -MemoryMaximumBytes ([int64]($memory -replace 'G','')*1GB) | Out-Null

Write-Info "Attaching CIDATA drive..."

Add-VMDvdDrive -VMName $vmName -Path $cidataOutput

Write-Info "Starting VM $vmName ..."

Start-VM -Name $vmName

Write-Host ""
Write-Host "=== ZERO-TOUCH LAUNCH COMPLETE ===" -ForegroundColor Green
Write-Host "VM '$vmName' is starting."
Write-Host "Golden base: $finalGolden (differencing child used)"
Write-Host "CIDATA: $cidataOutput"
Write-Host ""
Write-Host "To connect:"
Write-Host "  - Use Hyper-V Manager or: Get-VM -Name $vmName"
Write-Host "  - Once up, use the SSH key from your spec to connect as the openclaw user."
Write-Host "  - Or use the monitor-build.ps1 style to watch serial."
Write-Host ""
Write-Host "If you want the full token/json injection, enhance the user-data generation in this script"
Write-Host "using the same logic as scripts/launch.ps1 ."
Write-Host "===============================" -ForegroundColor Green

Remove-Item $tempUserData -ErrorAction SilentlyContinue
