#!/bin/bash

# Cloud provider handlers for rebuildKubeconfig in k8s_functions.sh.
# _aws_login <profile>  — authenticates the AWS profile.
# _aws_kubeconfig <alias> <cluster> <profile> <region>  — fetches EKS kubeconfig.
#
# _aws_login_all_profiles <result-map-name> <clusters-array-name>
#   Iterates the named CLUSTERS array, attempts login once per unique cloud:profile
#   pair, and populates the named associative array with "ok" or "failed" per key.

function _aws_login {
    local profile="$1"

    local -a PROFILES
    # shellcheck source=aws_profiles.conf
    source "${BASH_SOURCE[0]%/*}/aws_profiles.conf"

    local entry
    for entry in "${PROFILES[@]}"; do
        local p loginType
        IFS='|' read -r p _ _ _ _ loginType <<< "$entry"
        if [[ "$p" == "$profile" ]]; then
            local login_fn="_aws_login_${loginType}"
            if declare -f "$login_fn" > /dev/null; then
                "$login_fn" "$profile"
                return
            else
                echo "ERROR: unknown login type '$loginType' for profile '$profile'"
                return 1
            fi
        fi
    done

    echo "ERROR: profile '$profile' not found in aws_profiles.conf"
    return 1
}

function _aws_kubeconfig {
    local clusterAlias="$1" cluster="$2" profile="$3" region="$4"
    aws eks update-kubeconfig \
        --name "$cluster" \
        --region "$region" \
        --profile "$profile" \
        --alias "$clusterAlias"
}

# Attempt login once per unique cloud:profile pair.
# Usage: _aws_login_all_profiles <result-map-name> <cloud-profile-pairs-array-name>
#   <result-map-name>          — name of a 'local -A' associative array in the caller; will be
#                                populated with "ok" or "failed" keyed by "cloud:profile".
#   <cloud-profile-pairs-array-name> — name of an array of "cloud:profile" strings.

## TODO: something's stinky here. 
##   appservices-dev
##   ordermanager-qa
##   do not login correctly. maybe needs to ise OIDC?!?!?!
function _aws_login_all_profiles {
    local -n _login_states="$1"
    local -n _pairs_ref="$2"
    local pair
    for pair in "${_pairs_ref[@]}"; do
        [[ -n "${_login_states[$pair]+_}" ]] && continue
        local cloud profile
        IFS=":" read -r cloud profile <<< "$pair"

        local login_fn="_${cloud}_login"
        if declare -f "$login_fn" > /dev/null; then
            if "$login_fn" "$profile"; then
                _login_states[$pair]="ok"
            else
                echo "ERROR: login failed for profile '$profile' (cloud: $cloud)"
                _login_states[$pair]="failed"
            fi
        else
            echo "ERROR: unknown cloud provider '$cloud' for profile '$profile'"
            _login_states[$pair]="failed"
        fi
    done
}

# AWS SSO login helpers — used by awsLogin below.

function _aws_login_sso {
    local profile="$1"
    if aws sts get-caller-identity --profile "$profile" &>/dev/null; then
        echo "==> [$profile] Already authenticated, skipping login"
        return 0
    fi
    echo "==> [$profile] Logging in via SSO..."
    aws sso login --profile "$profile"
}

function _aws_login_oidc {
    local profile="$1"
    echo "Not implemented: OIDC login for profile '$profile'"
    return 1
}

function rebuildAwsCliConfig {
    echo "Rebuilding AWS CLI config and credentials files..."
    # Backup existing file
    cp ~/.aws/config ~/.aws/config.bak

    # Clear existing files
    > ~/.aws/config

    # SSOPROFILES and PROFILES are defined in aws_profiles.conf (same directory as this file).
    # Declare locals first so the sourced assignments stay in function scope.
    local -a SSOPROFILES PROFILES
    # shellcheck source=aws_profiles.conf
    source "${BASH_SOURCE[0]%/*}/aws_profiles.conf"

    for entry in "${SSOPROFILES[@]}"; do
        IFS='|' read -r profile URL region scopes <<< "$entry"
        echo "Adding SSO: $profile"
        # Add to config file
        {
            echo "[sso-session $profile]"
            echo "sso_start_url = $URL"
            echo "sso_region = $region"
            echo "region = $region"
            echo "sso_registration_scopes = $scopes"
            echo ""
        } >> ~/.aws/config
    done

    for entry in "${PROFILES[@]}"; do
        IFS='|' read -r profile ssoSession account role region _ <<< "$entry"
        echo "Adding profile: $profile with region: $region"

        # Add to config file
        {
            echo "[profile $profile]"
            echo "sso_session = $ssoSession"
            echo "sso_account_id = $account"
            echo "sso_role_name = $role"
            echo "sso_region = $region"
            echo "region = $region"
            echo ""
        } >> ~/.aws/config
    done

    echo "AWS CLI config and credentials have been rebuilt. Backups created as config.bak and credentials.bak."
}

function awsLogin {
    local profile="${1:?Usage: awsLogin <profile>}"
    echo "Logging in to AWS CLI profile: $profile"
    _aws_login "$profile" && awsProfile "$profile"
}

function awsProfile {
    local profile="${1:?Usage: awsProfile <profile>}"
    export AWS_PROFILE="$profile"
    echo "Switched to AWS CLI profile: $profile"

    # Look up the account ID for this profile from aws_profiles.conf
    local -a PROFILES
    # shellcheck source=aws_profiles.conf
    source "${BASH_SOURCE[0]%/*}/aws_profiles.conf"
    local entry
    for entry in "${PROFILES[@]}"; do
        local p account region
        IFS='|' read -r p _ account _ region _ <<< "$entry"
        if [[ "$p" == "$profile" ]]; then
            export AWS_ACCOUNT_ID="$account"
            echo "Set AWS_ACCOUNT_ID=$account"
            awsRegion $region
            return
        fi
    done
    echo "WARNING: no account ID found for profile '$profile' in aws_profiles.conf"
}

function awsRegion {
    local region="${1:?Usage: awsRegion <region>}"
    export AWS_DEFAULT_REGION="$region"
    echo "Switched to AWS region: $region"
}

# Discover EKS clusters across all profiles and operating regions from aws_profiles.conf.
# Prints a CLUSTERS=(...) block ready to paste into k8s_clusters.conf.
# Login output goes to stderr; cluster entries go to stdout.
function aws_discover_k8s_clusters {
    local -a PROFILES OPERATING_REGIONS
    # shellcheck source=aws_profiles.conf
    source "${BASH_SOURCE[0]%/*}/aws_profiles.conf"

    # Build set of aws:profile pairs, then login once per profile
    local -A _pair_set=()
    local entry
    for entry in "${PROFILES[@]}"; do
        local profile
        IFS='|' read -r profile _ _ _ _ _ <<< "$entry"
        _pair_set["aws:${profile}"]=1
    done
    local -a login_pairs=("${!_pair_set[@]}")

    local -A login_states=()
    _aws_login_all_profiles login_states login_pairs >&2

    # Filter to only profiles that authenticated successfully
    local -a authed_profiles=()
    for entry in "${PROFILES[@]}"; do
        local profile
        IFS='|' read -r profile _ _ _ _ _ <<< "$entry"
        if [[ "${login_states[aws:${profile}]}" == "ok" ]]; then
            authed_profiles+=("$profile")
        else
            echo "WARNING: login failed for profile=$profile, skipping" >&2
        fi
    done

    # Collect all cluster entries, then print them together at the end
    local -a cluster_entries=()
    for profile in "${authed_profiles[@]}"; do
        local region
        for region in "${OPERATING_REGIONS[@]}"; do
            local clusters_json
            clusters_json=$(aws eks list-clusters \
                --profile "$profile" \
                --region "$region" \
                --output json 2>/dev/null) || {
                echo "WARNING: could not list clusters for profile=$profile region=$region" >&2
                continue
            }

            local cluster
            while IFS= read -r cluster; do
                [[ -z "$cluster" ]] && continue
                cluster_entries+=("$(printf '    "aws_%s_%s|%s|aws|%s|%s"' "$profile" "$cluster" "$cluster" "$profile" "$region")")
            done < <(jq -r '.clusters[]' <<< "$clusters_json")
        done
    done

    echo "#------------Paste into CLUSTERS in k8s_clusters.conf------------"
    echo "# Format: \"alias|cluster-name|cloud|profile|region\""
    echo "# cloud must match a _cloud_login_<cloud> / _cloud_kubeconfig_<cloud> function pair."
    echo "# Discovered EKS clusters — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "CLUSTERS=("
    printf '%s\n' "${cluster_entries[@]}"
    echo ")"
}

###### Completions
function _awsProfile_completions {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local profiles
    profiles=$(grep -oP '(?<=^\[profile )[^\]]+' ~/.aws/config 2>/dev/null)
    COMPREPLY=( $(compgen -W "$profiles" -- "$cur") )
}

complete -C '/usr/local/bin/aws_completer' aws
complete -F _awsProfile_completions awsLogin
complete -F _awsProfile_completions awsProfile
