#!/bin/bash

# Script to generate barebone values.yaml file for mw-kube-agent-v3 Helm chart

# Function to get cluster name from kubectl context
get_cluster_from_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        echo "kubectl found, attempting to get cluster name from context..." >&2
        
        CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo "")"
        if [ -n "$CURRENT_CONTEXT" ]; then
            KUBECTL_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}" 2>/dev/null || echo "")"
            if [ -n "$KUBECTL_CLUSTER_NAME" ]; then
                echo "Found cluster name from kubectl context: $KUBECTL_CLUSTER_NAME" >&2
                echo "$KUBECTL_CLUSTER_NAME"
                return 0
            fi
        fi
        echo "Could not determine cluster name from kubectl context" >&2
    else
        echo "kubectl not found in PATH, skipping context detection" >&2
    fi
    return 1
}

# Determine cluster name priority:
# 1. MW_KUBE_CLUSTER_NAME environment variable
# 2. Cluster name from kubectl context
# 3. Default fallback
if [ -n "$MW_KUBE_CLUSTER_NAME" ]; then
    CLUSTER_NAME="$MW_KUBE_CLUSTER_NAME"
    echo "Using cluster name from MW_KUBE_CLUSTER_NAME environment variable: $CLUSTER_NAME"
else
    KUBECTL_CLUSTER_NAME="$(get_cluster_from_kubectl || echo "")"
    if [ -n "$KUBECTL_CLUSTER_NAME" ]; then
        CLUSTER_NAME="$KUBECTL_CLUSTER_NAME"
    else
        CLUSTER_NAME="my-k8s-cluster"
        echo "Using default cluster name: $CLUSTER_NAME"
    fi
fi

# Enable strict error handling after cluster name is determined
set -e

# Check if required environment variables are set
if [ -z "$MW_API_KEY" ]; then
    echo "Error: MW_API_KEY environment variable is not set"
    echo "Please set it with: export MW_API_KEY=your_api_key"
    exit 1
fi

if [ -z "$MW_TARGET" ]; then
    echo "Error: MW_TARGET environment variable is not set"
    echo "Please set it with: export MW_TARGET=your_target_url"
    exit 1
fi

# Generate the values.yaml file
cat > generated_values.yaml << EOF
global:
  mw:
    apiKey: ${MW_API_KEY}
    target: ${MW_TARGET}
  clusterMetadata:
    name: ${CLUSTER_NAME}
mw-autoinstrumentation:
  enabled: false
EOF

echo ""
echo "Generated generated_values.yaml with the following configuration:"
echo "- API Key: ${MW_API_KEY:0:10}..."
echo "- Target: ${MW_TARGET}"
echo "- Cluster Name: ${CLUSTER_NAME}"
echo ""
echo "You can now install the Helm chart using:"
echo "helm install mw-agent middleware-labs/mw-kube-agent-v3 -f generated_values.yaml -n mw-agent-ns --create-namespace"