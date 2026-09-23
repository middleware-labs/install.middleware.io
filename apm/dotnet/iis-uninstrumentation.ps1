#Requires -PSEdition Desktop

param(
    [switch]$SkipAppPoolRestart,

    # "complete" - machine env vars, GAC assemblies, install directories and all
    #              App Pools. "apppool" - App Pool env vars only.
    [string]$Mode,

    # App Pool name(s), or "all". Supplying this skips every interactive prompt so
    # the rollback can run unattended (SSM, Run Command) while a site is down.
    [string[]]$AppPools,

    # Leave the OpenTelemetry assemblies registered in the GAC.
    [switch]$KeepGacAssemblies,

    [switch]$SkipIisReset
)

Write-Host "========== REVERTING IIS INSTRUMENTATION ==========" -ForegroundColor Yellow

$nonInteractive = ($AppPools -and @($AppPools).Count -gt 0) -or $Mode

$validModes = @("complete", "apppool")
$mode = if ($Mode) { $Mode.Trim().ToLower() } else { $null }
if ($mode -and ($mode -notin $validModes)) {
    throw "Mode must be one of: $($validModes -join ', ')"
}
if (-not $mode) {
    if ($nonInteractive) {
        # -AppPools given without -Mode: only that pool was asked for.
        $mode = "apppool"
    } else {
        while (-not $mode) {
            # Note: do not name this $input - that is an automatic variable.
            $choice = Read-Host "Choose cleanup scope: [1] Complete removal (machine + all app pools) | [2] Specific app pool only"
            switch ($choice) {
                "1" { $mode = "complete" }
                "2" { $mode = "apppool" }
                default { Write-Host "Please enter 1 or 2." -ForegroundColor Yellow }
            }
        }
    }
}
Write-Host "Running in '$mode' mode." -ForegroundColor Cyan

$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
Import-Module WebAdministration -ErrorAction SilentlyContinue

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

# -----------------------------------------------------------------------------
# Step 0: find the install directory BEFORE anything is cleared.
#
# The GAC unregister step enumerates this directory to learn which assemblies to
# remove, so discovering it has to happen before the machine environment
# variables are cleared and before the directory is deleted. Deleting first
# orphans the GAC entries permanently.
# -----------------------------------------------------------------------------
function Get-OtelInstallDir {
    foreach ($var in @("OTEL_DOTNET_AUTO_INSTALL_DIR", "OTEL_DOTNET_AUTO_HOME")) {
        $value = [Environment]::GetEnvironmentVariable($var, "Machine")
        if ($value -and (Test-Path $value)) { return $value }
    }
    $default = "C:\Program Files\OpenTelemetry .NET AutoInstrumentation"
    if (Test-Path $default) { return $default }
    return $null
}

$installDir = Get-OtelInstallDir
if ($installDir) {
    Write-Host "Found OpenTelemetry install directory: $installDir" -ForegroundColor Cyan
} else {
    Write-Host "No OpenTelemetry install directory found." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Step 1: strip App Pool level environment variables
# -----------------------------------------------------------------------------
function Get-AppPoolEnvVarNames {
    param(
        [string]$AppCmd,
        [string]$AppPoolName
    )

    try {
        $configXml = (& $AppCmd list apppool "$AppPoolName" /config 2>$null) -join "`n"
        if (-not $configXml) { return @() }
        $node = ([xml]$configXml).add.environmentVariables
        if (-not $node) { return @() }
        return @($node.add | ForEach-Object { $_.name } | Where-Object { $_ })
    } catch {
        Write-Host "  Could not read environment variables for ${AppPoolName}: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

$appPoolListRaw = & $AppCmd list apppool /text:name
$appPoolNames = $appPoolListRaw -split "\r?\n" | Where-Object { $_ }

if ($AppPools -and @($AppPools).Count -gt 0) {
    if (@($AppPools).Count -eq 1 -and $AppPools[0].Trim().ToLower() -eq 'all') {
        $targetAppPools = $appPoolNames
    } else {
        $missing = @($AppPools | Where-Object { $appPoolNames -notcontains $_ })
        if ($missing.Count -gt 0) {
            Write-Host "Unknown App Pool(s): $($missing -join ', ')" -ForegroundColor Red
            Write-Host "Available: $($appPoolNames -join ', ')" -ForegroundColor Yellow
            exit 1
        }
        $targetAppPools = $AppPools
    }
} elseif ($mode -eq "apppool") {
    for ($i = 0; $i -lt $appPoolNames.Count; $i++) {
        Write-Host ("[{0}] {1}" -f $i, $appPoolNames[$i])
    }
    do {
        $selection = Read-Host "Enter the number of the App Pool to target"
        $isValid = $selection -match '^[0-9]+$' -and [int]$selection -ge 0 -and [int]$selection -lt $appPoolNames.Count
        if (-not $isValid) { Write-Host "Invalid selection. Try again." -ForegroundColor Red }
    } while (-not $isValid)
    $targetAppPools = @($appPoolNames[[int]$selection])
} else {
    $targetAppPools = $appPoolNames
}

Write-Host "`nTarget App Pool(s): $($targetAppPools -join ', ')" -ForegroundColor Cyan

$envsRemoved = @()
foreach ($pool in $targetAppPools) {
    $envNames = Get-AppPoolEnvVarNames -AppCmd $AppCmd -AppPoolName $pool
    $toRemove = @($instrVars | Where-Object { $envNames -contains $_ })

    if ($toRemove.Count -eq 0) { continue }

    Write-Host "`nCleaning App Pool: $pool" -ForegroundColor Cyan
    foreach ($name in $toRemove) {
        Write-Host "  Removing $name"
        & $AppCmd set apppool "/apppool.name:$pool" "/-environmentVariables.[name='$name']" | Out-Null
    }

    $envsRemoved += $pool
    if (-not $SkipAppPoolRestart) {
        Restart-WebAppPool -Name $pool -ErrorAction SilentlyContinue
    }
}

if ($envsRemoved.Count -eq 0) {
    Write-Host "`nNo instrumentation environment variables were found on the targeted App Pool(s)." -ForegroundColor Green
} else {
    Write-Host "`nCleaned instrumentation env vars from: $($envsRemoved -join ', ')" -ForegroundColor Green
}

if ($mode -ne "complete") {
    Write-Host "`nApp Pool scope only - machine settings, GAC assemblies and install directories were left in place." -ForegroundColor Cyan
    Write-Host "Re-run with -Mode complete to remove those as well." -ForegroundColor Cyan
    exit 0
}

# -----------------------------------------------------------------------------
# Step 2: machine level environment variables
# -----------------------------------------------------------------------------
Write-Host "`n========== REMOVING MACHINE-LEVEL SETTINGS ==========" -ForegroundColor Yellow
foreach ($var in $instrVars) {
    Write-Host "  Clearing $var"
    [Environment]::SetEnvironmentVariable($var, $null, "Machine")
}

# -----------------------------------------------------------------------------
# Step 3: restart IIS so no w3wp still holds the profiler DLL
# -----------------------------------------------------------------------------
if (-not $SkipIisReset) {
    Write-Host "`nPerforming IIS reset so the profiler is released..." -ForegroundColor Yellow
    # iisreset.exe lives in System32, not System32\inetsrv (that is appcmd.exe).
    $IisReset = (Get-Command iisreset.exe -ErrorAction SilentlyContinue).Source
    if (-not $IisReset) { $IisReset = "$env:SystemRoot\System32\iisreset.exe" }
    if (Test-Path $IisReset) {
        & $IisReset /noforce
    } else {
        Write-Host "iisreset.exe not found; restarting IIS services (WAS/W3SVC) directly." -ForegroundColor Yellow
        Restart-Service -Name WAS -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "`nSkipping IIS reset as requested. Files may stay locked and GAC removal may be incomplete." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Step 4: unregister assemblies from the GAC - must happen BEFORE the install
# directory is deleted, because the file list is what identifies them.
# -----------------------------------------------------------------------------
if ($KeepGacAssemblies) {
    Write-Host "`nLeaving GAC assemblies registered as requested." -ForegroundColor Yellow
} elseif (-not $installDir) {
    Write-Host "`nNo install directory found, so GAC assemblies cannot be identified." -ForegroundColor Yellow
    Write-Host "Any assemblies registered by a previous install remain in the GAC." -ForegroundColor Yellow
} else {
    Write-Host "`n========== UNREGISTERING ASSEMBLIES FROM GAC ==========" -ForegroundColor Yellow
    $netfxPath = Join-Path $installDir "netfx"
    if (-not (Test-Path $netfxPath)) {
        Write-Host "  $netfxPath not found; nothing to unregister." -ForegroundColor Yellow
    } else {
        try {
            [System.Reflection.Assembly]::Load("System.EnterpriseServices, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a") | Out-Null
            $publish = New-Object System.EnterpriseServices.Internal.Publish

            # Matches the installer: netfx root plus the framework-specific subfolders.
            $dlls = @(Get-ChildItem -Path $netfxPath -Recurse -Filter *.dll -File -ErrorAction SilentlyContinue)
            $removed = 0
            $failed = 0
            foreach ($dll in $dlls) {
                # The installer skips these, so they were never registered.
                if ($dll.Name -in @("netstandard.dll", "grpc_csharp_ext.x64.dll", "grpc_csharp_ext.x86.dll")) { continue }
                try {
                    $publish.GacRemove($dll.FullName)
                    $removed++
                } catch {
                    $failed++
                }
            }
            Write-Host "  Unregistered $removed assemblies ($failed could not be removed)." -ForegroundColor Green
        } catch {
            Write-Host "  GAC cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Assemblies may remain registered. Do not delete $installDir if you intend to retry." -ForegroundColor Yellow
        }
    }
}

# -----------------------------------------------------------------------------
# Step 5: remove directories
# -----------------------------------------------------------------------------
Write-Host "`n========== REMOVING DIRECTORIES ==========" -ForegroundColor Yellow
$targetDirs = @("C:\otel-dotnet-auto", "C:\otel-logs")
if ($installDir) { $targetDirs = @($installDir) + $targetDirs }

foreach ($dir in ($targetDirs | Sort-Object -Unique)) {
    if (-not (Test-Path $dir)) { continue }
    Write-Host "  Removing $dir"
    try {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "  Failed to remove ${dir}: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  A process may still hold files open. Re-run after an iisreset, or delete manually." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# Step 6: verify the rollback actually landed
# -----------------------------------------------------------------------------
Write-Host "`n========== VERIFICATION ==========" -ForegroundColor Yellow
$problems = @()

$leftoverMachine = @($instrVars | Where-Object { [Environment]::GetEnvironmentVariable($_, "Machine") })
if ($leftoverMachine.Count -gt 0) {
    $problems += "machine env vars still set: $($leftoverMachine -join ', ')"
} else {
    Write-Host "  Machine environment variables: clear" -ForegroundColor Green
}

$leftoverPools = @()
foreach ($pool in $appPoolNames) {
    $names = Get-AppPoolEnvVarNames -AppCmd $AppCmd -AppPoolName $pool
    if (@($instrVars | Where-Object { $names -contains $_ }).Count -gt 0) { $leftoverPools += $pool }
}
if ($leftoverPools.Count -gt 0) {
    $problems += "App Pools still instrumented: $($leftoverPools -join ', ')"
} else {
    Write-Host "  App Pool environment variables: clear" -ForegroundColor Green
}

$leftoverDirs = @($targetDirs | Where-Object { Test-Path $_ })
if ($leftoverDirs.Count -gt 0) {
    $problems += "directories still present: $($leftoverDirs -join ', ')"
} else {
    Write-Host "  Install directories: removed" -ForegroundColor Green
}

# Report - never silently remove - GAC entries left behind by earlier installs.
$gacRoot = "C:\Windows\Microsoft.NET\assembly\GAC_MSIL"
if (Test-Path $gacRoot) {
    $otelGac = @(Get-ChildItem $gacRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "OpenTelemetry*" })
    if ($otelGac.Count -gt 0) {
        Write-Host "  GAC: $($otelGac.Count) OpenTelemetry assemblies still registered, from earlier installs" -ForegroundColor Yellow
        Write-Host "       whose files are already gone, so they cannot be identified automatically." -ForegroundColor Yellow
        Write-Host "       They are inert without the profiler env vars. To list them:" -ForegroundColor Yellow
        Write-Host "       Get-ChildItem '$gacRoot' -Directory | Where-Object Name -like 'OpenTelemetry*'" -ForegroundColor DarkGray
    } else {
        Write-Host "  GAC: no OpenTelemetry assemblies registered" -ForegroundColor Green
    }
}

Write-Host ""
if ($problems.Count -gt 0) {
    Write-Host "ROLLBACK INCOMPLETE:" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host "Re-run this script, or reboot if files stayed locked." -ForegroundColor Yellow
    exit 1
}

Write-Host "ROLLBACK COMPLETE - instrumentation fully removed." -ForegroundColor Green
exit 0
