# Interview Q&A: Azure DevOps Platform project

How to use this: read an answer, close the file, then say it aloud in your own words. Short answers first, then the detail if they dig. If you don't know something, say so and explain how you'd find out.

---

## 0. The 60-second pitch

"I built a small cloud platform on Azure. I wrote Terraform to create the network, a container registry and a two-node Kubernetes cluster, with the Terraform state stored remotely in Azure Storage. I packaged a Flask app in a multi-stage, non-root Docker image. I built an Azure DevOps pipeline that, on every push, builds the image, tags it with the commit ID, pushes it to the registry and deploys it to AKS. The pipeline logs in with workload identity federation, so there are no stored secrets. I demonstrated a zero-downtime rolling update and a rollback, and I debugged several real issues along the way."

Likely follow-ups: "What was the hardest problem?" (use story 1 or 4 below.) "What would you do differently?" (see the Limitations section.)

---

## 1. Troubleshooting stories (what broke, how you found it, what you changed)

### Story 1: CrashLoopBackOff from a read-only root filesystem
- **Symptom:** pods stuck in `CrashLoopBackOff`, `rollout status` never finished.
- **Investigation:** `kubectl get pods`, then `kubectl logs <pod> --previous` (the current container had just restarted, so the previous one holds the error). The log said no usable temporary directory.
- **Cause:** I had set `readOnlyRootFilesystem: true` for security. Gunicorn writes worker heartbeat files to `/tmp`, so it crashed at start-up. Kubernetes kept restarting it with growing delays, which is the "BackOff".
- **Fix:** mounted a small `emptyDir` volume (16Mi limit) at `/tmp`. Everything else stays read-only.
- **Lesson:** fix the cause, don't remove the security control.

### Story 2: Both replicas on one node
- **Symptom:** `kubectl get pods -o wide` showed two pods on the same node.
- **Cause:** the scheduler only balances by resources, not by spreading replicas, unless asked. Losing that node would take the whole app down.
- **Fix:** added `topologySpreadConstraints` on `kubernetes.io/hostname`. First with `ScheduleAnyway` (a soft preference, which was ignored during rollouts), then `DoNotSchedule` (a hard rule).
- **Trade-off:** with `DoNotSchedule`, if a node is down, a new pod can stay Pending instead of doubling up on the survivor.
- **Also learned:** Kubernetes only checks spread when placing a pod. It doesn't move running pods. After a rollback I had to delete a pod to rebalance. A tool called the descheduler automates that.

### Story 3: Manifest rejected with "unknown field"
- **Symptom:** `kubectl apply` failed with `unknown field "spec.template.spec.securityContext.topologySpreadConstraints"`.
- **Cause:** YAML indentation. My block was indented two spaces too deep, so it became a child of `securityContext` instead of a sibling.
- **Fix:** corrected the indentation. Used `kubectl apply --dry-run=server` first, which validates against the real API without changing anything.
- **Also learned:** a "successfully rolled out" message after a failed apply refers to the old rollout. Only trust it when `apply` printed `configured`.

### Story 4: Deploy stage failed on one commit only
- **Symptom:** the Deploy stage failed with `cannot convert int64 to string`.
- **Investigation:** in the log, the env value was `2154064` without quotes.
- **Cause:** that commit's 7-character SHA was all digits, so YAML read the templated `APP_VERSION` as a number. Environment variable values must be strings. Earlier SHAs contained letters, so it had worked before. (Roughly 1 in 27 commits would hit it.)
- **Fix:** quoted the placeholder (`"VERSION_PLACEHOLDER"`) so the rendered value is always a string.
- **Lesson:** values templated into YAML need quoting. A cleaner long-term approach is Helm or Kustomize.

### Story 5: Rollback and drift
- After `kubectl rollout undo`, the cluster ran an older revision while git held the newer one. The next pipeline run would have overwritten the rollback.
- In a GitOps flow you revert the commit instead, so git stays the source of truth.

---

## 2. Terraform

**Why remote state?**
Local state is lost with your laptop and can't be shared. State can contain secrets, so it can't go in git. Remote state is shared, durable and locked during changes.

**How does the azurerm backend lock state?**
It takes a lease on the state blob. A second `apply` fails with a lock error until the lease is released.

**What is state, in simple words?**
A record of what Terraform built: resource IDs and settings. Terraform compares your code to the state and to reality, and works out the difference.

**What if two people run apply at once?**
The blob lease blocks the second. If a run was killed and left a stale lock, `terraform force-unlock <ID>` clears it, but only when you're sure nothing is running.

**How did you create the backend, given that Terraform needs it first?**
By hand with the Azure CLI, once (the chicken-and-egg problem). It sits in its own resource group, so `terraform destroy` on the project can't delete the state.

**Why can't a backend block use variables?**
Terraform reads the backend before it evaluates variables, because it needs state first. Values are literals, or passed with `-backend-config` at `init`.

**Control plane vs data plane permissions?**
Control plane manages resources (create a storage account). Data plane accesses what's inside (read blobs). Owner has the first, not the second, so I granted `Storage Blob Data Contributor` on the storage account.

**What does `~> 4.0` mean?**
Any 4.x version but never 5.0. It accepts fixes and blocks breaking changes.

**Why is `subscription_id` required in azurerm 4.x?**
The provider stopped guessing it, to avoid deploying into the wrong subscription by accident.

**How does Terraform know the order to create resources?**
From references like `azurerm_resource_group.main.name`. Those build a dependency graph. Independent resources are created in parallel.

**What is `.terraform.lock.hcl` and should you commit it?**
It pins the exact provider versions and checksums. Yes, commit it so everyone gets identical plugins.

**What are `count` and the conditional you used?**
`count = var.ado_subject == "" ? 0 : 1` creates zero or one copy of a resource. I used it because the issuer and subject only exist after the Azure DevOps wizard starts, so the first apply skipped the federated credential and the second created it.

**What is a data source?**
It reads existing information (such as the tenant ID of the current login) without creating anything.

**What does `plan -out=tfplan` do, and why?**
It saves the reviewed plan so `apply tfplan` runs exactly that, with no surprises in between.

**Your plan showed 1 to change on AKS after the first apply. Why?**
Azure filled in a default (`upgrade_settings`, `max_surge = 10%`) that my config didn't mention. This is normal drift between defaults and config, and it was an in-place update.

**What would you do for multiple environments?**
Separate state keys or workspaces, variable files per environment, and modules for repeated parts. (I used a single environment here because of the quota.)

---

## 3. Azure, networking and identity

**What is a resource group?**
A folder for related resources. Deleting it deletes everything inside.

**Explain the VNet and subnet CIDRs you used.**
VNet `10.0.0.0/16` has 65,536 addresses. The AKS subnet `10.0.1.0/24` is a 256-address slice inside it. Pod range `192.168.0.0/16` and service range `10.2.0.0/16` are separate, and none of the ranges may overlap.

**Why Azure CNI Overlay?**
Plain Azure CNI uses one VNet IP per pod, which burns address space. Overlay gives pods IPs from a separate range, so the VNet stays small.

**What is the difference between pod CIDR, service CIDR and the VNet range?**
VNet range: node IPs. Pod CIDR: pod IPs (overlay). Service CIDR: virtual IPs for Kubernetes Services. The DNS service IP must sit inside the service CIDR.

**Why a managed identity rather than a service principal with a secret?**
Azure holds and rotates the credentials, so there is no secret to leak or expire.

**What is a role assignment?**
Who (principal) can do what (role) on which thing (scope). I scoped each one to a single resource.

**Why does the kubelet identity need AcrPull, not the cluster identity?**
The kubelet is the node agent that actually downloads images, and it has its own identity.

**How do nodes pull from ACR without a password?**
The kubelet's managed identity has the `AcrPull` role on the registry. No admin account and no `imagePullSecrets`.

**Why is `admin_enabled = false` on ACR?**
The admin account is a single shared password with no per-user audit trail.

**What do you lose with the Free AKS tier?**
The uptime SLA and some scale limits. Production uses Standard.

**Why did you need `os_disk_type = "Managed"`?**
The VM size has no local temp disk, and AKS would otherwise try an ephemeral OS disk, which needs one.

**Why `skip_service_principal_aad_check`?**
To avoid a timing failure when Entra ID hasn't finished replicating a brand-new identity.

---

## 4. Docker

**Why multi-stage builds?**
The final image holds only what runs: no build tools or caches. Smaller image, smaller attack surface.

**Why copy `requirements.txt` before the code?**
Layer caching. Dependencies rarely change, so that layer stays cached and code edits rebuild only the last layers.

**Why run as non-root, and why a numeric UID?**
If the app is compromised, the attacker isn't root. Kubernetes' `runAsNonRoot` can only verify a numeric UID.

**Why never tag `latest`?**
It's mutable. You can't tell what's running or roll back reliably. I tag with the commit SHA.

**Exec form vs shell form for `CMD`?**
Exec form (a JSON list) makes gunicorn PID 1, so it receives SIGTERM and shuts down gracefully. Shell form wraps it in `sh`, which doesn't forward signals.

**Why gunicorn instead of `flask run`?**
Flask's built-in server is for development only. Gunicorn is a production-grade server with worker processes.

**Why bind to `0.0.0.0`?**
Listening only on `127.0.0.1` would make the app unreachable from outside the container.

**What does `EXPOSE` do?**
Documentation only. It doesn't publish a port.

**Why port 8080?**
Non-root users can't bind ports below 1024.

**What does `.dockerignore` do?**
Trims the build context, speeds up builds, and keeps secrets and junk out of the image.

**Why `PYTHONUNBUFFERED=1`?**
So logs appear immediately in `kubectl logs` instead of being buffered.

---

## 5. Kubernetes

**What is the hierarchy Deployment, ReplicaSet, Pod?**
The Deployment manages ReplicaSets. A ReplicaSet keeps the right number of pods alive. Each update creates a new ReplicaSet, and old ones are kept (`revisionHistoryLimit: 5`), which is what makes rollback possible.

**How does a rolling update achieve zero downtime here?**
`maxSurge: 1` starts a new pod first. `maxUnavailable: 0` keeps the old ones serving until the new pod passes its readiness probe.

**Readiness vs liveness probe?**
Readiness decides whether the pod receives traffic (failing removes it from the Service, no restart). Liveness decides whether to restart the container.

**Why is the liveness delay longer than the readiness delay?**
So a slow start doesn't cause a restart loop.

**Requests vs limits?**
Requests are for scheduling and HPA maths. Limits are enforced ceilings: over the memory limit means OOMKill, over the CPU limit means throttling.

**How does the HPA decide how many pods?**
`desired = ceil(current replicas x current utilization / target)`. Utilization is measured against CPU requests, which is why requests must be set. It also needs metrics-server.

**Why did the HPA show `<unknown>` at first?**
Metrics take a minute or two to appear after creation.

**How does a Service find its pods?**
By label selector. The Deployment's pod template labels, the Deployment selector and the Service selector all use `app: devops-app`.

**Why LoadBalancer and not Ingress?**
One service needs one public IP, so a LoadBalancer is simplest. With many services, an Ingress controller shares one IP and routes by host or path, and can terminate TLS.

**`port` vs `targetPort`?**
`port` is what clients connect to (80). `targetPort` is the container port (8080).

**What are the security settings you used and why?**
`runAsNonRoot` and a fixed UID, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities: drop: ["ALL"]`. Defence in depth: a compromised app can't escalate or persist changes.

**What is a namespace for?**
Separating workloads, applying permissions and quotas per area, and cleaning up in one command.

**What does `kubectl apply` mean by "declarative"?**
You describe the desired state and Kubernetes makes reality match. It's safe to re-run.

**What is `kubectl rollout undo` doing?**
It switches the Deployment back to the previous ReplicaSet. Git is unchanged, so the cluster and repo drift apart until you redeploy or revert.

**How did you debug a crashing pod?**
`kubectl get pods`, `kubectl describe pod` (events, exit code), `kubectl logs --previous`.

**What is a topology spread constraint?**
A rule telling the scheduler to balance matching pods across nodes or zones, with `maxSkew` limiting the imbalance. `DoNotSchedule` is hard, `ScheduleAnyway` is soft.

---

## 6. Azure DevOps pipeline and OIDC

**What is workload identity federation, and why use it over a secret?**
The pipeline presents a short-lived token from its own identity provider. Entra ID trusts it based on a configured issuer and subject. No secret exists, so nothing can leak or need rotating.

**What do the issuer and subject mean?**
The issuer is who signed the token (Azure DevOps). The subject identifies which service connection it was issued for. Entra ID requires an exact string match, so I copied them and never typed them.

**Why create the identity in Terraform instead of letting Azure DevOps create it?**
So the identity, its roles and its trust are all code: reviewable, repeatable and destroyable, with least-privilege roles written down.

**What roles does the pipeline have and why?**
`AcrPush` on one registry and `Azure Kubernetes Service Cluster User Role` on one cluster. No subscription-wide Contributor.

**Walk me through what happens when I push code.**
1. Push to GitHub. 2. Azure Pipelines sees a change under `app/`, `k8s/` or `pipelines/`. 3. A fresh Microsoft-hosted Ubuntu agent starts. 4. `AzureCLI@2` gets an OIDC token and logs in as the managed identity. 5. Build the image, tag it with the commit SHA, push to ACR. 6. Get cluster credentials. 7. Replace the placeholders and apply the manifests. 8. Kubernetes starts new pods, waits for readiness, and removes old ones.

**`$(var)` vs `${var}` in a pipeline script?**
`$(var)` is expanded by Azure Pipelines before the script runs. `${var}` is a bash variable expanded at run time.

**Why `set -euo pipefail`?**
Without it, a failing command can leave the step green. Strict mode stops on errors, unset variables and pipe failures.

**What does `dependsOn` do?**
Orders stages and skips later ones if an earlier one fails.

**What are stages, jobs and steps?**
Stages run in order. Jobs within a stage can run in parallel on separate agents. Steps run in sequence on one agent.

**Why tag images with the commit SHA?**
Immutable and traceable: for any running pod you can find the exact commit, and a rollback targets a known tag.

**Why does the pipeline have path filters?**
So a README change doesn't consume pipeline time.

**Why pin `ubuntu-24.04` instead of `ubuntu-latest`?**
Microsoft was migrating `ubuntu-latest` to a newer OS version. Pinning keeps builds repeatable.

**Why did the Deploy stage work with only the Cluster User role?**
The cluster has local accounts enabled, and the kubeconfig that role downloads carries broad rights. That is a weakness: in production I'd disable local accounts, enable Azure RBAC for Kubernetes, and grant a namespace-scoped role.

**How would this change for a team?**
Authorise pipelines per service connection, add approvals and environments before deploy, use separate identities per environment, and protect `main` with required reviews.

---

## 7. How the pieces connect (short answers)

**How does Terraform on my laptop create Azure resources?**
`az login` stores a signed-in session. The azurerm provider reuses that session to call the Azure Resource Manager API. The subscription ID in `providers.tf` says where to build.

**How does `kubectl` on my laptop reach the cluster?**
`az aks get-credentials` writes an entry to the kubeconfig file (`~/.kube/config`) holding the cluster's API address, its certificate authority and your login details. `kubectl` reads that file for every command.

**How does the pipeline know where to deploy?**
Through variables in the YAML (resource group and cluster name) and the service connection, which decides which Azure subscription and identity it acts as. `az aks get-credentials` then writes a kubeconfig on the build agent.

**How does the pipeline get triggered?**
The Azure Pipelines GitHub app is notified of pushes, matches the branch and path filters in `trigger`, and queues a run.

**How do nodes get images from ACR?**
Kubelet's managed identity holds `AcrPull` on the registry.

---

## 8. Honest limitations (say these plainly)

- **Monitoring:** not implemented in this project. I understand the concepts (metrics collection, dashboards, alert rules) from theory.
- **Helm and Argo CD:** not used. My deploy is push-based with `kubectl apply`. Helm templates and packages manifests, and Argo CD is pull-based GitOps that syncs the cluster from a Git repository.
- **Security gaps:** local accounts enabled, no TLS, public LoadBalancer. I know the fixes.
- **Scale:** single environment, one node pool, and no upgrades because of the 4 vCPU quota.
- **Origin:** a hands-on learning project, not production work.

---

## 9. Questions to ask the interviewer

- How do you manage Terraform state and environments today?
- Is deployment push-based or GitOps in your team?
- How do you handle secrets and pipeline authentication?
- What does on-call look like for the platform team?

---

## 10. Before the interview: your practice checklist

- [ ] Draw the architecture from memory, twice.
- [ ] Explain each of the five troubleshooting stories in under two minutes.
- [ ] Explain `az login` vs `kubeconfig` vs OIDC out loud.
- [ ] Explain every line of the Dockerfile and `deployment.yaml` without looking.
- [ ] Break something on purpose (wrong image tag, tiny memory limit, bad probe path) and fix it.
