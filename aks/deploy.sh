#!/bin/bash

#
# This is a script that deploys BigBang into Azure via AKS
#

scriptPath=$(dirname "$0")

test -f secrets.sh        || { echo -e "💥 Error! secrets.sh not found, please create"; exit 1; }
test -f deploy-vars.sh    || { echo -e "💥 Error! deploy-vars.sh not found, please create"; exit 1; }
which sops > /dev/null    || { echo -e "💥 Error! Command sops not installed"; exit 1; }
which az > /dev/null      || { echo -e "💥 Error! Command az not installed"; exit 1; }
which kubectl > /dev/null || { echo -e "💥 Error! Command kubectl not installed"; exit 1; }

source $scriptPath/secrets.sh
source $scriptPath/deploy-vars.sh

for varName in IRON_BANK_USER IRON_BANK_PAT GITHUB_USER GITHUB_PAT; do
  varVal=$(eval echo "\${$varName}")
  [[ -z $varVal ]] && { echo "💥 Error! Required variable '$varName' is not set!"; varUnset=true; }
done
[[ $varUnset ]] && exit 1

echo -e "\n\e[34m/=========================================\\"
echo -e "|   BigBang Automated Deployer  v0.1 🚀   |"
echo -e "\e[34m\\=========================================/\e[39m"

echo 
read -p "Are you sure you want to proceed? " -n 1 -r
echo 
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi

# This part creates the GPG keys without user input
gpg -K $GPG_KEY_NAME > /dev/null 2>&1
if [[ $? == "2" ]]; then
  echo -e "\e[36m###\e[33m 🔑 Creating GPG keys unattended\e[39m"
  gpg --quick-generate-key --batch --passphrase='' $GPG_KEY_NAME
  fingerPrint=$(gpg -K $GPG_KEY_NAME | sed -e 's/ *//;2q;d;')
  gpg --quick-add-key --batch --passphrase='' "${fingerPrint}" rsa4096 encr

  # Check if .sops.yaml already has a fingerprint
  grep 'pgp: FALSE_KEY_HERE' ../.sops.yaml > /dev/null 2>&1
  if [[ $? != "0" ]]; then
    echo -e "\e[31m### ERROR! Unable to update .sops.yaml, remove existing fingerprint and replace with FALSE_KEY_HERE"
    echo -e "\e[31m### ERROR! New GPG key will be removed, and deployment stopped"
    # Roll back new key
    gpg --batch --yes --delete-secret-keys "${fingerPrint}"
    gpg --batch --yes --delete-key "${fingerPrint}"
    exit 1
  fi

  echo -e "\e[36m###\e[33m 🧬 Updating .sops.yaml in git\e[39m"
  sed -i "s/pgp: FALSE_KEY_HERE/pgp: ${fingerPrint}/" $scriptPath/../.sops.yaml
  git add $scriptPath/../.sops.yaml
  git commit -m "Updated .sops.yaml by deployment script $(date)"
  git push
fi

fingerPrint=$(gpg -K $GPG_KEY_NAME | sed -e 's/ *//;2q;d;')
echo -e "\e[36m###\e[33m 🔑 Key $GPG_KEY_NAME ($fingerPrint) already exists, skipping creation\e[39m"

set -e

# Create & encrpyt the secrets.enc.yaml file from template using sops and envsubst
echo -e "\e[36m###\e[33m 📝 Creating & encrypting dev/secrets.enc.yaml\e[39m"
envsubst < $scriptPath/secrets.enc.yaml.template > $scriptPath/../base/secrets.enc.yaml
sops --encrypt --in-place $scriptPath/../base/secrets.enc.yaml
git add $scriptPath/../base/secrets.enc.yaml
git commit -m "Updated by deployment script $(date)"
git push

if [[ $DEPLOY_AKS == "true" ]]; then
  status=$(az feature list -o tsv --query "[?contains(name, 'Microsoft.ContainerService/CustomNodeConfigPreview')].{State:properties.state}")
  if [[ "$status" != "Registered" ]]; then
    echo "ERROR! CustomNodeConfigPreview is not registered, status is '$status'"
    echo "Please follow these stesp: https://docs.microsoft.com/en-us/azure/aks/custom-node-configuration#register-the-customnodeconfigpreview-preview-feature"
    exit 1
  fi
  
  echo -e "\e[36m###\e[33m 🌐 Deploying AKS cluster & Azure resources, please wait this can take some time\e[39m"
  az deployment sub create -f ${scriptPath}/template/main.bicep -l $AZURE_REGION -n $AZURE_DEPLOY_NAME --parameters resGroupName=$AZURE_RESGRP location=$AZURE_REGION
fi

clusterName=$(az deployment sub show --name $AZURE_DEPLOY_NAME --query "properties.outputs.clusterName.value" -o tsv)
echo -e "\n\e[36m###\e[33m 🔌 Connecting to cluster '$clusterName'\e[39m"
az aks get-credentials --overwrite-existing -g $AZURE_RESGRP -n $clusterName

set +e
echo -e "\n\e[36m###\e[33m 📦 Creating namespaces '$NAMESPACE' & 'flux-system'\e[39m"
kubectl create namespace $NAMESPACE
kubectl create namespace flux-system

echo -e "\n\e[36m###\e[33m 🔐 Creating secret sops-gpg in $NAMESPACE\e[39m"
gpg --export-secret-key --armor ${fingerPrint} | kubectl create secret generic sops-gpg -n $NAMESPACE --from-file=bigbangkey.asc=/dev/stdin

echo -e "\n\e[36m###\e[33m 🔐 Creating secret docker-registry in flux-system\e[39m"
kubectl create secret docker-registry private-registry --docker-server=registry1.dso.mil --docker-username="${IRON_BANK_USER}" --docker-password="${IRON_BANK_PAT}" -n flux-system

echo -e "\n\e[36m###\e[33m 🔐 Creating secret private-git in $NAMESPACE\e[39m"
kubectl create secret generic private-git --from-literal=username=${GITHUB_USER} --from-literal=password=${GITHUB_PAT} -n bigbang

echo -e "\n\e[36m###\e[33m 🚀 Installing flux from bigbang install script\e[39m"
if [[ $DEPLOY_FLUX == "true" ]]; then
  rm -rf $scriptPath/bigbang
  git clone $BB_REPO $scriptPath/bigbang
  pushd $scriptPath/bigbang
  ./scripts/install_flux.sh \
    --registry-username "${IRON_BANK_USER}" \
    --registry-password "${IRON_BANK_PAT}" \
    --registry-email bigbang@bigbang.dev 
  popd
fi

echo -e "\n\e[36m###\e[33m 🔨 Removing flux-system 'allow-scraping' network policy\e[39m"
# If we don't remove this the kustomisation will never reconcile!
kubectl delete netpol -n flux-system allow-scraping

echo -e "\n\e[36m###\e[33m 💣 Deploying BigBang!\e[39m"
pushd $scriptPath/../dev
kubectl apply -f bigbang.yaml
popd

echo -e "\n\e[36m###\e[33m 💤 Sleeping for a few seconds...\e[39m"
sleep 15

echo -e "\n\e[36m###\e[33m 👁‍🗨 Verifying gitrepositories & kustomizations\e[39m"
kubectl get -n $NAMESPACE gitrepositories,kustomizations -A
