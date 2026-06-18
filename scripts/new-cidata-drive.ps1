<#
.SYNOPSIS
    Create a small "CIDATA" VHDX seed disk for NoCloud cloud-init on Hyper-V.

.DESCRIPTION
    This produces a tiny dynamic VHDX (default 64 MB) that is formatted FAT32,
    labeled CIDATA, and contains user-data + meta-data at the root.

    When you attach this VHDX as an additional disk to a VM booted from a
    cloud-style Ubuntu image (or our Packer golden), cloud-init will find the
    NoCloud datasource and apply the config on first boot (and to a lesser
    degree on subsequent boots).

    Use this for the pure "Packer + native Hyper-V, no Multipass" workflow:
      - Build once with packer/openclaw.pkr.hcl (produces a golden .vhdx with
        Node, pnpm, openclaw, sandboxes, service, etc. already baked).
      - For each new instance, generate a fresh CIDATA VHDX from your
        vtorclaw.yaml (token, ssh public key, openclaw.json, etc.).
      - New-VM using the golden (or a fast differencing child of it).
      - Attach the CIDATA VHDX.
      - Start-VM. The heavy work is already done; only the tiny overlay runs.

    The CIDATA disk is cheap to create and can be unique per VM (different
    tokens, different ssh public keys for the openclaw user, different
    tailscale keys, etc.).

.PARAMETER UserDataPath
    Path to a cloud-config YAML file (the "user-data" content). This is the
    thin overlay: users + system_info.default_user + ssh_authorized_keys +
    write_files (openclaw.json + service unit overrides) + a couple of
    runcmd lines for adopt/enable. Keep it small — the golden image already
    did the real work.

.PARAMETER OutputPath
    Where to write the .vhdx. Defaults to a timestamped file next to the
    script or in $env:TEMP.

.PARAMETER SizeMB
    Size of the seed disk (small is fine; 64 MB is plenty).

.PARAMETER Label
    Volume label. Must be CIDATA (or cidata) for classic NoCloud detection
    on many images. You can also rely on the presence of the user-data file.

.EXAMPLE
    # Minimal manual example: you hand-wrote a tiny user-data for your key + json
    .\scripts\new-cidata-drive.ps1 -UserDataPath .\my-thin-user-data.yaml -OutputPath C:\VMs\openclaw-seed.vhdx

.EXAMPLE
    # In a real flow you would generate the thin user-data from the same
    # vtorclaw.yaml + secrets that the multipass launcher uses, but only the
    # users/ssh/write_files/light-runcmd parts (no Node install, no full pnpm,
    # no docker build — those are in the golden).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$UserDataPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath,

    [Parameter(Mandatory=$false)]
    [int]$SizeMB = 64,

    [Parameter(Mandatory=$false)]
    [string]$Label = "CIDATA",

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $UserDataPath)) {
    throw "UserDataPath not found: $UserDataPath"
}

if (-not $OutputPath) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputPath = Join-Path $env:TEMP "openclaw-cidata-$ts.vhdx"
}

if (-not $Quiet) {
    Write-Host "[INFO] Creating CIDATA seed VHDX at $OutputPath (label=$Label)" -ForegroundColor Cyan
}

# Create a small dynamic VHDX.
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
$Vhd = New-VHD -Path $OutputPath -SizeBytes ($SizeMB * 1MB) -Dynamic -ErrorAction Stop

# Mount it so we can format and lay out files.
$mount = Mount-VHD -Path $OutputPath -Passthru
try {
    $disk = Get-Disk -Number $mount.DiskNumber
    # Initialize as GPT (modern) or MBR; FAT32 works either way for cloud-init.
    Initialize-Disk -InputObject $disk -PartitionStyle GPT -ErrorAction SilentlyContinue | Out-Null

    # Create a small primary partition using the whole disk.
    $part = New-Partition -InputObject $disk -UseMaximumSize -AssignDriveLetter
    $driveLetter = $part.DriveLetter

    # Format FAT32 (cloud-init NoCloud is happy with vfat).
    Format-Volume -DriveLetter $driveLetter -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop | Out-Null

    $root = "$($driveLetter):\"

    # Write the two classic NoCloud files at the root (case sensitive on some FS but FAT32 here is fine).
    Copy-Item -Path $UserDataPath -Destination (Join-Path $root "user-data") -Force
    # Minimal meta-data is usually sufficient.
    $meta = @"
instance-id: openclaw-$(Get-Random -Minimum 100000 -Maximum 999999)
local-hostname: openclaw
"@
    $meta | Out-File -FilePath (Join-Path $root "meta-data") -Encoding ascii -Force

    # Optional: a network-config stub (cloud-init will use DHCP if absent).
    # You can extend this helper later if you want static IPs etc.

    if (-not $Quiet) {
        Write-Host "[INFO] CIDATA layout:" -ForegroundColor Green
        Get-ChildItem $root | Format-Table Name, Length -AutoSize | Out-String | Write-Host

        Write-Host "[INFO] Seed disk ready: $OutputPath" -ForegroundColor Green
    }
} finally {
    Dismount-VHD -Path $OutputPath -ErrorAction SilentlyContinue
}

# Return the path for scripting.
return $OutputPath
