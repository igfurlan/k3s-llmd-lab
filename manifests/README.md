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
| `05-render.yaml` | The tokenizer service. Real token IDs for both the simulators and the router |
| `10-sim-prefill.yaml` | Simulated model server, prefill role, pinned to `k3s-agent-1` |
| `11-sim-decode.yaml` | Simulated model server, decode role, pinned to `k3s-agent-2` |
| `20-gateway.yaml` | The Gateway, implemented by agentgateway |
| `epp-values.yaml` | Helm values for the InferencePool and endpoint picker — baseline scheduling |
| `epp-pd-values.yaml` | The same, plus prefill/decode disaggregation. Applied second, on purpose |
| `epp-precise-values.yaml` | The same again, plus **precise** prefix-cache routing: the EPP indexes the servers' real ZMQ cache events instead of estimating from its own past routing. Applied third — see [next-increments.md](../docs/next-increments.md). Needs the simulator image the two sim manifests pin (`pr668-seq0`); on v0.11.2 no event ever arrives |

## The model name appears in three places

`Qwen/Qwen2.5-1.5B-Instruct` must match in `05-render.yaml`, both simulator
`--model` arguments, and (once precise routing is configured) the EPP's
`token-producer` `modelName`. A mismatch is rejected rather than silently
tokenising against the wrong vocabulary.

It replaced `meta-llama/Llama-3.1-8B-Instruct`, which is **gated** on
HuggingFace — fetching its tokenizer needs an access token, and this lab's
"no credentials required" property is worth more than the model name.

Requests must use the new name:

```bash
curl -s http://192.168.58.11/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"..."}]}'
```

The InferencePool and the endpoint picker are **not** manifests — they come from
the `llm-d-router-gateway` Helm chart, with `epp-pd-values.yaml` supplying the
scheduling configuration. The install order and version pins are in
[hyperv-migration-plan.md](../docs/hyperv-migration-plan.md).

Order matters in one place: the Gateway API Inference Extension CRDs must be
installed **before** agentgateway. Installed after, agentgateway's informer
blocks on a resource that does not exist yet and its GatewayClass is never
registered — which presents as a controller stuck at 0/1 with no useful log.
