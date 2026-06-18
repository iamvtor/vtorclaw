# monitor-build.ps1
# Run this in a *separate* PowerShell window BEFORE or alongside your packer build.
# It captures everything from the host side:
#   - Serial console (ttyS0) output -> packer-serial.log (and prints here)
#   - Periodic guest diagnostics via SSH -> packer-guest-diag.log (and prints here)
#
# No need to watch or copy from the Hyper-V GUI window.
#
# Prerequisites:
# - Your SSH private key loaded in the agent (ssh-add) or adjust the ssh command below.
# - The build VM name matches (default "openclaw-packer-build"; pass -VMName or use same -var for packer).
# - Run as admin if needed for the pipe.
#
# Usage:
#   1. Open a new PowerShell window
#   2. cd to the packer dir
#   3. .\monitor-build.ps1                 # or .\monitor-build.ps1 -VMName myvm -SerialPipe '\\.\pipe\foo'
#   4. In your main window: packer build .\openclaw.pkr.hcl   # optionally -var 'build_vm_name=xxx'
#   5. Watch this window for live logs. When done, Ctrl-C here.
#
# Logs will be in the current directory.

param(
    [string]$VMName = "openclaw-packer-build",
    [string]$SerialPipe = "\\.\pipe\openclaw-serial"
)

$vmName = $VMName
$serialPipe = $SerialPipe
$serialLog = "packer-serial.log"
$diagLog = "packer-guest-diag.log"
$sshUser = "ubuntu"
# If not using agent, uncomment and set:
# $sshKey = "$env:USERPROFILE\.ssh\packer_build_key"
# $sshOpts = "-i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

Write-Host "=== Packer Build Monitor ===" -ForegroundColor Green
Write-Host "VM: $vmName"
Write-Host "Serial pipe: $serialPipe -> $serialLog"
Write-Host "SSH diags -> $diagLog"
Write-Host "Waiting for VM to appear..."

# Wait for VM
while (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 2
}
Write-Host "VM found. Setting up serial pipe (if not already)..."

# Ensure COM1 points to our pipe (harmless if already set)
try {
    Set-VMComPort -VMName $vmName -Number 1 -Path $serialPipe -ErrorAction SilentlyContinue
} catch {}

Write-Host "Starting serial logger (background job)..."

$serialJob = Start-Job -Name "serial-log" -ScriptBlock {
    param($pipe, $log)
    while ($true) {
        try {
            if (Test-Path $pipe) {
                Get-Content -Path $pipe -Wait -Encoding UTF8 | ForEach-Object {
                    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    "$ts $_" | Out-File -Append -FilePath $log -Encoding UTF8
                    Write-Output $_
                }
            }
        } catch {
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 100
    }
} -ArgumentList $serialPipe, (Join-Path $PWD $serialLog)

Write-Host "Serial logging to $serialLog (and this console)."

# Main monitoring loop
$lastIp = ""
while ($true) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') {
        Write-Host "VM not running, waiting..."
        Start-Sleep -Seconds 5
        continue
    }

    # Get guest IP(s) via Hyper-V integration (requires the guest packages we install)
    $ips = @()
    try {
        $adapters = Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop
        foreach ($a in $adapters) {
            $ips += $a.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+' }
        }
        $ips = $ips | Select-Object -Unique
    } catch {
        $ips = @()
    }

    $currentIp = $ips | Select-Object -First 1
    if ($currentIp -and $currentIp -ne $lastIp) {
        Write-Host "Guest IP(s) detected: $($ips -join ', ')" -ForegroundColor Cyan
        $lastIp = $currentIp
    }

    if ($currentIp) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $diag = @"
[$ts] === GUEST DIAGNOSTICS ===
IP: $currentIp
---
$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $sshUser@$currentIp "
  echo 'Guest IP:'; ip -4 addr show | grep -E 'inet '
  echo '---'
  echo 'ls -ld /tmp /home/ubuntu:'
  ls -ld /tmp /home/ubuntu 2>&1
  echo '---'
  echo 'scp location:'
  ls -l /usr/bin/scp 2>/dev/null || ls -l /usr/bin/scp 2>&1 || echo 'no scp'
  echo '---'
  echo 'PATH:'
  echo \$PATH
  echo '---'
  echo 'authorized_keys (last 80 chars):'
  tail -c 80 /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo 'no key file'
  echo '---'
  echo 'Recent dmesg / journal:'
  dmesg | tail -5 2>/dev/null || true
  journalctl --no-pager -n 10 2>/dev/null || true
  echo '---'
  echo 'Packer test files in /tmp or /home/ubuntu:'
  ls -l /tmp/packer* /home/ubuntu/packer* 2>/dev/null || echo 'none yet'
" 2>&1)
"@

        $diag | Out-File -Append -FilePath $diagLog -Encoding UTF8
        Write-Host $diag -ForegroundColor Yellow
    }

    # Also try to see if the VM is still in "waiting for SSH" state from packer perspective,
    # but we can't easily; just keep logging while VM runs.
    Start-Sleep -Seconds 15
}

# Cleanup on Ctrl-C
try { Stop-Job $serialJob -ErrorAction SilentlyContinue; Remove-Job $serialJob -ErrorAction SilentlyContinue } catch {}
Write-Host "Monitor stopped. Logs: $serialLog and $diagLog"
