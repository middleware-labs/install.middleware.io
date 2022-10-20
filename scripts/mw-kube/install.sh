#!/bin/sh
MW_PIXIE_SCRIPT_HOME=/usr/bin/mw-kube
export MW_PIXIE_SCRIPT_HOME

sudo su << EOSUDO
mkdir -p $MW_PIXIE_SCRIPT_HOME

touch -p $MW_PIXIE_SCRIPT_HOME/01_pixie.yaml
wget -O $MW_PIXIE_SCRIPT_HOME/01_pixie.yaml https://install.middleware.io/scripts/mw-kube/01_pixie.yaml

touch -p $MW_PIXIE_SCRIPT_HOME/02_pixiecustom.yaml
wget -O $MW_PIXIE_SCRIPT_HOME/02_pixiecustom.yaml https://install.middleware.io/scripts/mw-kube/02_pixiecustom.yaml

touch -p $MW_PIXIE_SCRIPT_HOME/03_otel.yaml
wget -O $MW_PIXIE_SCRIPT_HOME/03_otel.yaml https://install.middleware.io/scripts/mw-kube/03_otel.yaml


EOSUDO

cd $MW_PIXIE_SCRIPT_HOME
sudo touch pixiecustom.yaml
sudo touch otel.yaml
sudo cp 02_pixiecustom.yaml pixiecustom.yaml
sudo cp 03_otel.yaml otel.yaml
sudo rm 02_pixiecustom.yaml
sudo rm 03_otel.yaml
kubectl apply -f $MW_PIXIE_SCRIPT_HOME/01_pixie.yaml

while ! kubectl get secret pl-cluster-secrets -n pl; do echo "Waiting for Cluster ID"; sleep 1m; done

MW_PX_CLUSTER_ID=`kubectl get secret pl-cluster-secrets -n pl -o jsonpath="{.data.cluster-id}" | base64 -d`
export MW_PX_CLUSTER_ID
echo $MW_PX_CLUSTER_ID

sed -e 's|MW_PX_DEPLOY_KEY_VALUE|'${MW_PX_DEPLOY_KEY}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|MW_NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' otel.yaml | sudo tee otel.yaml
sed -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|MW_NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' pixiecustom.yaml | sudo tee pixiecustom.yaml

kubectl apply -f $MW_PIXIE_SCRIPT_HOME/pixiecustom.yaml
kubectl apply -f $MW_PIXIE_SCRIPT_HOME/otel.yaml