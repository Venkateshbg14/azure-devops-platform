# Azure DevOps Platform: AKS with Terraform and Keyless CI/CD

A small platform on Azure built end to end: infrastructure as code, a private container registry, a Kubernetes cluster, and a CI/CD pipeline that deploys without any stored secrets.

This is a hands-on learning project, built to practise real-world DevOps patterns and to debug the problems that come with them.

## Architecture

```
                         git push
                            |
                            v
                  GitHub repository
                            |
                            v
                    Azure Pipelines
        +-----------------------------------------+
        |  Build  ->  Verify AKS access  ->  Deploy |
        +-----------------------------------------+
              |                         |
   OIDC token (no secrets)              |
              v                         |
   Entra ID federated credential        |
              |                         |
              v                         |
   Managed identity (pipeline)          |
     |- AcrPush ---------> ACR <--------+---- image pushed by tag (commit SHA)
     |- Cluster User ----> AKS
                            |
                            v
        Internet -> Azure Load Balancer -> Service -> 2 pods (one per node)
```

## What it demonstrates

- **Terraform** with remote state in Azure Storage, Entra ID authentication, and blob lease locking
- **Azure networking and compute:** VNet, subnet, ACR, and a 2-node AKS cluster using Azure CNI Overlay, sized to a 4 vCPU quota
- **Keyless CI/CD:** Azure DevOps service connection using workload identity federation (OIDC). No passwords or keys in the repo or the pipeline
- **Least-privilege access:** `AcrPull` for the cluster's kubelet identity, `AcrPush` and `Cluster User` for the pipeline identity, each scoped to a single resource
- **Container hygiene:** multi-stage Docker build, non-root numeric user, images tagged with the Git commit SHA (never `latest`)
- **Kubernetes workload practices:** zero-downtime rolling updates, readiness and liveness probes, resource requests and limits, HPA, topology spread across nodes, read-only root filesystem, all Linux capabilities dropped

## Repository layout

| Path | Purpose |
|---|---|
| `infra/` | Terraform: resource group, network, ACR, AKS, pipeline identity |
| `app/` | Flask application, `requirements.txt`, multi-stage `Dockerfile` |
| `k8s/` | Namespace, Deployment, Service, HPA |
| `pipelines/` | Azure Pipelines definition (`azure-pipelines.yml`) |
| `docs/` | Interview notes and screenshots |

## How the pipeline works

1. A push to `main` that changes `app/`, `k8s/` or `pipelines/` triggers Azure Pipelines.
2. **Build:** logs in to Azure through the service connection (OIDC), builds the image, tags it with the first 7 characters of the commit SHA, and pushes it to ACR.
3. **Verify:** fetches the cluster credentials and runs `kubectl get nodes` to prove the pipeline can reach AKS.
4. **Deploy:** replaces the image and version placeholders in `k8s/deployment.yaml`, applies the manifests, and waits for the rollout to complete (the stage fails after 180 seconds if the new pods are not ready).

## Screenshots

| | |
|---|---|
| Pipeline run, all three stages green | `docs/images/pipeline-run.png` |
| Deploy step log | `docs/images/deploy-log.png` |
| Pods spread across both nodes | `docs/images/pods-two-nodes.png` |
| Rolling update in progress | `docs/images/rolling-update.png` |
| ACR repository with SHA tags | `docs/images/acr-tags.png` |
| Federated credential on the managed identity | `docs/images/federated-credential.png` |
| Cost analysis | `docs/images/cost.png` |

![Pipeline run](docs/images/pipeline-run.png)
![Pods across nodes](docs/images/pods-two-nodes.png)
![Rolling update](docs/images/rolling-update.png)

## How to run it yourself

Prerequisites: an Azure subscription, Azure CLI, Terraform 1.6 or later, Docker, kubectl, an Azure DevOps organisation, and a GitHub repository.

1. **Create the state backend** (once, with the Azure CLI): a resource group, a storage account, and a `tfstate` blob container. Grant yourself `Storage Blob Data Contributor` on the storage account.
2. **Configure Terraform:** put your storage account name in `infra/backend.tf`. Copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and set your subscription ID.
3. **Create the platform:**
   ```
   cd infra
   terraform init
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
4. **Push an image once** so the registry has content (or let the pipeline do it).
5. **Create the Azure DevOps service connection:** Azure Resource Manager, "App registration or managed identity (manual)", workload identity federation. Use the `pipeline_client_id`, `tenant_id` and `subscription_id` Terraform outputs. Copy the issuer and subject from the wizard into `terraform.tfvars` as `ado_issuer` and `ado_subject`, run `terraform apply` again, then click **Verify and save**.
6. **Create the pipeline** from `pipelines/azure-pipelines.yml` and run it.
7. **Find the public IP:** `kubectl -n demo get svc devops-app`

## Problems I hit and solved

- **CrashLoopBackOff from a read-only root filesystem.** Gunicorn needs a writable temp directory. I read the previous container's logs with `kubectl logs --previous`, found "no usable temporary directory", and mounted a small `emptyDir` at `/tmp` instead of weakening the security setting.
- **Both pods scheduled on one node.** Replicas had no reason to spread. I added a topology spread constraint, then changed it from `ScheduleAnyway` (a preference that was ignored) to `DoNotSchedule` (a hard rule).
- **Manifest rejected by the API.** A misindented topology block was read as a field of `securityContext`. I used `kubectl apply --dry-run=server` to validate manifests before applying them.
- **Numeric commit SHA broke the deploy stage.** One commit's short SHA was all digits, so YAML parsed the templated `APP_VERSION` as an integer and Kubernetes rejected it. I quoted the templated value so it is always a string.
- **Rollback left the cluster out of sync with git.** `kubectl rollout undo` changes the cluster, not the repository. I redeployed from git to restore the intended state.
- **Windows shell differences.** The commands were written for bash, so I rewrote them for PowerShell (variables, line continuation, quoting).

## Limitations and what I would do next

- **Deployment is push-based** (`kubectl apply` from the pipeline). A pull-based GitOps tool such as Argo CD would keep cluster credentials out of CI.
- **Cluster local accounts are enabled.** In production I would disable them, enable Azure RBAC for Kubernetes, and give the pipeline a namespace-scoped role.
- **No monitoring or alerting** in this project. I understand the concepts (metrics, dashboards, alert rules) but did not implement them here.
- **Public LoadBalancer without TLS.** I would add an Ingress controller with certificates.
- **Single environment and a single node pool**, because of the 4 vCPU quota.
- **Cluster was never upgraded:** the quota leaves no room for a surge node during upgrades.
- **Manifests are templated with `sed`.** Helm or Kustomize would handle typing and per-environment values more safely.

## Cost

Built on an Azure free-trial credit. Two small AKS nodes, a Basic ACR, a standard load balancer public IP, and a few storage transactions. Total spend over the build period: about [FILL IN] rupees (see the cost screenshot). All resources are removed afterwards with `terraform destroy`.

## Notes on secrets

No credentials are stored in this repository. `terraform.tfvars`, plan files and state files are git-ignored. The pipeline authenticates with a short-lived OIDC token, and the registry has its admin account disabled.
