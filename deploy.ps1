# ==========================================
# 1. INFRASTRUCTURE PURGE
# ==========================================
if (multipass list | Select-String "ai-agent") {
    Write-Host "Existing 'ai-agent' VM found. Stopping and purging..." -ForegroundColor Yellow
    multipass stop ai-agent 2>$null
    multipass delete ai-agent
    multipass purge
}

# ==========================================
# 2. LOCAL ENVIRONMENT INGESTION
# ==========================================
if (Test-Path .env) {
    Get-Content .env | Where-Object { $_ -match '=' -and $_ -notmatch '^#' } | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim().Trim('"'))
    }
} else {
    Write-Error "Missing local .env keys profile. Creation aborted."
    exit
}

# ==========================================
# 3. IN-MEMORY PATTERN RESOLUTION
# ==========================================
$cloudInit = Get-Content setup.yaml -Raw

# Replace all variables inside host memory before dumping the payload
$cloudInit = $cloudInit.Replace("__SSH_PUBLIC_KEY_PLACEHOLDER__", [System.Environment]::GetEnvironmentVariable("SSH_PUBLIC_KEY"))
$cloudInit = $cloudInit.Replace("__GEMINI_API_KEY_PLACEHOLDER__", [System.Environment]::GetEnvironmentVariable("GEMINI_API_KEY"))
$cloudInit = $cloudInit.Replace("__TELEGRAM_BOT_TOKEN_PLACEHOLDER__", [System.Environment]::GetEnvironmentVariable("TELEGRAM_BOT_TOKEN"))
$cloudInit = $cloudInit.Replace("__TELEGRAM_CHAT_ID_PLACEHOLDER__", [System.Environment]::GetEnvironmentVariable("TELEGRAM_CHAT_ID"))

# Drop compiled runtime cloud-init string into a transient file
$tempYaml = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tempYaml -Value $cloudInit

# ==========================================
# 4. INSTANCE PROVISIONING
# ==========================================
Write-Host "Launching fresh, pure AI agent workspace..." -ForegroundColor Green
multipass launch --name ai-agent --cpus 4 --memory 4G --disk 30G --cloud-init $tempYaml

# ==========================================
# 5. POST-BUILD CLEANUP
# ==========================================
Remove-Item $tempYaml
Write-Host "Deployment complete! Workspace successfully built." -ForegroundColor Green

