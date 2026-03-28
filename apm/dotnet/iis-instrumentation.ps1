#Requires -PSEdition Desktop

# Accept OTLP endpoint and API key as arguments or environment variables
param(
    [string]$OtlpEndpoint = $env:OTEL_EXPORTER_OTLP_ENDPOINT,
    [string]$ApiKey = $env:OTEL_EXPORTER_OTLP_API_KEY
)

Write-Host "========== CLEANING OLD OPEN TELEMETRY SETTINGS ==========" -ForegroundColor Yellow

# -----------------------------
# 1️⃣ Remove old machine-level OTEL and profiler environment variables
# -----------------------------
$oldEnvVars = @(
    "OTEL_DOTNET_AUTO_INSTALL_DIR",
    "OTEL_DOTNET_AUTO_INSTRUMENTATION_ENABLED",
    "OTEL_DOTNET_AUTO_LOG_DIRECTORY",
    "OTEL_DOTNET_AUTO_LOG_LEVEL",
    "OTEL_DOTNET_AUTO_TRACES_ENABLED",
    "OTEL_DOTNET_AUTO_METRICS_ENABLED",
    "OTEL_DOTNET_AUTO_LOGS_ENABLED",
    "OTEL_DOTNET_AUTO_NETFX_RUNTIME",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_HEADERS",
    "COR_ENABLE_PROFILING",
    "COR_PROFILER",
    "COR_PROFILER_PATH",
    "COR_PROFILER_PATH_32",
    "COR_PROFILER_PATH_64",
    "CORECLR_ENABLE_PROFILING",
    "CORECLR_PROFILER",
    "CORECLR_PROFILER_PATH",
    "CORECLR_PROFILER_PATH_32",
    "CORECLR_PROFILER_PATH_64",
    "DOTNET_STARTUP_HOOKS"
)

foreach ($var in $oldEnvVars) {
    Write-Host "Cleaning up.. $var"
    [Environment]::SetEnvironmentVariable($var, $null, "Machine")
}

# Restart IIS to ensure old profiler references are gone
Write-Host "Performing IIS reset..."
iisreset /noforce

Write-Host "========== Installing OpenTelemetry for IIS ==========" -ForegroundColor Cyan

# Create base directory (for module only)
$otelBasePath = "C:\otel-dotnet-auto"

if (Test-Path $otelBasePath) {
    Write-Host "`nDirectory $otelBasePath already exists." -ForegroundColor Yellow
    $choice = Read-Host "Type 's' to skip downloading, or 'd' to delete and re-download"
    if ($choice -eq 'd') {
        Write-Host "Deleting $otelBasePath..." -ForegroundColor Red
        Remove-Item -Recurse -Force $otelBasePath
        New-Item -ItemType Directory -Force -Path $otelBasePath | Out-Null
    } elseif ($choice -eq 's') {
        Write-Host "Skipping download and module import." -ForegroundColor Cyan
        $skipDownload = $true
    } else {
        Write-Host "Invalid choice. Exiting script." -ForegroundColor Red
        exit 1
    }
} else {
    New-Item -ItemType Directory -Force -Path $otelBasePath | Out-Null
}

# Download the OpenTelemetry module
$moduleUrl = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
$modulePath = Join-Path $otelBasePath "OpenTelemetry.DotNet.Auto.psm1"

if (-not $skipDownload) {
    Write-Host "Downloading OpenTelemetry module..."
    Invoke-WebRequest -Uri $moduleUrl -OutFile $modulePath -UseBasicParsing

    # Import the module
    Import-Module $modulePath -Force

    # Install OpenTelemetry Core
    Write-Host "Installing OpenTelemetry Core..."
    Install-OpenTelemetryCore
} else {
    Write-Host "Module download and install steps skipped as requested." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "✅ CLOSE VISUAL STUDIO COMPLETELY"
Write-Host "✅ REOPEN IT AND RUN USING IIS EXPRESS"
Write-Host ""



# Run as Administrator
$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"

Write-Host "Using OTLP Endpoint: $OtlpEndpoint" -ForegroundColor Cyan
Write-Host "Using API Key: $ApiKey" -ForegroundColor Cyan

# List all App Pools
Write-Host "\n========== AVAILABLE IIS APP POOLS ==========" -ForegroundColor Yellow
$appPools = & $AppCmd list apppool /text:name
$appPoolsArray = $appPools -split "\r?\n" | Where-Object { $_ -ne "" }

for ($i = 0; $i -lt $appPoolsArray.Count; $i++) {
    Write-Host ("[{0}] {1}" -f $i, $appPoolsArray[$i])
}

# Prompt user to select one, multiple, or all App Pools
do {
    $selection = Read-Host "Enter the number(s) of the App Pool(s) to use (comma-separated, or 'all' for all)"
    $isAll = $selection.Trim().ToLower() -eq 'all'
    if ($isAll) {
        $selectedIndices = @(0..($appPoolsArray.Count - 1))
        $isValid = $true
    } else {
        $selectedIndices = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }
        $isValid = $selectedIndices.Count -gt 0 -and ($selectedIndices | Where-Object { $_ -ge 0 -and $_ -lt $appPoolsArray.Count }).Count -eq $selectedIndices.Count
    }
    if (-not $isValid) {
        Write-Host "Invalid selection. Please enter valid number(s) or 'all'." -ForegroundColor Red
    }
} while (-not $isValid)

$SelectedAppPools = $selectedIndices | ForEach-Object { $appPoolsArray[$_] }
Write-Host "Selected App Pool(s): $($SelectedAppPools -join ', ')" -ForegroundColor Cyan



$envs = @{
    "OTEL_SERVICE_NAME" = "MyMvcIisService"
    "OTEL_EXPORTER_OTLP_ENDPOINT" = $OtlpEndpoint
    "OTEL_EXPORTER_OTLP_PROTOCOL" = "http/protobuf"
    "OTEL_DOTNET_AUTO_INSTALL_DIR" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation"
    "OTEL_DOTNET_AUTO_HOME" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation"
    "OTEL_TRACES_EXPORTER" = "otlp"
    "OTEL_METRICS_EXPORTER" = "otlp"
    "OTEL_LOGS_EXPORTER" = "otlp"
    "OTEL_DOTNET_AUTO_TRACES_ENABLED" = "true"
    "OTEL_DOTNET_AUTO_METRICS_ENABLED" = "true"
    "OTEL_DOTNET_AUTO_LOGS_ENABLED" = "true"
    "COR_ENABLE_PROFILING" = "1"
    "COR_PROFILER" = "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
    "COR_PROFILER_PATH" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x64\OpenTelemetry.AutoInstrumentation.Native.dll"
    "COR_PROFILER_PATH_32" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x86\OpenTelemetry.AutoInstrumentation.Native.dll"
    "COR_PROFILER_PATH_64" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x64\OpenTelemetry.AutoInstrumentation.Native.dll"
    "OTEL_DOTNET_AUTO_LOG_DIRECTORY" = "C:\otel-logs"
    "OTEL_DOTNET_AUTO_LOG_LEVEL" = "debug"
    "OTEL_DOTNET_AUTO_INSTRUMENTATION_ENABLED" = "true"
    "OTEL_BSP_SCHEDULE_DELAY" = "1000"
    "OTEL_BSP_MAX_EXPORT_BATCH_SIZE" = "1"
    "OTEL_EXPORTER_OTLP_HEADERS" = "Authorization=$ApiKey"
}

# Remove and set env vars for each selected App Pool
foreach ($AppPoolName in $SelectedAppPools) {
    Write-Host "`nConfiguring App Pool: $AppPoolName" -ForegroundColor Cyan

    # Get current environment variables for the App Pool
    $currentEnvVars = & $AppCmd list apppool /name:"$AppPoolName" /text:environmentVariables
    $currentEnvVarNames = @()
    if ($currentEnvVars) {
        $currentEnvVarNames = $currentEnvVars -split ';' | ForEach-Object {
            ($_ -split '=')[0]
        }
    }

    $appPoolEnvVarsToRemove = ($oldEnvVars + $envs.Keys) | Sort-Object -Unique
    foreach ($name in $appPoolEnvVarsToRemove) {
        if ($currentEnvVarNames -contains $name) {
            $cmd = "& `"$AppCmd`" set apppool /apppool.name:`"$AppPoolName`" /-environmentVariables.`"[name='$name']`""
            Write-Host "Unsetting App Pool env $name"
            Invoke-Expression $cmd
        }
    }

    # Refresh the list after unsetting
    $currentEnvVars = & $AppCmd list apppool /name:"$AppPoolName" /text:environmentVariables
    $currentEnvVarNames = @()
    if ($currentEnvVars) {
        $currentEnvVarNames = $currentEnvVars -split ';' | ForEach-Object {
            ($_ -split '=')[0]
        }
    }

    foreach ($name in $envs.Keys) {
        $value = $envs[$name] -replace '\\', '\\\\'   # Escape backslashes for appcmd

        # Always remove first to avoid duplicates
        $removeCmd = "& `"$AppCmd`" set apppool /apppool.name:`"$AppPoolName`" /-environmentVariables.`"[name='$name']`""
        Write-Host "Ensuring removal: $removeCmd"
        Invoke-Expression $removeCmd

        # Now add
        $addCmd = "& `"$AppCmd`" set apppool /apppool.name:`"$AppPoolName`" /+environmentVariables.`"[name='$name',value='$value']`""
        Write-Host "Adding: $addCmd"
        Invoke-Expression $addCmd
    }
    Write-Host "✅ All environment variables set for App Pool: $AppPoolName"
    Restart-WebAppPool -Name $AppPoolName
}
Write-Host "Done!"
