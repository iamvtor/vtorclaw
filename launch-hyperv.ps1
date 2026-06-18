<#
.SYNOPSIS
    One-command zero-touch for OpenClaw on native Hyper-V using the Packer golden + CIDATA.

.DESCRIPTION
    Single script at root.
    - Ensures openclaw-golden.vhdx exists (builds with packer if missing).
    - Generates CIDATA from your vtorclaw.yaml.
    - Creates (or cleans) Hyper-V VM with differencing disk off the golden.
    - Attaches CIDATA as second hard disk.
    - Starts the VM.

    Run as Administrator. PowerShell 7+ required.

.PARAMETER Spec
    Path to vtorclaw.yaml

.EXAMPLE
    pwsh -File .\launch-hyperv.ps1 -Spec vtorclaw.yaml
#>
param(
    [string]$Spec = "vtorclaw.yaml",
    [string]$Memory,
    [int]$Cpus,
    [string]$Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: Requires PowerShell 7+ (pwsh.exe)" -ForegroundColor Red
    exit 1
}

# Require admin for Hyper-V disk/VM operations
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Must run as Administrator (right-click pwsh -> Run as Administrator)" -ForegroundColor Red
    exit 1
}

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err($m) { Write-Host "[ERROR] $m" -ForegroundColor Red }

if (-not (Test-Path $Spec)) {
    Err "Spec not found: $Spec"
    exit 1
}

$spec = Get-Content $Spec -Raw

$vmName = if ($Name) { $Name } elseif ($spec -match 'name:\s*["'']?([^"''\s#]+)') { $Matches[1] } else { "openclaw" }
$memStr = if ($Memory) { $Memory } elseif ($spec -match 'memory:\s*["'']?([^"''\s#]+)') { $Matches[1] } else { "8GB" }
$cpu = if ($Cpus) { $Cpus } elseif ($spec -match 'cpus:\s*["'']?(\d+)') { [int]$Matches[1] } else { 2 }

$golden = "openclaw-golden.vhdx"
if (-not (Test-Path $golden)) {
    Info "Golden VHDX not found. Building it (one-time)..."
    Push-Location packer
    & packer build -var "cpus=$cpu" -var "memory=8192" .\openclaw.pkr.hcl
    Pop-Location
    if (-not (Test-Path $golden)) {
        Err "Packer failed to produce $golden"
        exit 1
    }
    Info "Golden built."
}

Info "Preparing VM '$vmName'"

# Generate token (simple)
$token = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_})

# Extract ssh key from spec if present
$sshKey = ""
if ($spec -match 'ssh_public_key:\s*["'']?(.+?)["'']?\s*(#|$)') { $sshKey = $Matches[1].Trim() }

# Create temp thin user-data for CIDATA (overlay on golden)
$tmpUserData = Join-Path $env:TEMP "thin-userdata-$vmName-$(Get-Date -Format 'yyyyMMddHHmmss').yaml"

# Use a unique CIDATA path each run to avoid "file in use" from previous attempts
$cidata = Join-Path $env:TEMP "cidata-$vmName-$(Get-Date -Format 'yyyyMMddHHmmss').vhdx"

# Pre-clean any stale CIDATA file (common cause of "file in use")
try { Dismount-VHD -Path $cidata -ErrorAction SilentlyContinue } catch {}
if (Test-Path $cidata) {
    Remove-Item $cidata -Force -ErrorAction SilentlyContinue
}
@"
#cloud-config
users:
  - name: openclaw
    gecos: OpenClaw Gateway
    system: true
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: [docker]
    ssh_authorized_keys:
      - "$sshKey"

write_files:
  - path: /home/openclaw/.openclaw/openclaw.json
    owner: openclaw:openclaw
    permissions: "0600"
    content: |
      {
        "gateway": {
          "mode": "local",
          "port": 18789,
          "auth": { "mode": "token", "token": "$token" }
        },
        "agents": {
          "defaults": {
            "sandbox": {
              "mode": "non-main",
              "backend": "docker",
              "browser": { "autoStart": true }
            }
          }
        }
      }

runcmd:
  - chown -R openclaw:openclaw /home/openclaw/.openclaw || true
  - systemctl daemon-reload || true
  - systemctl enable --now openclaw-gateway.service || true
  - echo "OpenClaw ready (token and config injected via CIDATA)."
"@ | Set-Content -Path $tmpUserData -Encoding UTF8

# Generate CIDATA (suppress helper's chatty instructions)
& .\scripts\new-cidata-drive.ps1 -UserDataPath $tmpUserData -OutputPath $cidata -SizeMB 64 | Out-Null
if (-not (Test-Path $cidata)) {
    Err "CIDATA generation failed"
    exit 1
}
Info "CIDATA ready at $cidata"

# Cleanup any existing VM/disk with same name (to avoid "file in use")
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    Warn "Existing VM '$vmName' found - stopping and removing for clean run"
    Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
}

$vmDir = "C:\VMs\$vmName"
if (Test-Path $vmDir) {
    Remove-Item "$vmDir\*" -Force -Recurse -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
}

$disk = Join-Path $vmDir "$vmName.vhdx"
if (Test-Path $disk) { Remove-Item $disk -Force }

Info "Creating differencing disk from golden..."
New-VHD -Path $disk -ParentPath (Resolve-Path $golden).Path -Differencing | Out-Null

Info "Creating Hyper-V VM..."
New-VM -Name $vmName `
    -MemoryStartupBytes ([int64]($memStr -replace '[^0-9]','') * 1GB) `
    -VHDPath $disk `
    -SwitchName "Default Switch" `
    -Generation 2 | Out-Null

Set-VMProcessor -VMName $vmName -Count $cpu

Info "Attaching CIDATA as second hard disk..."
Add-VMHardDiskDrive -VMName $vmName -Path $cidata

Info "Starting VM..."
Start-VM -Name $vmName

Write-Host ""
Write-Host "=== ZERO-TOUCH COMPLETE ===" -ForegroundColor Green
Write-Host "VM: $vmName (using differencing disk off golden)"
Write-Host "Golden: $golden"
Write-Host "CIDATA: $cidata"
Write-Host ""
Write-Host "The VM is starting. Give it 30-90 seconds."
Write-Host "Connect with your SSH key from the spec as the 'openclaw' user."
Write-Host "openclaw service should be up (baked into golden + activated by CIDATA)."
Write-Host "To inspect: Get-VM $vmName"
Write-Host "===========================" -ForegroundColor Green

Remove-Item $tmpUserData -ErrorAction SilentlyContinue
