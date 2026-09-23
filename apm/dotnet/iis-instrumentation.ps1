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
    [switch]$DetectOnly
)

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

# Returns the highest assembly version an application will tolerate for the
# tracked assemblies, or $null when it places no constraint on them.
function Get-AppAssemblyCeiling {
    param([string]$Path)

    $found = @()

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
            Write-Host "    Could not parse $webConfig : $($_.Exception.Message)" -ForegroundColor Yellow
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
        Write-Host "    No conflicting assemblies found." -ForegroundColor DarkGray
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
    iisreset /noforce
}

# Run as Administrator
$AppCmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"

Write-Host "Using OTLP Endpoint: $OtlpEndpoint" -ForegroundColor Cyan
Write-Host "Using API Key: $ApiKey" -ForegroundColor Cyan

# List all App Pools
Write-Host "`n========== AVAILABLE IIS APP POOLS ==========" -ForegroundColor Yellow
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

# -----------------------------
# 2️⃣ Decide which OpenTelemetry release is safe for these applications
# -----------------------------
if ($OtelVersion -and $OtelVersion -ne "auto") {
    $resolvedOtelVersion = $OtelVersion
    Write-Host "`nUsing explicitly requested OpenTelemetry release: $resolvedOtelVersion" -ForegroundColor Cyan
} else {
    Write-Host "`n========== CHECKING APPLICATIONS FOR ASSEMBLY CONFLICTS ==========" -ForegroundColor Yellow

    $ceiling = $null
    foreach ($AppPoolName in $SelectedAppPools) {
        foreach ($path in (Get-AppPoolPhysicalPaths -AppCmd $AppCmd -AppPoolName $AppPoolName)) {
            Write-Host "  $AppPoolName -> $path"
            $appCeiling = Get-AppAssemblyCeiling -Path $path
            if ($appCeiling -and (-not $ceiling -or $appCeiling -lt $ceiling)) {
                $ceiling = $appCeiling
            }
        }
    }

    if (-not $ceiling) {
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
            throw "Aborting: no compatible OpenTelemetry release for assembly version ceiling $ceiling."
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
    return
}

Write-Host "`n========== Installing OpenTelemetry for IIS ==========" -ForegroundColor Cyan

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
$moduleUrl = if ($resolvedOtelVersion -eq "latest") {
    "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/OpenTelemetry.DotNet.Auto.psm1"
} else {
    "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/$resolvedOtelVersion/OpenTelemetry.DotNet.Auto.psm1"
}
$modulePath = Join-Path $otelBasePath "OpenTelemetry.DotNet.Auto.psm1"

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
