# Inference Verification Protocol

Verathos uses probabilistic cryptographic audits for selected registered model
computations without requiring validators to load the model. The proof-v2 path
is an implementation candidate: its selected arithmetic is cryptographically
sound, but its general economic model-substitution claim remains release-blocked
on adversarial substitute-execution measurement.

For the transcript and proof details, see
[Proof Protocol v2](proof_protocol.md).

## Overview

For each proof-v2 response:

1. the validator commits to a hidden random nonce
2. the miner performs inference and streams every text token normally
3. the miner freezes commitments for the exact registered projection shell,
   captured runtime outputs, and causal decode trace
4. the validator reveals the nonce
5. the transcript selects the ordinary audit and, independently, any signed
   hard-execution audit, exact layers, and blocks
6. the miner proves those selected equations against authority-signed weight
   commitments
7. the validator verifies the response and applies proof policy

The final text token is not delayed for proof generation. The proof follows on
the same open SSE stream. One second from the last text token to the proof event
is a measured performance target, not an acceptance deadline.

## What validators need

Validators do not download full model weights or run inference. They need:

- the live on-chain `ModelSpec`
- the authority-signed proof-v2 manifest for the model
- tokenizer/chat metadata required for request binding
- the miner response commitment and proof payload

Miners need the same signed manifest plus the matching static weight catalog
used to construct polynomial openings.

## Protocol flow

```mermaid
flowchart TD
    A[Validator creates nonce and commitment] --> B[Inference request]
    B --> C[Miner streams all text tokens immediately]
    C --> D[Miner freezes all-layer X/runtime-Y and response commitment]
    D --> E[proof_precommit with H(C)]
    E --> F[Validator reveals nonce while full C streams]
    F --> G[Validate H(C), then derive exact light or signed-hard layer/block challenges]
    G --> H[Miner builds batched sumcheck and IPA proof]
    H --> I[done SSE proof event]
    I --> J{Validator verification}
    J -->|pass| K[Successful completion and usage settlement]
    J -->|fail| L[Terminal error, no success receipt or usage settlement]
```

The nonce reveal is a small authenticated POST to
`/proof/v2/challenge`; it is not a second inference request.

## Light execution audit

The signed dense execution profile registers the exact projection families used
by each layer:

```text
full attention: QKV, output, fused MLP gate/up, MLP down
GDN attention:  QKVZ, BA, output, fused MLP gate/up, MLP down
```

Before the validator reveals its nonce, the miner commits canonical X rows,
captured runtime-Y data, and the per-token causal trace for every registered
layer operation. Challenge selection therefore happens after the complete
sampling universe is frozen.

Current defaults select approximately 6.25% of layers:

| Layers | Selected per request |
|---:|---:|
| 32 | 2 |
| 64 | 4 |
| 80 | 5 |

The light tier chooses one operation in each selected layer. For each selected
operation, the verifier checks an exact registered block of:

```text
X × W = Y
```

`W` comes from the signed model manifest. `X` and runtime `Y` come from the
pre-challenge response commitment. The light tier leaves the causal trace
sealed, so a light success proves the selected equations but does not alone
prove that they produced the returned token. The verifier rejects missing,
duplicate, or unexpected operations, coordinates, dimensions, transcript
rounds, and miner-supplied trace openings.

## Hard execution audit

The hard tier is selected after commitment by the validator nonce and the
authority-signed execution-profile policy. The policy signs the hard-audit rate,
layer strata, selected-head minimums, and block coverage per operation. It is
not controlled by the caller-visible `sampling_verification_bps`: a request at
`10000` bps neither forces a hard audit nor reveals that a hard audit will be
required.

When selected, the verifier opens one transcript-selected generated decode row
across every model layer and requires a contiguous residual corridor. It
authenticates the row's decode-input embedding and binds its final hidden row
through final normalization, LM head, sampler, and returned token. Separately,
it proves every registered linear operation only in the stratified selected
layers, at the signed number of blocks per operation. Full-attention/GDN
transition replay is restricted to those selected transition layers; it is not
a replay of every layer in the corridor.

For selected witnesses, the verifier checks causal-trace cross-membership and
replays the signed RMSNorm, residual, and SiLU bridges. For selected
full-attention layers, it opens precommitted logical K/V prefixes for
nonce-selected heads and replays signed RoPE/GQA causal attention over the
generated suffix. For selected GDN layers, it opens the captured prompt state
and replays the generated suffix through the signed transition.

This does not prove that the opened corridor or post-prefill cache boundary was
produced by registered-model prefill, or that unselected operations executed.
The raw K/V full-attention path is a bounded reference adapter, not a qualified
250k- or 1m-context proof path. A request outside its qualified trace or payload
limits must fail closed rather than receive a hard-audit success.

## Decode and LM-head sampling

`sampling_verification_bps` governs the ordinary caller-visible decode-sampling
audit. It is distinct from the signed hard-execution policy described above.

Current ordinary decode-sampling policy:

| Traffic | Requested rate |
|---|---:|
| Organic | `1000` bps, approximately 10% |
| Canary | `10000` bps, every eligible ordinary decode audit |

When the ordinary decode gate selects it, the challenge opens one to three
output positions depending on response length. The validator checks:

- the output token is part of the committed token history
- the hidden row belongs to the committed hidden-row tree
- the canonical top-k logits row belongs to the committed logits-row tree
- greedy selection or supported canonical sampled replay matches the committed
  token

One selected position also receives an authenticated `model.lm_head` PCS audit
over four vocabulary blocks. The required blocks include the returned token
and committed top token; additional blocks are transcript-selected from top-k
and outside regions.

A selected hard audit derives its own canonical LM-head/sampler witness from
the post-commitment transcript even when ordinary decode sampling is zero. The
request BPS field must not be used to suppress, require, or predict that hard
audit.

This prevents a valid challenged LM-head opening from using substituted
LM-head weights. It is a sampled audit, not a full proof of every vocabulary
logit.

## Security claims

| Claim | Proof-v2 status |
|---|---|
| Miner changes a selected registered weight | Rejected by signed-manifest PCS opening |
| Miner changes selected X or runtime Y after seeing the challenge | Rejected because both were precommitted |
| Miner omits a selected layer/block | Rejected by exact-set enforcement |
| Miner chooses fake dimensions or transcript length | Rejected by verifier-owned layout |
| Miner returns token IDs different from the committed response | Rejected |
| Miner substitutes LM-head weights in a selected decode audit | Rejected |
| Miner attaches valid selected equations to a disconnected endpoint trace | Rejected by the hard full-row corridor; light alone does not make this claim |
| Miner constructs a self-consistent synthetic corridor or fabricated post-prefill cache | Not yet established as unprofitable; this is a release-blocking adversarial benchmark |
| Miner serves substituted work outside sampled claims | May escape one request; no general pass-rate bound is claimed before the substitute benchmark |
| RMSNorm, residual, and SiLU bridges in a hard-tier opened layer | Canonically replayed |
| Selected full-attention/GDN generated transition | Independently replayed from its precommitted state boundary; remaining heads/columns stay sampled |
| Earlier prompt-prefill execution states | Prompt/input bound, but not independently opened or recomputed |

Selected equations are cryptographically sound in both tiers. The accurate
description of this implementation candidate is a probabilistic selected-
computation audit: hard audits strengthen response binding, but do not yet make
a general whole-model or economic-substitution guarantee.

For a hard-tier defect that necessarily invalidates every operation in one
layer, and whose sampled witnesses are causally meaningful:

```text
P(caught after m requests) = 1 - (1 - k/N)^m
```

At `k/N = 6.25%`, detection across hard audits is approximately:

| Requests | Cumulative probability |
|---:|---:|
| 10 | 48% |
| 36 | 90% |
| 72 | 99% |

A light audit also samples one operation within each selected layer. Its
single-operation detection rate is therefore lower than the layer-only table.
The table is a conditional layer-local calculation, not a measured pass-rate
for a substituted model. That pass rate must come from the adversarial
substitute-execution benchmark.

## Streaming and proof failure

Text deltas are forwarded as soon as the miner produces them. The proxy does
not hold the last token to make proof timing look smaller.

Outside an active maintenance suppression, the OpenAI-compatible success finish
and usage events are emitted only after local proof verification succeeds. If
verification fails:

- the stream ends with an error
- no successful organic receipt is created
- API-key credit is not deducted
- x402 reserved usage is released by failure cleanup
- the miner enters the configured local/network probation path

Already streamed text cannot be recalled, which is why the stream reports a
terminal verification error instead of a successful completion.

## Proof-version transition

Proof-version compatibility is separate from operational maintenance. During a
bounded `prefer_v2_allow_v1` transition, validators and proxies prefer v2 but
may request and accept a valid v1 proof from a miner that advertises only v1.
Invalid v1 and v2 proofs remain invalid. An accepted v1 proof is recorded as
`legacy_compatibility`, never as a v2 or hard-audit success. Once the configured
epoch or Unix-time deadline passes, `v2_required` behavior takes effect and v1
is rejected through the normal failure path.

The transition must have a deadline; an open-ended v1 compatibility mode is
not valid configuration.

## Operational maintenance grace

Maintenance grace supports coordinated software and artifact updates. It does
not select a proof protocol and never downgrades a v2 request to v1. When its
configured suppression flags are active:

- missing or failed inference proofs remain recorded as unverified but do not
  cause score zeroing, proxy strikes, or probation
- missing or failed canaries do not cause score zeroing or probation
- hot-capacity failures remain observable but do not activate its score gate or
  probation
- an organic response may complete and settle as unverified

When maintenance expires, the independently configured proof-version policy
continues unchanged. Maintenance therefore provides the update window; bounded
v1 compatibility controls whether a valid legacy proof is accepted. Unverified
maintenance observations do not contribute proof coverage or pass-rate evidence.

## Hot-capacity audit

Inference proofs and hot-capacity audits cover different risks.

The inference proof samples registered response computations. The hot-capacity
audit verifies that an endpoint can perform a validator-scheduled calibrated
GPU workload within its deadline and cannot multiply registrations over one
physical resource without losing capacity. It cannot establish that a committed
inference trace was produced by the registered model.

Capacity v2 uses validator-owned workload parameters and `gpu_index=0`,
pre-challenge commitments, later chain entropy, sampled workspace transitions,
GEMM proof, and FP64 binding. Failure probation is applied only after the
relevant chain blocks finalize; reorged audits do not penalize miners.

## Performance model

Proof work runs after inference capture and outside the token-generation path.
The candidate implementation:

- streams tokens without proof buffering
- starts deterministic X/runtime-Y commitment preparation as the final
  capture becomes immutable, overlapping final-token transport without
  delaying that token
- releases inference/KV admission before CPU proof completion where safe
- generates proofs in a bounded background pool
- uses native batched sumcheck and IPA code
- bounds native PCS worker parallelism to avoid all-core contention
- batches layer and LM-head claims into one proof path

The release gate measures real last-token-to-proof latency, miner proof time,
validator verification time, payload size, and concurrent-request behavior on
the isolated miner/validator setup. Any long-context hard-attention path needs
its own qualified bounded-witness design and measurements; the current raw K/V
reference path is not a 250k- or 1m-context solution.
