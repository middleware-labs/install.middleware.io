#!/bin/sh
bash -c "$(curl -fsSL https://install.middleware.io/scripts/pixie-install-noauth.sh)"

# bash ./pixie-install-noauth.sh

px auth login --api_key $MW_PX_API_KEY
px deploy --deploy_key $MW_PX_DEPLOY_KEY
MW_PX_CLUSTER_ID=`px get cluster --id` && export MW_PX_CLUSTER_ID

MW_PIXIE_HOME=/usr/local/bin/mw-pixie
MW_PIXIE_DEPLOYMENT_FILE=pixie-agent-deployment.yaml
export MW_PIXIE_HOME

sudo su << EOSUDO
mkdir -p $MW_PIXIE_HOME
touch -p $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE

# wget -O $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE https://install.middleware.io/scripts/$MW_PIXIE_DEPLOYMENT_FILE

cp pixie-agent-deployment.yaml $MW_PIXIE_HOME
EOSUDO

if [ -z "${MW_KUBECONFIG}" ]; then
    sed -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE | sudo tee $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE
    kubectl apply --kubeconfig=${MW_KUBECONFIG}  -f $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE
else
    echo ${MW_PX_API_KEY}
    echo ${MW_PX_CLUSTER_ID}
    sed -e 's|MW_PX_API_KEY_VALUE|'${MW_PX_API_KEY}'|g' -e 's|MW_PX_CLUSTER_ID_VALUE|'${MW_PX_CLUSTER_ID}'|g' $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE | sudo tee $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE
    kubectl apply -f $MW_PIXIE_HOME/$MW_PIXIE_DEPLOYMENT_FILE
fi

echo 'Pixie Deployed Successfully !'
