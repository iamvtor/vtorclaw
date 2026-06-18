<# 
.SYNOPSIS
    One single command for a fully working OpenClaw VM on native Hyper-V (zero touch).

.DESCRIPTION
    Run this from the repo root with your vtorclaw.yaml.
    It will:
    - Build the golden VHDX if it doesn't exist (packer).
    - Generate CIDATA from your spec (token, config, ssh key).
    - Create a Hyper-V VM using a fast differencing disk of the golden.
    - Attach the CIDATA.
    - Start the VM.
    When it finishes, you have a running openclaw instance. No other commands required.

    Requires: PowerShell 7+, Hyper-V enabled, the packer golden build dependencies.

.PARAMETER Spec
    Your vtorclaw.yaml

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
    Write-Host "Use pwsh.exe (PowerShell 7+)" -ForegroundColor Red
    exit 1
}

# Elevation check - required for New-VM, Mount-VHD, etc.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "Right-click the PowerShell window title and choose 'Run as Administrator', then re-run the script." -ForegroundColor Yellow
    Write-Host "Example: pwsh -File .\launch-hyperv.ps1 -Spec vtorclaw.yaml" -ForegroundColor Yellow
    exit 1
}

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }

if (-not (Test-Path $Spec)) { throw "Spec not found: $Spec. Copy the example and edit." }

$spec = Get-Content $Spec -Raw

$vmName = if ($Name) { $Name } elseif ($spec -match 'name:\s*["'']?([^"''\s#]+)') { $Matches[1] } else { "openclaw" }
$memStr = if ($Memory) { $Memory } elseif ($spec -match 'memory:\s*["'']?([^"''\s#]+)') { $Matches[1] } else { "8GB" }
$cpu = if ($Cpus) { $Cpus } elseif ($spec -match 'cpus:\s*["'']?(\d+)') { [int]$Matches[1] } else { 2 }

$golden = "openclaw-golden.vhdx"
if (-not (Test-Path $golden)) {
    Info "Building golden image (one-time cost)..."
    Push-Location packer
    & packer build -var "cpus=$cpu" -var "memory=8192" openclaw.pkr.hcl
    Pop-Location
    if (-not (Test-Path $golden)) { throw "Golden build failed - check packer output" }
    Info "Golden ready."
}

Info "Preparing VM $vmName"

# Generate token
$token = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 32 | ForEach {[char]$_})

# Extract ssh key if present
$sshKey = ""
if ($spec -match 'ssh_public_key:\s*["'']?(.+?)["'']?\s*$') { $sshKey = $Matches[1].Trim() }

$tmpUserData = [System.IO.Path]::GetTempFileName() + ".yaml"
@"
#cloud-config
users:
  - name: openclaw
    gecos: "OpenClaw"
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
  - echo "OpenClaw is ready. Connect as the openclaw user with your SSH key."
"@ | Set-Content -Path $tmpUserData -Encoding UTF8

$cidata = Join-Path $env:TEMP "cidata-$vmName.vhdx"
Info "Generating CIDATA..."
& .\scripts\new-cidata-drive.ps1 -UserDataPath $tmpUserData -OutputPath $cidata -SizeMB 64

$vmDir = "C:\VMs\$vmName"
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

$disk = Join-Path $vmDir "$vmName.vhdx"
if (Test-Path $disk) { Remove-Item $disk -Force }
New-VHD -Path $disk -ParentPath (Resolve-Path $golden).Path -Differencing | Out-Null

Info "Creating and starting Hyper-V VM..."
New-VM -Name $vmName -MemoryStartupBytes ([int64]($memStr -replace '[^0-9]','')*1GB) -VHDPath $disk -SwitchName "Default Switch" -Generation 2 | Out-Null
Set-VMProcessor -VMName $vmName -Count $cpu
Add-VMHardDiskDrive -VMName $vmName -Path $cidata
Start-VM -Name $vmName

Write-Host ""
Write-Host "=== DONE. Your openclaw VM is booting. ===" -ForegroundColor Green
Write-Host "VM Name: $vmName"
Write-Host "Use Hyper-V Manager or: Get-VM $vmName"
Write-Host "Connect as 'openclaw' user with the SSH key from your spec."
Write-Host "The service should start automatically."
Write-Host "Golden used: $golden (differencing disk)"
Write-Host "=========================================" -ForegroundColor Green

Remove-Item $tmpUserData -ErrorAction SilentlyContinue
ENDSCRIPT
Write-Host "Root-level one-command launch-hyperv.ps1 created/updated."