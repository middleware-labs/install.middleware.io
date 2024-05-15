#Requires -RunAsAdministrator

$module_url = "https://install.middleware.io/apm/dotnet/v1.4.1/scripts/mw-dotnet-auto-install.psm1"
$download_path = Join-Path $env:temp "mw-dotnet-auto-install.psm1"
Invoke-WebRequest -Uri $module_url -OutFile $download_path -UseBasicParsing

# Import the module to use its functions
Import-Module $download_path

# Install core files
Install-OpenTelemetryCore
