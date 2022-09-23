#!/bin/bash
docker pull ghcr.io/middleware-labs/agent-host-go:dev
docker run -d \
--pid host \
--restart always \
-e MW_API_KEY=$MW_API_KEY \
-e TARGET=$TARGET \
-v /var/run/docker.sock:/var/run/docker.sock \
--privileged \
--network=host ghcr.io/middleware-labs/agent-host-go:dev api-server start