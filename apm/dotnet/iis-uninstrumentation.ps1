param(
    [switch]$SkipAppPoolRestart,
    [string]$Mode
)

Write-Host "========== REVERTING IIS INSTRUMENTATION ==========" -ForegroundColor Yellow

$validModes = @("complete", "apppool")
$mode = if ($Mode) { $Mode.Trim().ToLower() } else { $null }
if ($mode -and ($mode -notin $validModes)) {
    throw "Mode must be one of: $($validModes -join ', ')"
}
if (-not $mode) {
    while (-not $mode) {
        $input = Read-Host "Choose cleanup scope: [1] Complete removal (machine + all app pools) | [2] Specific app pool only"
        switch ($input) {
            "1" { $mode = "complete" }
            "2" { $mode = "apppool" }
            default { Write-Host "Please enter 1 or 2." -ForegroundColor Yellow }
        }
    }
}
Write-Host "Running in '$mode' mode." -ForegroundColor Cyan

function Remove-MachineInstrumentation {
    param(
        [string[]]$EnvVars,
        [string[]]$Dirs
    )

    foreach ($var in $EnvVars) {
        Write-Host "Clearing machine env var: $var" -ForegroundColor Cyan
        [Environment]::SetEnvironmentVariable($var, $null, "Machine")
    }

    foreach ($dir in $Dirs) {
        if (Test-Path $dir) {
            Write-Host "Removing instrumentation directory: $dir" -ForegroundColor Cyan
            try {
                Remove-Item -Recurse -Force $dir
            } catch {
                Write-Host "Warning: Failed to remove $dir. Please delete it manually if needed." -ForegroundColor Yellow
            }
        }
    }
}

$instrVars = @(
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
    "DOTNET_STARTUP_HOOKS",
    "OTEL_SERVICE_NAME",
    "OTEL_DOTNET_AUTO_HOME",
    "OTEL_TRACES_EXPORTER",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_BSP_SCHEDULE_DELAY",
    "OTEL_BSP_MAX_EXPORT_BATCH_SIZE"
)

$targetDirs = @(
    "C:\otel-dotnet-auto",
    "C:\Program Files\OpenTelemetry .NET AutoInstrumentation",
    "C:\otel-logs"
)

if ($mode -eq "complete") {
    Remove-MachineInstrumentation -EnvVars $instrVars -Dirs $targetDirs
} else {
    Write-Host "Skipping machine-level cleanup in specific app pool mode." -ForegroundColor Cyan
}

$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
$appPools = & $AppCmd list apppool /text:name
$appPoolNames = $appPools -split "\r?\n" | Where-Object {$_}

function Select-AppPool {
    param($Pools)

    for ($i = 0; $i -lt $Pools.Count; $i++) {
        Write-Host ("[{0}] {1}" -f $i, $Pools[$i])
    }

    do {
        $selection = Read-Host "Enter the number of the App Pool to target"
        $isValid = $selection -match '^[0-9]+$' -and [int]$selection -ge 0 -and [int]$selection -lt $Pools.Count
        if (-not $isValid) {
            Write-Host "Invalid selection. Try again." -ForegroundColor Red
        }
    } while (-not $isValid)

    return $Pools[$selection]
}

$targetAppPools = if ($mode -eq "apppool") { @(Select-AppPool -Pools $appPoolNames) } else { $appPoolNames }

$envsRemoved = @()

foreach ($pool in $targetAppPools) {
    $currentEnv = & $AppCmd list apppool /name:"$pool" /config
    $hasChanges = $false

    if ($currentEnv) {
        $envNames = @()

        try {
            $configXml = [xml]$currentEnv
            $envNodes = $configXml.SelectNodes('//environmentVariables/add')
            if ($envNodes) {
                foreach ($node in $envNodes) {
                    if ($node.name) {
                        $envNames += $node.name
                    }
                }
            }
        } catch {
            Write-Host "Unable to parse XML for $pool, falling back to text parsing." -ForegroundColor Yellow
        }

        if (-not $envNames.Count) {
            $envNames = ($currentEnv -split ';' | ForEach-Object {
                $entry = $_.Trim()
                if ($entry -match '^\s*$') { continue }
                $parts = $entry -split '='
                $parts[0].Trim()
            } | Where-Object { $_ }) -as [string[]]
        }
        if ($envNames.Count) {
            Write-Host ("Detected env vars on {0}: {1}" -f $pool, ($envNames -join ', ')) -ForegroundColor DarkCyan
        }

        foreach ($name in $instrVars) {
            if ($envNames -contains $name) {
                $cmd = "& `"$AppCmd`" set apppool /apppool.name:`"$pool`" /-environmentVariables.`"[name='$name']`""
                Write-Host "Removing $name from $pool"
                Invoke-Expression $cmd
                $hasChanges = $true
            }
        }
    }

    if ($hasChanges) {
        $envsRemoved += $pool
        if (-not $SkipAppPoolRestart) {
            Restart-WebAppPool -Name $pool
        }
    }
}

if ($envsRemoved.Count -eq 0) {
    Write-Host "No instrumentation environment variables were found on any App Pool." -ForegroundColor Green
} else {
    Write-Host "Cleaned instrumentation env vars from: $($envsRemoved -join ', ')" -ForegroundColor Green
}

if (-not $SkipAppPoolRestart) {
    Write-Host "Optionally run `iisreset /noforce` if you suspect lingering instrumentation state." -ForegroundColor Cyan
}
