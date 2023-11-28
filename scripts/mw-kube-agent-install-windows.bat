@echo off
setlocal EnableDelayedExpansion

REM Extracting hour, minute, and seconds from TIME
for /F "tokens=1-3 delims=:" %%a in ("%TIME%") do (
    set "hour=%%a"
    set "min=%%b"
    set "sec=%%c"
)
REM Added to convert seconds to integer
set /A sec=sec

REM Generating log file name with date and time stamps
REM set LOGFILE=%SystemRoot%\System32\winevt\Logs\mw-kube-agent\mw-kube-agent-install-%DATE%-%hour%_%min%_%sec%.log

set LOGFILE="Some.log" 

REM Creating directory for log file if it doesn't exist
if not exist "%SystemRoot%\System32\winevt\Logs\mw-kube-agent" (
    mkdir "%SystemRoot%\System32\winevt\Logs\mw-kube-agent"
)

REM Creating an empty log file
type nul > %LOGFILE%

REM Redirecting all output to the log file
(
  call :main
)  >> %LOGFILE% 2>&1
if flag==1 (
  echo "Middleware Kubernetes agent successfully installed"
) else (
  echo "MW_KUBE_AGENT_INSTALL_METHOD environment variable not set to 'helm' or 'manifest'"
)
exit /b

:main
  echo "Setting up Middleware Kubernetes agent ..."

  REM Setting up Namespaces
  set MW_DEFAULT_NAMESPACE="mw-agent-ns"
  set MW_NAMESPACE=%MW_NAMESPACE%
  if "%MW_NAMESPACE%"=="" (
    set "MW_NAMESPACE=%MW_DEFAULT_NAMESPACE%"
  )

  for /f %%I in ('kubectl config current-context') do set "CURRENT_CONTEXT=%%I"
  
  REM To get current cluster name
  kubectl config view -o jsonpath="{.contexts[?(@.name == '%CURRENT_CONTEXT%')].context.cluster}" > temp.txt
  set /p MW_KUBE_CLUSTER_NAME=<temp.txt
  del temp.txt


  echo "cluster : %MW_KUBE_CLUSTER_NAME%"
  echo "context : %CURRENT_CONTEXT%"

  if "%MW_KUBE_AGENT_INSTALL_METHOD%"=="" (
    echo "MW_KUBE_AGENT_INSTALL_METHOD environment variable not set to 'helm' or 'manifest'"
    set flag=0
    goto :scriptEnd 
  )
  if %MW_KUBE_AGENT_INSTALL_METHOD%=="manifest" (
    echo "Middleware Kubernetes agent is being installed using manifest files, please wait ..."
    if not exist "%SystemRoot%\MW_Agent\bin\mw-kube-agent" (
      mkdir %SystemRoot%\MW_Agent\bin\mw-kube-agent
    )
    type nul > "MW_KUBE_AGENT_HOME"
    powershell -command "(New-Object System.Net.WebClient).DownloadFile('https://install.middleware.io/scripts/mw-kube-agent.yaml', '%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml')"
    if "%MW_KUBECONFIG%"=="" (
      powershell -command "(Get-Content '%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml' -Raw) -replace 'MW_KUBE_CLUSTER_NAME_VALUE', '%MW_KUBE_CLUSTER_NAME%' -replace 'MW_ROLLOUT_RESTART_RULE', '%MW_ROLLOUT_RESTART_RULE%' -replace 'MW_LOG_PATHS', '%MW_LOG_PATHS%' -replace 'MW_DOCKER_ENDPOINT_VALUE', '%MW_DOCKER_ENDPOINT%' -replace 'MW_API_KEY_VALUE', '%MW_API_KEY%' -replace 'TARGET_VALUE', '%MW_TARGET%' -replace 'NAMESPACE_VALUE', '%MW_NAMESPACE%' | Set-Content '%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml'"
      kubectl create -f "%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml"
      kubectl -n %MW_NAMESPACE% rollout restart daemonset/mw-kube-agent
    ) else (
      powershell -command "(Get-Content '%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml' -Raw) -replace 'MW_KUBE_CLUSTER_NAME_VALUE', '%MW_KUBE_CLUSTER_NAME%' -replace 'MW_ROLLOUT_RESTART_RULE', '%MW_ROLLOUT_RESTART_RULE%' -replace 'MW_LOG_PATHS', '%MW_LOG_PATHS%' -replace 'MW_DOCKER_ENDPOINT_VALUE', '%MW_DOCKER_ENDPOINT%' -replace 'MW_API_KEY_VALUE', '%MW_API_KEY%' -replace 'TARGET_VALUE', '%MW_TARGET%' -replace 'NAMESPACE_VALUE', '%MW_NAMESPACE%' | Set-Content '%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml'"
      kubectl create --kubeconfig="%MW_KUBECONFIG%" -f "%SystemRoot%\MW_Agent\bin\mw-kube-agent\agent.yaml"
      kubectl --kubeconfig="%MW_KUBECONFIG%" -n %MW_NAMESPACE% rollout restart daemonset/mw-kube-agent
    )
  )
  if %MW_KUBE_AGENT_INSTALL_METHOD%=="helm" (
    echo "Middleware helm chart is being installed, please wait ..."
    helm repo add middleware.io https://helm.middleware.io
    helm install --set mw.target=%MW_TARGET% --set mw.apiKey=%MW_API_KEY% --wait mw-kube-agent middleware.io/mw-kube-agent -n %MW_NAMESPACE% --create-namespace
  )
  echo "Middleware Kubernetes agent successfully installed !"
  set flag=1
  :scriptEnd
  exit /b
