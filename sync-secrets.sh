#!/bin/bash
set -euo pipefail

# bws-sync — drift-first sync between .env and Bitwarden Secrets Manager.
# Run inside a project. See --help.

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log_info()    { echo -e "${BLUE}i${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}!${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1" >&2; }

die() { log_error "$1"; exit 1; }

CONFIG_DIR="${BWS_SYNC_CONFIG_DIR:-$HOME/.config/bws-sync}"
CONFIG_FILE="$CONFIG_DIR/secrets.conf"

usage() {
    cat <<EOF
${BOLD}bws-sync${NC} — keep .env and Bitwarden Secrets Manager in agreement.
Runs against the current directory.

${BOLD}USAGE${NC}
  bws-sync [command] [KEY...] [flags]

${BOLD}COMMANDS${NC}
  ${BOLD}(none)${NC}          Status. Show drift between .env and BWS. Read-only, no
                  prompts, exits 1 if anything differs.
  ${BOLD}init${NC}            Write .bws-sync.toml — this repo's BWS project IDs, one per
                  environment. Run once per project. Safe to commit.
  ${BOLD}push${NC} [KEY...]   Send values to BWS. No KEY = every key that is new or
                  changed. Named KEYs = only those.
  ${BOLD}pull${NC} [KEY...]   Bring values into .env. No KEY = rewrite the file (backs up
                  to .env.bak). Named KEYs = replace only those lines. Dev only.
  ${BOLD}prune${NC} [KEY...]  Delete BWS secrets that no longer exist in .env. Permanent.
  ${BOLD}wire${NC}            Rewrite .github/workflows/deploy-<env>.yml with the current
                  'UUID > KEY' block, and set BWS_ACCESS_TOKEN on the GitHub
                  environment. Produces a repo diff you commit.

${BOLD}FLAGS${NC}
  -e, --env <dev|staging|production>   Which environment. Default: dev.
  -d, --dir <path>                     Which project. Default: current directory.
  -y, --yes                            Skip confirmations.
  -h, --help                           This.

${BOLD}ALL vs ONE${NC}
  Bare command acts on everything; naming keys narrows it. There is no -a flag
  because the bare command already is one.

    bws-sync                       # what's out of sync in dev?
    bws-sync push                  # push every drifted dev key
    bws-sync push STRIPE_KEY       # push only that one
    bws-sync pull DATABASE_URL     # pull only that one, rest of .env untouched

${BOLD}ENVIRONMENTS${NC}
  Environments share their ${BOLD}keys${NC}, never their ${BOLD}values${NC}. Nothing is ever copied
  from dev into staging or production.

  dev         Values live in .env. Push reads it, pull writes it, status
              compares keys AND values.
  staging     Values live only in BWS. Push ${BOLD}prompts${NC} you for each one (Enter
  production  keeps what BWS already has). Status compares keys only — these
              values are never written to .env or printed. Pull is refused.

${BOLD}SETTING UP A NEW ENVIRONMENT${NC}
  Say production, on a project that already has dev working:

    1. In the Bitwarden web vault: create the project, create a machine account,
       grant it access, issue an access token. (No CLI or API exists for this.)
    2. Add the token to \$BWS_SYNC_CONFIG_DIR/secrets.conf as
       BWS_ACCESS_TOKEN_PRODUCTION.
    3. bws-sync init          — add the production project ID.
    4. bws-sync push -e production
         Takes the key list from .env, then prompts for each production value.
         Your dev values are not used. Press Enter to skip a key that doesn't
         apply to production.
    5. bws-sync wire -e production   — point the workflow at the new UUIDs.

${BOLD}FILES${NC}
  .bws-sync.toml   Project UUIDs. Not secret — commit it.
  .env             Real dev values. Gitignore it.
  \$BWS_SYNC_CONFIG_DIR/secrets.conf
                   Access tokens, one per environment. Never in a repo.
                   Currently: $CONFIG_DIR
EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------- args

CMD="status"
ENV="dev"
REPO_PATH="$PWD"
ASSUME_YES="no"
FROM_FILE=""
KEYS_ARG=()

case "${1:-}" in
    init|status|push|pull|prune|wire) CMD="$1"; shift ;;
    -h|--help|help) usage 0 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)  ENV="${2:-}"; shift 2 ;;
        -d|--dir)  REPO_PATH="${2:-}"; shift 2 ;;
        -f|--from) FROM_FILE="${2:-}"; shift 2 ;;
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

PROJECT_FILE="$REPO_PATH/.bws-sync.toml"

load_token() {
    [[ -f "$CONFIG_FILE" ]] || die "No token config: $CONFIG_FILE (see README)"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    local var="BWS_ACCESS_TOKEN_$(echo "$ENV" | tr '[:lower:]' '[:upper:]')"
    ACCESS_TOKEN="${!var:-}"
    [[ -n "$ACCESS_TOKEN" ]] || die "$var not set in $CONFIG_FILE"
}

load_project() {
    [[ -f "$PROJECT_FILE" ]] || die "No .bws-sync.toml in $REPO_NAME — run: bws-sync init"

    ENV_FILE_NAME=$(read_toml env_file)
    ENV_FILE_NAME="${ENV_FILE_NAME:-.env}"
    ENV_FILE="$REPO_PATH/$ENV_FILE_NAME"

    PROJECT_ID=$(read_toml "$ENV" projects)
    [[ -n "$PROJECT_ID" ]] || die "No '$ENV' project ID in .bws-sync.toml — run: bws-sync init"
}

# Reads one `key = "value"` out of .bws-sync.toml. Section-aware for [projects].
read_toml() {
    local want="$1" section="${2:-}"
    [[ -f "$PROJECT_FILE" ]] || return 0
    awk -v want="$want" -v want_sec="$section" '
        /^[[:space:]]*\[/ { sec = $0; gsub(/[][[:space:]]/, "", sec); next }
        $1 == want && sec == want_sec {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            gsub(/^"|"[[:space:]]*$/, "", $0)
            print; exit
        }' "$PROJECT_FILE"
}

# Prompt with the current value as the default — so re-running init to add one
# environment doesn't silently drop the others.
ask_with_default() {
    local label="$1" current="$2" reply
    if [[ -n "$current" ]]; then
        read -rp "  $label [$current]: " reply
        echo "${reply:-$current}"
    else
        read -rp "  $label: " reply
        echo "$reply"
    fi
}

cmd_init() {
    local dev staging production env_file
    dev=$(read_toml dev projects)
    staging=$(read_toml staging projects)
    production=$(read_toml production projects)
    env_file=$(read_toml env_file)

    echo ""
    if [[ -f "$PROJECT_FILE" ]]; then
        log_info "Updating .bws-sync.toml for $REPO_NAME (Enter keeps the current value)"
    else
        log_info "Project IDs for $REPO_NAME (blank to skip an environment)"
    fi

    dev=$(ask_with_default "dev:       " "$dev")
    staging=$(ask_with_default "staging:   " "$staging")
    production=$(ask_with_default "production:" "$production")
    env_file=$(ask_with_default "env file:  " "${env_file:-.env}")

    {
        echo "# bws-sync — BWS project IDs for this repo."
        echo "# Project IDs are not secrets: they are inert without an access token,"
        echo "# and tokens live only in $CONFIG_DIR. Safe to commit."
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

declare -A FROM_VALS=()   # key -> value from --from file

# parse_env_into <file> <name of associative array>
parse_env_into() {
    local file="$1"
    local -n target="$2"
    [[ -f "$file" ]] || return 1
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
        target["$key"]="$value"
    done < "$file"
}

parse_env_file() { parse_env_into "$ENV_FILE" LOCAL_VALS; }

fetch_remote() {
    log_info "Fetching $ENV secrets from BWS…" >&2

    local json err
    err=$(mktemp)
    if ! json=$(bws secret list "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json 2>"$err"); then
        # bws returns 404 for a project that exists but holds no secrets. That is
        # the normal state of a project you are about to provision, not an error —
        # so ask the project endpoint whether the token can actually see it.
        if bws project get "$PROJECT_ID" -t "$ACCESS_TOKEN" -o none &>/dev/null; then
            rm -f "$err"
            log_info "Project is empty — no secrets in BWS yet" >&2
            return 0
        fi
        log_error "Cannot read project $PROJECT_ID in $ENV"
        log_error "$(head -3 "$err" | tr -d '\n')"
        rm -f "$err"
        exit 1
    fi
    rm -f "$err"

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

# --from holds plaintext values for an environment whose values are otherwise
# never on disk. Refuse to read it if git would track it, and offer to destroy
# it once the values are safely in BWS.
load_from_file() {
    [[ -n "$FROM_FILE" ]] || return 0
    [[ -f "$FROM_FILE" ]] || die "No such file: $FROM_FILE"

    if git -C "$REPO_PATH" rev-parse --git-dir &>/dev/null; then
        local rel="$FROM_FILE"
        [[ "$rel" = /* ]] && rel="$(realpath --relative-to="$REPO_PATH" "$FROM_FILE" 2>/dev/null || echo "$FROM_FILE")"
        if [[ "$rel" != ../* && "$rel" != /* ]] \
           && ! git -C "$REPO_PATH" check-ignore -q "$rel" 2>/dev/null; then
            log_error "git is not ignoring $rel — it holds plaintext $ENV secrets"
            log_error "Add it to .gitignore, or keep the file outside the repo."
            exit 1
        fi
    fi

    parse_env_into "$FROM_FILE" FROM_VALS || die "Could not read $FROM_FILE"
    (( ${#FROM_VALS[@]} )) || die "No KEY=VALUE lines in $FROM_FILE"
    log_info "Values from: $FROM_FILE (${#FROM_VALS[@]} keys)"
}

shred_from_file() {
    [[ -n "$FROM_FILE" ]] || return 0
    echo ""
    log_warn "$FROM_FILE still holds plaintext $ENV secrets — BWS has them now."
    if confirm "  Delete it?"; then
        command -v shred &>/dev/null && shred -u "$FROM_FILE" 2>/dev/null || rm -f "$FROM_FILE"
        log_success "Deleted $FROM_FILE"
    else
        log_warn "Left in place. Delete it when you're done."
    fi
}

cmd_push() {
    load_state
    load_from_file

    # Bare push acts on drift only. For dev that's new + changed keys. For
    # staging/production we cannot see drift in values, so it's the keys BWS is
    # missing — an existing key is changed by naming it, never by Entering past it.
    local keys=()
    if (( ${#KEYS_ARG[@]} )); then
        mapfile -t keys < <(printf '%s\n' "${KEYS_ARG[@]}")
    elif [[ "$ENV" == "dev" ]]; then
        mapfile -t keys < <(printf '%s\n' "${LOCAL_ONLY[@]:-}" "${CHANGED[@]:-}" | grep -v '^$' || true)
    else
        mapfile -t keys < <(printf '%s\n' "${LOCAL_ONLY[@]:-}" | grep -v '^$' || true)
    fi

    (( ${#keys[@]} )) || { log_success "Nothing to push — $ENV has every key in $ENV_FILE_NAME"; return 0; }

    # Where each value will come from, so the confirmation can say so per key.
    value_source() {
        if [[ "$ENV" == "dev" ]];              then echo "$ENV_FILE_NAME"
        elif [[ -n "${FROM_VALS[$1]+x}" ]];    then echo "file"
        else                                        echo "prompt"; fi
    }

    echo ""
    echo "Push to $ENV ($REPO_NAME):"
    local key src prompted=0
    for key in "${keys[@]}"; do
        src=$(value_source "$key")
        [[ "$src" == "prompt" ]] && (( ++prompted ))
        if [[ -n "${REMOTE_IDS[$key]:-}" ]]; then
            echo -e "  ${YELLOW}~${NC} $key ${DIM}($src → overwrites existing $ENV value)${NC}"
        else
            echo -e "  ${GREEN}+${NC} $key ${DIM}($src → new)${NC}"
        fi
    done
    echo ""
    [[ "$ENV" != "dev" && $prompted -gt 0 ]] && log_info "$prompted key(s) will be prompted for"
    confirm "Continue?" || exit 0
    echo ""

    local value
    for key in "${keys[@]}"; do
        case "$(value_source "$key")" in
            "$ENV_FILE_NAME")
                [[ -n "${LOCAL_VALS[$key]+x}" ]] || { log_warn "skipped $key (not in $ENV_FILE_NAME)"; continue; }
                put_secret "$key" "${LOCAL_VALS[$key]}" ;;
            file)
                put_secret "$key" "${FROM_VALS[$key]}" ;;
            prompt)
                local hint="new"
                [[ -n "${REMOTE_IDS[$key]:-}" ]] && hint="Enter to keep current"
                read -rp "$(echo -e "${CYAN}?${NC} $key ${DIM}($hint)${NC}: ")" value
                [[ -z "$value" ]] && { log_info "skipped $key"; continue; }
                put_secret "$key" "$value" ;;
        esac
    done

    shred_from_file
}

# ---------------------------------------------------------------- pull

# pull writes plaintext secrets to disk. Refuse to do that silently if git
# would track them. Only warns when the target is actually a git repo.
warn_if_tracked() {
    git -C "$REPO_PATH" rev-parse --git-dir &>/dev/null || return 0

    local exposed=() f
    for f in "$ENV_FILE_NAME" "$ENV_FILE_NAME.bak"; do
        git -C "$REPO_PATH" check-ignore -q "$f" 2>/dev/null || exposed+=("$f")
    done
    (( ${#exposed[@]} )) || return 0

    echo ""
    log_warn "git is not ignoring: $(join_keys "${exposed[@]}")"
    log_warn "pull writes plaintext secrets there — add to .gitignore first:"
    printf '    %s\n' "${exposed[@]}"
    echo ""
    confirm "  Continue anyway?" || exit 1
}

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

    warn_if_tracked

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

    log_success "Wrote $ENV_FILE_NAME (${#keys[@]} secrets)"
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
