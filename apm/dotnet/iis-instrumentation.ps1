#Requires -PSEdition Desktop

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
    Write-Host "Unsetting $var"
    [Environment]::SetEnvironmentVariable($var, $null, "Machine")
}

# Restart IIS to ensure old profiler references are gone
Write-Host "Performing IIS reset..."
iisreset /noforce

Write-Host "========== Installing OpenTelemetry for IIS ==========" -ForegroundColor Cyan

# 1. Create base directory (for module only)
$otelBasePath = "C:\otel-dotnet-auto"
New-Item -ItemType Directory -Force -Path $otelBasePath | Out-Null

# 2. Download the OpenTelemetry module
$moduleUrl = "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
$modulePath = Join-Path $otelBasePath "OpenTelemetry.DotNet.Auto.psm1"

Write-Host "Downloading OpenTelemetry module..."
Invoke-WebRequest -Uri $moduleUrl -OutFile $modulePath -UseBasicParsing

# 3. Import the module
Import-Module $modulePath -Force

# 4. ✅ Install OpenTelemetry Core (ONLINE - DEFAULT PATH)
Write-Host "Installing OpenTelemetry Core..."
Install-OpenTelemetryCore

Write-Host ""
Write-Host "✅ INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "✅ CLOSE VISUAL STUDIO COMPLETELY"
Write-Host "✅ REOPEN IT AND RUN USING IIS EXPRESS"
Write-Host ""


# Run as Administrator
$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"

# List all App Pools
Write-Host "\n========== AVAILABLE IIS APP POOLS ==========" -ForegroundColor Yellow
$appPools = & $AppCmd list apppool /text:name
$appPoolsArray = $appPools -split "\r?\n" | Where-Object { $_ -ne "" }
for ($i = 0; $i -lt $appPoolsArray.Count; $i++) {
    Write-Host ("[{0}] {1}" -f $i, $appPoolsArray[$i])
}

# Prompt user to select App Pool
do {
    $selection = Read-Host "Enter the number of the App Pool to use"
    $isValid = $selection -match '^[0-9]+$' -and [int]$selection -ge 0 -and [int]$selection -lt $appPoolsArray.Count
    if (-not $isValid) {
        Write-Host "Invalid selection. Please enter a valid number." -ForegroundColor Red
    }
} while (-not $isValid)

$AppPoolName = $appPoolsArray[$selection]
Write-Host "Selected App Pool: $AppPoolName" -ForegroundColor Cyan


$envs = @{
    "OTEL_SERVICE_NAME" = "MyMvcIisService"
    "OTEL_EXPORTER_OTLP_ENDPOINT" = "https://localhost:9320"
    "OTEL_EXPORTER_OTLP_PROTOCOL" = "http/protobuf"
    "OTEL_DOTNET_AUTO_INSTALL_DIR" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation"
    "OTEL_TRACES_EXPORTER" = "otlp"
    "OTEL_METRICS_EXPORTER" = "otlp"
    "OTEL_LOGS_EXPORTER" = "otlp"
    "OTEL_DOTNET_AUTO_TRACES_ENABLED" = "true"
    "OTEL_DOTNET_AUTO_METRICS_ENABLED" = "true"
    "OTEL_DOTNET_AUTO_LOGS_ENABLED" = "true"
    "COR_ENABLE_PROFILING" = "1"
    "COR_PROFILER" = "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
    "COR_PROFILER_PATH" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x64\OpenTelemetry.AutoInstrumentation.Native.dll"
    "COR_PROFILER_PATH_32" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x64\OpenTelemetry.AutoInstrumentation.Native.dll"
    "COR_PROFILER_PATH_64" = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation\win-x64\OpenTelemetry.AutoInstrumentation.Native.dll"
    "OTEL_DOTNET_AUTO_LOG_DIRECTORY" = "C:\otel-logs"
    "OTEL_DOTNET_AUTO_LOG_LEVEL" = "debug"
    "OTEL_DOTNET_AUTO_INSTRUMENTATION_ENABLED" = "true"
    "OTEL_BSP_SCHEDULE_DELAY" = "1000"
    "OTEL_BSP_MAX_EXPORT_BATCH_SIZE" = "1"
    "OTEL_EXPORTER_OTLP_HEADERS" = "Authorization=fronvgmuphtdegeougdooktdtsztfxxmzayc"
}

foreach ($name in $envs.Keys) {
    $value = $envs[$name] -replace '\\', '\\\\'   # Escape backslashes for appcmd
    $cmd = "& `"$AppCmd`" set apppool /apppool.name:`"$AppPoolName`" /+environmentVariables.`"[name='$name',value='$value']`""
    Write-Host "Running: $cmd"
    Invoke-Expression $cmd
}

Write-Host "✅ All environment variables set for App Pool: $AppPoolName"
Restart-WebAppPool -Name $AppPoolName
Write-Host "Done!"
