#! /bin/bash
function rebuildKubeconfig {
    # CLUSTERS is defined in k8s_clusters.conf (same directory as this file).
    # Declare local first so the sourced assignment stays in function scope.
    local -a CLUSTERS
    # shellcheck source=k8s_clusters.conf
    source "${BASH_SOURCE[0]%/*}/k8s_clusters.conf"

    # Build a set of unique cloud:profile pairs, then extract keys as the login list
    local -A _seen_pairs=()
    local entry
    for entry in "${CLUSTERS[@]}"; do
        local _a _b cloud profile _r
        IFS="|" read -r _a _b cloud profile _r <<< "$entry"
        _seen_pairs["${cloud}:${profile}"]=1
    done
    local -a login_pairs=("${!_seen_pairs[@]}")

    local -A logged_in_profiles  # populated by _aws_login_all_profiles
    # TODO: generalize to support multiple clouds. Extract login logic to some cross-cloud lib
    _aws_login_all_profiles logged_in_profiles login_pairs

    for entry in "${CLUSTERS[@]}"; do
        local clusterAlias cluster cloud profile region
        IFS="|" read -r clusterAlias cluster cloud profile region <<< "$entry"

        [[ "$cloud" == "custom" ]] && continue

        local login_key="${cloud}:${profile}"
        # Skipp clusters where login failed for the associated profile
        if [[ "${logged_in_profiles[$login_key]}" == "failed" ]]; then
            echo "SKIP [$clusterAlias] ($cluster) — $cloud profile '$profile' failed authentication"
            continue
        fi

        echo "==> [$clusterAlias] Updating kubeconfig for cluster: $cluster"

        # Look up the cluster and user referenced by the existing context (may differ from alias)
        local existing_cluster existing_user
        existing_cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${clusterAlias}\")].context.cluster}" 2>/dev/null)
        existing_user=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${clusterAlias}\")].context.user}" 2>/dev/null)

        kubectl config delete-context "$clusterAlias" &>/dev/null || true
        [[ -n "$existing_cluster" ]] && kubectl config delete-cluster "$existing_cluster" &>/dev/null || true
        [[ -n "$existing_user" ]] && kubectl config delete-user "$existing_user" &>/dev/null || true

        local kubeconfig_fn="_${cloud}_kubeconfig"
        if declare -f "$kubeconfig_fn" > /dev/null; then
            "$kubeconfig_fn" "$clusterAlias" "$cluster" "$profile" "$region" || \
                echo "WARNING: kubeconfig update failed for $cluster"
        else
            echo "ERROR: no kubeconfig handler for cloud '$cloud', skipping $clusterAlias"
        fi
    done

    echo ""
    echo "Done. Active contexts:"
    kubectl config get-contexts
}

function kns {
    local ns="${1:?Usage: kns <namespace>}"
    kubectl config set-context --current --namespace="$ns"
}

function kctx {
    local ctx="${1:?Usage: kctx <context>}"
    kubectl config use-context "$ctx"
}

function kgy {
    local namespace=""
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace) namespace="$2"; shift 2 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    local ns_flag=()
    [[ -n "$namespace" ]] && ns_flag=(-n "$namespace")
    if [[ ${#positional[@]} -ge 2 ]]; then
        kubectl get "${positional[0]}" "${positional[1]}" -o yaml "${ns_flag[@]}"
    elif [[ ${#positional[@]} -eq 1 ]]; then
        kubectl get "${positional[0]}" -o yaml "${ns_flag[@]}"
    else
        echo "Usage: kgy [-n <namespace>] [<type>] <name|type/name>" >&2
        return 1
    fi
}

###### Completions
function _kns_complete {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local namespaces
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    COMPREPLY=($(compgen -W "$namespaces" -- "$cur"))
}
complete -F _kns_complete kns

function _kctx_complete {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null)
    COMPREPLY=($(compgen -W "$contexts" -- "$cur"))
}
complete -F _kctx_complete kctx
