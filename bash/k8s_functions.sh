function kubeconfigRebuild{
    echo Not implemented yet. Uncertainty around handling OIDC user config vs. AWS CLI SSO login. Will likely need to be a more complex script that handles both, and can be re-run idempotently.
    echo Also needs cloud, onprem, and local generalization
    return
    # Define entries as: "alias|cluster-name|aws-profile|aws-region"
    local -a CLUSTERS=(
        "env|clustername|ctxName|AWSRegion"
    )

    local -A logged_in_profiles  # associative array to track logins

    for entry in "${CLUSTERS[@]}"; do
        local env cluster profile region
        IFS="|" read -r env cluster profile region <<< "$entry"

        # Login once per unique profile
        if [[ -z "${logged_in_profiles[$profile]+_}" ]]; then
            # Check if already authenticated
            if aws sts get-caller-identity --profile "$profile" &>/dev/null; then
                echo "==> [$profile] Already authenticated, skipping login"
            else
                echo "==> [$profile] Logging in..."
                aws sso login --profile "$profile" || {
                    echo "ERROR: sso login failed for $profile, skipping all clusters using this profile"
                    logged_in_profiles[$profile]="failed"
                    continue
                }
            fi
            logged_in_profiles[$profile]="ok"
        fi

        # Skip clusters whose profile login failed
        if [[ "${logged_in_profiles[$profile]}" == "failed" ]]; then
            echo "SKIP [$env] ($cluster) — profile $profile failed authentication"
            continue
        fi

        echo "==> [$env] Updating kubeconfig for cluster: $cluster"
        aws eks update-kubeconfig \
            --name "$cluster" \
            --region "$region" \
            --profile "$profile" \
            --alias "$env" || echo "WARNING: update-kubeconfig failed for $cluster"
    done

    echo ""
    echo "Done. Active contexts:"
    kubectl config get-contexts
}

function kns {
    local ns="${1:?Usage: kns <namespace>}"
    kubectl config set-context --current --namespace="$ns"
}

function _kns_complete {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local namespaces
    namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    COMPREPLY=($(compgen -W "$namespaces" -- "$cur"))
}
complete -F _kns_complete kns

function kctx {
    local ctx="${1:?Usage: kctx <context>}"
    kubectl config use-context "$ctx"
}

function _kctx_complete {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null)
    COMPREPLY=($(compgen -W "$contexts" -- "$cur"))
}
complete -F _kctx_complete kctx

function kgy {
    local namespace=""
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace) namespace="$2"; shift 2 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    local type="${positional[0]:?Usage: kgy [-n <namespace>] <type> <name>}"
    local name="${positional[1]:?Usage: kgy [-n <namespace>] <type> <name>}"
    local ns_flag=()
    [[ -n "$namespace" ]] && ns_flag=(-n "$namespace")
    kubectl get "$type" "$name" -o yaml "${ns_flag[@]}"
}

