MW_LOG_PATHS=""

DOCKERRUN="docker run -d \
--name mw-agent-${MW_API_KEY:0:5} \
--pid host \
--restart always \
-e MW_API_KEY=$MW_API_KEY \
-e TARGET=$TARGET \
-e MW_LOG_PATHS=$MW_LOG_PATHS \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /var/log:/var/log \
--privileged \
--network=host ghcr.io/middleware-labs/agent-host-go:master api-server start"

echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]"
while true; do
    read -p "Do you want to monitor any more directories for logs ? [Y|n] : " yn
    case $yn in
        [Yy]* )
          MW_LOG_PATH_DIR=""
          
          while true; do
            read -p "    Enter list of comma seperated paths that you want to monitor [ Ex. => /home/test, /etc/test2] : " MW_LOG_PATH_DIR
            export MW_LOG_PATH_DIR
            if [[ $MW_LOG_PATH_DIR =~ ^/|(/[\w-]+)+(,/|(/[\w-]+)+)*$ ]]
            then 
              break
            else
              echo $MW_LOG_PATH_DIR
              echo "Invalid file path, try again ..."
            fi
          done

          MW_LOG_PATH_COMPLETE=""

          MW_LOG_VOLUME_BINDING=""

          MW_LOG_PATH_DIR_ARRAY=($(echo $MW_LOG_PATH_DIR | tr "," "\n"))

          for i in "${MW_LOG_PATH_DIR_ARRAY[@]}"
          do
            MW_LOG_VOLUME_BINDING=$MW_LOG_VOLUME_BINDING$MW_LOG_PATH_COMPLETE
            if [ "${MW_LOG_PATH_COMPLETE}" = "" ]; then
              MW_LOG_PATH_COMPLETE="$MW_LOG_PATH_COMPLETE$i/**/*.*"
            else
              MW_LOG_PATH_COMPLETE="$MW_LOG_PATH_COMPLETE,$i/**/*.*"
            fi
          done

          export MW_LOG_PATH_COMPLETE

          MW_LOG_PATHS=$MW_LOG_PATH_COMPLETE
          export MW_LOG_PATHS
          echo -e "\n------------------------------------------------"
          echo -e "\nNow, our agent will also monitor these paths : "$MW_LOG_PATH_COMPLETE
          echo -e "\n------------------------------------------------\n"
          sleep 4
          break;;
        [Nn]* ) 
          echo -e "\n----------------------------------------------------------\n\nOkay, Continuing installation ....\n\n----------------------------------------------------------\n"
          break;;
        * ) 
          echo -e "\nPlease answer y or n."
          continue;;
    esac
done

#!/bin/bash
docker pull ghcr.io/middleware-labs/agent-host-go:master
eval $DOCKERRUN
