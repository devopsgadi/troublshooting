# ~/.k8s_profile — K8s / Helm / Istio troubleshooting + multi-cluster (on-prem + AKS/kubelogin)
# Install:  cp k8s_profile.sh ~/.k8s_profile && echo '[ -f ~/.k8s_profile ] && source ~/.k8s_profile' >> ~/.bashrc
# Deps:     kubectl helm istioctl az kubelogin openssl | optional: fzf, bash-completion
# Run `khelp` for the command list.

_K8S_PROFILE="${BASH_SOURCE[0]}"

# ==== Config ====
export KCFG_DIR="${KCFG_DIR:-$HOME/.kube/configs}"        # one kubeconfig file per cluster
export ISTIO_NS="${ISTIO_NS:-istio-system}"
export IGW_SELECTOR="${IGW_SELECTOR:-istio=ingressgateway}"
export PROD_PATTERN="${PROD_PATTERN:-prod|prd}"            # regex on context name -> red prompt + confirm guard
export AKS_LOGIN_MODE="${AKS_LOGIN_MODE:-azurecli}"        # azurecli | devicecode | spn | msi | workloadidentity
export EMER_DIR="${EMER_DIR:-$HOME/.kube/emer}"            # emerID kubeconfigs — NEVER merged into KUBECONFIG
export RANCHER_REGISTRY="${RANCHER_REGISTRY:-$HOME/.kube/rancher.conf}"  # lines: <name> <url> [cacert]
export INVENTORY="${INVENTORY:-$HOME/.kube/inventory.conf}"    # team facts per context: env zone gateway-ip namespaces owner
export NS_DIR="${NS_DIR:-$HOME/.kube/ns}"                  # per-context namespace lists: <context>.list
export NS_EXCLUDE="${NS_EXCLUDE:-^(kube-|istio-system$|istio-ingress|cattle-|fleet-|local$|default$|gatekeeper-system$|calico-|tigera-|azure-|aks-|app-routing-system$|cert-manager$|ingress-nginx$|kyverno$|monitoring$|logging$|velero$|flux-system$|argocd$)}"
export PCI_PATTERN="${PCI_PATTERN:-^pci}"                  # regex on context name -> PCI tag in prompt
# Naming: <rancher-name>-<cluster>  e.g. pci-prod-dc1, npci-uat-dc2  (zone = first segment)
export EMER_AUTOPURGE="${EMER_AUTOPURGE-1}"                # 1 = revoke token + delete kubeconfig when session ends/expires
mkdir -p "$KCFG_DIR" "$EMER_DIR" "$NS_DIR" && chmod 700 "$EMER_DIR"

# ==== Read-only guard (ALL identities incl. emerID) ====
# Safety net only — RBAC is the real control. Blocks mutating + exec-family verbs for kubectl/helm/istioctl.
export K_READONLY=1
_RO_K='^(delete|apply|patch|edit|replace|scale|drain|cordon|uncordon|taint|annotate|label|create|set|run|expose|autoscale|exec|attach|cp|debug|certificate)( |$)|^rollout (restart|undo|pause|resume)'
_RO_H='^(install|upgrade|uninstall|delete|rollback|test)( |$)'
_RO_I='^(install|uninstall|upgrade)( |$)|^manifest apply|^tag (set|remove)|^operator (init|remove)'

_ro_verb() { # first positional words, skipping flags and their values
  local a skip="" out=()
  for a in "$@"; do
    if [ -n "$skip" ]; then skip=""; continue; fi
    case "$a" in
      -n|--namespace|--context|--kube-context|--kubeconfig|-c|--container|-l|--selector|-o|--output|-f|--filename|--revision) skip=1;;
      -*) ;;
      *) out+=("$a"); [ ${#out[@]} -ge 3 ] && break;;
    esac
  done
  echo "${out[*]}"
}

_ro_blocked() {
  local tool="$1"; shift; local v; v="$(_ro_verb "$@")"
  case "$tool" in
    kubectl)  [[ "$v" =~ $_RO_K ]] ;;
    helm)     [[ "$v" =~ $_RO_H ]] ;;
    istioctl) [[ "$v" =~ $_RO_I ]] || { [[ "$v" =~ ^(proxy-config|pc)\ log ]] && [[ "$*" == *--level* ]]; } ;;
    *) return 1 ;;
  esac
}

_ro_run() {
  local tool="$1"; shift
  if [ "$K_READONLY" = 1 ] && _ro_blocked "$tool" "$@"; then
    echo "BLOCKED (read-only profile): $tool $*" >&2
    [ -n "$K_EMER" ] && _emer_log "BLOCKED $tool $*"
    return 126
  fi
  if [ -n "$K_EMER" ]; then case "$1" in __complete*|config|version|completion) ;; *) _emer_log "$tool $*";; esac; fi
  command "$tool" "$@"
}
kubectl()  { _ro_run kubectl "$@"; }
helm()     { _ro_run helm "$@"; }
istioctl() { _ro_run istioctl "$@"; }
alias k=kubectl

_nsflag() { if [ -n "$1" ]; then echo "-n $1"; else echo "-A"; fi; }

# ==== Kubeconfig / context ====
_kcfg_merge() {
  local f list=""
  for f in "$KCFG_DIR"/${K_ZONE:+$K_ZONE-}*.yaml "$KCFG_DIR"/${K_ZONE:+$K_ZONE-}*.yml; do [ -f "$f" ] && list="${list:+$list:}$f"; done
  [ -z "$K_ZONE" ] && [ -f "$HOME/.kube/config" ] && list="${list:+$list:}$HOME/.kube/config"
  export KUBECONFIG="$list"
}
_kcfg_merge

kzone() { # limit THIS shell's merged view to a zone prefix (pci|npci|aks|onprem|all)
  if [ -z "$1" ] || [ "$1" = all ]; then unset K_ZONE; else export K_ZONE="$1"; fi
  _kcfg_merge; echo "zone=${K_ZONE:-all}"; command kubectl config get-contexts -o name
}

_kcfg_normalize() { # <src> <dst> <name>: one context; cluster/user/context all renamed to <name> (no merge collisions)
  local src="$1" dst="$2" n="$3" srv ca tok
  srv=$(command kubectl --kubeconfig "$src" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
  ca=$(command kubectl --kubeconfig "$src" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  tok=$(command kubectl --kubeconfig "$src" config view --minify --raw -o jsonpath='{.users[0].user.token}')
  [ -n "$srv" ] || { echo "no server in $src"; return 1; }
  rm -f "$dst"
  if [ -z "$tok" ]; then  # exec/OIDC style kubeconfig: keep auth block, only minify + rename context
    ( umask 077; command kubectl --kubeconfig "$src" config view --minify --flatten --raw > "$dst" )
    command kubectl --kubeconfig "$dst" config rename-context "$(command kubectl --kubeconfig "$dst" config current-context)" "$n" >/dev/null
    echo "stored $dst (context $n) — WARN: non-token auth, cluster/user names not renamed"; return 0
  fi
  ( umask 077
    command kubectl --kubeconfig "$dst" config set-cluster "$n" --server="$srv" >/dev/null
    [ -n "$ca" ] && command kubectl --kubeconfig "$dst" config set "clusters.$n.certificate-authority-data" "$ca" >/dev/null
    command kubectl --kubeconfig "$dst" config set-credentials "$n" --token="$tok" >/dev/null
    command kubectl --kubeconfig "$dst" config set-context "$n" --cluster="$n" --user="$n" >/dev/null
    command kubectl --kubeconfig "$dst" config use-context "$n" >/dev/null )
  chmod 600 "$dst"; echo "stored $dst (context $n -> $srv)"
}

# ==== Cluster details / inventory ====
kls() { # every kubeconfig in ~/.kube: file, context, auth type, server [-p = live /version check]
  local f ctx srv tok ex crt auth st tag
  printf '%-30s %-30s %-10s %-10s %s\n' FILE CONTEXT AUTH STATUS SERVER
  for f in "$KCFG_DIR"/*.yaml "$KCFG_DIR"/*.yml "$EMER_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    IFS='|' read -r ctx srv tok ex crt <<< "$(command kubectl --kubeconfig "$f" config view --minify --raw -o jsonpath='{.current-context}{"|"}{.clusters[0].cluster.server}{"|"}{.users[0].user.token}{"|"}{.users[0].user.exec.command}{"|"}{.users[0].user.client-certificate-data}' 2>/dev/null)"
    if [ -n "$tok" ]; then auth=token; elif [ -n "$ex" ]; then auth=$(basename "$ex"); elif [ -n "$crt" ]; then auth=cert; else auth="?"; fi
    st="-"
    if [ "$1" = -p ]; then
      st=$(command kubectl --kubeconfig "$f" --request-timeout=5s get --raw /version 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | cut -d'"' -f4)
      st="${st:-FAIL}"
    fi
    tag=""; [[ "$f" == "$EMER_DIR"/* ]] && tag=" (emer)"
    printf '%-30s %-30s %-10s %-10s %s\n' "$(basename "$f")$tag" "$ctx" "$auth" "$st" "$srv"
  done
  unset tok
}

kinfo() { # live details of the current cluster: server, Rancher id, version, identity, nodes, Istio, ingress IPs, inventory
  local ctx srv v who n istio igw
  ctx=$(command kubectl config current-context 2>/dev/null) || { echo "no current context"; return 1; }
  srv=$(command kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  v=$(kubectl get --raw /version 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | cut -d'"' -f4)
  who=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
  n=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  istio=$(kubectl get deploy -n "$ISTIO_NS" -l app=istiod -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{" "}{end}' 2>/dev/null | sed 's#=[^ ]*/#=#g')
  igw=$(kubectl get svc -n "$ISTIO_NS" -l "$IGW_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.type}:{.status.loadBalancer.ingress[*].ip}{.status.loadBalancer.ingress[*].hostname}{" "}{end}' 2>/dev/null)
  echo "context  : $ctx"
  echo "server   : $srv"
  [[ "$srv" == */k8s/clusters/* ]] && echo "rancher  : ${srv%%/k8s/clusters/*}  cluster-id=${srv##*/k8s/clusters/}"
  echo "k8s      : ${v:-unreachable}"
  echo "identity : ${who:-unknown (kubectl < 1.28 or not allowed)}"
  if [ "${n:-0}" -gt 0 ]; then echo "nodes    : $n"; else echo "nodes    : n/a (no node read)"; fi
  echo "istiod   : ${istio:-n/a}"
  echo "ingress  : ${igw:-n/a}"
  echo "inventory: $(kinv "$ctx" | tail -n +2)"
}

kinv() { # team inventory (~/.kube/inventory.conf) [context]  — creates template if missing
  if [ ! -f "$INVENTORY" ]; then
    printf '%s\n' '# context          env   zone  gateway-ip     app-namespaces        owner/notes' \
      '# npci-prod-dc1    prod  npci  10.20.30.40    payments,accounts     platform-team' > "$INVENTORY"
    echo "created $INVENTORY — fill it in"; return
  fi
  awk -v c="$1" 'NR==1 && /^#/ {print; next} !/^#/ && NF && (c=="" || $1==c)' "$INVENTORY" | column -t
}

kgwip() { awk -v c="${1:-$(command kubectl config current-context)}" '!/^#/ && $1==c {print $4}' "$INVENTORY" 2>/dev/null; }  # gateway IP from inventory: tlscheck host 443 $(kgwip)
kappns() { # app namespaces for a context: ns list file, else inventory column [ctx]
  local c="${1:-$(command kubectl config current-context)}" f; f=$(_nsfile "$c")
  if [ -s "$f" ]; then _nslist "$f" | tr '\n' ' '; echo
  else awk -v c="$c" '!/^#/ && $1==c && $5!="-" {gsub(",", " ", $5); print $5}' "$INVENTORY" 2>/dev/null; fi
}

# ==== Namespace lists (~/.kube/ns/<context>.list) ====
_nsfile() { echo "$NS_DIR/${1:-$(command kubectl config current-context)}.list"; }
_nslist() { [ -f "$1" ] && grep -v '^#' "$1" | grep -Ev '#[[:space:]]*ignore' | awk '{print $1}' | grep .; }  # active names only

kns-sync() { # discover app namespaces, keep '# pin' lines: kns-sync [ctx|--all] [label-selector]
  local c sel="$2" f live old pins ign added removed n
  if [ "$1" = --all ]; then
    for c in $(command kubectl config get-contexts -o name); do echo "== $c"; kns-sync "$c" "$sel"; done; return
  fi
  c="${1:-$(command kubectl config current-context)}"; f=$(_nsfile "$c")
  live=$(kubectl --context "$c" --request-timeout=15s get ns ${sel:+-l "$sel"} -o name 2>/dev/null) \
    || { echo "  cannot list namespaces on $c (no permission / unreachable) — maintain by hand: kns-add <ns> $c"; return 1; }
  live=$(printf '%s\n' "$live" | sed 's|namespace/||' | grep -Ev "$NS_EXCLUDE" | grep . | sort -u)
  ign=$( [ -f "$f" ] && grep -E '#[[:space:]]*ignore' "$f" | awk '{print $1}' | sort -u )
  live=$(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$ign") | grep .)
  old=$(_nslist "$f" | sort -u)
  pins=$( [ -f "$f" ] && grep -E '#[[:space:]]*pin' "$f" | awk '{print $1}' | sort -u )
  added=$(comm -13 <(printf '%s\n' "$old") <(printf '%s\n' "$live") | grep .)
  removed=$(comm -23 <(printf '%s\n' "$old") <(printf '%s\n%s\n' "$live" "$pins" | sort -u) | grep .)
  { echo "# synced $(date -u +%FT%TZ)${sel:+ selector=$sel}"
    printf '%s\n%s\n' "$live" "$pins" | grep . | sort -u | while read -r n; do
      if grep -qx -- "$n" <<< "$pins"; then echo "$n  # pin"; else echo "$n"; fi
    done
    printf '%s\n' "$ign" | grep . | sed 's/$/  # ignore/'; } > "$f.tmp" && mv "$f.tmp" "$f"
  echo "  $(_nslist "$f" | grep -c .) namespaces  (+$(grep -c . <<< "$added") new, -$(grep -c . <<< "$removed") gone)"
  [ -n "$added" ]   && printf '%s\n' "$added"   | sed 's/^/  + /'
  [ -n "$removed" ] && printf '%s\n' "$removed" | sed 's/^/  - /'
  return 0
}

kns-ls()   { local f; f=$(_nsfile "$1"); [ -f "$f" ] || { echo "no list for ${1:-current context} — kns-sync or kns-add"; return 1; }; cat "$f"; }  # show namespace list [ctx]
kns-add()  { # pin a namespace by hand (kept across syncs): kns-add <ns> [ctx]
  local f; f=$(_nsfile "$2"); touch "$f"
  awk -v n="${1:?usage: kns-add <ns> [ctx]}" '$1==n {found=1; print n"  # pin"; next} {print} END {if (!found) print n"  # pin"}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  echo "pinned $1 in $(basename "$f")"
}
kns-rm()   { local f; f=$(_nsfile "$2"); awk -v n="${1:?usage: kns-rm <ns> [ctx]}" '$1!=n' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; echo "removed $1 from $(basename "$f") (a synced ns returns on next sync — use kns-ignore)"; }  # remove from list [ctx]
kns-ignore() { # hide a namespace permanently (survives syncs): kns-ignore <ns> [ctx]
  local f; f=$(_nsfile "$2"); touch "$f"
  awk -v n="${1:?usage: kns-ignore <ns> [ctx]}" '$1==n {found=1; print n"  # ignore"; next} {print} END {if (!found) print n"  # ignore"}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  echo "ignoring $1 in $(basename "$f")"
}
kns-find() { grep -E -- "^[^#]*${1:?usage: kns-find <pattern>}" "$NS_DIR"/*.list 2>/dev/null | grep -Ev '#[[:space:]]*ignore' | sed "s|^$NS_DIR/||; s|\.list:| |" | column -t; }  # which clusters have a namespace
kns-count() { local f; for f in "$NS_DIR"/*.list; do [ -f "$f" ] && printf '%-30s %4s  %s\n' "$(basename "$f" .list)" "$(_nslist "$f" | grep -c .)" "$(head -1 "$f" | sed 's/^# //')"; done; }  # namespaces per cluster + last sync

kscan() { # quick health across all app namespaces in inventory for current context
  local ns list; list=$(kappns)
  [ -n "$list" ] || { echo "no namespaces for $(command kubectl config current-context) in $INVENTORY"; return 1; }
  for ns in $list; do
    printf '== %-20s bad=%s pending=%s oom=%s warnings=%s noEndpoints=%s\n' "$ns" \
      "$(kbad "$ns" | wc -l | tr -d ' ')" \
      "$(kpending "$ns" | tail -n +2 | wc -l | tr -d ' ')" \
      "$(koom "$ns" | grep -c . )" \
      "$(kubectl get events -n "$ns" --field-selector type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
      "$(knoep "$ns" | grep -c .)"
  done
}

# ==== Log platforms: Kibana / Datadog handshake ====
# ~/.kube/logs.conf maps each context to how the log platforms name it. Field names vary by shipper:
#   Filebeat/Elastic Agent: kubernetes.namespace / kubernetes.pod.name (defaults below)
#   Fluent Bit/Fluentd:     kubernetes.namespace_name / kubernetes.pod_name  -> override KIB_F_* in ~/.bashrc
export LOGS_CONF="${LOGS_CONF:-$HOME/.kube/logs.conf}"
export KIB_F_CLUSTER="${KIB_F_CLUSTER:-orchestrator.cluster.name}"
export KIB_F_NS="${KIB_F_NS:-kubernetes.namespace}"
export KIB_F_POD="${KIB_F_POD:-kubernetes.pod.name}"
export KIB_F_MSG="${KIB_F_MSG:-message}"
export KIB_URL_STYLE="${KIB_URL_STYLE:-8}"        # 8 = dataViewId URLs, 7 = index-pattern URLs
export ES_INDEX="${ES_INDEX:-logs-*}"              # index/data stream for kibsearch

_logcfg() { # -> _L_CLUSTER _L_KIB _L_DV _L_DD _L_ES for a context
  local c="${1:-$(command kubectl config current-context)}" line v
  if [ ! -f "$LOGS_CONF" ]; then
    printf '%s\n' '# context        log-cluster-name   kibana-url                 kibana-dataview-id   dd-site          es-url' \
      '# npci-prod-dc1  onprem-prod-dc1    https://kibana.corp.com    3f2a9c1e-...         datadoghq.com    https://es.corp.com:9200' \
      '# aks-eus-prod   aks-eus-prod-01    -                          -                    datadoghq.com    -' > "$LOGS_CONF"
    echo "created $LOGS_CONF — fill it in (use - for none)" >&2; return 1
  fi
  line=$(awk -v c="$c" '!/^#/ && $1==c' "$LOGS_CONF")
  [ -n "$line" ] || { echo "no line for '$c' in $LOGS_CONF" >&2; return 1; }
  read -r _ _L_CLUSTER _L_KIB _L_DV _L_DD _L_ES <<< "$line"
  for v in _L_CLUSTER _L_KIB _L_DV _L_DD _L_ES; do [ "${!v}" = "-" ] && printf -v "$v" '%s' ''; done
  _L_KIB="${_L_KIB%/}"; _L_ES="${_L_ES%/}"
}
_secs()  { local n="${1%[smhd]}"; case "${1: -1}" in s) echo "$n";; m) echo $((n*60));; h) echo $((n*3600));; d) echo $((n*86400));; *) echo "$1";; esac; }
_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }
_iso()   { date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ; }
_uri()   { jq -rn --arg s "$1" '$s|@uri'; }
_open()  { echo "$1"; [ "${KLQ_OPEN:-1}" = 1 ] || return 0; if command -v open >/dev/null 2>&1; then open "$1"; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1; fi; }

klq() { # Kibana KQL + Datadog query for this cluster: klq <pod|deploy/x|ns:N|rid:ID> [ns] [since=1h] [extra terms]
  local t="${1:?usage: klq <pod|deploy/name|ns:<ns>|rid:<request-id>> [ns] [since=1h] [extra]}" ns="$2" since="${3:-1h}" extra="$4" kq dq fin e now from to
  [ -n "$ns" ] || ns=$(command kubectl config view --minify -o jsonpath='{..namespace}'); ns="${ns:-default}"
  _logcfg || return 1
  now=$(date -u +%s); to=$now; from=$(( now - $(_secs "$since") ))
  case "$t" in
    rid:*) kq="\"${t#rid:}\""; dq="\"${t#rid:}\"" ;;
    ns:*)  ns="${t#ns:}"; kq="$KIB_F_NS:\"$ns\""; dq="kube_namespace:$ns" ;;
    deploy/*|deployment/*) kq="$KIB_F_NS:\"$ns\" and $KIB_F_POD:${t#*/}-*"; dq="kube_namespace:$ns kube_deployment:${t#*/}" ;;
    *) kq="$KIB_F_NS:\"$ns\" and $KIB_F_POD:\"$t\""; dq="kube_namespace:$ns pod_name:$t"
       if [ -z "$3" ]; then
         fin=$(kubectl get pod "$t" -n "$ns" -o jsonpath='{.status.containerStatuses[*].lastState.terminated.finishedAt}' 2>/dev/null | tr ' ' '\n' | grep . | sort | tail -1)
         if [ -n "$fin" ] && e=$(_epoch "$fin") && [ -n "$e" ]; then from=$((e-900)); to=$((e+300)); echo "# window centred on last container exit $fin (-15m/+5m)"; fi
       fi ;;
  esac
  [ -n "$_L_CLUSTER" ] && { kq="$KIB_F_CLUSTER:\"$_L_CLUSTER\" and $kq"; dq="kube_cluster_name:$_L_CLUSTER $dq"; }
  [ -n "$extra" ] && { kq="$kq and ($extra)"; dq="$dq ($extra)"; }
  _KLQ_K="$kq"; _KLQ_D="$dq"; _KLQ_FROM=$from; _KLQ_TO=$to
  echo "KQL     : $kq"
  echo "Datadog : $dq"
  echo "window  : $(_iso "$from") -> $(_iso "$to")"
}

kkib() { # open Kibana Discover pre-filtered (same args as klq)
  klq "$@" || return 1
  [ -n "$_L_KIB" ] || { echo "no kibana-url for this context in $LOGS_CONF"; return 1; }
  local k g a
  k=$(printf '%s' "$_KLQ_K" | sed "s/!/!!/g; s/'/!'/g")
  g="(time:(from:'$(_iso "$_KLQ_FROM")',to:'$(_iso "$_KLQ_TO")'))"
  if [ "$KIB_URL_STYLE" = 7 ]; then a="(index:'$_L_DV',query:(language:kuery,query:'$k'))"
  else a="(dataSource:(dataViewId:'$_L_DV',type:dataView),query:(language:kuery,query:'$k'))"; fi
  _open "$_L_KIB/app/discover#/?_g=$(_uri "$g")&_a=$(_uri "$a")"
}

kdd() { # open Datadog Logs pre-filtered (same args as klq)
  klq "$@" || return 1
  local site="${_L_DD:-datadoghq.com}" host
  case "$site" in datadoghq.com|datadoghq.eu|ddog-gov.com) host="app.$site" ;; *) host="$site" ;; esac
  _open "https://$host/logs?query=$(_uri "$_KLQ_D")&from_ts=$((_KLQ_FROM*1000))&to_ts=$((_KLQ_TO*1000))&live=false"
}

ddsearch() { # Datadog Logs API, read-only, latest lines in terminal (same args as klq); keys prompted, session only
  klq "$@" >/dev/null || return 1
  local site="${_L_DD:-datadoghq.com}" body
  [ -n "$DD_API_KEY" ] || { read -r -s -p "DD_API_KEY: " DD_API_KEY; echo; export DD_API_KEY; }
  [ -n "$DD_APP_KEY" ] || { read -r -s -p "DD_APP_KEY: " DD_APP_KEY; echo; export DD_APP_KEY; }
  body=$(jq -n --arg q "$_KLQ_D" --arg f "$(_iso "$_KLQ_FROM")" --arg t "$(_iso "$_KLQ_TO")" --argjson l "${KLQ_LIMIT:-50}" \
    '{filter:{query:$q,from:$f,to:$t},sort:"-timestamp",page:{limit:$l}}')
  curl -fsS -X POST "https://api.$site/api/v2/logs/events/search" -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
       -H 'Content-Type: application/json' -d "$body" \
  | jq -r '.data[]? | .attributes as $a | [$a.timestamp, ($a.status // "-"), (([$a.tags[]? | select(startswith("pod_name:"))][0] // "pod_name:-") | sub("pod_name:";"")), (($a.message // "") | gsub("\n";" ") | .[0:220])] | @tsv'
}

kibsearch() { # Elasticsearch search, read-only, latest lines in terminal (same args as klq); ES_API_KEY prompted, session only
  klq "$@" >/dev/null || return 1
  [ -n "$_L_ES" ] || { echo "no es-url for this context in $LOGS_CONF"; return 1; }
  [ -n "$ES_API_KEY" ] || { read -r -s -p "ES_API_KEY (base64 id:key): " ES_API_KEY; echo; export ES_API_KEY; }
  local lq body
  lq=$(printf '%s' "$_KLQ_K" | sed 's/ and / AND /g; s/ or / OR /g')
  body=$(jq -n --arg q "$lq" --arg f "$(_iso "$_KLQ_FROM")" --arg t "$(_iso "$_KLQ_TO")" --argjson l "${KLQ_LIMIT:-50}" \
    '{size:$l, sort:[{"@timestamp":"desc"}], query:{bool:{filter:[{query_string:{query:$q}},{range:{"@timestamp":{gte:$f,lte:$t}}}]}}}')
  curl -fsS ${ES_CACERT:+--cacert "$ES_CACERT"} -H "Authorization: ApiKey $ES_API_KEY" -H 'Content-Type: application/json' \
       "$_L_ES/$ES_INDEX/_search" -d "$body" \
  | jq -r --arg m "$KIB_F_MSG" --arg p "$KIB_F_POD" '.hits.hits[]?._source as $s
      | [$s["@timestamp"], ($s[$p] // ($s | getpath($p|split("."))) // "-"), ((($s[$m] // ($s | getpath($m|split(".")))) // "") | tostring | gsub("\n";" ") | .[0:220])] | @tsv'
}

klogkeys-clear() { unset DD_API_KEY DD_APP_KEY ES_API_KEY; echo "log API keys cleared from this shell"; }  # drop API keys from env

kgo() { # from a log line to the cluster: kgo <log-cluster|context> <ns> [pod] — pins this shell, shows pod state
  local lc="${1:?usage: kgo <log-cluster|context> <ns> [pod]}" ns="${2:?usage: kgo <log-cluster|context> <ns> [pod]}" pod="$3" c p
  c=$(awk -v l="$lc" '!/^#/ && ($2==l || $1==l) {print $1; exit}' "$LOGS_CONF" 2>/dev/null); c="${c:-$lc}"
  if [ -f "$KCFG_DIR/$c.yaml" ]; then kuse "$c" >/dev/null; else kctx "$c" >/dev/null || { echo "no context for '$lc' — add it to $LOGS_CONF (column 2)"; return 1; }; fi
  command kubectl config set-context --current --namespace="$ns" >/dev/null; kcur
  if [ -z "$pod" ]; then kbad "$ns"; return; fi
  if kubectl get pod "$pod" -n "$ns" >/dev/null 2>&1; then
    kubectl get pod "$pod" -n "$ns" -o wide
    kubectl get pod "$pod" -n "$ns" -o go-template='{{range .status.containerStatuses}}{{.name}}: ready={{.ready}} restarts={{.restartCount}}{{if .lastState.terminated}} last={{.lastState.terminated.reason}}/exit {{.lastState.terminated.exitCode}} at {{.lastState.terminated.finishedAt}}{{end}}{{"\n"}}{{end}}'
    echo "-- events"; kubectl get events -n "$ns" --field-selector involvedObject.name="$pod" --sort-by=.lastTimestamp 2>/dev/null | tail -n 10
  else
    p="${pod%-*}"; p="${p%-*}"
    echo "pod $pod no longer exists (restarted/rolled). Current pods of workload '$p':"
    kubectl get pods -n "$ns" -o wide 2>/dev/null | awk -v p="$p" 'NR==1 || index($1,p)==1'
  fi
}

# ==== Rancher servers (registry) ====
_rancher() { # _rancher <name> -> _R_URL, _R_CA
  local line
  [ -f "$RANCHER_REGISTRY" ] || { echo "missing $RANCHER_REGISTRY — run rlist"; return 1; }
  line=$(awk -v n="$1" '!/^#/ && $1==n {print $2" "$3}' "$RANCHER_REGISTRY")
  [ -n "$line" ] || { echo "rancher '$1' not in $RANCHER_REGISTRY"; return 1; }
  _R_URL="${line%% *}"; _R_URL="${_R_URL%/}"; _R_CA="${line#* }"; _R_CA="${_R_CA/#\~/$HOME}"
}
_rcurl() { curl -fsS --max-time 20 ${_R_CA:+--cacert "$_R_CA"} "$@"; }

rlist() { # registered Rancher servers + /ping reachability
  if [ ! -f "$RANCHER_REGISTRY" ]; then
    printf '%s\n' '# name       url                                 [cacert]' \
      '# pci-it     https://rancher-pci-it.corp.com     ~/certs/pci-ca.pem' \
      '# npci-prod  https://rancher-prod.corp.com' > "$RANCHER_REGISTRY"
    echo "created $RANCHER_REGISTRY — edit it"; return
  fi
  local n
  for n in $(awk '!/^#/ && NF>=2 {print $1}' "$RANCHER_REGISTRY"); do
    _rancher "$n" || continue
    printf '%-12s %-45s %s\n' "$n" "$_R_URL" "$(_rcurl "$_R_URL/ping" 2>/dev/null || echo UNREACHABLE)"
  done
}

rclusters() { # clusters visible to your token on a Rancher: rclusters <rancher>
  local tok; _rancher "${1:?usage: rclusters <rancher>}" || return 1
  command -v jq >/dev/null || { echo "needs jq"; return 1; }
  read -r -s -p "API token for $1 ($_R_URL): " tok; echo
  _rcurl -H "Authorization: Bearer $tok" "$_R_URL/v3/clusters" | jq -r '.data[] | [.name, .id, .state] | @tsv' | column -t
}

rfetch() { # kubeconfig via Rancher API: rfetch <rancher> <cluster> [ro|emer]
  local r="$1" c="$2" mode="${3:-ro}" tok id tmp name dst rc
  [ -n "$r" ] && [ -n "$c" ] || { echo "usage: rfetch <rancher> <cluster> [ro|emer]"; return 1; }
  command -v jq >/dev/null || { echo "needs jq (or use rload / kemer-load)"; return 1; }
  _rancher "$r" || return 1
  name="$r-$c"; dst="$KCFG_DIR/$name.yaml"
  [ "$mode" = emer ] && { dst="$EMER_DIR/$name.yaml"; name="$name-emer"; }
  read -r -s -p "[$mode] API token for $r ($_R_URL): " tok; echo
  id=$(_rcurl -H "Authorization: Bearer $tok" "$_R_URL/v3/clusters?name=$c" | jq -r '.data[0].id // empty')
  [ -n "$id" ] || { echo "cluster '$c' not found / not visible on $r"; return 1; }
  tmp=$(mktemp); chmod 600 "$tmp"
  _rcurl -X POST -H "Authorization: Bearer $tok" "$_R_URL/v3/clusters/$id?action=generateKubeconfig" | jq -r .config > "$tmp" || { rm -f "$tmp"; return 1; }
  _kcfg_normalize "$tmp" "$dst" "$name"; rc=$?; rm -f "$tmp"
  [ $rc -eq 0 ] && [ "$mode" = ro ] && _kcfg_merge
  return $rc
}

rload() { # import Rancher UI kubeconfig as personal read-only: rload <rancher> <cluster> <file>
  [ $# -eq 3 ] || { echo "usage: rload <rancher> <cluster> <file>"; return 1; }
  _kcfg_normalize "$3" "$KCFG_DIR/$1-$2.yaml" "$1-$2" && _kcfg_merge
}

kcur() { # show current context / ns / kubeconfig
  local ns; ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  echo "ctx=$(kubectl config current-context 2>/dev/null)  ns=${ns:-default}"
  echo "KUBECONFIG=$KUBECONFIG"
}

kctx() { # switch context (fzf picker if no arg)
  local c="$1"
  if [ -z "$c" ]; then
    command -v fzf >/dev/null || { kubectl config get-contexts; return; }
    c=$(kubectl config get-contexts -o name | fzf --prompt="context> ") || return
  fi
  kubectl config use-context "$c"
}

kns() { # switch namespace (fzf picker if no arg)
  local n="$1"
  if [ -z "$n" ]; then
    command -v fzf >/dev/null || { kns-ls 2>/dev/null || kubectl get ns; return; }
    n=$( { f=$(_nsfile); if [ -s "$f" ]; then _nslist "$f"; else kubectl get ns -o name | sed 's|namespace/||'; fi; } | fzf --prompt="namespace> " --print-query | tail -1) || true
    [ -n "$n" ] || return
  fi
  kubectl config set-context --current --namespace="$n" >/dev/null && kcur
}

kuse() { # per-shell isolation: point THIS shell at a single kubeconfig file
  local f="$1"
  if [ -z "$f" ]; then
    command -v fzf >/dev/null || { ls -1 "$KCFG_DIR"; return; }
    f=$(ls -1 "$KCFG_DIR" | fzf --prompt="kubeconfig> ") || return
  fi
  [ -f "$KCFG_DIR/$f" ] || f="$f.yaml"
  [ -f "$KCFG_DIR/$f" ] || { echo "not found: $KCFG_DIR/$f"; return 1; }
  export KUBECONFIG="$KCFG_DIR/$f"; kcur
}

kmerge() { _kcfg_merge; kcur; }  # back to merged view of all kubeconfigs

kcfg-dupes() { # find user/cluster names that collide across files (breaks merged auth)
  local f
  for f in "$KCFG_DIR"/*.yaml "$KCFG_DIR"/*.yml; do
    [ -f "$f" ] || continue
    kubectl --kubeconfig "$f" config view -o jsonpath='{range .users[*]}user {.name}{"\n"}{end}{range .clusters[*]}cluster {.name}{"\n"}{end}'
  done | sort | uniq -d
}

konprem-add() { # konprem-add <name> <kubeconfig-path>  -> $KCFG_DIR/onprem-<name>.yaml
  [ $# -eq 2 ] || { echo "usage: konprem-add <name> <kubeconfig>"; return 1; }
  local f="$KCFG_DIR/onprem-$1.yaml" old
  cp "$2" "$f" && chmod 600 "$f" || return 1
  old=$(kubectl --kubeconfig "$f" config current-context)
  [ "$old" != "onprem-$1" ] && kubectl --kubeconfig "$f" config rename-context "$old" "onprem-$1"
  _kcfg_merge; echo "added onprem-$1"; kcfg-dupes | sed 's/^/DUPLICATE: /'
}

# ==== Azure / AKS (kubelogin) ====
azsub() { # set/show Azure subscription
  [ -n "$1" ] && az account set --subscription "$1"
  az account show --query '{name:name,id:id,user:user.name}' -o table
}

aks-ls() { # list AKS clusters in current (or given) subscription
  az aks list ${1:+--subscription "$1"} --query '[].{name:name,rg:resourceGroup,k8s:kubernetesVersion,state:powerState.code}' -o table
}

aks-add() { # aks-add <sub> <rg> <cluster> [alias]  -> creds + kubelogin convert
  [ $# -ge 3 ] || { echo "usage: aks-add <sub> <rg> <cluster> [alias]"; return 1; }
  local name="${4:-$3}"; local f="$KCFG_DIR/aks-$name.yaml"
  az aks get-credentials --subscription "$1" -g "$2" -n "$3" --context "$name" --file "$f" --overwrite-existing || return 1
  kubelogin convert-kubeconfig -l "$AKS_LOGIN_MODE" --kubeconfig "$f" || return 1
  chmod 600 "$f"; _kcfg_merge; echo "added $name ($AKS_LOGIN_MODE) -> $f"
}

aks-relogin() { # clear kubelogin token cache + ensure az login
  kubelogin remove-tokens
  az account get-access-token >/dev/null 2>&1 || az login
  echo "tokens cleared; next kubectl call re-authenticates"
}

# ==== Prompt + prod guard ====
_KPS1_BASE="${_KPS1_BASE:-$PS1}"
__kube_prompt() {
  local ctx ns color left z=""
  if [ -n "$K_EMER" ]; then
    left=$(( (K_EMER_UNTIL - $(date +%s)) / 60 ))
    if [ "$left" -lt 0 ]; then echo "!! EMER session expired"; kemer-off; fi
  fi
  if [ "${KPS1:-on}" = on ] && ctx=$(command kubectl config current-context 2>/dev/null); then
    ns=$(command kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    color='\[\e[0;36m\]'; [[ "$ctx" =~ $PROD_PATTERN ]] && color='\[\e[1;41;97m\]'
    [[ "$ctx" =~ $PCI_PATTERN ]] && z='\[\e[1;97;45m\] PCI \[\e[0m\]'
    if [ -n "$K_EMER" ]; then
      PS1="\[\e[1;5;97;41m\] EMER ${left}m [${K_EMER_CHG}] \[\e[0m\]${z}${color}(⎈ ${ctx}:${ns:-default})\[\e[0m\] ${_KPS1_BASE}"
    else
      PS1="${z}${color}(⎈ ${ctx}:${ns:-default} ro)\[\e[0m\] ${_KPS1_BASE}"
    fi
  else
    PS1="$_KPS1_BASE"
  fi
}
case "$PROMPT_COMMAND" in *__kube_prompt*) ;; *) PROMPT_COMMAND="__kube_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}";; esac


# ==== Access: read-only checks ====
kcan() { # permission matrix for current identity [ns]
  local ns="${1:-$(command kubectl config view --minify -o jsonpath='{..namespace}')}" verb res sub r
  ns="${ns:-default}"
  command kubectl auth whoami 2>/dev/null | tail -n +2
  printf '%-10s %-42s %-12s %s\n' VERB RESOURCE SUBRES "ALLOWED (ns=$ns)"
  while read -r verb res sub; do
    r=$(command kubectl auth can-i "$verb" "$res" ${sub:+--subresource="$sub"} -n "$ns" 2>/dev/null)
    printf '%-10s %-42s %-12s %s\n' "$verb" "$res" "${sub:--}" "${r:-no}"
  done <<'EOF'
get pods log
list secrets
get secrets
create pods exec
create pods portforward
get pods proxy
patch deployments
delete pods
list envoyfilters.networking.istio.io
patch envoyfilters.networking.istio.io
list virtualservices.networking.istio.io
EOF
}

tlscheck() { # cert served at the edge, NO cluster perms: tlscheck <host> [port] [gateway-ip]
  local h="${1:?usage: tlscheck <host> [port] [ip]}" p="${2:-443}" ip="${3:-$1}"
  echo | openssl s_client -connect "$ip:$p" -servername "$h" 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
  echo | openssl s_client -connect "$ip:$p" -servername "$h" -showcerts 2>/dev/null | grep -E 'Verify return code|^ *[0-9] s:' 
}

gwcurl() { # request via gateway IP, bypass DNS: gwcurl <host> [path] [ip] [port]
  local h="${1:?usage: gwcurl <host> [path] [ip] [port]}" path="${2:-/}" ip="$3" p="${4:-443}"
  curl -sk -o /dev/null ${ip:+--resolve "$h:$p:$ip"} -D - -w '\ncode=%{http_code} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' "https://$h:$p$path" \
  | grep -iE '^HTTP|^server:|^x-envoy|^code='
}

istats-ro() { # envoy error stats WITHOUT exec (needs get pods/proxy): istats-ro <pod> <ns>
  command kubectl get --raw "/api/v1/namespaces/$2/pods/$1:15020/proxy/stats/prometheus" \
  | grep -E '^envoy_cluster_upstream_(rq_(5xx|timeout|retry)|cx_connect_fail)|^envoy_.*ssl.*(fail|error)' | grep -v ' 0$' | head -50
}
isc-ready-ro() { command kubectl get --raw "/api/v1/namespaces/$2/pods/$1:15021/proxy/healthz/ready" && echo "ready"; }  # sidecar readiness w/o exec

# ==== Access: emerID break-glass (Rancher) ====
kemer-fetch() { rfetch "$1" "$2" emer; }  # emerID kubeconfig via API: kemer-fetch <rancher> <cluster>
kemer-load() { # import Rancher UI download (logged in as emerID): kemer-load <rancher> <cluster> <file>
  [ $# -eq 3 ] || { echo "usage: kemer-load <rancher> <cluster> <file>"; return 1; }
  _kcfg_normalize "$3" "$EMER_DIR/$1-$2.yaml" "$1-$2-emer" && echo "now delete the download: rm '$3'"
}
kemer-ls() { ls -1 "$EMER_DIR" | grep -E '\.ya?ml$' | sed 's/\.ya*ml$//'; }  # emer kubeconfigs on disk

kemer() { # start time-boxed, audited emerID (elevated READ) session in THIS shell: kemer <cluster> [minutes=60]
  local c="${1:?usage: kemer <cluster> [minutes]}" m="${2:-60}" chg
  [ -n "$K_EMER" ] && { echo "already in EMER session ($K_EMER) — kemer-off first"; return 1; }
  [ -f "$EMER_DIR/$c.yaml" ] || { echo "no emer kubeconfig '$c' (have: $(kemer-ls | tr '\n' ' ')) — kemer-fetch <rancher> <cluster>"; return 1; }
  read -r -p "Change/Incident #: " chg; [ -n "$chg" ] || { echo "ticket required"; return 1; }
  export _K_PREV_KUBECONFIG="$KUBECONFIG" KUBECONFIG="$EMER_DIR/$c.yaml"
  export K_EMER="$c" K_EMER_CHG="$chg" K_EMER_UNTIL=$(( $(date +%s) + m * 60 ))
  trap '[ -n "$K_EMER" ] && kemer-off' EXIT
  _emer_log "SESSION START minutes=$m ctx=$(command kubectl config current-context)"
  echo "EMER session: $c for ${m}m, ticket $chg. Identity:"; command kubectl auth whoami 2>/dev/null || command kubectl auth can-i --list -n default | head -5
}

kemer-off() { # end EMER session (auto-runs on expiry/shell exit); purges token if EMER_AUTOPURGE=1
  [ -n "$K_EMER" ] || { echo "no EMER session"; return 0; }
  local c="$K_EMER"
  _emer_log "SESSION END"
  export KUBECONFIG="$_K_PREV_KUBECONFIG"
  unset K_EMER K_EMER_CHG K_EMER_UNTIL _K_PREV_KUBECONFIG
  trap - EXIT
  [ -n "$EMER_AUTOPURGE" ] && kemer-purge "$c"
  echo "back to read-only: $(kubectl config current-context 2>/dev/null)"
}

kemer-purge() { # revoke Rancher token in emer kubeconfig + delete it: kemer-purge <rancher>-<cluster>
  local f="$EMER_DIR/${1:?usage: kemer-purge <rancher>-<cluster>}.yaml" tok srv base
  [ -f "$f" ] || return 0
  tok=$(command kubectl --kubeconfig "$f" config view --raw -o jsonpath='{.users[0].user.token}')
  srv=$(command kubectl --kubeconfig "$f" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  base="${srv%%/k8s/clusters/*}"
  _R_CA=$(awk -v u="$base" '!/^#/ && ($2==u || $2==u"/") {print $3}' "$RANCHER_REGISTRY" 2>/dev/null); _R_CA="${_R_CA/#\~/$HOME}"
  if [ -n "$tok" ] && [ "$base" != "$srv" ]; then
    if _rcurl -X DELETE -H "Authorization: Bearer $tok" "$base/v3/tokens/${tok%%:*}" >/dev/null; then
      echo "revoked ${tok%%:*} on $base"
    else
      echo "WARN: revoke failed — delete ${tok%%:*} in $base UI (Account & API Keys)"
    fi
  elif [ -n "$tok" ]; then
    echo "WARN: $srv is not a Rancher proxy URL (ACE/direct) — revoke token ${tok%%:*} manually"
  fi
  rm -f "$f" && echo "deleted $f"
}

kemer-audit() { tail -n "${1:-50}" "$EMER_DIR/audit.log"; }  # last EMER commands (attach to change record)

# ==== Pods / workloads / health ====
alias kp='kubectl get pods -o wide'                  # pods (current ns)
alias kpa='kubectl get pods -A -o wide'              # pods (all ns)
alias kd='kubectl describe'                          # describe <kind> <name>

kbad() { # pods not Running/Ready (optional ns)
  kubectl get pods -A --no-headers | awk -v ns="$1" '(ns=="" || $1==ns){ split($3,r,"/"); if ($4!="Completed" && ($4!="Running" || r[1]!=r[2])) print }'
}
krestarts() { kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -n "${1:-20}"; }  # top restarting pods
kdbad() { # deployments not fully available (all ns)
  kubectl get deploy -A --no-headers | awk '{split($3,r,"/"); if (r[1]!=r[2]) print}'
}
kev() { kubectl get events $(_nsflag "$1") --sort-by=.lastTimestamp | tail -n "${2:-40}"; }  # events [ns] [n]
kwarn() { kubectl get events $(_nsflag "$1") --field-selector type=Warning --sort-by=.lastTimestamp | tail -n "${2:-40}"; }  # warning events [ns] [n]
klog() { kubectl logs "$1" ${2:+-c "$2"} --tail=200 -f; }  # klog <pod> [container]
klogp() { kubectl logs "$1" ${2:+-c "$2"} --previous --tail=200; }  # logs of crashed (previous) container
klogl() { kubectl logs -l "$1" --all-containers --prefix --tail=100 --max-log-requests=20; }  # logs by label: klogl app=foo
kimg() { kubectl get pods $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,IMAGES:.spec.containers[*].image'; }  # images per pod
knodes() { # node readiness / pressure / taints
  kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEM:.status.conditions[?(@.type=="MemoryPressure")].status,DISK:.status.conditions[?(@.type=="DiskPressure")].status,PID:.status.conditions[?(@.type=="PIDPressure")].status,VER:.status.nodeInfo.kubeletVersion,TAINTS:.spec.taints[*].key'
}
ktop() { kubectl top pods $(_nsflag "$1") --sort-by="${2:-memory}" | head -n 25; }  # top pods [ns] [cpu|memory]
alias ktopn='kubectl top nodes'                       # node usage
kepsvc() { kubectl get endpointslices ${2:+-n "$2"} -l kubernetes.io/service-name="$1" -o wide; }  # endpoints of svc: kepsvc <svc> [ns]
knoep() { kubectl get endpoints ${1:+-n "$1"} --no-headers 2>/dev/null | awk '$2=="<none>"{print $1}'; }  # services with no endpoints [ns]

# ==== Secrets / certs ====
ksec() { kubectl get secrets $(_nsflag "$1") --field-selector type!=helm.sh/release.v1; }  # secrets minus helm release secrets
ksecd() { # decode all keys: ksecd <secret> [ns]
  kubectl get secret "$1" ${2:+-n "$2"} -o go-template='{{range $k,$v := .data}}{{printf "=== %s ===\n" $k}}{{$v | base64decode}}{{"\n"}}{{end}}'
}
kcert() { # TLS secret cert: subject/issuer/dates/SANs: kcert <secret> [ns]
  kubectl get secret "$1" ${2:+-n "$2"} -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
}
kcerts() { # expiry of all TLS secrets in ns (default istio-system)
  local ns="${1:-$ISTIO_NS}" s
  for s in $(kubectl get secrets -n "$ns" --field-selector type=kubernetes.io/tls -o name); do
    printf '%-55s %s\n' "${s#secret/}" "$(kubectl get -n "$ns" "$s" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  done
}

# ==== Istio ====
_ISTIO_KINDS='gateways.networking.istio.io,virtualservices.networking.istio.io,destinationrules.networking.istio.io,serviceentries.networking.istio.io,sidecars.networking.istio.io,envoyfilters.networking.istio.io,peerauthentications.security.istio.io,authorizationpolicies.security.istio.io'
igw() { kubectl get pod -n "$ISTIO_NS" -l "$IGW_SELECTOR" -o jsonpath='{.items[0].metadata.name}'; }  # ingress gateway pod name
inet() { kubectl get "$_ISTIO_KINDS" $(_nsflag "$1"); }  # all istio objects [ns]
ivs() { kubectl get virtualservices.networking.istio.io $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,GATEWAYS:.spec.gateways,HOSTS:.spec.hosts'; }  # VS -> gateways/hosts
ief() { kubectl get envoyfilters.networking.istio.io $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.workloadSelector.labels,PRIORITY:.spec.priority'; }  # envoyfilters + selectors
alias ips='istioctl proxy-status'                     # SYNCED/STALE per proxy
ianalyze() { istioctl analyze $(_nsflag "$1"); }      # config validation [ns]
iinject() { kubectl get ns -L istio-injection -L istio.io/rev; }  # sidecar injection labels
iver() { istioctl version; }                          # control/data plane versions
idesc() { istioctl x describe pod "$1" -n "${2:-default}"; }  # VS/DR/policy applied to pod
ipc() { istioctl proxy-config "$1" "$2" -n "${3:-$ISTIO_NS}" "${@:4}"; }  # ipc <routes|clusters|listeners|endpoints|secret|bootstrap> <pod> [ns]
igw-routes() { istioctl proxy-config routes "$(igw)" -n "$ISTIO_NS" ${1:+| grep -i "$1"}; }  # gateway routes [host filter]
igw-listeners() { istioctl proxy-config listeners "$(igw)" -n "$ISTIO_NS"; }  # gateway listeners/ports
igw-secrets() { istioctl proxy-config secret "$(igw)" -n "$ISTIO_NS"; }  # certs loaded by gateway (ACTIVE/WARMING)
igw-ep() { istioctl proxy-config endpoints "$(igw)" -n "$ISTIO_NS" | grep -i "${1:-.}"; }  # upstream endpoint health [svc filter]
iproxylog() { kubectl logs "$1" -n "$2" -c istio-proxy --tail="${3:-200}"; }  # sidecar access/error logs
iistiod() { kubectl logs -n "$ISTIO_NS" -l app=istiod --tail="${1:-300}" | grep -iE 'error|warn|reject|invalid'; }  # istiod errors/rejections

# ==== Istio sidecar ====
# istio-proxy may be a regular container or a native sidecar (initContainers) -> functions check both.
_ISC_IMG='{.spec.containers[?(@.name=="istio-proxy")].image}{.spec.initContainers[?(@.name=="istio-proxy")].image}'

isc-missing() { # pods in injection-enabled namespaces WITHOUT istio-proxy [ns]
  local nss
  nss=$( { kubectl get ns -l istio-injection=enabled -o name; kubectl get ns -l istio.io/rev -o name; } 2>/dev/null | sed 's|namespace/||' | sort -u | tr '\n' ' ')
  kubectl get pods $(_nsflag "$1") -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.annotations.sidecar\.istio\.io/inject}{"|"}{.metadata.labels.sidecar\.istio\.io/inject}{"|"}{.spec.containers[*].name} {.spec.initContainers[*].name}{"\n"}{end}' \
  | awk -F'|' -v nss=" $nss " 'BEGIN{print "NAMESPACE|POD|PHASE|INJECT_ANNOT|INJECT_LABEL"}
      index(nss," "$1" ") && $6 !~ /(^| )istio-proxy( |$)/ && $3!="Succeeded" {print $1"|"$2"|"$3"|"$4"|"$5}' | column -t -s'|'
}

isc-check() { istioctl x check-inject -n "$2" "$1"; }  # why was/wasn't pod injected: isc-check <pod> <ns>

isc-status() { # sidecar state for one pod: isc-status <pod> <ns>
  local p="$1" n="$2"
  kubectl get pod "$p" -n "$n" -o jsonpath='image:      '"$_ISC_IMG"'
revision:   {.metadata.labels.istio\.io/rev}
inject:     annot={.metadata.annotations.sidecar\.istio\.io/inject} label={.metadata.labels.sidecar\.istio\.io/inject}
holdStart:  {.metadata.annotations.proxy\.istio\.io/config}
ready:      {.status.containerStatuses[?(@.name=="istio-proxy")].ready}{.status.initContainerStatuses[?(@.name=="istio-proxy")].ready}
restarts:   {.status.containerStatuses[?(@.name=="istio-proxy")].restartCount}{.status.initContainerStatuses[?(@.name=="istio-proxy")].restartCount}
lastExit:   {.status.containerStatuses[?(@.name=="istio-proxy")].lastState.terminated.reason}{.status.initContainerStatuses[?(@.name=="istio-proxy")].lastState.terminated.reason}
init:       {.status.initContainerStatuses[?(@.name=="istio-init")].state}
'
  echo "sidecar /healthz/ready: $(isc-ready-ro "$p" "$n" 2>&1 | tr -d '\n')"
  istioctl proxy-status 2>/dev/null | awk -v p="$p.$n" 'NR==1 || index($1,p)==1'
}

isc-ver() { # proxy image/version distribution (skew after upgrade) [ns]
  kubectl get pods $(_nsflag "$1") -o jsonpath='{range .items[*]}'"$_ISC_IMG"'{"\n"}{end}' | grep . | sort | uniq -c | sort -rn
  echo "-- control plane:"; kubectl get pods -n "$ISTIO_NS" -l app=istiod -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
}

isc-old() { # pods whose proxy image != given/istiod version: isc-old <ver-substring> [ns]
  local v="${1:?usage: isc-old <version e.g. 1.22.3> [ns]}"
  kubectl get pods $(_nsflag "$2") -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}'"$_ISC_IMG"'{"\n"}{end}' | awk -v v="$v" 'NF==3 && index($3,v)==0'
}

isc-oom() { # istio-proxy OOMKilled / restarted pods [ns]
  kubectl get pods $(_nsflag "$1") -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.containerStatuses[?(@.name=="istio-proxy")].restartCount}{.status.initContainerStatuses[?(@.name=="istio-proxy")].restartCount}{" "}{.status.containerStatuses[?(@.name=="istio-proxy")].lastState.terminated.reason}{.status.initContainerStatuses[?(@.name=="istio-proxy")].lastState.terminated.reason}{"\n"}{end}' \
  | awk 'NF>=3 && $3>0' | sort -k3 -rn
}

isc-res() { # sidecar requests/limits per pod [ns]
  kubectl get pods $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,REQ_CPU:.spec.containers[?(@.name=="istio-proxy")].resources.requests.cpu,REQ_MEM:.spec.containers[?(@.name=="istio-proxy")].resources.requests.memory,LIM_CPU:.spec.containers[?(@.name=="istio-proxy")].resources.limits.cpu,LIM_MEM:.spec.containers[?(@.name=="istio-proxy")].resources.limits.memory' | awk 'NR==1 || $3!="<none>"'
}

isc-init() { # istio-init / istio-validation (CNI) logs: isc-init <pod> <ns>
  kubectl logs "$1" -n "$2" -c istio-init 2>/dev/null || kubectl logs "$1" -n "$2" -c istio-validation
}

isc-crd() { # Sidecar CRDs (egress scoping -> 404/NR/503 to out-of-scope hosts) [ns]
  kubectl get sidecars.networking.istio.io $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.workloadSelector.labels,EGRESS:.spec.egress[*].hosts,OUTBOUND:.spec.outboundTrafficPolicy.mode'
}

isc-injector() { # injector webhooks + namespaceSelectors (revision tags)
  kubectl get mutatingwebhookconfigurations -o custom-columns='NAME:.metadata.name,REV:.metadata.labels.istio\.io/rev,TAG:.metadata.labels.istio\.io/tag,NS_SELECTOR:.webhooks[*].namespaceSelector.matchExpressions[*].key' | grep -iE 'NAME|istio|sidecar'
  istioctl tag list 2>/dev/null
}


# ==== Logs (extra) ====
klogd() { # logs from ALL pods of a deployment: klogd <deploy> <ns> [since=15m] [container]
  local sel; sel=$(kubectl get deploy "$1" -n "$2" -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}') || return 1
  if [ -n "$4" ]; then kubectl logs -n "$2" -l "${sel%,}" -c "$4" --since="${3:-15m}" --prefix --timestamps --max-log-requests=50
  else kubectl logs -n "$2" -l "${sel%,}" --all-containers --since="${3:-15m}" --prefix --timestamps --max-log-requests=50; fi
}
klogg() { kubectl logs "$1" -n "$2" --all-containers --since="${4:-1h}" --timestamps | grep -iE -- "$3"; }  # grep logs: klogg <pod|deploy/x> <ns> <regex> [since]
iaccess() { # istio-proxy access-log errors grouped: count code flag path: iaccess <pod> <ns> [since=30m]
  # flags: UF connect fail | UH no healthy upstream | NR no route | URX retries exhausted | UO circuit breaker
  #        UT timeout | UC upstream closed | DC client disconnect | UAEX ext-authz deny | rbac_access_denied = AuthorizationPolicy
  kubectl logs "$1" -n "$2" -c istio-proxy --since="${3:-30m}" | awk '{
    for(i=2;i<NF;i++) if($i ~ /HTTP\/[0-9.]+"$/){ code=$(i+1); flag=$(i+2); det=$(i+3); path=$(i-1)
      if(code ~ /^(0|4[0-9][0-9]|5[0-9][0-9])$/) c[code" "flag" "det" "path]++; break } }
    END{for(k in c) print c[k], k}' | sort -rn | head -30
}

# ==== Read YAML ====
_KY_DEL='del(.status) | del(.metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp, .metadata.managedFields, .metadata.selfLink) | del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")'
_ky_clean() {
  if yq --version 2>&1 | grep -q mikefarah; then yq "$_KY_DEL"
  else awk '
    /^status:/ {skip=1; next}
    skip && /^[^ ]/ {skip=0}
    skip {next}
    /kubectl\.kubernetes\.io\/last-applied-configuration:/ {la=1; match($0,/^ */); ind=RLENGTH; next}
    la { match($0,/^ */); if (RLENGTH>ind) next; la=0 }
    /^  (uid|resourceVersion|generation|creationTimestamp|selfLink):/ {next}
    {print}'
  fi
}
ky() { kubectl ${_KY_CTX:+--context "$_KY_CTX"} get "$1" "$2" ${3:+-n "$3"} -o yaml | _ky_clean; }  # clean YAML: ky <kind> <name> [ns]
kyvs()  { ky virtualservices.networking.istio.io "$1" "$2"; }        # VirtualService yaml: kyvs <name> <ns>
kydr()  { ky destinationrules.networking.istio.io "$1" "$2"; }       # DestinationRule yaml
kygw()  { ky gateways.networking.istio.io "$1" "${2:-$ISTIO_NS}"; }  # Gateway yaml
kyse()  { ky serviceentries.networking.istio.io "$1" "$2"; }         # ServiceEntry yaml
kyef()  { ky envoyfilters.networking.istio.io "$1" "$2"; }           # EnvoyFilter yaml
kyap()  { ky authorizationpolicies.security.istio.io "$1" "$2"; }    # AuthorizationPolicy yaml
kysvc() { ky service "$1" "$2"; }                                    # Service yaml
kydep() { ky deployment "$1" "$2"; }                                 # Deployment yaml
kycm()  { ky configmap "$1" "$2"; }                                  # ConfigMap yaml

kchain() { # full path for a service: VS -> Service -> DR -> pods/owners -> endpoints: kchain <svc> <ns>
  local s="${1:?usage: kchain <svc> <ns>}" n="${2:?usage: kchain <svc> <ns>}" sel v
  local m='{for(i=3;i<=NF;i++){h=$i; if((h==s && $1==n)||h==s"."n||h==s"."n".svc"||h==s"."n".svc.cluster.local"){print $1" "$2; break}}}'
  echo "== Service"
  kubectl get svc "$s" -n "$n" -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[*].port,TARGET:.spec.ports[*].targetPort,PORTNAME:.spec.ports[*].name,PROTO:.spec.ports[*].appProtocol,SELECTOR:.spec.selector' || return 1
  echo; echo "== VirtualServices routing to $s"
  kubectl get virtualservices.networking.istio.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.http[*].route[*].destination.host} {.spec.tcp[*].route[*].destination.host} {.spec.tls[*].route[*].destination.host}{"\n"}{end}' \
  | awk -v s="$s" -v n="$n" "$m" | while read -r vn v; do
      kubectl get virtualservices.networking.istio.io "$v" -n "$vn" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,GATEWAYS:.spec.gateways,HOSTS:.spec.hosts,TIMEOUT:.spec.http[*].timeout,RETRIES:.spec.http[*].retries.attempts'
    done
  echo; echo "== DestinationRules for $s"
  kubectl get destinationrules.networking.istio.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' \
  | awk -v s="$s" -v n="$n" "$m" | while read -r vn v; do
      kubectl get destinationrules.networking.istio.io "$v" -n "$vn" --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host,SUBSETS:.spec.subsets[*].name,TLS:.spec.trafficPolicy.tls.mode,LB:.spec.trafficPolicy.loadBalancer.simple,OUTLIER:.spec.trafficPolicy.outlierDetection.consecutive5xxErrors'
    done
  sel=$(kubectl get svc "$s" -n "$n" -o go-template='{{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}'); sel="${sel%,}"
  echo; echo "== Pods (selector: ${sel:-<none>})"
  [ -n "$sel" ] && kubectl get pods -n "$n" -l "$sel" -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].name,VERSION:.metadata.labels.version,NODE:.spec.nodeName'
  echo; echo "== Endpoints"; kepsvc "$s" "$n"
  echo; echo "== Policies in $n"; kubectl get peerauthentications.security.istio.io,authorizationpolicies.security.istio.io,sidecars.networking.istio.io -n "$n" 2>/dev/null
}

kycmp() { # same object across clusters (e.g. UAT vs PROD): kycmp <kind> <name> <ns> <ctxA> <ctxB>
  [ $# -eq 5 ] || { echo "usage: kycmp <kind> <name> <ns> <ctxA> <ctxB>  (both contexts must be in KUBECONFIG; kzone all)"; return 1; }
  diff -u --label "$4" --label "$5" <(_KY_CTX="$4" ky "$1" "$2" "$3") <(_KY_CTX="$5" ky "$1" "$2" "$3")
}

kydiff() { # live object vs local file (read-only, no server dry-run): kydiff <kind> <name> <ns> <file>
  [ $# -eq 4 ] || { echo "usage: kydiff <kind> <name> <ns> <file>"; return 1; }
  if yq --version 2>&1 | grep -q mikefarah; then
    diff -u --label live --label "$4" <(ky "$1" "$2" "$3" | yq -P 'sort_keys(..)') <(yq -P 'sort_keys(..)' "$4")
  else
    diff -u --label live --label "$4" <(ky "$1" "$2" "$3") "$4"
  fi
}

kexport() { # dump ns config (no secrets) for offline grep/diff/RCA: kexport <ns> [dir]
  local n="${1:?usage: kexport <ns> [dir]}" d k f
  d="${2:-./export-$(command kubectl config current-context)-$1-$(date +%Y%m%d-%H%M)}"
  mkdir -p "$d"
  for k in deploy sts ds svc cm hpa pdb ingress $(echo "$_ISTIO_KINDS" | tr ',' ' '); do
    f="$d/${k%%.*}.yaml"
    kubectl get "$k" -n "$n" -o yaml 2>/dev/null > "$f"
    { [ ! -s "$f" ] || grep -q '^items: \[\]' "$f"; } && rm -f "$f"
  done
  ls -1 "$d"; echo "-> $d"
}

# ==== Secrets: consumers / staleness / TLS ====
_SEC_REFS='{.spec.volumes[*].secret.secretName} {.spec.volumes[*].projected.sources[*].secret.name} {.spec.containers[*].env[*].valueFrom.secretKeyRef.name} {.spec.containers[*].envFrom[*].secretRef.name} {.spec.initContainers[*].envFrom[*].secretRef.name} {.spec.imagePullSecrets[*].name}'

ksec-users() { # pods referencing a secret (env/envFrom/volume/pullSecret): ksec-users <secret> <ns>
  kubectl get pods -n "${2:?usage: ksec-users <secret> <ns>}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.startTime}{" | "}'"$_SEC_REFS"'{"\n"}{end}' \
  | awk -v s="$1" '{for(i=4;i<=NF;i++) if($i==s){print $1, "started="$2; break}}'
}

ksec-owners() { # deploy/sts/ds whose template references a secret: ksec-owners <secret> <ns>
  local t="${_SEC_REFS//.spec./.spec.template.spec.}"
  kubectl get deploy,sts,ds -n "${2:?usage: ksec-owners <secret> <ns>}" -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{" | "}'"$t"'{"\n"}{end}' \
  | awk -v s="$1" '{for(i=3;i<=NF;i++) if($i==s){print tolower($1); break}}'
}

ksec-stale() { # pods started BEFORE secret's last update (need restart): ksec-stale <secret> <ns>
  local s="$1" n="${2:?usage: ksec-stale <secret> <ns>}" upd
  upd=$(kubectl get secret "$s" -n "$n" -o jsonpath='{.metadata.creationTimestamp} {.metadata.managedFields[*].time}' | tr ' ' '\n' | grep . | sort | tail -1)
  echo "secret last updated: $upd"
  ksec-users "$s" "$n" | awk -v u="$upd" '{split($2,a,"="); print (a[2] < u ? "STALE  " : "ok     ") $0}'
}


kcert-match() { # tls.key matches tls.crt?: kcert-match <secret> [ns]
  local c k
  c=$(kubectl get secret "$1" ${2:+-n "$2"} -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -pubkey 2>/dev/null | openssl sha256)
  k=$(kubectl get secret "$1" ${2:+-n "$2"} -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -pubout 2>/dev/null | openssl sha256)
  if [ -n "$c" ] && [ "$c" = "$k" ]; then echo "MATCH"; else echo "MISMATCH  cert:$c  key:$k"; fi
}

kcert-chain() { # every cert in tls.crt (missing intermediate?): kcert-chain <secret> [ns]
  kubectl get secret "$1" ${2:+-n "$2"} -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout
}

igw-cred() { # Gateway TLS credentialName -> secret present in gateway pod ns + expiry
  local ns gw port mode cred st canread
  canread=$(command kubectl auth can-i get secrets -n "$ISTIO_NS" 2>/dev/null)
  kubectl get gateways.networking.istio.io -A -o go-template='{{range .items}}{{$n := .metadata.namespace}}{{$g := .metadata.name}}{{range .spec.servers}}{{$n}} {{$g}} {{.port.number}} {{if .tls}}{{or .tls.mode "-"}} {{or .tls.credentialName "-"}}{{else}}- -{{end}}{{"\n"}}{{end}}{{end}}' |
  while read -r ns gw port mode cred; do
    if [ "$cred" = "-" ]; then st="(no credentialName)"
    elif [ "$canread" != yes ]; then st="(no secret read — use: tlscheck <host> 443 <gw-ip>)"
    elif kubectl get secret "$cred" -n "$ISTIO_NS" >/dev/null 2>&1; then
      st="OK exp=$(kubectl get secret "$cred" -n "$ISTIO_NS" -o jsonpath='{.data.tls\.crt}{.data.cert}' | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    else st="MISSING in $ISTIO_NS"; fi
    printf '%-15s %-28s %-6s %-10s %-35s %s\n' "$ns" "$gw" "$port" "$mode" "$cred" "$st"
  done
}

# ==== EnvoyFilter: scope / applied? / backup ====
ief-who() { # patches + which pods an EnvoyFilter hits: ief-who <name> <ns>
  local name="$1" ns="${2:?usage: ief-who <envoyfilter> <ns>}" sel
  kubectl get envoyfilters.networking.istio.io "$name" -n "$ns" -o go-template='{{range .spec.configPatches}}applyTo={{.applyTo}} op={{.patch.operation}}{{with .match}} context={{or .context "ANY"}}{{with .proxy}} proxyVersion={{.proxyVersion}}{{end}}{{end}}{{"\n"}}{{end}}' || return 1
  sel=$(kubectl get envoyfilters.networking.istio.io "$name" -n "$ns" -o go-template='{{with .spec.workloadSelector}}{{range $k,$v := .labels}}{{$k}}={{$v}},{{end}}{{end}}'); sel="${sel%,}"
  if [ -z "$sel" ]; then
    if [ "$ns" = "$ISTIO_NS" ]; then echo "NO selector in root ns -> ALL proxies in mesh"; else echo "NO selector -> ALL proxies in ns $ns"; fi
  else
    echo "selector: $sel"; kubectl get pods -n "$ns" -l "$sel" -o wide
  fi
}


ief-backup() { # dump EnvoyFilters to /tmp before changes/upgrades [ns]
  local out="/tmp/envoyfilters_${1:-all}_$(date +%s).yaml"
  kubectl get envoyfilters.networking.istio.io $(_nsflag "$1") -o yaml > "$out" && echo "$out"
}

# ==== Rollout restart ====

krstuck() { # why a rollout is stuck: krstuck <deploy/name> <ns>
  local r="$1" n="${2:?usage: krstuck <deploy/name> <ns>}" sel
  kubectl get "$r" -n "$n" -o go-template='{{range .status.conditions}}{{.type}}={{.status}} {{.reason}}: {{.message}}{{"\n"}}{{end}}'
  sel=$(kubectl get "$r" -n "$n" -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}'); sel="${sel%,}"
  echo "-- replicasets"; kubectl get rs -n "$n" -l "$sel" 2>/dev/null
  echo "-- pods";        kubectl get pods -n "$n" -l "$sel" -o wide
  echo "-- pdb";         kubectl get pdb -n "$n"
  echo "-- hpa";         kubectl get hpa -n "$n" 2>/dev/null
  echo "-- quota";       kubectl get resourcequota -n "$n" 2>/dev/null
  echo "-- warnings";    kwarn "$n" 15
}

krhist() { kubectl rollout history "$1" -n "$2" ${3:+--revision "$3"}; }  # krhist <deploy/name> <ns> [rev]

# ==== Helm ====
alias hls='helm list -A'                              # all releases
alias hbad='helm list -A --failed --pending'          # failed / stuck releases
hhist() { helm history "$1" -n "$2"; }                # hhist <rel> <ns>
hvals() { helm get values "$1" -n "$2" ${3:+--revision "$3"}; }  # user-supplied values [rev]
hvalsa() { helm get values "$1" -n "$2" -a; }         # computed values (incl. defaults)
hman() { helm get manifest "$1" -n "$2" ${3:+--revision "$3"}; }  # rendered manifest [rev]
hrevdiff() { diff -u <(helm get manifest "$1" -n "$2" --revision "$3") <(helm get manifest "$1" -n "$2" --revision "$4"); }  # hrevdiff <rel> <ns> <r1> <r2>
hsecrets() { kubectl get secret -n "$2" -l owner=helm,name="$1" -L status,version --sort-by=.metadata.creationTimestamp; }  # release storage (stuck pending-upgrade)
htpl() { helm template "$1" "$2" -n "$3" "${@:4}"; }  # htpl <rel> <chart> <ns> [-f values.yaml ...]

# ==== Other failure domains (read-only) ====
kpending() { kubectl get pods $(_nsflag "$1") --field-selector=status.phase=Pending -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,REASON:.status.conditions[?(@.type=="PodScheduled")].reason,MESSAGE:.status.conditions[?(@.type=="PodScheduled")].message'; }  # Pending pods + scheduler reason [ns]
koom() { # any container OOMKilled (app or sidecar) [ns]
  kubectl get pods $(_nsflag "$1") -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$p := .metadata.name}}{{range .status.containerStatuses}}{{if .lastState.terminated}}{{if eq .lastState.terminated.reason "OOMKilled"}}{{$ns}} {{$p}} {{.name}} restarts={{.restartCount}} at={{.lastState.terminated.finishedAt}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}'
}
kalloc() { kubectl describe nodes ${1:+"$1"} | awk '/^Name:/{n=$2} /Allocated resources/{p=1; print "== " n; next} p && /^Events:/{p=0} p'; }  # requests/limits vs allocatable per node [node]
kquota() { kubectl describe resourcequota,limitrange -n "${1:?usage: kquota <ns>}"; }  # quota/limitrange blocking pods
knetpol() { kubectl get networkpolicy $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PODS:.spec.podSelector.matchLabels,TYPES:.spec.policyTypes'; }  # NetworkPolicies [ns]
kpvc() { kubectl get pvc $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage,VOLUME:.spec.volumeName' | awk 'NR==1 || $3!="Bound"'; }  # PVCs not Bound [ns]
kjobs() { kubectl get jobs $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,OK:.status.succeeded,FAILED:.status.failed,ACTIVE:.status.active,START:.status.startTime' | awk 'NR==1 || ($4!="<none>" && $4>0)'; }  # failed Jobs [ns]
kwebhooks() { kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o custom-columns='NAME:.metadata.name,FAILPOLICY:.webhooks[*].failurePolicy,SVC:.webhooks[*].clientConfig.service.name,SVCNS:.webhooks[*].clientConfig.service.namespace,TIMEOUT:.webhooks[*].timeoutSeconds'; }  # admission webhooks (apply/scale failures)
klb() { kubectl get svc -A -o wide | awk 'NR==1 || $3=="LoadBalancer"'; }  # LoadBalancer services (EXTERNAL-IP <pending>?)
kcattle() { kubectl get pods -n cattle-system -o wide; kubectl get pods -n cattle-fleet-system 2>/dev/null; }  # Rancher agents (cluster shows unavailable in Rancher)
hls-ro() { # Helm releases WITHOUT secret access (from workload annotations/labels) [ns]
  kubectl get deploy,sts,ds $(_nsflag "$1") -o custom-columns='NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name,RELEASE:.metadata.annotations.meta\.helm\.sh/release-name,CHART:.metadata.labels.helm\.sh/chart,IMAGE:.spec.template.spec.containers[0].image' | awk 'NR==1 || $4!="<none>"'
}
icp() { # Istio control plane health incl. NACKs (read-only substitute for proxy-status)
  echo "== $ISTIO_NS pods"; kubectl get pods -n "$ISTIO_NS" -o wide
  echo; echo "== istio-cni";    kubectl get ds -A -l k8s-app=istio-cni-node 2>/dev/null
  echo; echo "== hpa/pdb";      kubectl get hpa,pdb -n "$ISTIO_NS" 2>/dev/null
  echo; echo "== istiod NACK/reject/errors (15m)"
  kubectl logs -n "$ISTIO_NS" -l app=istiod --since=15m --tail=5000 2>/dev/null | grep -iE 'nack|rejected|invalid|error' | tail -n 25
}

# ==== Triage ====
ktriage() { # one-shot namespace health: ktriage <ns>
  local ns="${1:?usage: ktriage <ns>}"
  echo "== context";                   kcur
  echo; echo "== pods not ready";      kbad "$ns"
  echo; echo "== pending (scheduler)"; kpending "$ns"
  echo; echo "== OOMKilled";           koom "$ns"
  echo; echo "== PVC not bound";       kpvc "$ns"
  echo; echo "== deployments not available"; kubectl get deploy -n "$ns" --no-headers | awk '{split($2,r,"/"); if (r[1]!=r[2]) print}'
  echo; echo "== services w/o endpoints"; knoep "$ns"
  echo; echo "== warning events";      kwarn "$ns" 20
  echo; echo "== istio objects";       inet "$ns" 2>/dev/null
  echo; echo "== istio analyze";       istioctl analyze -n "$ns" 2>&1 | tail -n 30
  echo; echo "== helm";                helm list -n "$ns" -a 2>/dev/null || hls-ro "$ns"
}

khelp() { # list all commands
  sed -n -e 's/^# ==== \(.*\) ====$/\n[\1]/p' \
         -e 's/^\([a-z][a-z0-9_-]*\)() {.*# \(.*\)$/  \1|\2/p' \
         -e 's/^alias \([^=]*\)=.*# \(.*\)$/  \1|\2/p' "$_K8S_PROFILE" | column -t -s'|'
}

# ==== Completion ====
if command -v kubectl >/dev/null; then source <(command kubectl completion bash); complete -o default -F __start_kubectl k; fi
command -v helm     >/dev/null && source <(command helm completion bash)
command -v istioctl >/dev/null && source <(command istioctl completion bash)
