#Requires -PSEdition Desktop

# Accept OTLP endpoint and API key as arguments or environment variables
param(
    [string]$OtlpEndpoint = $env:OTEL_EXPORTER_OTLP_ENDPOINT,
    [string]$ApiKey = $env:OTEL_EXPORTER_OTLP_API_KEY,

    # OpenTelemetry .NET Auto-Instrumentation release to install.
    #   "auto"    - inspect the selected App Pools and pick a compatible release (default)
    #   "latest"  - always take the newest release
    #   "vX.Y.Z"  - pin explicitly, skipping detection
    [string]$OtelVersion = "auto",

    # Skips the GitHub release/attestation check that Install-OpenTelemetryCore does
    # from v1.17.0 onward, which needs the GitHub CLI ("gh") on the machine.
    [switch]$SkipReleaseVerification,

    # Read-only dry run: report which App Pools would be instrumented, what the
    # applications bind the shared assemblies to, and which release would be
    # installed. Changes nothing - no env vars, no IIS reset, no install.
    [switch]$DetectOnly,

    # App Pool name(s) to instrument, or "all". Supplying this skips every
    # interactive prompt so the script can run unattended (Run Command, SSM,
    # scheduled deploys). Omit it to pick pools interactively.
    [string[]]$AppPools
)

$nonInteractive = $AppPools -and @($AppPools).Count -gt 0

# -----------------------------------------------------------------------------
# OpenTelemetry release compatibility
#
# Each release hard-codes the assembly versions its native profiler rewrites
# references to. A .NET Framework app that binds these assemblies LOWER than the
# release requires will throw MissingMethodException during PreApplicationStart
# and return HTTP 500 for every request, because web.config binding redirects
# take precedence over anything the instrumentation does at runtime.
#
# Values below are the highest version each release rewrites the tracked
# assemblies to, taken from assembly_redirection_netfx.h in the OTel repo.
# Ordered newest first - selection walks down until it finds one the app allows.
# -----------------------------------------------------------------------------
$OtelReleaseBaselines = [ordered]@{
    "v1.17.0" = "10.0.0.12"
    "v1.16.0" = "10.0.0.9"
    "v1.15.0" = "10.0.0.7"
    "v1.14.1" = "10.0.0.2"
    "v1.13.0" = "10.0.0.0"
    "v1.12.0" = "9.0.0.6"
    "v1.11.0" = "9.0.0.2"
    "v1.10.0" = "9.0.0.1"
    "v1.9.0"  = "8.0.0.2"
}
$NewestOtelVersion = @($OtelReleaseBaselines.Keys)[0]

# Assemblies the instrumentation shares with the application. A version conflict
# on any one of these is enough to break startup.
$TrackedAssemblies = @(
    "Microsoft.Extensions.Configuration",
    "Microsoft.Extensions.Configuration.Abstractions",
    "Microsoft.Extensions.Configuration.Binder",
    "Microsoft.Extensions.Configuration.EnvironmentVariables",
    "Microsoft.Extensions.DependencyInjection",
    "Microsoft.Extensions.DependencyInjection.Abstractions",
    "Microsoft.Extensions.Diagnostics.Abstractions",
    "Microsoft.Extensions.Logging",
    "Microsoft.Extensions.Logging.Abstractions",
    "Microsoft.Extensions.Logging.Configuration",
    "Microsoft.Extensions.Options",
    "Microsoft.Extensions.Options.ConfigurationExtensions",
    "Microsoft.Extensions.Primitives",
    "System.Diagnostics.DiagnosticSource"
)

# appcmd has no scalar query for the environmentVariables collection
# ("list apppool /text:environmentVariables" fails with "Unknown attribute"), and
# Get-ItemProperty's .Collection came back empty in some sessions. Parsing the
# config XML is the reliable route. Without this, existing variables are
# invisible and stale ones (CORECLR_*, DOTNET_STARTUP_HOOKS) never get removed.
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
        Write-Host "  Could not read existing environment variables for ${AppPoolName}: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

# Resolves every on-disk location served by an App Pool.
function Get-AppPoolPhysicalPaths {
    param(
        [string]$AppCmd,
        [string]$AppPoolName
    )

    $paths = @()
    $appNames = & $AppCmd list app /apppool.name:"$AppPoolName" /text:app.name 2>$null
    foreach ($appName in ($appNames -split "\r?\n" | Where-Object { $_ -ne "" })) {
        $vdirs = & $AppCmd list vdir /app.name:"$appName" /text:physicalPath 2>$null
        foreach ($vdir in ($vdirs -split "\r?\n" | Where-Object { $_ -ne "" })) {
            $expanded = [Environment]::ExpandEnvironmentVariables($vdir)
            if (Test-Path $expanded) {
                $paths += $expanded
            }
        }
    }

    return @($paths | Sort-Object -Unique)
}

# Config binding redirects only govern .NET Framework app pools. A "No Managed
# Code" pool hosts .NET (Core) / .NET 5+, which resolves assemblies through
# AssemblyLoadContext instead, so none of the version ceiling logic applies.
function Test-IsNetFrameworkAppPool {
    param(
        [string]$AppCmd,
        [string]$AppPoolName
    )

    $runtime = & $AppCmd list apppool /name:"$AppPoolName" /text:managedRuntimeVersion 2>$null
    return -not [string]::IsNullOrWhiteSpace((@($runtime) -join "").Trim())
}

# Returns the highest assembly version an application will tolerate for the
# tracked assemblies, or $null when it places no constraint on them.
function Get-AppAssemblyCeiling {
    param([string]$Path)

    $found = @()
    $parseFailed = $false

    # Binding redirects are authoritative - they override the instrumentation.
    $webConfig = Join-Path $Path "web.config"
    if (Test-Path $webConfig) {
        try {
            $xml = [xml](Get-Content -LiteralPath $webConfig -Raw)
            $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $nsm.AddNamespace("asm", "urn:schemas-microsoft-com:asm.v1")
            foreach ($node in $xml.SelectNodes("//asm:dependentAssembly", $nsm)) {
                $identity = $node.SelectSingleNode("asm:assemblyIdentity", $nsm)
                $redirect = $node.SelectSingleNode("asm:bindingRedirect", $nsm)
                if (-not $identity -or -not $redirect) { continue }
                if ($TrackedAssemblies -notcontains $identity.name) { continue }

                $parsed = $null
                if ([version]::TryParse($redirect.newVersion, [ref]$parsed)) {
                    $found += [pscustomobject]@{
                        Name    = $identity.name
                        Version = $parsed
                        Source  = "web.config redirect"
                    }
                }
            }
        } catch {
            # An unreadable config must never be reported as "no conflicts" - it may
            # pin versions below what the instrumentation needs.
            Write-Host "    Could not parse ${webConfig}: $($_.Exception.Message)" -ForegroundColor Red
            $script:configParseFailures += $webConfig
            $parseFailed = $true
        }
    }

    # Without a redirect, whatever ships in bin\ is what gets loaded.
    $bin = Join-Path $Path "bin"
    if (Test-Path $bin) {
        foreach ($name in $TrackedAssemblies) {
            if ($found.Name -contains $name) { continue }
            $dll = Join-Path $bin "$name.dll"
            if (-not (Test-Path $dll)) { continue }
            try {
                $found += [pscustomobject]@{
                    Name    = $name
                    Version = [System.Reflection.AssemblyName]::GetAssemblyName($dll).Version
                    Source  = "bin"
                }
            } catch {
                Write-Host "    Could not read $dll : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if ($found.Count -eq 0) {
        # Saying "no conflicts" after a parse failure would contradict the warning.
        if (-not $parseFailed) {
            Write-Host "    No conflicting assemblies found." -ForegroundColor DarkGray
        }
        return $null
    }

    foreach ($entry in ($found | Sort-Object Name)) {
        Write-Host ("    {0,-55} {1,-12} ({2})" -f $entry.Name, $entry.Version, $entry.Source)
    }

    return ($found | Sort-Object Version | Select-Object -First 1).Version
}

# Newest release whose required versions the application can already satisfy.
# Compared on major version only: that is where the API and type-identity breaks
# happen. A gap in the servicing revision (8.0.0.0 vs 8.0.0.2) is binary
# compatible and safe to redirect across.
function Select-OtelVersion {
    param([version]$Ceiling)

    foreach ($release in $OtelReleaseBaselines.Keys) {
        if (([version]$OtelReleaseBaselines[$release]).Major -le $Ceiling.Major) {
            return $release
        }
    }
    return $null
}

if (-not $DetectOnly) {
    Write-Host "========== CLEANING OLD OPEN TELEMETRY SETTINGS ==========" -ForegroundColor Yellow
}

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

if (-not $DetectOnly) {
    foreach ($var in $oldEnvVars) {
        Write-Host "Cleaning up.. $var"
        [Environment]::SetEnvironmentVariable($var, $null, "Machine")
    }

    # Restart IIS to ensure old profiler references are gone
    Write-Host "Performing IIS reset..."
    # iisreset.exe lives in System32, not System32\inetsrv (that is appcmd.exe).
    # Prefer whatever PATH resolves, then fall back to the known location.
    $IisReset = (Get-Command iisreset.exe -ErrorAction SilentlyContinue).Source
    if (-not $IisReset) { $IisReset = "$env:SystemRoot\System32\iisreset.exe" }
    if (Test-Path $IisReset) {
        & $IisReset /noforce
    } else {
        Write-Host "iisreset.exe not found; restarting IIS services (WAS/W3SVC) directly." -ForegroundColor Yellow
        Restart-Service -Name WAS -Force -ErrorAction SilentlyContinue
    }
}

# Run as Administrator
$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
Import-Module WebAdministration -ErrorAction SilentlyContinue

Write-Host "Using OTLP Endpoint: $OtlpEndpoint" -ForegroundColor Cyan
Write-Host "Using API Key: $ApiKey" -ForegroundColor Cyan

# List all App Pools
Write-Host "`n========== AVAILABLE IIS APP POOLS ==========" -ForegroundColor Yellow
# Must not be named $appPools: PowerShell variable names are case-insensitive,
# so that would overwrite the $AppPools parameter with every pool on the box.
$appPoolListRaw = & $AppCmd list apppool /text:name
$appPoolsArray = $appPoolListRaw -split "\r?\n" | Where-Object { $_ -ne "" }

for ($i = 0; $i -lt $appPoolsArray.Count; $i++) {
    Write-Host ("[{0}] {1}" -f $i, $appPoolsArray[$i])
}

if ($nonInteractive) {
    # Names supplied on the command line - no prompting.
    if (@($AppPools).Count -eq 1 -and $AppPools[0].Trim().ToLower() -eq 'all') {
        $selectedIndices = @(0..($appPoolsArray.Count - 1))
    } else {
        $missing = @($AppPools | Where-Object { $appPoolsArray -notcontains $_ })
        if ($missing.Count -gt 0) {
            Write-Host "`nUnknown App Pool(s): $($missing -join ', ')" -ForegroundColor Red
            Write-Host "Available: $($appPoolsArray -join ', ')" -ForegroundColor Yellow
            exit 1
        }
        $selectedIndices = @($AppPools | ForEach-Object { [array]::IndexOf($appPoolsArray, $_) })
    }
} else {

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

}

$SelectedAppPools = $selectedIndices | ForEach-Object { $appPoolsArray[$_] }
Write-Host "Selected App Pool(s): $($SelectedAppPools -join ', ')" -ForegroundColor Cyan

# -----------------------------
# 2️⃣ Decide which OpenTelemetry release is safe for these applications
# -----------------------------
if ($OtelVersion -and $OtelVersion -ne "auto") {
    $resolvedOtelVersion = $OtelVersion
    Write-Host "`nUsing explicitly requested OpenTelemetry release: $resolvedOtelVersion" -ForegroundColor Cyan
} else {
    Write-Host "`n========== CHECKING APPLICATIONS FOR ASSEMBLY CONFLICTS ==========" -ForegroundColor Yellow

    $ceiling = $null
    $pathsInspected = 0
    $script:configParseFailures = @()
    foreach ($AppPoolName in $SelectedAppPools) {
        if (-not (Test-IsNetFrameworkAppPool -AppCmd $AppCmd -AppPoolName $AppPoolName)) {
            Write-Host "  $AppPoolName -> No Managed Code (.NET Core / .NET 5+); binding redirects do not apply, skipping check." -ForegroundColor DarkGray
            continue
        }
        foreach ($path in (Get-AppPoolPhysicalPaths -AppCmd $AppCmd -AppPoolName $AppPoolName)) {
            Write-Host "  $AppPoolName -> $path"
            $pathsInspected++
            $appCeiling = Get-AppAssemblyCeiling -Path $path
            if ($appCeiling -and (-not $ceiling -or $appCeiling -lt $ceiling)) {
                $ceiling = $appCeiling
            }
        }
    }

    if ($script:configParseFailures.Count -gt 0) {
        Write-Host "`nCould not parse the following web.config file(s), so their assembly bindings are unknown:" -ForegroundColor Red
        foreach ($f in $script:configParseFailures) { Write-Host "  $f" -ForegroundColor Red }
        Write-Host "Refusing to guess: an unreadable config may bind Microsoft.Extensions.* below what the" -ForegroundColor Red
        Write-Host "instrumentation requires, which would break the site at startup." -ForegroundColor Red
        Write-Host "Fix the file, or re-run with -OtelVersion to choose a release explicitly." -ForegroundColor Yellow
        exit 1
    }

    if ($pathsInspected -eq 0) {
        # No application directory was resolved, so nothing was actually checked.
        # Say so rather than reporting a clean result nobody verified.
        $resolvedOtelVersion = $NewestOtelVersion
        Write-Host "`nNo application paths resolved for the selected App Pool(s) - nothing could be checked." -ForegroundColor Yellow
        Write-Host "Defaulting to $resolvedOtelVersion. Verify the apps do not bind Microsoft.Extensions.* below $($OtelReleaseBaselines[$resolvedOtelVersion])." -ForegroundColor Yellow
    } elseif (-not $ceiling) {
        $resolvedOtelVersion = $NewestOtelVersion
        Write-Host "`nNo conflicting assemblies detected. Using $resolvedOtelVersion." -ForegroundColor Green
    } else {
        $resolvedOtelVersion = Select-OtelVersion -Ceiling $ceiling
        if (-not $resolvedOtelVersion) {
            Write-Host ""
            Write-Host "No OpenTelemetry release is compatible with these applications." -ForegroundColor Red
            $oldestRelease = @($OtelReleaseBaselines.Keys)[-1]
            Write-Host "The lowest version they bind is $ceiling; the oldest available release ($oldestRelease) needs $($OtelReleaseBaselines[$oldestRelease])." -ForegroundColor Red
            Write-Host "Instrumenting anyway would break the site with HTTP 500 at startup." -ForegroundColor Red
            Write-Host "Either raise the binding redirects in the application's web.config, or re-run with -OtelVersion to override this check." -ForegroundColor Yellow
            Write-Host "Aborting: nothing was installed or changed." -ForegroundColor Red
            exit 1
        }
        Write-Host "`nApplications bind these assemblies at $ceiling or lower." -ForegroundColor Cyan
        Write-Host "Selected OpenTelemetry $resolvedOtelVersion (requires $($OtelReleaseBaselines[$resolvedOtelVersion]))." -ForegroundColor Green
        if ($resolvedOtelVersion -ne $NewestOtelVersion) {
            Write-Host "Note: this is older than the newest release ($NewestOtelVersion). To use the newest one, raise the application's binding redirects first." -ForegroundColor Yellow
        }
    }
}

if ($DetectOnly) {
    Write-Host "`n-DetectOnly was specified: nothing was installed or changed." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n========== Installing OpenTelemetry for IIS ==========" -ForegroundColor Cyan

# Create base directory (for module only)
$otelBasePath = "C:\otel-dotnet-auto"

if (Test-Path $otelBasePath) {
    Write-Host "`nDirectory $otelBasePath already exists." -ForegroundColor Yellow
    if ($nonInteractive) {
        Write-Host "Running unattended: re-downloading so the module matches $resolvedOtelVersion." -ForegroundColor Cyan
        $choice = 'd'
    } else {
        $choice = Read-Host "Type 's' to skip downloading, or 'd' to delete and re-download"
    }
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
$moduleUrl = if ($resolvedOtelVersion -eq "latest") {
    "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
} else {
    "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$resolvedOtelVersion/OpenTelemetry.DotNet.Auto.psm1"
}
$modulePath = Join-Path $otelBasePath "OpenTelemetry.DotNet.Auto.psm1"

# A cached module pins its own release, so reusing one from a different version
# would quietly install something other than what was selected above.
if ($skipDownload -and $resolvedOtelVersion -ne "latest" -and (Test-Path $modulePath)) {
    $match = Select-String -Path $modulePath -Pattern '^\s*\$version\s*=\s*"(v[0-9.]+)"' | Select-Object -First 1
    $cachedVersion = if ($match) { $match.Matches[0].Groups[1].Value } else { $null }
    if ($cachedVersion -and $cachedVersion -ne $resolvedOtelVersion) {
        Write-Host "`nCached module in $otelBasePath is $cachedVersion, but $resolvedOtelVersion was selected." -ForegroundColor Red
        Write-Host "Re-run without skipping the download, or delete $otelBasePath first." -ForegroundColor Yellow
        exit 1
    }
}

if (-not $skipDownload) {
    Write-Host "Downloading OpenTelemetry module ($resolvedOtelVersion)..."
    Invoke-WebRequest -Uri $moduleUrl -OutFile $modulePath -UseBasicParsing

    # Import the module
    Import-Module $modulePath -Force

    # Install OpenTelemetry Core
    Write-Host "Installing OpenTelemetry Core..."
    # Release verification (and the "gh" dependency it brings) only exists from v1.17.0 on.
    if (-not (Get-Command Install-OpenTelemetryCore).Parameters.ContainsKey("SkipReleaseVerification")) {
        Install-OpenTelemetryCore
    } elseif ($SkipReleaseVerification) {
        Install-OpenTelemetryCore -SkipReleaseVerification
    } elseif (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
        throw "Install-OpenTelemetryCore verifies the release with the GitHub CLI ('gh'), which is not installed. Install it from https://cli.github.com/ or re-run this script with -SkipReleaseVerification."
    } else {
        Install-OpenTelemetryCore
    }
} else {
    Write-Host "Module download and install steps skipped as requested." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✅ INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "✅ CLOSE VISUAL STUDIO COMPLETELY"
Write-Host "✅ REOPEN IT AND RUN USING IIS EXPRESS"
Write-Host ""

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
    $currentEnvVarNames = Get-AppPoolEnvVarNames -AppCmd $AppCmd -AppPoolName $AppPoolName

    $appPoolEnvVarsToRemove = ($oldEnvVars + $envs.Keys) | Sort-Object -Unique
    foreach ($name in $appPoolEnvVarsToRemove) {
        if ($currentEnvVarNames -contains $name) {
            Write-Host "  Unsetting $name"
            & $AppCmd set apppool "/apppool.name:$AppPoolName" "/-environmentVariables.[name='$name']" | Out-Null
        }
    }

    # Refresh after unsetting so the add loop knows what is still present.
    $currentEnvVarNames = Get-AppPoolEnvVarNames -AppCmd $AppCmd -AppPoolName $AppPoolName

    foreach ($name in $envs.Keys) {
        # No backslash escaping: appcmd stores the value verbatim, and escaping
        # here turned every "\" in a path into "\\\\" in applicationHost.config.
        $value = $envs[$name]

        # Only remove when present, otherwise appcmd prints "Cannot find
        # requested collection element" for each variable.
        if ($currentEnvVarNames -contains $name) {
            & $AppCmd set apppool "/apppool.name:$AppPoolName" "/-environmentVariables.[name='$name']" | Out-Null
        }

        Write-Host "  Setting $name = $value"
        & $AppCmd set apppool "/apppool.name:$AppPoolName" "/+environmentVariables.[name='$name',value='$value']" | Out-Null
    }
    Write-Host "✅ All environment variables set for App Pool: $AppPoolName"
    Restart-WebAppPool -Name $AppPoolName
}
Write-Host "Done!"
exit 0
