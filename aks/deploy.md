# Azure Deployment

This is a fast (ish) way to deploy BigBang into Azure using AKS

## Pre-reqs

Due to the way BigBang is designed and the reliance on gitops and flux there are several pre-reqs that can not be automated or scripted

### 1. Local Tools

Local tools & environment required are:

- Azure CLI
- kubectl
- bicep
- gpg (`sudo apt-get install -y gpg`)
- sops
- Bash (Linux / WSL2 / MacOS)

Install scripts for all these can be obtained here https://github.com/benc-uk/tools-install

### 1. Accounts

- GitHub account
- [GitHub PAT](https://docs.github.com/en/github/authenticating-to-github/keeping-your-account-and-data-secure/creating-a-personal-access-token)
- [Iron Bank Account](https://ironbank.dso.mil/)

### 2. Set Up Git Repo

1. Fork this repo on GitHub https://github.com/benc-uk/bigbang-azure
1. Clone your fork locally
1. Create branch called "azure" and push up to GitHub to track this branch
   ```bash
   git checkout -b azure
   git push -u origin azure
   ```

### 3. Create Keys and Configure Repo

Rather than duplicating instructions, follow the steps in the [main readme](../README.md) for the following section:

- Configure for GitOps

> Note. Please ignore the sections 'Create GPG Encryption Key' & 'Add Pull Credentials' these will be carried out by deploy.sh

### 4. Deploy

1. Copy `secrets.sh.sample` to `secrets.sh` and edit to set with your own values and secrets
2. Copy `deploy-vars.sh.sample` to `deploy-vars.sh` and configure as you wish

It is critical you get the values in these two files correct as they drive all the automation

Run the automated deployment script

```bash
cd aks
./deploy.sh
```

This will do:

1. One time creation of GPG keys and update to .sops.yaml
2. Creation of `secrets.enc.yaml` and sync with git
3. Deployment of AKS cluster. Note you can skip this by setting `DEPLOY_AKS="false"` in deploy-vars.sh
4. Connection to AKS cluster for kubectl etc
5. Creation of namespaces
6. Creation of secrets: `sops-gpg`, `private-registry` & `private-git`
7. Deployment of Flux from the main bigbang repo which will be cloned and `scripts/install_flux.sh` run
8. Removes network policies which block Flux being scraped
9. Deploys the `dev/bigbang.yaml` to the cluster
10. Validates the status of the deployment

Run `kubectl get gitrepositories,ks,hr -A` to see the status of the deployment
