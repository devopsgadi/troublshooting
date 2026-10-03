# K8s Troubleshooting Workstation Setup — Rancher, Azure, Clusters, Namespaces

Oct 3, 2026

## Purpose and scope

This sets up one Bash profile (`~/.k8s_profile`) that reaches every cluster we support — Rancher-managed on-prem (PCI and non-PCI), AKS via `az` + `kubelogin`, and standalone on-prem — for **diagnosis only**.

- **Read-only by design.** No delete, apply, exec, restart or rollback, with either identity. A built-in guard blocks those verbs for `kubectl`, `helm` and `istioctl`; RBAC remains the real control.
- **Two identities.** Personal ID (default, read-only). emerID (checked out for UAT/PROD, used only when it can *read* more, e.g. secrets or proxy config), time-boxed and audited.
- **Environments.** IT, UAT, PROD, each split into PCI and non-PCI Rancher servers, plus AKS.
- **Companion doc.** The troubleshooting runbook (`02-runbook.md`) covers what to run, when and where.

## Prerequisites

Install these on the workstation, or on the PCI jump host for PCI clusters. Keep `kubectl` within one minor version of the clusters and `istioctl` matched to the mesh version.

| Tool | Needed for | Required | Check |
| --- | --- | --- | --- |
| bash 4+ with bash-completion | profile, tab completion | Yes | `bash --version` |
| kubectl | everything | Yes | `kubectl version --client` |
| istioctl | Istio analysis, proxy views | Yes | `istioctl version --remote=false` |
| helm 3 | release reads | Yes | `helm version` |
| az CLI | AKS credentials, subscriptions | AKS only | `az version` |
| kubelogin | AKS Entra ID auth | AKS only | `kubelogin --version` |
| openssl 1.1.1+ | cert checks (`tlscheck`, `kcert*`) | Yes | `openssl version` |
| curl, jq | Rancher API (`rfetch`, `rclusters`) | Yes | `jq --version` |
| yq (mikefarah v4) | clean YAML diffs (`kydiff`, `kycmp`) | Recommended | `yq --version` |
| fzf | context / namespace pickers | Optional | `fzf --version` |
| column (util-linux / bsdmainutils) | table output | Yes | `which column` |

macOS: `brew install kubectl istioctl helm azure-cli Azure/kubelogin/kubelogin jq yq fzf bash bash-completion@2`.

## Install the profile

1. Copy the script and load it from `~/.bashrc`. Put the exports *before* the source line.

```bash
cp k8s_profile.sh ~/.k8s_profile
cat >> ~/.bashrc <<'EOF'
export PROD_PATTERN='prod|prd|uat'   # contexts treated as high-env (red prompt)
export PCI_PATTERN='^pci'            # contexts tagged PCI in the prompt
export ISTIO_NS=istio-system
export IGW_SELECTOR='istio=ingressgateway'
export AKS_LOGIN_MODE=azurecli
[ -f ~/.k8s_profile ] && source ~/.k8s_profile
EOF
exec bash
khelp            # lists every command by section
```

2. The profile creates this layout on first load:

```
~/.kube/
  rancher.conf        # Rancher server registry (name  url  [cacert])
  inventory.conf      # team facts per context: env zone gateway-ip namespaces owner
  logs.conf           # context -> Kibana/Datadog cluster name, URLs
  ns/                 # namespace list per context: <context>.list (synced / pinned / ignored)
  configs/            # personal READ-ONLY kubeconfigs, one file per cluster, merged into KUBECONFIG
    pci-prod-dc1.yaml
    npci-uat-dc2.yaml
    aks-eus-prod.yaml
    onprem-lab.yaml
  emer/               # emerID kubeconfigs (mode 700) - NEVER merged
    audit.log         # every command run in an emerID session
```

3. Environment variables you can override:

| Variable | Default | Purpose |
| --- | --- | --- |
| `KCFG_DIR` | `~/.kube/configs` | read-only kubeconfigs |
| `EMER_DIR` | `~/.kube/emer` | emerID kubeconfigs + audit log |
| `RANCHER_REGISTRY` | `~/.kube/rancher.conf` | Rancher server list |
| `PROD_PATTERN` | `prod\|prd` | red prompt for high envs |
| `PCI_PATTERN` | `^pci` | magenta PCI tag |
| `ISTIO_NS` / `IGW_SELECTOR` | `istio-system` / `istio=ingressgateway` | gateway lookups |
| `AKS_LOGIN_MODE` | `azurecli` | kubelogin mode |
| `EMER_AUTOPURGE` | `1` | revoke emerID token + delete kubeconfig at session end |
| `KPS1` | `on` | set `off` if the prompt feels slow |
| `K_READONLY` | `1` | write/exec guard |

## Rancher: servers and read-only kubeconfigs

Register each Rancher once by a `<zone>-<env>` name; every cluster file and context then starts with that name.

1. Create and edit the registry (`rlist` creates a template on first run). No trailing slash on URLs.

```
# name       url                                  [cacert]
pci-it       https://rancher-pci-it.corp.com      ~/certs/pci-ca.pem
pci-uat      https://rancher-pci-uat.corp.com     ~/certs/pci-ca.pem
pci-prod     https://rancher-pci.corp.com         ~/certs/pci-ca.pem
npci-it      https://rancher-it.corp.com
npci-uat     https://rancher-uat.corp.com
npci-prod    https://rancher.corp.com
```

2. Check reachability and what your ID can see:

```bash
rlist                    # pong / UNREACHABLE per server
rclusters npci-uat       # prompts for your personal API token; lists cluster name, id, state
```

3. Add each cluster with your **personal** identity. Use the API, or a kubeconfig downloaded from the Rancher UI (Cluster → Download KubeConfig):

```bash
rfetch npci-uat dc2                         # -> ~/.kube/configs/npci-uat-dc2.yaml
rload  pci-prod dc1 ~/Downloads/dc1.yaml    # import a UI download, then delete the download
```

**Why files are normalized.** Rancher kubeconfigs reuse names like `dc1` across servers. Merged as-is, a PCI context can silently pick up a non-PCI token. `rfetch`/`rload` keep one context and rename cluster, user and context to `<rancher>-<cluster>`. If a Rancher uses SSO exec-plugin kubeconfigs (no embedded token), only the context is renamed and a warning is printed — run `kcfg-dupes` afterwards.

**PCI.** PCI Rancher servers are often reachable only from the PCI jump host. If `rlist` shows UNREACHABLE for `pci-*`, install the profile on the jump host and keep PCI kubeconfigs off the laptop.

## Azure / AKS with kubelogin

AKS clusters authenticate through Entra ID; `kubelogin` turns your `az login` session into cluster tokens.

1. Sign in and pick the subscription:

```bash
az login                          # add --tenant <id> for a different tenant
azsub                             # show current subscription
azsub "<subscription name or id>" # switch
aks-ls                            # clusters in that subscription: name, RG, version, power state
```

2. Add each cluster (writes credentials, converts to kubelogin, merges):

```bash
aks-add <subscription> <resource-group> <cluster> aks-eus-prod
aks-add <subscription> <resource-group> <cluster> aks-cus-uat
```

3. Use it. The first `kubectl` call fetches a token silently from the `az` session.

| Situation | Do |
| --- | --- |
| `401 Unauthorized` after a tenant or subscription switch | `aks-relogin` (clears kubelogin cache, re-checks `az login`) |
| Cluster in another tenant | `az login --tenant <id>`, then `aks-relogin` |
| Headless / jump host without a browser | `export AKS_LOGIN_MODE=devicecode` before `aks-add` |
| Need Azure-layer data (LB, NSG, node pools) | requires Azure **Reader** on the subscription or resource group; outside this profile |

`azsub` only matters for `az aks ...` commands; `kubectl` uses whichever cluster the context points to.

## On-prem clusters not managed by Rancher

For clusters where you receive a kubeconfig file directly (kubeadm, lab, vendor-managed):

```bash
konprem-add lab-dc1 /path/to/kubeconfig     # -> ~/.kube/configs/onprem-lab-dc1.yaml, context renamed
kcfg-dupes                                   # prints user/cluster names that collide across files
```

kubeadm files all ship as `kubernetes-admin@kubernetes` with user `kubernetes-admin`. If `kcfg-dupes` prints anything, don't use the merged view for those clusters — pin the shell to the file with `kuse onprem-lab-dc1`.

## Naming, zones, namespaces and switching

One rule: **file name = context name = `<zone>-<env>-<cluster>`**. The zone is the first segment and drives filtering and prompt colours.

| Source | Example context | Zone |
| --- | --- | --- |
| PCI Rancher | `pci-prod-dc1` | `pci` |
| Non-PCI Rancher | `npci-uat-dc2` | `npci` |
| AKS | `aks-eus-prod` | `aks` |
| Standalone on-prem | `onprem-lab-dc1` | `onprem` |
| emerID (any source) | `pci-prod-dc1-emer` | separate dir, never merged |

**Switching**

| Want | Command | Scope |
| --- | --- | --- |
| Only one zone in this terminal | `kzone pci` / `kzone npci` / `kzone all` | this shell |
| Pick a context | `kctx` (fzf) or `kctx npci-uat-dc2` | every shell on the merged view |
| Pin this terminal to one cluster | `kuse npci-uat-dc2` (back: `kmerge`) | this shell only |
| Pick a namespace | `kns` (fzf) or `kns payments` | that context |
| One-off on another cluster | `kubectl --context pci-prod-dc1 get pods -n payments` | that command |
| Where am I? | `kcur` | — |

**Working pattern.** One terminal per zone, pinned with `kuse` for UAT/PROD so a `kctx` elsewhere can't move you. The prompt always shows `(⎈ context:namespace ro)`, red for `PROD_PATTERN`, with a magenta **PCI** tag on `pci-*`.

**Namespaces.** Keep a per-cluster list of the app namespaces you support, plus the platform ones you'll read during triage:

| Namespace | What lives there |
| --- | --- |
| `istio-system` | istiod, ingress gateway, gateway TLS secrets, mesh-wide EnvoyFilters |
| `kube-system` | CoreDNS, kube-proxy, CNI |
| `cattle-system` / `cattle-fleet-system` | Rancher agents |
| App namespaces (e.g. `payments`) | workloads, VirtualServices, DestinationRules, policies |

## Cluster details and inventory

`~/.kube` holds two kinds of cluster detail: what the kubeconfigs say (server, auth) and what the team knows (gateway IP, app namespaces, owner). The first is read automatically; the second lives in `~/.kube/inventory.conf`, filled in by hand once.

1. Fill the inventory (`kinv` creates a template on first run). One line per context:

```
# context          env   zone  gateway-ip     app-namespaces        owner/notes
npci-prod-dc1      prod  npci  10.20.30.40    payments,accounts     platform-team
pci-prod-dc1       prod  pci   10.50.60.70    cards                 pci-team
aks-eus-prod       prod  aks   20.1.2.3       payments              platform-team
```

2. Read cluster details:

| Command | Shows | Where |
| --- | --- | --- |
| `kls` | every kubeconfig: file, context, auth type (token / kubelogin / cert), server; emerID files marked | workstation |
| `kls -p` | same + live Kubernetes version per cluster, or FAIL (expired token, unreachable) | workstation |
| `kinfo` | current cluster: server, Rancher URL + cluster id, k8s version, your identity, node count, istiod version, ingress gateway LB IP, inventory line | current context |
| `kinv [context]` | inventory lines | workstation |
| `kgwip` | gateway IP for current context, e.g. `tlscheck api.bank.com 443 $(kgwip)` | current context |
| `kappns` | app namespaces for current context | current context |
| `kscan` | per app namespace: bad pods, pending, OOM, warnings, services without endpoints | current context |

Keep `inventory.conf` in a team repo and copy it to `~/.kube/`; it holds no secrets. Never commit anything from `configs/` or `emer/` — those contain tokens.

## Maintaining namespaces

Each cluster gets a plain list at `~/.kube/ns/<context>.list`. Many-namespace clusters (AKS) are **synced** from the cluster; few-namespace or locked-down clusters (on-prem) are **pinned** by hand. Both live in the same file, so every command reads one source.

```
# synced 2026-10-03T20:10Z selector=team=payments
accounts
legacy-batch  # pin       <- added by hand, kept across syncs
loans
payments
sandbox-joe   # ignore    <- hidden permanently, never re-added
```

| Situation | Command |
| --- | --- |
| AKS / any cluster where you can list namespaces | `kns-sync` (current) or `kns-sync <context>` |
| Only your team's namespaces (many unrelated ones exist) | `kns-sync <context> team=payments` (label selector) |
| All clusters at once (monthly, or after onboarding) | `kns-sync --all` |
| On-prem / Rancher project-scoped (listing denied) | `kns-add <ns> [context]` for each — pinned |
| Hide a namespace that sync keeps finding | `kns-ignore <ns> [context]` |
| Remove a pinned one | `kns-rm <ns> [context]` |
| Show / count | `kns-ls [context]`, `kns-count` (all clusters + last sync) |
| Which cluster has namespace X? | `kns-find payments` |

Sync output shows `+ new` and `- gone` namespaces since the last run — useful drift signal on its own.

Platform namespaces are skipped by `NS_EXCLUDE` (`kube-*`, `istio-system`, `cattle-*`, `azure-*`, `aks-*`, `cert-manager`, `monitoring`, …). Extend it in `~/.bashrc` for your environment.

What reads the lists: `kns` (picker shows your list first, works even without list permission), `kappns`, `kscan`. The `app-namespaces` column in `inventory.conf` is now only a fallback for clusters with no list; set it to `-` for AKS.

## Log platforms: Kibana and Datadog

The handshake between kubectl and the log platforms depends on one fact per cluster: **what the log platform calls this cluster**. Store it once in `~/.kube/logs.conf` (`klq` creates a template on first run; use `-` for none):

```
# context        log-cluster-name   kibana-url                  kibana-dataview-id   dd-site            es-url
npci-prod-dc1    onprem-prod-dc1    https://kibana.corp.com     3f2a9c1e-...         -                  https://es.corp.com:9200
pci-prod-dc1     pci-prod-dc1       https://kibana-pci.corp.com 7b11d0aa-...         -                  -
aks-eus-prod     aks-eus-prod-01    -                           -                    datadoghq.com      -
```

| Column | Where to find it |
| --- | --- |
| log-cluster-name | Kibana: value of `orchestrator.cluster.name` (or your custom cluster field) on any log line. Datadog: the `kube_cluster_name` tag |
| kibana-dataview-id | Kibana → Stack Management → Data Views → open the logs view; the id is in the URL |
| dd-site | your Datadog site: `datadoghq.com`, `us3.datadoghq.com`, `datadoghq.eu`, … |
| es-url | only for `kibsearch` (terminal search via the Elasticsearch API) |

**Field names.** Defaults match Filebeat / Elastic Agent. If your logs are shipped by Fluent Bit or Fluentd, set in `~/.bashrc`:

```bash
export KIB_F_NS=kubernetes.namespace_name
export KIB_F_POD=kubernetes.pod_name
export KIB_F_CLUSTER=<your cluster field>
export KIB_URL_STYLE=7        # only if Kibana is 7.x (index-pattern URLs)
export ES_INDEX='filebeat-*'  # index / data stream for kibsearch
```

Datadog uses the standard Kubernetes tags (`kube_cluster_name`, `kube_namespace`, `pod_name`, `kube_deployment`) — no setup.

**API keys (optional).** Browser links (`kkib`, `kdd`) use your SSO session and need no keys. Terminal search needs read-only keys: `DD_API_KEY` + `DD_APP_KEY` for `ddsearch`, `ES_API_KEY` for `kibsearch`. They are prompted when missing, held only in the current shell, and dropped with `klogkeys-clear`. Never put them in files. Requires `jq`.

## emerID elevated-read sessions

Use emerID only when your personal ID can't **read** what you need (secrets, proxy config). It is still read-only: the guard blocks writes and exec in emerID sessions too.

1. Check out the emerID per your PAM process and log in to the relevant Rancher as emerID.
2. Get its kubeconfig into `~/.kube/emer/`:

```bash
kemer-fetch pci-prod dc1                      # API: prompts for the emerID API token
kemer-load  npci-uat dc2 ~/Downloads/dc2.yaml # or import a UI download, then delete the download
kemer-ls                                      # what's on disk
```

3. Start a session in **one** terminal:

```bash
kemer pci-prod-dc1 45        # prompts for the CHG/INC number; 45-minute timer
```

The prompt shows `EMER 45m [CHG123]` and counts down. Every `kubectl`/`helm`/`istioctl` call is written to `~/.kube/emer/audit.log` with UTC time, ticket and return code; blocked attempts are logged too.

4. End it:

```bash
kemer-off        # also runs automatically on expiry and when the terminal exits
kemer-audit      # last 50 lines - attach to the change/incident record
```

With `EMER_AUTOPURGE=1` (default), ending revokes the Rancher token on the server it came from and deletes the kubeconfig. This matters because a Rancher token stays valid after the emerID password is checked back in and rotated.

Open question for Rancher admins: can emerID create API keys? If not, use `kemer-load` and revoke the token manually in the UI (Account & API Keys).

## Verify access

Run this once per cluster, with each identity, and record the result. It decides which runbook commands work for you there.

```bash
kuse npci-prod-dc1 && kcan payments
kcan istio-system
```

| Permission | Unlocks | If "no" |
| --- | --- | --- |
| `get pods/log` | all log commands, `iaccess` | escalate — core to diagnosis |
| read `networking.istio.io` / `security.istio.io` | `ivs`, `kchain`, `ief`, `ianalyze` | request cluster-wide read on Istio CRDs |
| `list` / `get secrets` | `ksecd`, `kcert*`, `kcerts`, all Helm commands | use `tlscheck`, `gwcurl`, `hls-ro`; or emerID |
| `create pods/portforward` | `ips`, `ipc`, `igw-routes`, `igw-secrets`, `igw-ep` | use `icp`, `istats-ro`, `iaccess`; or emerID |
| `get pods/proxy` | `istats-ro`, `isc-ready-ro` | request it (lower risk than exec/portforward) |
| nodes, `metrics.k8s.io` | `knodes`, `kalloc`, `ktop` | request read |

Expected: a `view`-style role excludes secrets, so Helm reads fail with your personal ID. That's normal.

## Maintenance

| When | Do |
| --- | --- |
| Rancher read-only token expires (401 on a `pci-*`/`npci-*` context) | re-run `rfetch <rancher> <cluster>` or `rload` |
| AKS 401 | `aks-relogin` |
| New cluster | `rfetch` / `aks-add` / `konprem-add`, then `kcfg-dupes` and `kcan` |
| Cluster decommissioned | `rm ~/.kube/configs/<name>.yaml` |
| Profile updated | `cp k8s_profile.sh ~/.k8s_profile && source ~/.k8s_profile` |
| Monthly | `rlist`, `kemer-ls` (should be empty), review `~/.kube/emer/audit.log` and archive it |
| Istio upgrade | update `istioctl` to the new mesh version |

- [ ] Rancher registry filled in for all six servers
- [ ] Read-only kubeconfig for every supported cluster
- [ ] `kcan` recorded per cluster and identity
- [ ] Rancher admins asked whether emerID can create API keys
