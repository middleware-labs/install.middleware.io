# Log File Handling
$logFilePath = "mw-kube-agent-install-$(Get-Date -UFormat %s).log"
$null = New-Item -ItemType Directory -Force -Path "mw-kube-agent-logs"
$null = New-Item -Path $logFilePath -ItemType File -Force
Start-Transcript -Path $logFilePath -Append

# Function to send logs
function Send-Logs {
    param(
        [string]$status,
        [string]$message
    )

    $payload = @{
        status      = $status
        metadata    = @{
            script      = "kubernetes"
            status      = "ok"
            message     = $message
            script_logs = (Get-Content -Path $logFilePath -Raw) -replace "`r`n", '`n'
        }
    } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$env:MW_TARGET/api/v1/agent/tracking/$env:MW_API_KEY" -Method Post -ContentType "application/json" -Body $payload
}

# Cleanup function
function Cleanup {
    if ($global:?) {
        Remove-Item $MW_KUBE_AGENT_HOME -Force -Recurse -ErrorAction SilentlyContinue
        Send-Logs -status "installed" -message "Script Completed"
    } else {
        Send-Logs -status "error" -message "Script Failed"
    }
}

# Set error handling
$ErrorActionPreference = "Stop"

# Try-Catch block to ensure cleanup
try {
    # Attempt log
    $null = Invoke-RestMethod -Uri "$env:MW_TARGET/api/v1/agent/tracking/$env:MW_API_KEY" -Method Post -ContentType "application/json" -Body '{
        "status": "tried",
        "metadata": {
            "script": "kubernetes",
            "status": "ok",
            "message": "agent installed"
        }
    }' -UseBasicParsing

    # Rest of the script...
    Write-Host "`nSetting up Middleware Kubernetes agent ...`n"
    $CURRENT_CONTEXT = kubectl config current-context
    $MW_KUBE_CLUSTER_NAME = (kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")
    $MW_KUBE_AGENT_HOME = "mw-kube-agent-manifests"
    $MW_DEFAULT_NAMESPACE = "mw-agent-ns"
    $MW_NAMESPACE = if (-not $env:MW_NAMESPACE) { $MW_DEFAULT_NAMESPACE } else { $env:MW_NAMESPACE }

    Write-Host "`n`n`tcluster : $MW_KUBE_CLUSTER_NAME `n`tcontext : $CURRENT_CONTEXT`n"

    if ($env:MW_KUBE_AGENT_INSTALL_METHOD -eq "manifest" -or -not $env:MW_KUBE_AGENT_INSTALL_METHOD) {
        Write-Host "`nMiddleware Kubernetes agent is being installed using manifest files, please wait ..."

        # Fetch install manifest
        $null = New-Item -ItemType Directory -Force -Path $MW_KUBE_AGENT_HOME
        Invoke-WebRequest -Uri "https://install.middleware.io/scripts/mw-kube-agent.yaml" -OutFile "$MW_KUBE_AGENT_HOME/agent.yaml"

        if (-not $env:MW_KUBECONFIG) {
            (Get-Content "$MW_KUBE_AGENT_HOME/agent.yaml" -Raw) -replace 'MW_KUBE_CLUSTER_NAME_VALUE', $MW_KUBE_CLUSTER_NAME `
            -replace 'MW_ROLLOUT_RESTART_RULE', $env:MW_ROLLOUT_RESTART_RULE -replace 'MW_LOG_PATHS', $env:MW_LOG_PATHS `
            -replace 'MW_DOCKER_ENDPOINT_VALUE', $env:MW_DOCKER_ENDPOINT -replace 'MW_API_KEY_VALUE', $env:MW_API_KEY `
            -replace 'TARGET_VALUE', $env:MW_TARGET -replace 'NAMESPACE_VALUE', $MW_NAMESPACE | Out-File "$MW_KUBE_AGENT_HOME/agent.yaml"

            kubectl create --kubeconfig=$env:MW_KUBECONFIG -f "$MW_KUBE_AGENT_HOME/agent.yaml"
            kubectl --kubeconfig=$env:MW_KUBECONFIG -n $MW_NAMESPACE rollout restart daemonset/mw-kube-agent
        } else {
            (Get-Content "$MW_KUBE_AGENT_HOME/agent.yaml" -Raw) -replace 'MW_KUBE_CLUSTER_NAME_VALUE', $MW_KUBE_CLUSTER_NAME `
            -replace 'MW_ROLLOUT_RESTART_RULE', $env:MW_ROLLOUT_RESTART_RULE -replace 'MW_LOG_PATHS', $env:MW_LOG_PATHS `
            -replace 'MW_DOCKER_ENDPOINT_VALUE', $env:MW_DOCKER_ENDPOINT -replace 'MW_API_KEY_VALUE', $env:MW_API_KEY `
            -replace 'TARGET_VALUE', $env:MW_TARGET -replace 'NAMESPACE_VALUE', $MW_NAMESPACE | Out-File "$MW_KUBE_AGENT_HOME/agent.yaml"

            kubectl create -f "$MW_KUBE_AGENT_HOME/agent.yaml"
            kubectl -n $MW_NAMESPACE rollout restart daemonset/mw-kube-agent
        }
    } elseif ($env:MW_KUBE_AGENT_INSTALL_METHOD -eq "helm") {
        Write-Host "`nMiddleware helm chart is being installed, please wait ..."
        helm repo add middleware.io https://helm.middleware.io
        helm install --set mw.target=$env:MW_TARGET --set mw.apiKey=$env:MW_API_KEY --wait mw-kube-agent middleware.io/mw-kube-agent -n $MW_NAMESPACE --create-namespace
    } else {
        Write-Host "MW_KUBE_AGENT_INSTALL_METHOD environment variable not set to 'helm' or 'manifest'"
        exit 1
    }

    Write-Host "Middleware Kubernetes agent successfully installed !"


} finally {
    # Cleanup in case of success or failure
    Cleanup
}

