# Packer template for a pre-baked OpenClaw golden image on Hyper-V.
#
# Purpose: Move all the heavy lifting (Node 24 + pnpm + openclaw global install +
# stable wrappers + symlinks + pre-built browser sandboxes + openclaw dedicated
# user skeleton + hardened systemd service) out of first boot and into a
# reproducible golden VHDX.
#
# Result: A standalone .vhdx you can use with plain Hyper-V (New-VM etc.) with
# zero dependency on Multipass. Per-VM declarative config (token, keys, ssh public
# key for openclaw-as-default-user, tailscale, openclaw.json overrides) is
# supplied at "launch" time via a tiny NoCloud config drive (CIDATA VHDX).
#
# Requirements on the Windows build machine:
#   - Packer 1.10+
#   - packer plugins install github.com/hashicorp/hyperv
#   - Hyper-V enabled, "Default Switch" (or your preferred external switch) available
#   - Enough disk to hold the full Ubuntu + Node + Docker images (~15-20 GB free recommended)
#
# Usage (one time, or when you want to update the golden image):
#   cd packer
#   packer init .
#   packer build -var "cpus=4" -var "memory=8192" openclaw.pkr.hcl
#
# After build you will have something like:
#   output-openclaw\Virtual Hard Disks\openclaw.vhdx   (or similar path printed at the end)
#
# Then use that .vhdx (or a differencing child of it) for fast per-instance VMs
# with native Hyper-V PowerShell + a small CIDATA seed disk for your vtorclaw.yaml
# secrets + ssh key + default user bits. See the sibling hyperv launch guidance.
#
# The build uses the official Ubuntu 24.04 live server ISO + autoinstall.
# We serve the autoinstall config (user-data + meta-data) over Packer's built-in
# temporary HTTP server (http_content) instead of a secondary CD/ISO. This removes
# any dependency on external ISO creation tools (oscdimg, xorriso, etc.), which
# makes the template work cleanly on Windows without installing the Windows ADK.
#
# Update the iso_url / iso_checksum when new point releases appear.

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 4096   # MB during build (you can raise for faster builds)
}

variable "disk_size" {
  type    = string
  default = "30720"  # MB
}

variable "switch_name" {
  type    = string
  default = "Default Switch"
}

variable "iso_url" {
  type    = string
  default = "https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  # Get the current one from https://releases.ubuntu.com/noble/SHA256SUMS
  default = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
}

variable "build_vm_name" {
  type    = string
  default = "openclaw-packer-build"
}

locals {
  # A build-only password for the "ubuntu" user created by autoinstall.
  # This VM is ephemeral and thrown away at the end of `packer build`.
  # You can change it; it is only used for the SSH communicator during provisioning.
  build_password = "PackerBuildOnly-ChangeMe-9f3k2"
}

source "hyperv-iso" "openclaw" {
  # --- ISO + autoinstall via Packer's temporary HTTP server (no external tools required) ---
  # This is the portable approach that works on Windows without installing the Windows ADK
  # or any ISO creation tools (oscdimg, xorriso, etc.).
  #
  # Packer will start a short-lived HTTP server during the build and serve the contents
  # of the local ./http/ directory. The boot_command below tells the Ubuntu live installer
  # to fetch the config from that HTTP server using the nocloud datasource
  # (ds=nocloud;s=http://.../ points at user-data + meta-data).
  #
  # We use a small local http/ directory (standard for hyperv-iso + live server) rather than
  # http_content or cd_content. This has proven the most reliable for getting the autoinstall
  # seed to actually be fetched instead of falling back to the interactive installer.
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # Serve the autoinstall cloud-config over HTTP from the local ./http/ directory.
  # Files (packer/http/user-data and meta-data) are served at the root of Packer's
  # temporary HTTP server, e.g. http://<packer-http-ip>:<port>/user-data
  #
  # This is the classic, most reliable method with the hyperv-iso builder for Ubuntu
  # live-server autoinstall (http_content was not actually registering the paths in testing).
  http_directory = "http"

  # Boot via the GRUB console ('c') and issue explicit linux/initrd/boot with autoinstall
  # datasource pointing at Packer's temporary HTTP server (serves the local ./http/ directory).
  #
  # We use the 'c' method because 'e' + cursor keys are unreliable on the hyperv-iso builder
  # (numpad scan codes + numlock produce digits instead of movement; <numlock> isn't a special key).
  #
  # Critical for autoinstall to actually engage (instead of dropping to interactive language chooser):
  # - Put autoinstall/ds params AFTER the "---" separator.
  # - Use the nocloud;s= form (works well for this http_content + live ISO case).
  # - Include `ip=dhcp` so the kernel brings up networking very early (before the ds fetch in initramfs).
  # - Quote the ds= value with **double quotes** in the GRUB command (ds=\"...\") so the ; is not
  #   interpreted by GRUB as a command separator.
  # - set gfxpayload=keep to match the stock menuentry.
  #
  # Watch the Packer output for these two lines (they appear after "Starting build ..."):
  #   Starting HTTP server on port XXXX
  #   Host IP for the HyperV machine: 172.18.64.1   (or similar; this is what the guest reaches)
  #
  # You can test from the Windows host browser while at the GRUB prompt:
  #   http://<that-ip>:<port>/user-data
  #   http://<that-ip>:<port>/meta-data
  # Both must return the content.
  #
  # If it still falls through to language selection on next run:
  #   In Hyper-V console (when at language screen): Ctrl+Alt+F2 (or F3) for a shell.
  #   Then: cat /proc/cmdline   <--- MOST IMPORTANT: this shows exactly what kernel params were received
  #   And try: curl -v http://<ip>:<port>/user-data   (to see if the guest can reach Packer's HTTP server).
  #
  # {{ .HTTPIP }} and {{ .HTTPPort }} are substituted by Packer at runtime.
  boot_command = [
    "<wait10s>",
    "c<wait3s>",
    "set gfxpayload=keep<enter><wait>",
    "linux /casper/vmlinuz --- autoinstall ip=dhcp net.ifnames=0 biosdevname=0 ds=\"nocloud-net;seedfrom=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"<wait>",
    "<enter><wait5s>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  boot_wait = "5s"

  # Communicator for all the shell provisioners below (after autoinstall finishes and SSH is up).
  communicator     = "ssh"
  ssh_username     = "ubuntu"
  ssh_password     = local.build_password
  ssh_timeout      = "45m"
  ssh_port         = 22
  # For robustness during long package installs:
  ssh_handshake_attempts = 50

  # Helpful for debugging upload issues: force remote temp to /tmp and add a small test step
  # The test step verifies that scp/sftp uploads work from the host to the guest.

  # VM resources for the *build* VM (not the final golden characteristics).
  cpus      = var.cpus
  memory    = var.memory
  disk_size = var.disk_size
  switch_name = var.switch_name

  # Hyper-V generation 2 is fine; secure boot can interfere with some cloud-style boots.
  generation        = 2
  enable_secure_boot = false
  enable_dynamic_memory = true

  # Output location. After successful build the VHDX lives under here.
  output_directory = "output-openclaw"
  vm_name          = var.build_vm_name

  # Clean shutdown at the end of provisioning.
  shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
  shutdown_timeout = "10m"
}

build {
  sources = ["source.hyperv-iso.openclaw"]

  # 0. Tiny test provisioner to verify that script upload (scp/sftp) works from the host.
  #    If this fails with "Error uploading script", the problem is still in the guest's sftp setup or /tmp perms.
  #    Output also echoed to console (ttyS0/tty0) for visibility in Hyper-V.
  provisioner "shell" {
    inline = [
      "echo '=== PACKER UPLOAD TEST ===' | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true",
      "whoami | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true",
      "id | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true",
      "ls -ld /tmp | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true",
      "echo 'upload-test-ok' > /tmp/packer-upload-test.txt",
      "cat /tmp/packer-upload-test.txt | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true",
      "echo '=== PACKER UPLOAD TEST END ===' | tee -a /dev/ttyS0 /dev/tty0 2>/dev/null || true"
    ]
    remote_folder = "/tmp"
  }

  # 1. Basic hygiene + Docker (we will enable it properly later too).
  provisioner "shell" {
    inline = [
      "set -e",
      "sudo apt-get update -y",
      "sudo apt-get install -y --no-install-recommends curl ca-certificates gnupg jq docker.io",
      "sudo systemctl enable --now docker || true",
      "sudo usermod -aG docker ubuntu || true"
    ]
    remote_folder = "/tmp"
  }

  # 1. Node 24 via NodeSource + corepack + pnpm (matches the exact sequence used by the multipass launcher).
  provisioner "shell" {
    inline = [
      "set -e",
      "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -",
      "sudo apt-get install -y nodejs",
      "sudo corepack enable",
      "sudo corepack prepare pnpm@latest --activate || true",
      "node --version && pnpm --version"
    ]
  }

  # 2. Create the dedicated openclaw user early (system-style, docker group, home skeleton).
  provisioner "shell" {
    inline = [
      "set -e",
      "sudo useradd --system --create-home --shell /bin/bash --home /home/openclaw openclaw || true",
      "sudo usermod -aG docker openclaw || true",
      "sudo mkdir -p /home/openclaw/.openclaw/bin /home/openclaw/.openclaw/state /home/openclaw/.openclaw/logs/stability",
      "sudo chown -R openclaw:openclaw /home/openclaw"
    ]
  }

  # 3. The critical pnpm global install + stable wrapper + dual symlinks.
  #    This block is intentionally very close to the one in scripts/launch.ps1 so behavior is identical.
  provisioner "shell" {
    inline = [
      "set -e",
      "echo '=== OPENCLAW PACKER BAKE START ==='",
      "sudo chown -R openclaw:openclaw /home/openclaw || true",

      # PATH reinforcement for the dedicated user (same as launcher).
      "sudo -u openclaw bash -c '",
      "  mkdir -p ~/.openclaw/bin",
      "  for f in ~/.bashrc ~/.profile; do",
      "    if [ -f \"$f\" ] || [ ! -e \"$f\" ]; then",
      "      grep -q \"export PATH=/usr/local/bin:\\$PATH\" \"$f\" 2>/dev/null || echo \"export PATH=/usr/local/bin:\\$PATH\" >> \"$f\"",
      "      grep -q \"pnpm/bin\" \"$f\" 2>/dev/null || echo \"export PATH=\\\"\\$HOME/.local/share/pnpm/bin:\\$PATH\\\"\" >> \"$f\"",
      "    fi",
      "  done",
      "' || true",

      # Official pnpm global install (as the openclaw user, with login shell so profile is sourced).
      "echo 'Running pnpm add -g openclaw ...'",
      "sudo -u openclaw bash -l -c '",
      "  corepack prepare pnpm@latest --activate || true",
      "  export PATH=\"\\$HOME/.local/share/pnpm/bin:\\$PATH\"",
      "  pnpm add -g openclaw",
      "  pnpm rebuild -g openclaw || true",
      "' || true",

      # Stable wrapper creation (exact dedent + sed pattern from the launcher so the wrapper is identical).
      # We create it at the canonical /home/openclaw/.openclaw/bin/openclaw location.
      "echo 'Creating stable wrapper + force links...'",

      "sudo -u openclaw bash -c '",
      "  set -e",
      "  mkdir -p /home/openclaw/.openclaw/bin",
      "  CANDIDATE=\"/home/openclaw/.openclaw/bin/openclaw\"",
      "  cat > \"\\$CANDIDATE\" << \"WRAPPER\" | sed \"s/^[[:space:]]*//\"",
      "  #!/usr/bin/env sh",
      "  export PATH=\"\\$HOME/.local/share/pnpm/bin:\\$PATH\"",
      "  exec \"\\$HOME/.local/share/pnpm/bin/openclaw\" \"\\$@\"",
      "  WRAPPER",
      "  chmod +x \"\\$CANDIDATE\"",
      "  chown openclaw:openclaw \"\\$CANDIDATE\"",
      "  echo \"  stable wrapper at \\$CANDIDATE\"",
      "' || true",

      # Belt-and-suspenders: ensure wrapper again (in case the heredoc under sudo had issues).
      "CANDIDATE=\"/home/openclaw/.openclaw/bin/openclaw\"",
      "sudo -u openclaw bash -c '",
      "  cat > \"\\$CANDIDATE\" << \"WRAPPER\" | sed \"s/^[[:space:]]*//\"",
      "  #!/usr/bin/env sh",
      "  export PATH=\"\\$HOME/.local/share/pnpm/bin:\\$PATH\"",
      "  exec \"\\$HOME/.local/share/pnpm/bin/openclaw\" \"\\$@\"",
      "  WRAPPER",
      "  chmod +x \"\\$CANDIDATE\"",
      "  chown openclaw:openclaw \"\\$CANDIDATE\" || true",
      "' || true",

      # Root-owned link in /usr/local/bin so bare `openclaw` works after sudo or in PATH.
      "sudo ln -sf /home/openclaw/.openclaw/bin/openclaw /usr/local/bin/openclaw || true",
      "sudo chmod +x /usr/local/bin/openclaw || true",
      "ls -l /usr/local/bin/openclaw || true",

      # Quick verification markers (easy to grep in packer logs).
      "if [ -x /home/openclaw/.openclaw/bin/openclaw ]; then echo 'VERIFIED: /home/openclaw/.openclaw/bin/openclaw'; else echo 'MISSING: user bin'; fi",
      "if [ -x /usr/local/bin/openclaw ]; then echo 'VERIFIED: /usr/local/bin/openclaw'; else echo 'MISSING: /usr/local/bin'; fi",
      "echo '=== OPENCLAW PACKER BAKE END ==='"
    ]
  }

  # 4. Write the hardened system service unit (token will be supplied/override at launch time via overlay or adopt).
  provisioner "shell" {
    inline = [
      "set -e",
      "sudo tee /etc/systemd/system/openclaw-gateway.service > /dev/null << 'UNIT'",
      "[Unit]",
      "Description=OpenClaw Gateway (dedicated user)",
      "After=network-online.target docker.service",
      "Wants=network-online.target",
      "Requires=docker.service",
      "",
      "[Service]",
      "Type=simple",
      "User=openclaw",
      "Group=openclaw",
      "WorkingDirectory=/home/openclaw",
      "Environment=HOME=/home/openclaw",
      "Environment=OPENCLAW_GATEWAY_TOKEN=PACKER_BUILD_PLACEHOLDER_REPLACE_AT_LAUNCH",
      "ExecStart=/home/openclaw/.openclaw/bin/openclaw gateway run",
      "Restart=on-failure",
      "RestartSec=5s",
      "",
      "ProtectSystem=strict",
      "ProtectHome=read-only",
      "ReadWritePaths=/home/openclaw/.openclaw",
      "PrivateTmp=true",
      "NoNewPrivileges=true",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "UNIT",
      "sudo systemctl daemon-reload || true",
      "sudo systemctl enable openclaw-gateway.service || true"
    ]
  }

  # 5. Write a minimal base openclaw.json (real declarative one + token come from the thin launch overlay).
  provisioner "shell" {
    inline = [
      "set -e",
      "sudo -u openclaw bash -c '",
      "  mkdir -p ~/.openclaw",
      "  cat > ~/.openclaw/openclaw.json << \"JSON\"",
      "  {",
      "    \"gateway\": { \"mode\": \"local\", \"bind\": \"loopback\", \"auth\": { \"mode\": \"token\", \"token\": \"PACKER_PLACEHOLDER\" } },",
      "    \"agents\": { \"defaults\": { \"sandbox\": { \"mode\": \"non-main\", \"backend\": \"docker\", \"browser\": { \"autoStart\": true } } } }",
      "  }",
      "  JSON",
      "  chmod 600 ~/.openclaw/openclaw.json",
      "' || true"
    ]
  }

  # 6. Pre-build the sandbox images (the reason browser tools are fast on first use).
  #    Run as openclaw so the images are in that user's Docker context (or root; docker is root by default on this image).
  provisioner "shell" {
    inline = [
      "set -e",
      "echo 'Pre-building openclaw-sandbox:bookworm-slim ...'",
      "sudo -u openclaw bash -c 'docker build -t openclaw-sandbox:bookworm-slim - << \"DOCKERFILE\"",
      "FROM debian:bookworm-slim",
      "ENV DEBIAN_FRONTEND=noninteractive",
      "RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git jq python3 ripgrep && rm -rf /var/lib/apt/lists/*",
      "RUN useradd --create-home --shell /bin/bash sandbox",
      "USER sandbox",
      "WORKDIR /home/sandbox",
      "CMD [\"sleep\", \"infinity\"]",
      "DOCKERFILE' || true",

      "echo 'Pre-building openclaw-sandbox-browser:bookworm-slim ...'",
      "sudo -u openclaw bash -c 'docker build -t openclaw-sandbox-browser:bookworm-slim - << \"DOCKERFILE\"",
      "FROM mcr.microsoft.com/playwright:v1.44.0-jammy",
      "RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*",
      "ENTRYPOINT [\"/usr/bin/tini\", \"--\"]",
      "CMD [\"sleep\", \"infinity\"]",
      "DOCKERFILE' || true",

      "docker images | grep -E 'openclaw-sandbox' || true"
    ]
  }

  # 7. Final ownership + enablement.
  provisioner "shell" {
    inline = [
      "set -e",
      "sudo chown -R openclaw:openclaw /home/openclaw || true",
      "sudo systemctl daemon-reload || true",
      "sudo systemctl enable --now docker || true",
      "sudo systemctl enable openclaw-gateway.service || true",
      "echo 'Golden image bake complete. The resulting VHDX can be used directly with native Hyper-V.'"
    ]
  }

  # Tell the user exactly where the usable disk is after the build VM is cleaned up.
  post-processor "shell-local" {
    inline = [
      "Write-Host 'Packer build finished.' -ForegroundColor Green",
      "Write-Host ''",
      "Write-Host 'The golden VHDX is under the output directory. Typical location:' -ForegroundColor Cyan",
      "Write-Host '  .\\packer\\output-openclaw\\Virtual Hard Disks\\${var.build_vm_name}.vhdx' -ForegroundColor Yellow",
      "Write-Host '  (or open the output-openclaw folder and look for the .vhdx)'",
      "Write-Host ''",
      "Write-Host 'Next: use that .vhdx (copy it or make a differencing child) with native Hyper-V New-VM.' -ForegroundColor Cyan",
      "Write-Host 'A thin CIDATA config drive (generated from your vtorclaw.yaml) supplies the real token, ssh public key (for openclaw as default login user), and per-instance openclaw.json.' -ForegroundColor Cyan"
    ]
    only_on = ["windows"]
  }
}
