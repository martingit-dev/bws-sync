#!/bin/bash
set -euo pipefail

# bws-sync — drift-first sync between .env and Bitwarden Secrets Manager
#
#   bws-sync                    status (default): show drift, read-only
#   bws-sync init               write .bws-sync.toml with project IDs
#   bws-sync push [KEY...]      push .env -> BWS (all keys, or just KEY...)
#   bws-sync pull [KEY...]      pull BWS -> .env (dev only)
#   bws-sync prune [KEY...]     delete BWS keys that aren't in .env
#   bws-sync wire               rewrite .github/workflows/deploy-<env>.yml UUIDs
#
# Flags: -e/--env <dev|staging|production>  -d/--dir <path>  -y/--yes  -h/--help
#
# Values are only ever read from or written to .env for dev. For staging and
# production the script compares keys only, and prompts for values.

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'

log_info()    { echo -e "${BLUE}i${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}!${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

die() { log_error "$1"; exit 1; }

usage() {
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------- args

CMD="status"
ENV="dev"
REPO_PATH="$PWD"
ASSUME_YES="no"
KEYS_ARG=()

case "${1:-}" in
    init|status|push|pull|prune|wire) CMD="$1"; shift ;;
    -h|--help|help) usage 0 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)  ENV="${2:-}"; shift 2 ;;
        -d|--dir)  REPO_PATH="${2:-}"; shift 2 ;;
        -y|--yes)  ASSUME_YES="yes"; shift ;;
        -h|--help) usage 0 ;;
        -*)        die "Unknown flag: $1" ;;
        *)         KEYS_ARG+=("$1"); shift ;;
    esac
done

case "$ENV" in
    dev|staging|production) ;;
    prod) ENV="production" ;;
    *) die "Invalid env: $ENV (dev|staging|production)" ;;
esac

[[ -d "$REPO_PATH" ]] || die "Not a directory: $REPO_PATH"
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
REPO_NAME="$(basename "$REPO_PATH")"

for bin in bws jq; do
    command -v "$bin" >/dev/null || die "$bin not found on PATH"
done

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local reply
    read -rp "$1 [y/N]: " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ---------------------------------------------------------------- config

CONFIG_DIR="${BWS_SYNC_CONFIG_DIR:-$HOME/.config/bws-sync}"
CONFIG_FILE="$CONFIG_DIR/secrets.conf"
PROJECT_FILE="$REPO_PATH/.bws-sync.toml"

load_token() {
    [[ -f "$CONFIG_FILE" ]] || die "No token config: $CONFIG_FILE (see README)"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    local var="BWS_ACCESS_TOKEN_$(echo "$ENV" | tr '[:lower:]' '[:upper:]')"
    ACCESS_TOKEN="${!var:-}"
    [[ -n "$ACCESS_TOKEN" ]] || die "$var not set in $CONFIG_FILE"
}

# Reads `dev = "uuid"` under [projects], plus a top-level `env_file = "..."`.
load_project() {
    [[ -f "$PROJECT_FILE" ]] || die "No $PROJECT_FILE — run: bws-sync init"

    ENV_FILE_NAME=$(awk -F'=' '/^[[:space:]]*env_file[[:space:]]*=/ {
        gsub(/^[[:space:]]*"?|"?[[:space:]]*$/, "", $2); print $2; exit }' "$PROJECT_FILE")
    ENV_FILE_NAME="${ENV_FILE_NAME:-.env}"

    PROJECT_ID=$(awk -v want="$ENV" '
        /^\[/ { section = $0 }
        section == "[projects]" && $1 == want {
            gsub(/^[^=]*=[[:space:]]*"?|"?[[:space:]]*$/, "", $0); print; exit }' "$PROJECT_FILE")

    [[ -n "$PROJECT_ID" ]] || die "No project ID for '$ENV' in $PROJECT_FILE"
    ENV_FILE="$REPO_PATH/$ENV_FILE_NAME"
}

cmd_init() {
    if [[ -f "$PROJECT_FILE" ]]; then
        log_warn "$PROJECT_FILE already exists"
        confirm "  Overwrite?" || exit 0
    fi

    echo ""
    log_info "Project IDs for $REPO_NAME (blank to skip an environment)"
    local dev staging production env_file
    read -rp "  dev:        " dev
    read -rp "  staging:    " staging
    read -rp "  production: " production
    read -rp "  env file [.env]: " env_file

    {
        echo "# bws-sync — BWS project IDs for this repo."
        echo "# Project IDs are not secrets; the access token lives in $CONFIG_DIR."
        echo "env_file = \"${env_file:-.env}\""
        echo ""
        echo "[projects]"
        [[ -n "$dev" ]]        && echo "dev = \"$dev\""
        [[ -n "$staging" ]]    && echo "staging = \"$staging\""
        [[ -n "$production" ]] && echo "production = \"$production\""
    } > "$PROJECT_FILE"

    log_success "Wrote $PROJECT_FILE — safe to commit"
}

# ---------------------------------------------------------------- state

declare -A LOCAL_VALS=()   # key -> value from .env
declare -A REMOTE_VALS=()  # key -> value from BWS
declare -A REMOTE_IDS=()   # key -> BWS secret UUID

parse_env_file() {
    [[ -f "$ENV_FILE" ]] || return 1
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        value="${value%"${value##*[![:space:]]}"}"      # rstrip
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        LOCAL_VALS["$key"]="$value"
    done < "$ENV_FILE"
}

fetch_remote() {
    log_info "Fetching $ENV secrets from BWS…" >&2
    local json
    json=$(bws secret list "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json 2>/dev/null) \
        || die "Cannot read project $PROJECT_ID — check token and project ID"

    local key id value
    while IFS=$'\t' read -r key id value; do
        [[ -n "$key" ]] || continue
        REMOTE_IDS["$key"]="$id"
        REMOTE_VALS["$key"]="$value"
    done < <(echo "$json" | jq -r '.[] | [.key, .id, .value] | @tsv')
}

# Populates SYNCED / LOCAL_ONLY / REMOTE_ONLY / CHANGED.
# CHANGED is only computed for dev — staging/prod compare keys, never values.
declare -a SYNCED=() LOCAL_ONLY=() REMOTE_ONLY=() CHANGED=()

diff_state() {
    SYNCED=(); LOCAL_ONLY=(); REMOTE_ONLY=(); CHANGED=()
    local key
    for key in "${!LOCAL_VALS[@]}"; do
        if [[ -z "${REMOTE_IDS[$key]+x}" ]]; then
            LOCAL_ONLY+=("$key")
        elif [[ "$ENV" == "dev" && "${LOCAL_VALS[$key]}" != "${REMOTE_VALS[$key]}" ]]; then
            CHANGED+=("$key")
        else
            SYNCED+=("$key")
        fi
    done
    for key in "${!REMOTE_IDS[@]}"; do
        [[ -z "${LOCAL_VALS[$key]+x}" ]] && REMOTE_ONLY+=("$key")
    done
    [[ ${#SYNCED[@]}      -gt 0 ]] && mapfile -t SYNCED      < <(printf '%s\n' "${SYNCED[@]}" | sort)
    [[ ${#LOCAL_ONLY[@]}  -gt 0 ]] && mapfile -t LOCAL_ONLY  < <(printf '%s\n' "${LOCAL_ONLY[@]}" | sort)
    [[ ${#REMOTE_ONLY[@]} -gt 0 ]] && mapfile -t REMOTE_ONLY < <(printf '%s\n' "${REMOTE_ONLY[@]}" | sort)
    [[ ${#CHANGED[@]}     -gt 0 ]] && mapfile -t CHANGED     < <(printf '%s\n' "${CHANGED[@]}" | sort)
    return 0
}

load_state() {
    load_token
    load_project
    parse_env_file || log_warn "No $ENV_FILE_NAME in $REPO_NAME — comparing against BWS only"
    fetch_remote
    diff_state
}

# ---------------------------------------------------------------- status

cmd_status() {
    load_state

    echo ""
    echo -e "${DIM}$REPO_NAME · $ENV · $ENV_FILE_NAME${NC}"
    printf '  %s%d in sync%s' "$GREEN" "${#SYNCED[@]}" "$NC"
    printf '   %s+%d local-only%s' "$YELLOW" "${#LOCAL_ONLY[@]}" "$NC"
    printf '   %s-%d bws-only%s' "$YELLOW" "${#REMOTE_ONLY[@]}" "$NC"
    [[ "$ENV" == "dev" ]] && printf '   %s~%d changed%s' "$RED" "${#CHANGED[@]}" "$NC"
    echo -e "\n"

    (( ${#LOCAL_ONLY[@]} ))  && printf "  ${YELLOW}+${NC} %s ${DIM}(in %s, not in BWS)${NC}\n" "$(join_keys "${LOCAL_ONLY[@]}")" "$ENV_FILE_NAME"
    (( ${#REMOTE_ONLY[@]} )) && printf "  ${YELLOW}-${NC} %s ${DIM}(in BWS, not in %s)${NC}\n" "$(join_keys "${REMOTE_ONLY[@]}")" "$ENV_FILE_NAME"
    (( ${#CHANGED[@]} ))     && printf "  ${RED}~${NC} %s ${DIM}(values differ)${NC}\n" "$(join_keys "${CHANGED[@]}")"

    if (( ${#LOCAL_ONLY[@]} + ${#REMOTE_ONLY[@]} + ${#CHANGED[@]} == 0 )); then
        log_success "No drift"
        return 0
    fi

    echo ""
    if [[ "$ENV" == "dev" ]]; then
        echo -e "  ${DIM}bws-sync push [KEY…]   ·   bws-sync pull [KEY…]   ·   bws-sync prune${NC}"
    else
        echo -e "  ${DIM}keys only — $ENV values are never read into $ENV_FILE_NAME${NC}"
        echo -e "  ${DIM}bws-sync push -e $ENV [KEY…]   ·   bws-sync prune -e $ENV   ·   bws-sync wire -e $ENV${NC}"
    fi
    echo ""
    return 1
}

join_keys() { printf '%s' "$1"; shift; printf ', %s' "$@"; echo; }

# Keys to act on: explicit args, else the drift set passed in.
select_keys() {
    if (( ${#KEYS_ARG[@]} )); then
        printf '%s\n' "${KEYS_ARG[@]}"
    else
        printf '%s\n' "$@"
    fi
}

# ---------------------------------------------------------------- push

put_secret() {
    local key="$1" value="$2"
    if [[ -n "${REMOTE_IDS[$key]:-}" ]]; then
        bws secret edit --value "$value" "${REMOTE_IDS[$key]}" -t "$ACCESS_TOKEN" -o none \
            && log_success "updated $key" || log_error "failed to update $key"
    else
        local result
        if result=$(bws secret create "$key" "$value" "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json); then
            REMOTE_IDS["$key"]=$(echo "$result" | jq -r '.id')
            log_success "created $key"
        else
            log_error "failed to create $key"
        fi
    fi
}

cmd_push() {
    load_state

    local keys=()
    mapfile -t keys < <(select_keys "${LOCAL_ONLY[@]:-}" "${CHANGED[@]:-}" | grep -v '^$' || true)

    # staging/prod: nothing local to diff against means push whatever the user named,
    # or every key .env declares (values are prompted, not read).
    if [[ "$ENV" != "dev" ]] && ! (( ${#KEYS_ARG[@]} )); then
        mapfile -t keys < <(printf '%s\n' "${!LOCAL_VALS[@]}" "${!REMOTE_IDS[@]}" | sort -u)
    fi

    (( ${#keys[@]} )) || { log_success "Nothing to push"; return 0; }

    echo ""
    echo "Push to $ENV ($REPO_NAME):"
    printf '  %s\n' "${keys[@]}"
    echo ""
    confirm "Continue?" || exit 0
    echo ""

    local key value
    for key in "${keys[@]}"; do
        if [[ "$ENV" == "dev" ]]; then
            [[ -n "${LOCAL_VALS[$key]+x}" ]] || { log_warn "skipped $key (not in $ENV_FILE_NAME)"; continue; }
            put_secret "$key" "${LOCAL_VALS[$key]}"
        else
            local hint="new"
            [[ -n "${REMOTE_IDS[$key]:-}" ]] && hint="has existing value — Enter to keep"
            read -rp "$(echo -e "${CYAN}?${NC} $key ${DIM}($hint)${NC}: ")" value
            [[ -z "$value" ]] && { log_info "kept $key"; continue; }
            put_secret "$key" "$value"
        fi
    done
}

# ---------------------------------------------------------------- pull

# Rewrite one KEY= line in place, preserving everything else. Done in bash
# rather than sed so that secret values are never parsed as pattern syntax.
replace_env_line() {
    local key="$1" value="$2" tmp line found="no"
    tmp=$(mktemp)
    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?"$key"[[:space:]]*= ]]; then
                printf '%s%s=%s\n' "${BASH_REMATCH[1]:-}" "$key" "$value"
                found="yes"
            else
                printf '%s\n' "$line"
            fi
        done < "$ENV_FILE" > "$tmp"
    fi
    [[ "$found" == "yes" ]] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$ENV_FILE"

    if [[ "$found" == "yes" ]]; then
        log_success "updated $key in $ENV_FILE_NAME"
    else
        log_success "appended $key to $ENV_FILE_NAME"
    fi
}

cmd_pull() {
    [[ "$ENV" == "dev" ]] || die "pull is dev-only — staging/production values must not land in $ENV_FILE_NAME"
    load_state

    (( ${#REMOTE_IDS[@]} )) || die "No secrets in BWS project $PROJECT_ID"

    local keys=()
    mapfile -t keys < <(select_keys "${!REMOTE_IDS[@]}" | sort)

    if (( ${#KEYS_ARG[@]} )); then
        # Surgical: rewrite just these keys in place, leave the rest of .env alone.
        local key
        for key in "${keys[@]}"; do
            [[ -n "${REMOTE_IDS[$key]:-}" ]] || { log_warn "skipped $key (not in BWS)"; continue; }
            replace_env_line "$key" "${REMOTE_VALS[$key]}"
        done
        return 0
    fi

    echo ""
    echo "Pull $ENV -> $ENV_FILE_NAME (${#keys[@]} secrets):"
    (( ${#CHANGED[@]} ))     && printf "  ${RED}~${NC} %s ${DIM}(local value will be replaced)${NC}\n" "$(join_keys "${CHANGED[@]}")"
    (( ${#LOCAL_ONLY[@]} ))  && printf "  ${RED}!${NC} %s ${DIM}(local-only — will be LOST)${NC}\n" "$(join_keys "${LOCAL_ONLY[@]}")"
    (( ${#REMOTE_ONLY[@]} )) && printf "  ${GREEN}+${NC} %s ${DIM}(new)${NC}\n" "$(join_keys "${REMOTE_ONLY[@]}")"
    echo ""
    [[ -f "$ENV_FILE" ]] && log_warn "$ENV_FILE_NAME will be overwritten (backup: $ENV_FILE_NAME.bak)"
    confirm "Continue?" || exit 0

    [[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "$ENV_FILE.bak"

    {
        echo "# Pulled from Bitwarden Secrets Manager — $(date -Iseconds)"
        echo "# Project: $PROJECT_ID | Environment: $ENV"
        echo ""
        local key
        for key in "${keys[@]}"; do
            echo "$key=${REMOTE_VALS[$key]}"
        done
    } > "$ENV_FILE"

    log_success "Wrote $ENV_FILE_NAME — make sure it's gitignored"
}

# ---------------------------------------------------------------- prune

cmd_prune() {
    load_state

    local keys=()
    mapfile -t keys < <(select_keys "${REMOTE_ONLY[@]:-}" | grep -v '^$' || true)
    (( ${#keys[@]} )) || { log_success "Nothing to prune"; return 0; }

    echo ""
    log_warn "Delete from BWS $ENV — permanent:"
    printf '  %s\n' "${keys[@]}"
    echo ""
    confirm "Delete?" || exit 0

    local key
    for key in "${keys[@]}"; do
        [[ -n "${REMOTE_IDS[$key]:-}" ]] || { log_warn "skipped $key (not in BWS)"; continue; }
        bws secret delete "${REMOTE_IDS[$key]}" -t "$ACCESS_TOKEN" -o none \
            && log_success "deleted $key" || log_error "failed to delete $key"
    done
}

# ---------------------------------------------------------------- wire

cmd_wire() {
    load_state

    local workflow="$REPO_PATH/.github/workflows/deploy-${ENV}.yml"
    [[ -f "$workflow" ]] || die "No workflow: .github/workflows/deploy-${ENV}.yml"
    (( ${#REMOTE_IDS[@]} )) || die "No secrets in BWS project $PROJECT_ID"

    local lines="" key
    for key in $(printf '%s\n' "${!REMOTE_IDS[@]}" | sort); do
        lines+="            ${REMOTE_IDS[$key]} > ${key}"$'\n'
    done
    lines="${lines%$'\n'}"

    local tmp
    tmp=$(mktemp)
    awk -v new_secrets="$lines" '
        /secrets: \|/ { print; in_secrets = 1; printed = 0; next }
        in_secrets {
            if (/^[[:space:]]+[a-f0-9-]+ >/ || /^[[:space:]]+[a-f0-9]+-xxxx/) {
                if (!printed) { print new_secrets; printed = 1 }
                next
            }
            in_secrets = 0
        }
        { print }
    ' "$workflow" > "$tmp"
    mv "$tmp" "$workflow"

    log_success "Wired ${#REMOTE_IDS[@]} UUIDs into deploy-${ENV}.yml"

    local gh_repo
    gh_repo=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null \
        | sed -E 's#.*github\.com[:/]([^/]+/[^/]+?)(\.git)?$#\1#') || true
    [[ -n "$gh_repo" ]] || return 0
    command -v gh >/dev/null || return 0

    if ! gh api "repos/$gh_repo/environments/$ENV" &>/dev/null; then
        confirm "GitHub environment '$ENV' missing — create it?" || return 0
        gh api --method PUT "repos/$gh_repo/environments/$ENV" &>/dev/null \
            && log_success "created environment $ENV" || { log_error "failed to create environment"; return 0; }
    fi

    if gh secret list --repo "$gh_repo" --env "$ENV" 2>/dev/null | grep -q '^BWS_ACCESS_TOKEN'; then
        log_success "BWS_ACCESS_TOKEN already set on $ENV"
    elif confirm "Set BWS_ACCESS_TOKEN on GitHub environment '$ENV'?"; then
        echo "$ACCESS_TOKEN" | gh secret set BWS_ACCESS_TOKEN --repo "$gh_repo" --env "$ENV" \
            && log_success "BWS_ACCESS_TOKEN configured"
    fi
}

# ---------------------------------------------------------------- dispatch

case "$CMD" in
    init)   cmd_init ;;
    status) cmd_status ;;
    push)   cmd_push ;;
    pull)   cmd_pull ;;
    prune)  cmd_prune ;;
    wire)   cmd_wire ;;
esac
