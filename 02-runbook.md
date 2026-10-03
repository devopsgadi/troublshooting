# K8s / Istio Troubleshooting Runbook — What to Run, When, Where

Oct 3, 2026

## Ground rules

Diagnose, collect evidence, hand off. Nothing in this runbook changes a cluster.

- **Read-only.** No delete, apply, exec, restart or rollback, with either identity. The profile blocks those verbs; fixes go through the pipeline owner.
- **Identity.** Start with your personal ID. Switch to emerID (`kemer`) only when a step says *needs secrets* or *needs portforward* and your ID lacks it (`kcan`).
- **Where.** "Where" in each table means: which context/zone, which namespace, which identity. PCI clusters: run from the PCI jump host.
- **One terminal per cluster** for UAT/PROD (`kuse`), so nothing switches under you.
- **Write it down as you go.** Every check's output is evidence for the handoff (last section).

## First 5 minutes

Narrow scope before opening any logs.

1. **Frame it.** Answer from the ticket or report:

| Question | Why |
| --- | --- |
| What exactly fails? (one API, one feature, everything) | picks the service path |
| Who / where? (one user, region, PCI only, one cluster) | blast radius |
| Since when? (first error timestamp in Kibana/monitoring) | anchors the timeline |
| What changed around then? | most incidents are a change |
| Still happening, or intermittent? | live checks vs log forensics |

2. **Pick the context.** Same check on each affected cluster.

```bash
kzone npci            # or pci / aks
kuse npci-prod-dc1    # pin this terminal
kcur                  # confirm context + namespace
kinfo                 # cluster details: Rancher id, versions, identity, ingress IP
kscan                 # quick health across this cluster's app namespaces
kcan payments         # what this identity can read here
```

3. **Triage the namespace.**

```bash
ktriage payments
```

Output covers: pods not ready, pending, OOMKilled, unbound PVCs, deployments not available, services without endpoints, warning events, Istio objects, `istioctl analyze`, Helm releases. Anything red here sets the next section; if all clean, go to *Find the change*.

## Find the change

Check in this order — most likely cause first. Stop when one lines up with the first-error time.

| # | Change | Command | Where | Needs |
| --- | --- | --- | --- | --- |
| 1 | App deploy | `krhist deploy/<app> <ns>`, `hls-ro <ns>`, GitLab pipeline history | affected cluster, app ns | personal ID |
| 2 | Config drift | `kycmp <kind> <name> <ns> <uat-ctx> <prod-ctx>`, `kydiff ... <repo-file>` | `kzone all` (both contexts loaded) | personal ID |
| 3 | Secret / cert rotated or expired | `tlscheck <host> 443 <gw-ip>`, `ksec-stale <secret> <ns>`, `kcerts` | gateway: `istio-system`; app secret: app ns | `tlscheck` none; others need secrets → emerID |
| 4 | Istio upgrade / proxy skew | `isc-ver`, `isc-old <version>` | affected cluster | personal ID |
| 5 | New or changed EnvoyFilter | `ief`, `ief-who <name> <ns>` | all ns, then filter's ns | personal ID |
| 6 | Control plane rejected config | `icp` (istiod NACK / rejected lines) | `istio-system` | personal ID |
| 7 | Platform events | `knodes`, `kwarn`, `kcattle`; Azure Activity Log for AKS | cluster-wide | personal ID (+ Azure Reader) |
| 8 | External dependency | app logs for connect/timeout to DB/API | app ns | personal ID |

Nothing changed on our side → suspect load, data, or an external dependency.

## Walk the request path

Follow one request outside-in. At each hop ask: *did it arrive, did it leave?* The first hop where the answer flips is the problem.

`DNS → LB / NGINX Plus → Istio ingress gateway → VirtualService → Service → sidecar → app → downstream`

| Hop | Command | Where | Looks wrong when |
| --- | --- | --- | --- |
| DNS | `dig <host>` | workstation | wrong IP / no answer |
| LB / NGINX Plus | `gwcurl <host> <path> <lb-ip>` vs via DNS; NGINX Plus upstream dashboard | workstation | differs by path taken, upstream down |
| Gateway TLS | `tlscheck <host> 443 <gw-ip>`, `igw-cred` | workstation; `istio-system` | expired, SAN mismatch, chain incomplete, credentialName missing |
| Gateway | `iaccess <igw-pod> istio-system 30m` | `istio-system` | NR, UH, 404 with no `x-envoy-upstream-service-time` |
| Routing | `kchain <svc> <ns>`, `ianalyze <ns>` | app ns | no VS for host, wrong gateway binding, port mismatch |
| Service → pods | `kepsvc <svc> <ns>`, `kbad <ns>` | app ns | no endpoints, pods not ready |
| Sidecar | `isc-status <pod> <ns>`, `iaccess <pod> <ns>` | app ns | sidecar not ready, UF/UC flags |
| App | `klogd <deploy> <ns> 30m`, `klogp <pod>`, `koom <ns>` | app ns | exceptions, crashes, OOM |
| Downstream | app logs; `kyse <name> <ns>`, `knetpol <ns>` | app ns | connect timeouts, egress blocked |

**Correlate one request end to end.** Take the `x-request-id` from the gateway access log, then:

```bash
klogg <pod> <ns> <request-id> 1h     # sidecar + app lines for that request
```

## Kibana / Datadog handshake

kubectl shows the **current state** (which pod is unhealthy, since when, why it restarted). Kibana and Datadog show **history and volume** (what it logged before it died, across all replicas, beyond the last restart). Move between them using four shared keys: **cluster, namespace, pod (or deployment), time window** — plus `x-request-id` / trace id for a single request.

**Direction 1 — kubectl first** (`ktriage` / `kbad` found a bad pod):

```bash
klq payments-api-7d9f-abcde payments          # prints KQL + Datadog query + window
kkib payments-api-7d9f-abcde payments          # opens Kibana Discover, pre-filtered
kdd  deploy/payments-api payments 2h "error"   # opens Datadog Logs for all replicas, last 2h, errors
ddsearch payments-api-7d9f-abcde payments      # or read the latest 50 lines in the terminal
```

For a pod that has restarted, the window is set automatically to **15 min before → 5 min after its last container exit**, which is where the cause usually is (`klogp` only shows the last crash; the log platform shows all of them).

**Direction 2 — logs first** (alert, error spike, or a user's request id):

1. From the log line, note `kube_cluster_name` / cluster field, namespace, pod name, timestamp.
2. Jump to the cluster: `kgo onprem-prod-dc1 payments payments-api-7d9f-abcde` — maps the log cluster name to the context, pins this shell, shows pod status, last exit reason, and its events. If the pod is gone, it lists the current pods of the same workload.
3. Continue with the runbook: `kchain`, `iaccess`, `isc-status`, `kycmp`.

**Direction 3 — one request end to end:**

```bash
klq rid:5f1c2e9a-... "" 2h       # finds the request id across every pod in the cluster
kkib rid:5f1c2e9a-... "" 2h
```

Read the hits in time order: gateway access log → sidecar → app. The last hop that logged it is where it failed.

| Command | Does | Needs |
| --- | --- | --- |
| `klq <pod\|deploy/x\|ns:N\|rid:ID> [ns] [since] [extra]` | print KQL + Datadog query + window | `logs.conf` |
| `kkib …` / `kdd …` | open the platform pre-filtered | SSO in browser |
| `ddsearch …` / `kibsearch …` | latest lines in the terminal | read-only API keys (session only) |
| `kgo <log-cluster> <ns> [pod]` | log line → cluster, pod state, events | `logs.conf` |
| `klogkeys-clear` | drop API keys from the shell | — |

What to look for in the platform that kubectl can't show: the first error before a crash loop started, whether all replicas fail or one, error rate before vs after a deploy time (from `krhist`), and errors from pods that no longer exist.

## HTTP symptoms (5xx / 4xx)

Start with `iaccess <pod> <ns> 30m` on the gateway pod (`istio-system`) and on the app pod. The Envoy response flag tells you which hop failed.

| Code + flag | Meaning | Next check | Where |
| --- | --- | --- | --- |
| 503 **UF** | upstream connect failure | `kchain` — targetPort vs container port, port name; app listening? `klogd` | app ns |
| 503 **UC** | upstream closed connection | app logs at that time; keep-alive / idle timeouts | app ns |
| 503 **UH** | no healthy upstream | `kepsvc`, `kbad`, DR outlier detection in `kchain` | app ns |
| 404 / 503 **NR** | no route | `ivs <ns>`, `kyvs` hosts + gateways, `ianalyze` | app ns + `istio-system` |
| 504 **UT** | upstream timeout | VS timeout in `kchain`, app latency in `klogd` | app ns |
| 503 **URX** | retries exhausted | VS retries in `kchain`, then the underlying flag | app ns |
| 503 **UO** | circuit breaker overflow | DR `connectionPool` (`kydr`) | app ns |
| 0 / 499 **DC** | client disconnected | client timeout shorter than server; check LB/NGINX timeouts | edge |
| 403 `rbac_access_denied` | AuthorizationPolicy | `kyap <name> <ns>`, PeerAuthentication in `kchain` | app ns + `istio-system` |
| 403 **UAEX** | ext-authz denied | ext-authz service logs | authz ns |
| 500 with `via_upstream` | the app itself returned it | app logs (`klogg <pod> <ns> <request-id>`) | app ns |
| 502 at LB, nothing in gateway log | never reached the mesh | `gwcurl` direct to gateway IP, LB/NGINX health | edge |

3xx loops: compare the VS `redirect` / `rewrite` rules (`kyvs`) and app redirect settings for scheme/host.

## Non-HTTP symptoms

| Symptom | Likely layer | Run | Where |
| --- | --- | --- | --- |
| Hang / no response | timeout chain, downstream, NetworkPolicy | `iaccess` (UT/DC), VS timeout in `kchain`, `knetpol <ns>` | app ns |
| Connection reset / refused | port mismatch, app not listening, mTLS mode | `kchain` (ports, port names, appProtocol), PeerAuthentication; `iaccess` UF/UC | app ns |
| Slow but succeeds | CPU throttling, GC, downstream latency, retries | `ktop <ns> cpu`, `istats-ro <pod> <ns>`, app timing logs; throttling needs Prometheus | app ns |
| Intermittent | one bad pod / node / zone, outlier ejection | `kbad`, `krestarts`, NODE column in `kchain`, `iaccess` per pod | app ns |
| Pods flapping | probes, OOM, sidecar start order | `kd pod <name>` (probe events), `koom`, `isc-status` | app ns |
| Wrong behaviour / data | config or image drift | `kycmp`, `kycm`, `hls-ro` image tags | app ns, both envs |
| Works in UAT, fails in PROD | env-specific objects | `kycmp` each object from `kchain`, `ief`, `isc-ver` | `kzone all` |
| DNS errors in app logs | CoreDNS, ServiceEntry, egress | `kubectl logs -n kube-system -l k8s-app=kube-dns --since=30m`, `kyse` | `kube-system`, app ns |
| Jobs failing | job pods, quota | `kjobs <ns>`, `klogp`, `kquota <ns>` | app ns |
| Whole mesh affected | control plane, mesh-wide filter, webhooks | `icp`, `ief` (no selector in `istio-system`), `kwebhooks`, `isc-injector` | `istio-system` |
| Cluster shows unavailable in Rancher | Rancher agents | `kcattle` | `cattle-system` |

**Bisect.** Find a working instance of the same thing and diff it: one pod vs the others (node, version label, restarts), PROD vs UAT (`kycmp`), PCI vs non-PCI (certs, policies), before vs after a release (`kydiff`, `hls-ro`).

## Secrets and certificates

How a secret is consumed decides whether a change reaches the pod.

| Consumed as | Picks up a change? |
| --- | --- |
| `env` / `envFrom` | never — pod must restart |
| volume mount | yes, after ~60–120 s; app must re-read the file |
| volume with `subPath` | never — pod must restart |
| Gateway `credentialName` (SDS) | yes, live |
| `imagePullSecrets` | only on next image pull |

**"Secret updated, app still uses the old value"** — app ns:

1. `ksec-users <secret> <ns>` — which pods use it (personal ID).
2. `ksec-owners <secret> <ns>` — which deploy/sts/ds templates reference it (personal ID).
3. `ksec-stale <secret> <ns>` — STALE = pod started before the secret's last update (needs secrets → emerID).
4. `ksecd <secret> <ns>` — actual value; watch for a trailing newline (needs secrets → emerID).
5. Hand off: the STALE workloads need a restart by the owner.

**TLS errors at the gateway** — `istio-system`:

1. `tlscheck <host> 443 <gw-ip>` — expiry, SANs, chain, verify result. No cluster access needed.
2. `igw-cred` — each Gateway server's `credentialName` and whether the secret exists in the gateway pod's namespace (reports "no secret read" instead of a false MISSING).
3. With emerID: `kcert-match <secret> istio-system` (key ↔ cert), `kcert-chain` (missing intermediate), `kcerts` (all expiries).
4. With portforward: `igw-secrets` — did Envoy load it (ACTIVE vs WARMING).
5. `iistiod | grep -i <secret>` — SDS fetch errors.

Common causes: secret in the app namespace instead of the gateway's; wrong type or key names; mTLS CA not in `<credentialName>-cacert`; Gateway host not in the cert SAN.

**Other:** `ErrImagePull` → `kwarn <ns>` then `ksecd <pull-secret> <ns>` (registry/auth). RBAC questions → `kubectl auth can-i get secret/<name> -n <ns> --as=system:serviceaccount:<ns>:<sa>`.

## EnvoyFilter and sidecar issues

**EnvoyFilter.** Istio does not validate EnvoyFilters: a bad match is silently ignored, a bad patch can be rejected by every proxy it targets. Answer three questions in order.

| Question | Command | Where |
| --- | --- | --- |
| Which filters exist, and who do they hit? | `ief` then `ief-who <name> <ns>` (warns if mesh-wide) | all ns; filter's ns |
| Did proxies reject it? | `icp` (NACK lines), `ips` (STALE) | `istio-system` |
| Is it in the live config? | `igw-listeners` / `ipc listeners <pod> <ns>` (needs portforward) | gateway or app ns |
| What does it say? | `kyef <name> <ns>`; save all with `kexport` | filter's ns |

Common causes: selector doesn't match pod labels; no selector in `istio-system` = whole mesh; wrong `context` (`GATEWAY` vs `SIDECAR_INBOUND`/`SIDECAR_OUTBOUND`); filter in the wrong namespace for the gateway; after an Istio upgrade a `proxyVersion` regex no longer matches or filter/`@type` names changed; two filters patching the same chain (`priority`).

**Sidecar.**

| Symptom | Command | Where |
| --- | --- | --- |
| Pod has no sidecar / mTLS failures from it | `isc-missing <ns>`, then `isc-check <pod> <ns>` | app ns |
| Wrong revision / webhook not matching | `isc-injector`, `iinject` | cluster |
| Sidecar not ready, app starts first | `isc-status <pod> <ns>` | app ns |
| Proxy version skew after upgrade | `isc-ver <ns>`, `isc-old <version> <ns>` | app ns |
| istio-proxy OOM / restarts | `isc-oom <ns>`, `isc-res <ns>` | app ns |
| iptables / CNI init failure | `isc-init <pod> <ns>` | app ns |
| 404 / NR / 503 to some hosts only | `isc-crd <ns>` (Sidecar egress scoping) | app ns |

## Pods, scheduling and rollouts (read-only)

| Pod state | Run | Look for |
| --- | --- | --- |
| Pending | `kpending <ns>`, `kalloc`, `kquota <ns>`, `kpvc <ns>` | insufficient CPU/memory, taints/affinity, quota, PVC not bound |
| CrashLoopBackOff | `klogp <pod>`, `koom <ns>`, `kd pod <pod>` | exception before crash, OOMKilled, exit code, probe failures |
| ImagePullBackOff | `kwarn <ns>`, `kimg <ns>` | wrong tag, registry auth, network |
| Running, not Ready | `isc-status <pod> <ns>`, `klog <pod>`, `kd pod <pod>` | sidecar not ready, readiness probe failing |
| Restarting | `krestarts`, `koom`, `klogp` | memory limit, liveness probe too tight |
| Evicted | `kwarn <ns>`, `knodes` | node Memory/Disk/PID pressure |

**Rollout stuck** (`kubectl rollout status` doesn't finish):

```bash
krstuck deploy/<app> <ns>     # conditions, old vs new ReplicaSet, pods, PDB, HPA, quota, warnings
krhist  deploy/<app> <ns>     # revisions; krhist deploy/<app> <ns> <rev> for one revision's spec
```

Typical causes: new pods fail readiness (check `klogp`, `isc-status`), PDB `minAvailable` equal to replicas, ResourceQuota exhausted by `maxSurge`, image or secret errors on the new ReplicaSet, nowhere to schedule. Diagnosis ends here; the restart or rollback is done by the owner through the pipeline.

## Command reference

Every command in the profile, grouped by area. "Needs" is the permission beyond basic read; check yours with `kcan`. Full list in the shell: `khelp`. Log platform commands (`klq`, `kkib`, `kdd`, `ddsearch`, `kibsearch`, `kgo`, `klogkeys-clear`) are listed under *Kibana / Datadog handshake*.

| Area | Command | When | Where | Needs |
| --- | --- | --- | --- | --- |
| Context | `kcur`, `kctx`, `kns`, `kuse`, `kmerge`, `kzone` | start of every session | any | — |
| Context | `kcan [ns]` | first time on a cluster / identity | target ns | — |
| Cluster | `kls`, `kls -p` | which kubeconfigs exist, auth type, expired/unreachable | workstation | — |
| Cluster | `kinfo` | details of the current cluster (Rancher id, versions, identity, ingress IP) | current context | — |
| Cluster | `kinv [ctx]`, `kgwip`, `kappns` | inventory facts: gateway IP, app namespaces, owner | workstation | — |
| Namespaces | `kns-sync [ctx\|--all] [selector]` | refresh namespace lists (AKS, many ns) | workstation | list namespaces |
| Namespaces | `kns-add`, `kns-ignore`, `kns-rm` | pin by hand (on-prem), hide, remove | workstation | — |
| Namespaces | `kns-ls`, `kns-count`, `kns-find <pattern>` | show lists, which cluster has a namespace | workstation | — |
| Triage | `ktriage <ns>` | first look at a namespace | app ns | — |
| Triage | `kscan` | quick health across all app namespaces of a cluster | current context | — |
| Pods | `kbad`, `kpending`, `koom`, `krestarts`, `kdbad` | pods unhealthy | app ns or all | — |
| Pods | `kd pod <name>`, `kimg`, `kalloc`, `knodes`, `ktop`, `ktopn` | scheduling, resources | ns / cluster | nodes, metrics |
| Events | `kev [ns]`, `kwarn [ns]` | anything changed in the last hour | ns | — |
| Logs | `klog`, `klogp`, `klogl`, `klogd`, `klogg` | app errors, crashes, request tracing | app ns | pods/log |
| Logs | `iaccess <pod> <ns>`, `iproxylog` | any HTTP error | gateway or app ns | pods/log |
| Logs | `iistiod`, `icp` | config not applied, mesh-wide issues | `istio-system` | pods/log |
| YAML | `ky`, `kyvs`, `kydr`, `kygw`, `kyse`, `kyef`, `kyap`, `kysvc`, `kydep`, `kycm` | read one object cleanly | object's ns | — |
| YAML | `kchain <svc> <ns>` | routing / connectivity to a service | app ns | Istio CRD read |
| YAML | `kycmp`, `kydiff`, `kexport` | drift, before/after, evidence | `kzone all` for `kycmp` | — |
| Istio | `inet`, `ivs`, `ief`, `ief-who`, `ianalyze`, `iinject`, `iver` | Istio config | ns / cluster | Istio CRD read |
| Istio | `ips`, `ipc`, `igw-routes`, `igw-listeners`, `igw-secrets`, `igw-ep` | live Envoy config | gateway / app pod | pods/portforward |
| Istio | `istats-ro`, `isc-ready-ro` | Envoy stats / readiness without exec | app pod | pods/proxy |
| Sidecar | `isc-missing`, `isc-check`, `isc-status`, `isc-ver`, `isc-old`, `isc-oom`, `isc-res`, `isc-init`, `isc-crd`, `isc-injector` | sidecar problems | app ns / cluster | — |
| Secrets | `ksec-users`, `ksec-owners` | who uses a secret | app ns | — |
| Secrets | `ksec`, `ksecd`, `ksec-stale`, `kcert`, `kcert-match`, `kcert-chain`, `kcerts` | secret value / cert detail | app ns, `istio-system` | secrets (emerID) |
| Edge | `tlscheck`, `gwcurl` | TLS / routing from outside (`tlscheck <host> 443 $(kgwip)`) | workstation | none |
| Edge | `igw-cred` | Gateway → TLS secret mapping | cluster | secrets for the check |
| Network | `knetpol`, `kepsvc`, `knoep`, `klb` | connectivity, no endpoints, LB pending | ns | — |
| Workloads | `krstuck`, `krhist`, `kjobs`, `kpvc`, `kquota`, `kwebhooks` | rollouts, jobs, storage, admission | ns / cluster | — |
| Helm | `hls`, `hbad`, `hhist`, `hvals`, `hvalsa`, `hman`, `hrevdiff`, `hsecrets` | release state, values | release ns | secrets (emerID) |
| Helm | `hls-ro [ns]` | release + chart version without secrets | ns | — |
| Rancher | `rlist`, `rclusters`, `rfetch`, `rload`, `kcattle` | setup, cluster unavailable | workstation / `cattle-system` | Rancher API token |
| AKS | `azsub`, `aks-ls`, `aks-add`, `aks-relogin` | setup, 401s | workstation | Azure access |
| emerID | `kemer`, `kemer-off`, `kemer-fetch`, `kemer-load`, `kemer-ls`, `kemer-audit`, `kemer-purge` | elevated read on UAT/PROD | one pinned terminal | emerID checkout |

## Evidence and handoff

Diagnosis is done when someone else can apply the fix without re-investigating.

- [ ] **Failing hop** named (from *Walk the request path*)
- [ ] **Cause** stated as one sentence, or "no internal change found — external / load"
- [ ] **Change** that triggered it, with time (deploy revision, config diff, cert expiry, upgrade)
- [ ] **Evidence attached:** `iaccess` output, relevant log lines with `x-request-id`, `kycmp` / `kydiff` diff, `kexport <ns>` folder
- [ ] **Scope:** clusters, namespaces, PCI/non-PCI affected
- [ ] **Fix requested** from the owner (restart, rollback, config change) via the pipeline / change record
- [ ] **emerID** session ended (`kemer-off`), `kemer-audit` attached to the CHG/INC

Don't paste secret values, tokens or full certificates into tickets; reference the secret name and `kcert` metadata only.
