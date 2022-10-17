#!/bin/sh
sudo touch pixiecustom.yaml
sudo touch otel.yaml
sudo cp 07_pixiecustom.yaml pixiecustom.yaml
sudo cp 08_otel.yaml otel.yaml
sed -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' otel.yaml | sudo tee otel.yaml
sed -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' pixiecustom.yaml | sudo tee pixiecustom.yaml
kubectl apply -f ./
