# recording agent installation attempt
Invoke-WebRequest -Uri https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY -Method POST -ContentType 'application/json' -Body '{
    "status": "tried",
    "metadata": {
        "script": "docker",
        "status": "ok",
        "message": "agent installed"
    }
}' | Out-Null

$MW_LOG_PATHS=""
$MW_AGENT_DOCKER_IMAGE=""

$MW_DETECTED_ARCH=$(dpkg --print-architecture)
if ($MW_DETECTED_ARCH -eq "arm64" -or $MW_DETECTED_ARCH -eq "arm32") {
  $MW_AGENT_DOCKER_IMAGE="ghcr.io/middleware-labs/agent-host-go:master"
}
else {
  $MW_AGENT_DOCKER_IMAGE="ghcr.io/middleware-labs/agent-host-go:master"
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
  Write-Host ""
}
else {
  Write-Host "Seems like docker is not already installed on the system"
  Write-Host "Please install docker first, This link might be helpful : https://docs.docker.com/engine/install/"
  exit 1
}

Write-Host "The host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]"

# conditional log path capabilities
if ($MW_ADVANCE_LOG_PATH_SETUP -eq "true") {
  while ($true) {
    $yn = Read-Host -Prompt "`nDo you want to monitor any more directories for logs ?`n[C-continue to quick install | A-advanced log path setup]`n[C|A] : "
    switch -regex ($yn) {
        "[Aa].*" {
          $MW_LOG_PATH_DIR=""
          
          while ($true) {
            $MW_LOG_PATH_DIR = Read-Host "    Enter list of comma separated paths that you want to monitor [ Ex. => /home/test, /etc/test2 ] : "
            if ($MW_LOG_PATH_DIR -match '^/|(/[\w-]+)+(,/|(/[\w-]+)+)*$') {
              break
            }
            else {
              Write-Host $MW_LOG_PATH_DIR
              Write-Host "Invalid file path, try again ..."
            }
          }

          $MW_LOG_PATH_COMPLETE=""
          $MW_LOG_PATHS_BINDING=""

          $MW_LOG_PATH_DIR_ARRAY = $MW_LOG_PATH_DIR -split ","
          foreach ($i in $MW_LOG_PATH_DIR_ARRAY) {
          $MW_LOG_PATHS_BINDING = $MW_LOG_PATHS_BINDING + " -v ${i}:${i}"
          if ($MW_LOG_PATH_COMPLETE -eq "") {
              $MW_LOG_PATH_COMPLETE = "$MW_LOG_PATH_COMPLETE$i/**/*.*"
          } else {
              $MW_LOG_PATH_COMPLETE = "$MW_LOG_PATH_COMPLETE,$i/**/*.*"
          }
}


          $MW_LOG_PATHS=$MW_LOG_PATH_COMPLETE
          Write-Host "`n------------------------------------------------"
          Write-Host "`nNow, our agent will also monitor these paths : $MW_LOG_PATH_COMPLETE"
          Write-Host "`n------------------------------------------------`n"
          Start-Sleep -Seconds 4
          break
        }
        "[Cc].*" { 
          Write-Host "`n----------------------------------------------------------`n`nOkay, Continuing installation ....`n`n----------------------------------------------------------`n"
          break
        }
        default { 
          Write-Host "`nPlease answer with c or a."
          continue
        }
    }
  }
}

docker pull $MW_AGENT_DOCKER_IMAGE


$HOSTNAME = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name Hostname).Hostname

$dockerrun="docker run -d --hostname $HOSTNAME
--name mw-agent-$($env:MW_API_KEY.Substring(0,5)) --pid host
--restart always -e MW_API_KEY=$env:MW_API_KEY
-e MW_LOG_PATHS=$env:MW_LOG_PATHS -e TARGET=$env:TARGET
-v /var/run/docker.sock:/var/run/docker.sock -v /var/log:/var/log
-v /var/lib/docker/containers:/var/lib/docker/containers -v /tmp:/tmp
$env:MW_LOG_PATHS_BINDING --privileged
-p 9319:9319 -p 9320:9320 -p 8006:8006 $env:MW_AGENT_DOCKER_IMAGE api-server start"


Set-Item -Path env:dockerrun -Value $dockerrun
Invoke-Expression $dockerrun
