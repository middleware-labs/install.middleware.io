#!/bin/bash
docker pull ghcr.io/middleware-labs/agent-host-go:master
docker run -d \
--name mw-agent-${MW_API_KEY:0:5} \
--pid host \
--restart always \
-e MW_API_KEY=$MW_API_KEY \
-e TARGET=$TARGET \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /var/log:/var/log \
--network=host ghcr.io/middleware-labs/agent-host-go:master api-server start
