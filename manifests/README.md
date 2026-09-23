# manifests

Applied on `k3s-server`, in numeric order. They are kept here rather than typed
into the node so that a rebuilt cluster is a `vagrant up` plus an `apply`, not
an archaeology exercise — the previous cluster's manifests existed only inside a
VM, and were lost with it.

The repository is **not** synced into the guests (Hyper-V's shared folders want
host credentials, so `synced_folder` is disabled). Copy them in with Vagrant's
own uploader, from an elevated PowerShell in the repository root:

```powershell
vagrant upload manifests /home/vagrant/manifests k3s-server
```

Then, inside `vagrant ssh k3s-server`:

```bash
kubectl apply -f ~/manifests/00-namespace.yaml
kubectl label node k3s-agent-1 llm-d.ai/role=prefill --overwrite
kubectl label node k3s-agent-2 llm-d.ai/role=decode  --overwrite
kubectl apply -f ~/manifests/10-sim-prefill.yaml -f ~/manifests/11-sim-decode.yaml
kubectl apply -f ~/manifests/20-gateway.yaml
```

| File | What it is |
|---|---|
| `00-namespace.yaml` | The `llm-d` namespace |
| `10-sim-prefill.yaml` | Simulated model server, prefill role, pinned to `k3s-agent-1` |
| `11-sim-decode.yaml` | Simulated model server, decode role, pinned to `k3s-agent-2` |
| `20-gateway.yaml` | The Gateway, implemented by agentgateway |
| `epp-pd-values.yaml` | Helm values for the endpoint picker, including the P/D decider |

The InferencePool and the endpoint picker are **not** manifests — they come from
the `llm-d-router-gateway` Helm chart, with `epp-pd-values.yaml` supplying the
scheduling configuration. The install order and version pins are in
[../hyperv-migration-plan.md](../hyperv-migration-plan.md).

Order matters in one place: the Gateway API Inference Extension CRDs must be
installed **before** agentgateway. Installed after, agentgateway's informer
blocks on a resource that does not exist yet and its GatewayClass is never
registered — which presents as a controller stuck at 0/1 with no useful log.
