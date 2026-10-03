# Microservices Troubleshooting Notes

Oct 3, 2026

## Mental model

In microservices the service that **shows** the error is rarely the service that **caused** it. Find the first failing hop in the call chain, then ask what changed there.

- **A request is a chain.** `client → edge (LB/NGINX) → gateway → service A → service B → service C / DB / queue / external API`. Each hop adds latency, a timeout, retries and a failure mode.
- **Source vs victim.** When C is slow, B's threads and connections fill up, then A times out calling B, then the gateway returns 503/504 for A. Every service in the chain looks broken; only C is. The **deepest** service with errors or latency that has **no failing dependency of its own** is the source.
- **Errors travel up, causes travel down.** Start where users see it, follow the calls down until the errors stop. The last service still erroring is the source.
- **Partial is the norm.** One replica, one node, one zone, one version or one tenant failing looks like "intermittent". Always split by pod, node and version before concluding it's random.
- **Most incidents are changes.** A deploy, a config or secret change, a dependency's deploy, a certificate, a mesh upgrade, or load. Check the change timeline of every service in the chain, not just the one that alerted.

## Triage order

Seven steps, in order. Each step either finds the source or narrows where to look next.

1. **Scope.** Which user-facing API fails, since when, for whom (all users, one tenant, one region, PCI only). First error time comes from Kibana / Datadog.
2. **Locate the entry service.** The service behind that API: `kchain <svc> <ns>` shows the VirtualService, gateway, pods.
3. **Read its response flags.** `iaccess <pod> <ns> 30m` on the entry service. `UF/UH/NR` = problem at this hop; `UT/URX` or errors from the app = look downstream.
4. **Map its dependencies.** `kdeps <deploy> <ns>` (endpoints from env and ConfigMaps, ServiceEntries), plus APM service map if you have it.
5. **Walk down.** For each dependency: `iaccess` on its pods, `klogd` for errors, `kbad` / `koom` for health. Stop at the deepest service still failing.
6. **Check what changed there.** `krhist`, `hls-ro`, `kycmp` vs a healthy env, `ksec-stale`, `isc-ver`, and the dependency's own release history.
7. **Split the failure.** Per pod, node, version label and zone (`kchain` pods table, `iaccess` per pod). A single bad replica or version is the most common "intermittent".

Run steps 3–5 against the gateway pod too (`iaccess <igw-pod> istio-system`): if the gateway shows no traffic for the route, the problem is in front of the mesh.

## Map dependencies (who calls whom)

You can't walk a chain you can't see. Build the map from what each service is configured to call, then confirm with traffic data.

| Source | Shows | Command / where | Access |
| --- | --- | --- | --- |
| Workload config | outbound URLs and hosts in env vars and ConfigMaps; secret-held URLs by name | `kdeps <deploy> <ns>` | personal ID |
| ServiceEntries | external dependencies registered in the mesh (DBs, vendor APIs, brokers) | `kdeps` (section), `kyse <name> <ns>` | personal ID |
| Sidecar CRD | which hosts a namespace is *allowed* to call | `kdeps` (section), `isc-crd <ns>` | personal ID |
| VirtualServices | who receives traffic for a host, and from which gateway | `kchain <svc> <ns>`, `ivs` | personal ID |
| AuthorizationPolicy | which service accounts may call a service (inbound) | `kyap <name> <ns>` | personal ID |
| Access logs | real calls: upstream cluster and response per request | `iaccess`, `klogg <pod> <ns> outbound` | pods/log |
| APM / service map | live call graph with error rate and latency per edge | Datadog APM service map, Kiali if installed | browser |

Keep the result: one line per edge (`payments → accounts (http)`, `payments → pg-main:5432`, `payments → fraud.vendor.com (ServiceEntry)`). Put it in the incident notes; it becomes the walk-down list for steps 4–5 of triage.

`kdeps` reads configuration, not traffic: a URL in config that's never called shows up, and a host built at runtime doesn't. Confirm edges against access logs or APM.

## Golden signals

Judge every service with **RED** and every resource it uses with **USE**. Compare each against the same window yesterday or last week, not against zero.

| Signal | Question | Where to read it |
| --- | --- | --- |
| **R**ate | Did traffic change? A drop means callers fail before reaching it; a spike means retries or load | Datadog APM / Kibana request counts; `iaccess` line counts |
| **E**rrors | What share fails, and with which code + flag? | `iaccess` (code + Envoy flag), `kdd deploy/<x> <ns> 1h "error"` |
| **D**uration | p50 vs p99 latency; p99 alone rising = queueing or one slow dependency | APM latency; `istats-ro` (upstream_rq_time); app timing logs |
| **U**tilization | CPU, memory, connections, threads vs limits | `ktop <ns> cpu`, `isc-res`, app pool metrics |
| **S**aturation | queues, pending requests, throttling, consumer lag | APM / Prometheus (CPU throttling, pool waiters), broker lag |
| **E**rrors (resource) | OOM, restarts, evictions, connection refusals | `koom`, `krestarts`, `kwarn` |

Reading the combination:

- Errors ↑, rate normal, duration normal → a fast failure: config, auth, policy, a missing route or dependency refusing connections.
- Errors ↑, duration ↑ → timeouts: something downstream is slow; walk down.
- Duration ↑, errors flat → saturation building; it becomes an outage when timeouts trip.
- Rate ↓ at a service, errors ↑ upstream → the caller fails before calling (connection, DNS, mTLS, policy).
- Rate ↑ sharply with errors → a retry storm amplifying a smaller failure.

## Failure patterns

The fifteen patterns behind most microservice incidents. "Confirm" is read-only; the fix goes to the owner.

| Pattern | Symptoms | Confirm | Fix owner / direction |
| --- | --- | --- | --- |
| Cascading failure | many services erroring at once, latency rising up the chain | walk down until errors stop (triage step 5); deepest erroring service = source | source service team; callers add timeouts / breakers |
| Retry storm | request rate spikes during an incident, dependency overloaded further | rate ↑ with errors in APM; `URX` flags; VS retries in `kchain` at several layers | cap retries to one layer, add budgets |
| Timeout mismatch | `UT` / 504 at caller while callee eventually succeeds; or caller waits longer than its own client | compare VS timeout, app client timeout, gateway/LB timeout (next section) | align timeouts outside-in |
| Connection pool exhaustion | latency then errors under load, "pool exhausted" / "too many connections", DB fine otherwise | `klogg <pod> <ns> 'pool\|exhaust\|too many conn'`; DR `connectionPool`; `UO` flags | app pool size, DR limits, DB max connections |
| One bad replica | intermittent errors, roughly 1/N of requests | `iaccess` per pod; pods table in `kchain` (node, version, restarts) | owner recycles pod; outlier detection in DR |
| Version skew / contract break | 400/500 or deserialization errors right after a deploy of either side | `krhist` + `hls-ro` both services; `klogg` 'unrecognized\|deserializ\|schema' | roll back / make the change backward compatible |
| Config drift | works in UAT, fails in PROD; or one cluster only | `kycmp` each object in the chain; `kdeps` on both envs; `kycm` | align config via pipeline |
| Secret / credential change | 401/403 to a dependency, DB auth failures after rotation | `ksec-stale`; `klogg` 'auth\|401\|denied'; `tlscheck` for cert expiry | restart stale consumers; fix secret |
| Discovery / DNS | `UH`, NXDOMAIN, "unknown host" in app logs | `kepsvc`, `knoep`, CoreDNS logs, `kyse` for external hosts, `isc-crd` egress scope | add ServiceEntry / fix Service selector / Sidecar egress |
| mTLS / policy | 503 `UF` with TLS errors, 403 `rbac_access_denied` | PeerAuthentication + `kyap` in `kchain`; `isc-missing` (caller without sidecar) | align mTLS mode, add principal to policy |
| Rate limiting | 429s from a dependency or gateway | `iaccess` 429 counts; EnvoyFilter / gateway rate limits (`ief`) | raise limit or smooth caller traffic |
| Resource starvation | slow without errors, then timeouts; CPU throttled; OOMKilled | `ktop`, `koom`, `isc-oom`, `kalloc`; Prometheus throttling | requests/limits, HPA |
| Cold start / probes | errors right after scale-up or deploy; pods ready before app warm | `kd pod` probe events, `isc-status` (sidecar ready), restarts after rollout | readiness probe, startup probe, holdApplicationUntilProxyStarts |
| Async backlog | data late, consumers busy or restarting, no HTTP errors | consumer pod logs, restarts; broker lag in monitoring | scale consumers, fix poison message |
| External dependency | timeouts to one external host only, nothing changed internally | `klogg` for that host; `kyse`; `tlscheck` external host | vendor / network team |

## Timeouts, retries and circuit breaking

The rule: **each layer's timeout is longer than everything beneath it, including retries**, and only one layer retries. Broken budgets cause most 504s and retry storms.

Worked budget for `client → gateway → payments → accounts`:

| Layer | Setting | Example | Check with |
| --- | --- | --- | --- |
| Client / LB / NGINX | request timeout | 30 s | LB / NGINX config |
| Gateway → payments | VS `timeout` | 15 s | `kyvs <vs> <ns>`, `kchain` (TIMEOUT column) |
| payments → accounts | VS `timeout` × (1 + retries) | 3 s × (1 + 2) = 9 s | `kyvs` on accounts' VS (RETRIES column in `kchain`) |
| payments app HTTP client | client timeout | ≥ 9 s, so mesh retries finish first (or disable mesh retries and let the app retry) | app config (`kycm`, `kdeps`) |
| accounts → DB | query / pool wait timeout | 2 s | app config |

What to check when timeouts show up:

1. Collect every timeout and retry setting along the chain (VS, DR, app client, LB) into one table like the one above.
2. An inner total longer than its outer timeout means the caller gives up while work continues, and logs `UT` / 504 even though the callee "succeeded".
3. Retries at two or more layers multiply: 3 attempts × 3 attempts = 9 calls to the deepest service per user request.
4. Retries on non-idempotent calls (POST payments) can duplicate work; check the VS `retryOn` and the API's idempotency.

**Istio defaults to know.** HTTP routes without a `retries` block still retry up to 2 times on connection failures and some 5xx-like conditions; without a `timeout`, there is no route timeout, so the app client or LB decides. Set both explicitly in the VS.

**Circuit breaking** lives in the DestinationRule: `connectionPool` (max connections, pending requests; overflow → `UO` flag) and `outlierDetection` (eject a pod after N consecutive 5xx; ejected pods → fewer endpoints, possibly `UH`). Read both with `kydr <dr> <ns>`; `kchain` shows the outlier threshold.

## Correlation and tracing

One request crosses many pods; one ID ties its log lines together. Get the ID first, then search every service for it.

| ID | Created by | Visible in | Search with |
| --- | --- | --- | --- |
| `x-request-id` | Istio gateway / first sidecar, if absent | Envoy access logs on every hop; app logs only if the app logs it | `klq rid:<id> "" 2h`, `kkib rid:<id>`, `klogg <pod> <ns> <id>` |
| `traceparent` (W3C) / `x-b3-traceid` | tracing library or Envoy | APM traces; app logs with trace injection | Datadog APM trace view, `kdd rid:<trace-id>` |
| `dd.trace_id` | Datadog tracer | Datadog logs linked to traces | Datadog: open the trace → related logs |
| Business key (order id, payment id) | the app | app logs | `klq rid:<key>` (free-text search) |

**Propagation is the app's job.** Envoy creates and logs the headers, but a service must copy `x-request-id` and the trace headers from its inbound request onto its outbound calls. If it doesn't, the trace breaks at that service: the chain looks like two unrelated requests. Missing links in an APM trace usually mean a service that doesn't propagate, not a missing hop.

**Reading a correlated request.** Sort hits by time. Each service should show inbound then outbound lines. The last service with an inbound line but no successful outbound (or no response) is where it stopped. Compare its Envoy flag (`iaccess`) with its app log line at the same timestamp.

If the app doesn't log request IDs, raise it as a gap in the handoff: without them, every multi-service incident starts from timestamps alone.

## Releases: version skew, canaries, contract breaks

In microservices, "after the deploy" may mean a deploy of **any** service in the chain. List releases for every service you mapped, not just the one alerting.

| Question | Command | Look for |
| --- | --- | --- |
| What deployed, when, across the chain? | `krhist deploy/<svc> <ns>` and `hls-ro <ns>` per service; GitLab pipelines | a release minutes before the first error |
| Are two versions live at once? | pods table in `kchain` (VERSION label), `kimg <ns>` | old and new images side by side during or after a stuck rollout |
| Is traffic split by version? | `kyvs` (weights, subsets), `kydr` (subsets) | canary weight, subset label that matches no pods (→ `NR`/`UH`) |
| Does the error follow one version? | `iaccess` per pod, grouped by version label | errors only on new (or only old) pods |
| Did an API contract change? | `klogg <pod> <ns> 'deserializ\|unrecognized\|schema\|NoSuchField\|400'` on the **caller** | caller fails parsing callee's response, or callee rejects caller's request |
| Did the mesh change? | `isc-ver`, `isc-old <version>` | pods still on the old proxy after an Istio upgrade |

Contract breaks show up on the **caller's** side: the callee returns 200 with a new field shape, or 400 for a request it used to accept. Compare versions of both, and ask whether the change was meant to be backward compatible.

Environment comparison is the fastest test: if UAT runs the same versions and works, `kycmp` the VS, DR, Deployment and ConfigMap of each service in the chain.

## Async messaging and data layer

These failures rarely produce HTTP errors: data is late, missing or duplicated. kubectl shows the consumers; the broker and database show the cause.

**Queues and topics (Kafka, Service Bus, RabbitMQ)**

| Symptom | Check | Where |
| --- | --- | --- |
| Data late, lag growing | consumer pods healthy? `kbad`, `krestarts`, `koom` on consumer deploys | consumer ns |
| Consumers restarting in a loop | `klogp <pod>` for the message that crashed it; same offset every time = poison message | consumer ns; Kibana/DD for repeats |
| Lag after scaling | partitions vs consumer replicas (extra replicas sit idle) | broker metrics / monitoring |
| Duplicates | retries without idempotency; consumer rebalance mid-batch | consumer logs around rebalance time |
| Messages land in DLQ | DLQ count and the error recorded with them | broker UI / monitoring |
| Can't connect to broker | `kdeps` (bootstrap hosts), `kyse`, `isc-crd` egress, TLS: `tlscheck <broker> 9093` | consumer ns |

**Databases and caches**

| Symptom | Check | Where |
| --- | --- | --- |
| Pool exhausted / timeouts acquiring connection | `klogg <pod> <ns> 'pool\|timeout\|acquire'`; replicas × pool size vs DB max connections | app ns; DB team |
| Slow queries after a release | duration ↑ only on endpoints touching one table; release history | APM per endpoint; DB slow log (DB team) |
| Lock waits / deadlocks | `klogg ... 'deadlock\|lock wait'` | app logs; DB team |
| Cache miss storm | DB load spikes right after a cache restart or key change | cache metrics; app logs |
| Auth to DB fails after rotation | `ksec-stale <secret> <ns>`; app logs for auth errors | app ns |

The connection maths matters: 20 replicas × pool of 20 = 400 connections. An HPA scale-out can exhaust the database without any code change.

## Worked example

Illustrative incident: `POST /payments` returns 504 for about 30% of requests in PROD from 14:05; UAT is fine.

1. **Scope.** Kibana shows 504s start 14:05, PROD non-PCI only. `kuse npci-prod-dc1`.
2. **Entry service.** `kchain payments-api payments` → VS timeout 15 s, 6 pods ready, DR outlier threshold 5.
3. **Gateway flags.** `iaccess <igw-pod> istio-system 30m` → 504 `UT` on `/payments`: the gateway waited 15 s for payments-api.
4. **Dependencies.** `kdeps payments-api payments` → `accounts.accounts.svc:8080`, `pg-main.data.svc:5432`, `fraud.vendor.com` (ServiceEntry).
5. **Walk down.** `iaccess <payments-pod> payments` → outbound to accounts is fine (200 in 40 ms); outbound to `fraud.vendor.com` shows `UT` after 10 s, then retries. `klogd payments-api payments 30m` → "fraud check timeout".
6. **Budget.** Fraud call: 10 s app timeout × 2 attempts = 20 s, longer than the 15 s VS timeout above it. Any slow fraud response becomes a 504.
7. **Change.** No internal deploy. `tlscheck fraud.vendor.com 443` fine. `kycmp cm payments-config payments npci-uat-dc2 npci-prod-dc1` → UAT points at the vendor's sandbox; PROD calls the live endpoint, which the vendor's status page shows degraded since 14:00.
8. **Split.** All 6 pods affected equally (`iaccess` per pod), so not a bad replica.

**Handoff:** source = external fraud vendor latency; amplifier = timeout budget (20 s inside 15 s) plus app-level retry. Asks: vendor ticket; payments team to cut fraud timeout to 4 s with one retry and fail open/closed per business rule.

## Evidence and handoff

Copy this into the incident or change record. Every line should point at evidence, not opinion.

```markdown
**Impact:** <API / feature>, <% or count failing>, <users / tenants / PCI or non-PCI>, from <first error UTC> to <now | end>
**Chain:** <gateway> → <svc A> → <svc B> → <dependency>   (from kdeps / APM)
**Source:** <service or dependency> — <one sentence: what fails there>
**Amplifiers:** <timeout budget / retries / pool size / bad replica>, if any
**Trigger:** <deploy rev / config diff / secret rotation / vendor incident / load>, at <time>
**Evidence:** iaccess output, log lines with x-request-id, kycmp/kydiff diff, kexport folder, APM screenshot
**Ruled out:** <what was checked and is fine — saves the next person time>
**Asks:** <team> — <change requested via pipeline>; <team> — <ticket>
**Gaps found:** <missing request-id logging, no timeout set, no ServiceEntry, …>
```

Never paste secret values, tokens or full certificates. End any emerID session (`kemer-off`) and attach `kemer-audit`.
