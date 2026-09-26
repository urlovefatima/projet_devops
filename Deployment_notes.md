# Deploying Ollama and Open WebUI on Kubernetes

**Namespace:** `llm-app` | **Cluster:** minikube | **Models (Kubernetes deployment):** `llama3.2:3b`, `qwen2.5:0.5b`, `tinyllama:latest`

## 1. Overview

This project recreates a Docker Compose deployment of two applications on Kubernetes: **Ollama**, which runs the language models, and **Open WebUI**, a web interface that sends prompts to Ollama. All manifests are organized with Kustomize under `k8s/base/` and `k8s/overlays/dev/`, and are applied with `kubectl apply -k k8s/overlays/dev`.

## 2. Purpose of each Kubernetes resource

| Resource | Name(s) | Purpose |
|---|---|---|
| Namespace | `llm-app` | Groups every resource of the project and isolates it from other workloads in the cluster. It can be deleted in one command to clean up. |
| ConfigMap | `ollama-config`, `openwebui-config` | Store non-sensitive configuration (`OLLAMA_BASE_URL`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL`) outside the container image. The Deployments load them with `envFrom`, so configuration changes do not require editing the Deployment or rebuilding an image. |
| PersistentVolumeClaim | `ollama-pvc` (10Gi), `openwebui-pvc` (5Gi) | Request durable storage for the downloaded models and for Open WebUI's data. |
| Deployment | `ollama`, `open-webui` | Describe the desired state of each application (image, ports, resources, probes, volumes). Kubernetes keeps one pod running and recreates it if it fails. |
| Service | `ollama` (11434), `open-webui` (8080) | Give each application a stable internal address and DNS name, since pod IPs change at every restart. |
| Ingress | `open-webui` | Expose the web interface outside the cluster on `openwebui.local`, routed through an NGINX ingress controller. `kubectl port-forward` was used as an alternative when the Ingress controller was not enabled on a given machine. |

Both Deployments use `replicas: 1` and the `Recreate` update strategy. The volumes are `ReadWriteOnce`, so only one pod can mount them at a time; a rolling update would leave the old and the new pod competing for the same volume and for the same limited memory.

**Requests and limits.** Every container declares CPU and memory requests (the amount the scheduler reserves) and limits (the maximum it may consume). Because the deployment targets a memory-constrained minikube node, three small models were used instead of larger ones (`mistral:7b`, `deepseek-r1:8b`), which keeps the memory limits modest:

| Container | Requests | Limits |
|---|---|---|
| Ollama | 500m CPU, 1Gi | 2 CPU, 3Gi |
| Open WebUI | 250m CPU, 512Mi | 1 CPU, 1Gi |

`OLLAMA_MAX_LOADED_MODELS=1` keeps only one model in memory at a time, which is enough headroom for the largest of the three models (`llama3.2:3b`, about 2 GB) plus its context.

## 3. How the services communicate

```
Browser
  │  Ingress (openwebui.local) or kubectl port-forward
  ▼
Service open-webui :8080  ──►  Pod open-webui
                                   │  OLLAMA_BASE_URL = http://ollama:11434
                                   ▼
                          Service ollama :11434  ──►  Pod ollama  ──►  PVC ollama-pvc
```

1. The user reaches Open WebUI through the Ingress or the port-forward, which target the `open-webui` Service on port 8080.
2. The Service forwards the traffic to the pod whose label matches its selector (`app: open-webui`).
3. Open WebUI reads `OLLAMA_BASE_URL=http://ollama:11434` from its ConfigMap. The name `ollama` is resolved by the cluster's internal DNS (CoreDNS) to the ClusterIP of the `ollama` Service, which forwards the request to the pod labelled `app: ollama`.
4. Ollama loads the requested model from its volume and streams the answer back along the same path.

Both Services are of type `ClusterIP`: Ollama is only reachable from inside the cluster, and the only entry point from outside is the Open WebUI interface. This means Ollama's API is never directly exposed to the outside world.

## 4. Why Persistent Volume Claims are required

A container's filesystem is ephemeral: when a pod is deleted, evicted, or restarted, everything written inside it is lost. Two kinds of data must survive:

- **Ollama's models** (`/root/.ollama`). The three models together weigh a few gigabytes. Without a PVC they would have to be downloaded again after every pod restart, which is slow and wastes bandwidth.
- **Open WebUI's data** (`/app/backend/data`): user accounts, settings, and chat history.

A PVC separates the lifecycle of the data from the lifecycle of the pod. The claim is bound to a volume, and any new pod that mounts `ollama-pvc` or `openwebui-pvc` finds the data exactly where the previous pod left it. In this deployment, deleting the Ollama pod (`kubectl delete pod -l app=ollama`) does not remove the models: once the new pod starts, `ollama list` still shows all three models, which confirms the PVC is doing its job.

## 5. Liveness, readiness, and startup probes

Probes let Kubernetes check the health of a container instead of assuming that a running process is a working one. Each application uses all three, on `/` for Ollama and `/health` for Open WebUI.

- **Startup probe.** Runs first and disables the other two probes until it succeeds. Applications such as Ollama and Open WebUI can take a long time to start, so this probe allows up to five minutes (`periodSeconds: 5`, `failureThreshold: 60`). Without it, a slow start could be mistaken for a failed container and be restarted before it ever had a chance to come up.
- **Readiness probe.** Decides whether the pod should receive traffic. If it fails, the pod stays running but is removed from the Service's list of endpoints. This prevents requests from reaching an application that is not ready yet, for example Open WebUI before Ollama is available.
- **Liveness probe.** Detects a container that is running but stuck. After repeated failures, Kubernetes restarts the container.

The timeouts on all three probes are deliberately generous (5 to 10 seconds, several allowed failures) rather than the 1-second default. During early testing on a memory-constrained machine, the default timeout caused repeated `context deadline exceeded` errors on Ollama, which triggered restarts of a container that was simply slow, not broken. A liveness probe that is too strict can turn a temporary slowdown into a crash loop.

## 6. Docker Compose versus Kubernetes

| | Docker Compose | Kubernetes |
|---|---|---|
| Scope | One host | A cluster of nodes |
| Failure handling | Restart policy only | Self-healing: pods are recreated, unhealthy ones are removed from traffic or restarted |
| Updates | Recreate containers | Rolling updates and rollbacks |
| Networking | Compose network, service names | Services, cluster DNS, Ingress |
| Storage | Docker volumes | PersistentVolumes and PersistentVolumeClaims, decoupled from the pod |
| Configuration | `environment` and `.env` in one file | ConfigMaps and Secrets, separate objects |
| Health checks | Optional `healthcheck` | Startup, readiness, and liveness probes, each with a distinct role |
| Resources | Optional limits | Requests (used for scheduling) and limits (enforced at runtime) |
| Scaling | Manual | Declarative (`replicas`, HorizontalPodAutoscaler) |

When this stack is migrated from Compose to Kubernetes, each Compose element maps to one or more Kubernetes resources: a Compose service becomes a Deployment plus a Service, `volumes` become PVCs, `environment` becomes a ConfigMap, `ports` become a Service and an Ingress, and `depends_on` is effectively replaced by readiness probes. Compose is simpler to write and is well suited to local development on a single machine. Kubernetes requires more objects, but in exchange it provides resilience across restarts, explicit resource control, and a deployment that is portable across different clusters and environments.

## 7. Difficulties encountered and conclusion

The main challenge was memory. The development machine had 8 GB of RAM installed, but only about 5.9 GB usable by Windows, since roughly 2 GB was reserved for the integrated GPU. On top of that, `.wslconfig` had been set to request 6 GB for WSL2, more than the machine could actually provide, which caused the system to swap. This surfaced as an Ollama pod stuck in an `Unknown` state, with `kubectl describe pod` showing liveness and readiness probes failing with `context deadline exceeded`, and eventually the container terminating unexpectedly.

Diagnosing this required checking the node's real available memory (`systeminfo`, `Get-CimInstance Win32_PhysicalMemory`), correcting `.wslconfig` to a value below the machine's usable RAM, and resizing minikube accordingly. Because the models required for a full comparison (`mistral:7b`, `deepseek-r1:8b`) would not fit in this budget, the Kubernetes deployment was scaled down to three lighter models — `llama3.2:3b`, `qwen2.5:0.5b`, and `tinyllama:latest` — which together stay well under the memory limit configured on the Ollama Deployment, while still exercising three different model families.

This experience directly shaped several design choices described above: generous probe timeouts instead of the 1-second default, a single replica per Deployment with the `Recreate` strategy to avoid two pods competing for the same limited memory, and resource limits sized to the actual models in use rather than to the largest models available. Overall, the deployment satisfies all the required conditions: both pods reach the `Running` state, no pod enters `CrashLoopBackOff` or stays `Pending`, Open WebUI successfully communicates with Ollama through the cluster's internal DNS, and all three models are visible in the interface and answer prompts correctly.