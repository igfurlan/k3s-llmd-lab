# Model backends — simulated, local, and hosted

This lab runs **simulated** inference by default. That is a deliberate constraint of the
hardware, not a limitation of the architecture — and swapping in a real model changes
**one resource**. Everything else in the stack stays exactly as it is.

## Why simulated here

Three independent facts rule out running real vLLM on this host:

1. VirtualBox has no GPU passthrough, so the host's RTX 5070 Ti is invisible to every guest.
2. vLLM's CPU backend requires AVX-512, which VirtualBox does not expose to guests. Measured
   in the running VMs: `avx avx2`, nothing beyond.
3. VirtualBox runs under Hyper-V's platform here (no AMD-V), costing nested paging and
   sometimes AVX2 itself.

So the model servers are [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) —
the llm-d project's own GPU-free vLLM mock. It is OpenAI-API compliant, models prefill and
decode latency, degrades realistically under concurrency, and emits vLLM-compatible
Prometheus metrics.

**What that costs:** no real tokens, no meaningful throughput numbers.
**What it preserves:** the gateway, the endpoint picker, `InferencePool` routing,
KV-cache-aware scheduling, prefill/decode disaggregation, and the entire observability story.

## The three modes

| | Simulated | Local (ollama) | Hosted (Claude) |
|---|---|---|---|
| Real tokens | No | Yes | Yes |
| Runs where | In-cluster | In-cluster, CPU | Anthropic's API |
| Needs a GPU | No | No (slow on CPU) | No |
| Needs credentials | No | No | **Yes — API key** |
| Costs money | No | No | Per token |
| Model quality | n/a | Small models only | Frontier |
| Good for | Routing, scheduling, metrics | End-to-end realism | Real application work |

The instructive part: **the Gateway, HTTPRoute, InferencePool and metrics pipeline are
identical in all three.** Only the backend resource changes. That is the whole argument for
an inference gateway — the application talks to one OpenAI-compatible endpoint and never
learns where the tokens came from.

---

## Local inference with ollama

ollama runs on CPU and exposes an OpenAI-compatible API. On these nodes it works because the
guests do have **AVX2** — expect a 1B-class quantised model to be usable and anything larger
to be slow.

Deploy ollama in-cluster, then point a backend at it:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:
        model: llama3.2
      host: ollama.agentgateway-system.svc.cluster.local
      port: 11434
      path: /v1/chat/completions
```

Note the `openai` provider block pointing at an ollama service — ollama's OpenAI-compatible
endpoint is consumed through the OpenAI provider shape rather than a dedicated one.

Attach it to the gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ollama
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - backendRefs:
        - name: ollama
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

**Storage note:** model weights land in a PersistentVolume. On these nodes that means
local-path, which writes to `/var/lib/rancher` — the 30 GB disk, not the 8.9 GB root. A 1B
model is under a gigabyte; a 7B quantised model is several.

---

## Hosted inference with Claude

Useful when you want real answers from a frontier model without any local compute. The
gateway becomes a policy and observability layer in front of Anthropic's API — which is
arguably agentgateway's strongest use case, since it also brings token budgets, rate limits
and prompt redaction.

**The API key is a real credential.** It goes in a Secret, never in a manifest that reaches
git — the same discipline as the k3s join token and the kubeconfig.

```bash
export ANTHROPIC_API_KEY=<your key>

kubectl apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-secret
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: $ANTHROPIC_API_KEY
EOF
```

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: anthropic
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic:
        model: "claude-sonnet-5"
  policies:
    auth:
      secretRef:
        name: anthropic-secret
```

agentgateway sends the token in the `x-api-key` header automatically.

Model IDs for the current generation: `claude-opus-5`, `claude-sonnet-5`, and
`claude-haiku-4-5-20251001`. Sonnet is the sensible default; Opus for harder reasoning,
Haiku when latency and cost matter most.

**Do not commit the key.** Use a `.env` file that `.gitignore` excludes, your shell history
settings, or a real secret manager. A repository that rebuilds a whole cluster from one
command must not also hand over the credentials to it.

---

## Switching between them

Because all three speak the same OpenAI-compatible API through the same gateway, a client
never changes:

```bash
curl http://<gateway-address>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"...","messages":[{"role":"user","content":"hello"}]}'
```

Only the `model` field and the backing `AgentgatewayBackend` differ. You can run more than
one at once and route between them on path, header or model name — which is the natural next
experiment once the simulated path works: **send cheap requests to a local model and hard
ones to Claude, decided at the gateway.**
