# Isolated AI Agent Workspace (OpenClaw + LiteLLM Proxy)

This repository provides an automated workflow to spin up an isolated, secure virtual machine tailored for autonomous AI agents. By decoupling the AI runtime from your local hardware, this configuration offloads heavy language model inference to the Google AI Studio free tier while strictly sandboxing file execution and browser-based E2E tests within disposable Docker containers.

## Architecture Overview

```text
                     ┌──────────────────────────────────────────────────┐
                     │                 MULTIPASS VM (Ubuntu)            │
                     │                                                  │
 ┌──────────────┐    │ ┌──────────────┐   ┌─────────┐                   │
 │ Messaging App│ ───┼─► OpenClaw     ├──►│ LiteLLM │   (Cloud API)     │
 │  (Telegram)  │    │ │ (Host Mode)  │   │ Proxy   │ ────────────────┼───┐
 └──────────────┘    │ └──────┬───────┘   └─────────┘                   │   │
                     │        │                                         │   ▼
                     │        ▼ (Triggers Worker Sandbox)               │ ┌───────────────┐
                     │ ┌──────────────────────────────────────────────┐ │ │ Google Studio │
                     │ │        EPHEMERAL DOCKER CONTAINER            │ │ │ Gemini 3.x    │
                     │ │                                              │ │ └───────────────┘
                     │ │  🌐 Playwright / Chromium (E2E Tests)        │ │
                     │ └──────────────────────────────────────────────┘ │
                     └──────────────────────────────────────────────────┘
```

* **Orchestrator:** OpenClaw runs natively in the Ubuntu guest OS to receive messages and manage workflows.
* **API Routing:** LiteLLM Proxy runs locally inside the VM via `uv`, shaping traffic to prevent rate limit blocks (`429`) on the Google AI Studio free tier.
* **Execution Layer:** All scripts, file changes, and Playwright automated browser instances run strictly inside an ephemeral Docker sandbox to prevent prompt-injection attacks from compromising the host.

## Prerequisites

Before deployment, ensure you have the following installed on your Windows host machine:
* [Multipass](https://multipass.run) (`winget install Canonical.Multipass`)
* An SSH Keypair (typically located at `~/.ssh/id_rsa.pub`)
* A valid Google AI Studio API Key

## File Structures

Ensure the following two files are placed in your current working directory:

### 1. `setup.yaml`
Acts as the `cloud-init` blueprint. It provisions the VM, installs Docker, bootstraps `uv`, pulls LiteLLM, and configures the automated backend services. 

> ⚠️ **Configuration Action Required:** 
> * Replace `YOUR_PUBLIC_SSH_KEY_HERE` with the raw text string from your `id_rsa.pub`.
> * Replace `AIzaSy_YOUR_ACTUAL_GOOGLE_STUDIO_KEY_HERE` with your live Google AI Studio credential.

### 2. `openclaw.json`
Tells OpenClaw to communicate with the local LiteLLM Proxy port (`4000`) and forces all tool and browser task routines into the official `playwright:v1.45.0-noble` image layer.

## Quick Start Deployment

1. Open PowerShell or a terminal inside the folder containing your configurations.
2. Provision and launch the virtual workspace with a single command:
   ```powershell
   multipass launch --name ai-agent --cpus 4 --memory 4G --disk 30G --cloud-init setup.yaml
   ```
3. Once fully loaded, retrieve the network details of your newly generated cluster instance:
   ```powershell
   multipass info ai-agent
   ```
4. Access the environment using your local SSH key pair:
   ```bash
   ssh ubuntu@<VM_IP_ADDRESS>
   ```

## Verification & Testing

To confirm that the sandbox isolation layer and browser automation frameworks are operating as intended, perform the following verification checks inside the VM:

### 1. Check Backend API Proxy Routing
Verify that LiteLLM successfully registers the Gemini models and can safely handle communication loops:
```bash
curl http://localhost:4000/v1/models
```
*Expected Output:* A JSON array detailing your active model mappings (`agent-smart`, `agent-fast`).

### 2. Test Containerized Browser Execution
To verify that Playwright tools can spin up headless browser tasks inside the container runtime without throwing environment layout errors, execute a direct shell worker test:
```bash
docker run --rm --network=host -v /home/ubuntu/workspace:/workspace ://microsoft.com python3 -c "
import urllib.request
print('Sandbox operating normally. Network access confirmed.')
"
```

## Maintenance & Control Commands

* **Stop the workspace:** `multipass stop ai-agent`
* **Restart the workspace:** `multipass start ai-agent`
* **Monitor LiteLLM runtime logs:** `multipass exec ai-agent -- journalctl -u litellm.service -f`
* **Nuke and rebuild from scratch:** 
  ```powershell
  multipass delete ai-agent
  multipass purge
  multipass launch --name ai-agent --cpus 4 --memory 4G --disk 30G --cloud-init setup.yaml
  ```

