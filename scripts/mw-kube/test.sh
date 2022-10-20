#!/bin/sh
while [ -z `kubectl get secret pl-cluster-secrets -n pl -o jsonpath="{.data.cluster-id}"` ]; do echo "Waiting for Cluster ID"; sleep 1m; done