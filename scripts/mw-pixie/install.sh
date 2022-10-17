#!/bin/sh
MW_PIXIE_SCRIPT_HOME=/usr/bin/mw-pixie
export MW_PIXIE_SCRIPT_HOME

sudo su << EOSUDO
mkdir -p $MW_PIXIE_SCRIPT_HOME

touch -p $MW_KUBE_AGENT_HOME_GO/00_nm.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/00_nm.yaml https://install.middleware.io/scripts/mw-pixie/00_nm.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/00_olm_crd.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/00_olm_crd.yaml https://install.middleware.io/scripts/mw-pixie/00_olm_crd.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/01_vizier_crd.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/01_vizier_crd.yaml https://install.middleware.io/scripts/mw-pixie/01_vizier_crd.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/02_olm.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/02_olm.yaml https://install.middleware.io/scripts/mw-pixie/02_olm.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/03_px_olm.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/03_px_olm.yaml https://install.middleware.io/scripts/mw-pixie/03_px_olm.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/04_catalog.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/04_catalog.yaml https://install.middleware.io/scripts/mw-pixie/04_catalog.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/05_subscription.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/05_subscription.yaml https://install.middleware.io/scripts/mw-pixie/05_subscription.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/06_vizier.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/06_vizier.yaml https://install.middleware.io/scripts/mw-pixie/06_vizier.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/07_pixiecustom.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/07_pixiecustom.yaml https://install.middleware.io/scripts/mw-pixie/07_pixiecustom.yaml

touch -p $MW_KUBE_AGENT_HOME_GO/08_otel.yaml
wget -O $MW_KUBE_AGENT_HOME_GO/08_otel.yaml https://install.middleware.io/scripts/mw-pixie/08_otel.yaml


EOSUDO

cd $MW_PIXIE_SCRIPT_HOME
sudo touch pixiecustom.yaml
sudo touch otel.yaml
sudo cp 07_pixiecustom.yaml pixiecustom.yaml
sudo cp 08_otel.yaml otel.yaml
sed -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' otel.yaml | sudo tee otel.yaml
sed -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_API_KEY_VALUE|'${MW_API_KEY}'|g' -e 's|MW_TARGET_VALUE|'${MW_TARGET}'|g' -e 's|NAMESPACE_VALUE|mw-agent-ns-'${MW_API_KEY:0:5}'|g' pixiecustom.yaml | sudo tee pixiecustom.yaml
kubectl apply -f $MW_PIXIE_SCRIPT_HOME
