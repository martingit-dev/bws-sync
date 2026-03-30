#!/bin/bash
set -e

# Sync secrets to Bitwarden Secrets Manager
# - Dev: reads from .env file
# - Staging/Prod: prompts for each value (like gh secret set)
#
# Usage: ./sync-secrets.sh <repo_path>

REPO_PATH="$1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Config file
CONFIG_DIR="${BWS_SYNC_CONFIG_DIR:-$HOME/.config/bws-sync}"
CONFIG_FILE="$CONFIG_DIR/secrets.conf"

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}!${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_prompt() { echo -e "${CYAN}?${NC} $1"; }

# Validate repo path
if [[ -z "$REPO_PATH" ]]; then
    echo "Usage: $0 <repo_path>"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/your/project"
    exit 1
fi

if [[ ! -d "$REPO_PATH" ]]; then
    log_error "Repository not found: $REPO_PATH"
    exit 1
fi

REPO_NAME=$(basename "$REPO_PATH")

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    echo ""
    echo "Create it with your BWS access tokens:"
    echo "  mkdir -p $CONFIG_DIR"
    echo "  cat > $CONFIG_FILE << 'EOF'"
    echo "BWS_ACCESS_TOKEN_DEV=\"your-dev-token\""
    echo "BWS_ACCESS_TOKEN_STAGING=\"your-staging-token\""
    echo "BWS_ACCESS_TOKEN_PRODUCTION=\"your-production-token\""
    echo "EOF"
    exit 1
fi

source "$CONFIG_FILE"

# Get secret keys from .env.example
get_secret_keys() {
    local env_example="$REPO_PATH/.env.example"
    local env_file="$REPO_PATH/.env"
    local env_local="$REPO_PATH/.env.local"

    local source_file=""
    if [[ -f "$env_example" ]]; then
        source_file="$env_example"
    elif [[ -f "$env_file" ]]; then
        source_file="$env_file"
    elif [[ -f "$env_local" ]]; then
        source_file="$env_local"
    fi

    if [[ -z "$source_file" ]]; then
        return 1
    fi

    # Extract variable names
    grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$source_file" | \
        sed 's/[[:space:]]*=.*//' | \
        sed 's/^[[:space:]]*//' | \
        grep -v '^#' | \
        sort -u
}

# Parse .env file into associative array
declare -A SECRETS

parse_env_file() {
    local file="$1"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            value="${value%"${value##*[![:space:]]}"}"

            SECRETS[$key]="$value"
        fi
    done < "$file"
}

echo ""
log_info "Repository: $REPO_NAME"

# Select action
echo ""
echo "Select action:"
echo "  1) push dev        - Upload .env to BWS"
echo "  2) push staging    - Enter values manually"
echo "  3) push production - Enter values manually"
echo "  4) pull dev        - Download secrets from BWS to .env"
echo ""
read -p "Choice [1-4]: " env_choice

case $env_choice in
    1) ENV="dev"; ACTION="push" ;;
    2) ENV="staging"; ACTION="push" ;;
    3) ENV="production"; ACTION="push" ;;
    4) ENV="dev"; ACTION="pull" ;;
    *) log_error "Invalid choice"; exit 1 ;;
esac

# Get token
ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
ACCESS_TOKEN_VAR="BWS_ACCESS_TOKEN_${ENV_UPPER}"
ACCESS_TOKEN="${!ACCESS_TOKEN_VAR}"

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "$ACCESS_TOKEN_VAR not set in $CONFIG_FILE"
    exit 1
fi

# Prompt for project ID
echo ""
log_prompt "BWS Project ID for $ENV:"
read -p "  Project ID: " PROJECT_ID

if [[ -z "$PROJECT_ID" ]]; then
    log_error "Project ID required"
    exit 1
fi

# Validate project access
log_info "Validating project access..."
if ! bws project get "$PROJECT_ID" -t "$ACCESS_TOKEN" -o none 2>&1; then
    log_error "Cannot access project. Check token and project ID."
    exit 1
fi
log_success "Project access confirmed"

# Get existing secrets
log_info "Fetching existing secrets..."
EXISTING=$(bws secret list "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json || echo "[]")

echo ""

# PULL MODE: Download secrets from BWS to .env
if [[ "$ACTION" == "pull" ]]; then
    SECRET_COUNT=$(echo "$EXISTING" | jq 'length')

    if [[ "$SECRET_COUNT" -eq 0 || "$SECRET_COUNT" == "null" ]]; then
        log_error "No secrets found in this project"
        exit 1
    fi

    log_info "Found $SECRET_COUNT secrets in BWS"

    ENV_FILE="$REPO_PATH/.env"

    # Show what will be written
    echo ""
    echo "Secrets to write:"
    echo "$EXISTING" | jq -r '.[].key' | sort | while read -r key; do
        echo "  - $key"
    done
    echo ""

    if [[ -f "$ENV_FILE" ]]; then
        log_warn ".env already exists — it will be overwritten"
    else
        log_info ".env will be created"
    fi

    read -p "Continue? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    # Write .env file
    echo "# Generated from Bitwarden Secrets Manager" > "$ENV_FILE"
    echo "# Project: $PROJECT_ID | Environment: $ENV" >> "$ENV_FILE"
    echo "# Pulled: $(date -Iseconds)" >> "$ENV_FILE"
    echo "" >> "$ENV_FILE"

    echo "$EXISTING" | jq -r '.[] | .key + "=" + .value' | sort >> "$ENV_FILE"

    log_success "Written to: $ENV_FILE"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Pull complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Make sure .env is in your .gitignore!"
    exit 0
fi

# PUSH MODE
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Pushing to: $ENV${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Track UUIDs
declare -A UUID_MAP

if [[ "$ENV" == "dev" ]]; then
    # DEV: Read from .env file
    ENV_FILE="$REPO_PATH/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        ENV_FILE="$REPO_PATH/.env.local"
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "No .env or .env.local found"
        exit 1
    fi

    log_info "Reading from: $ENV_FILE"
    parse_env_file "$ENV_FILE"

    echo ""
    echo "Variables to sync:"
    for key in $(echo "${!SECRETS[@]}" | tr ' ' '\n' | sort); do
        echo "  - $key"
    done
    echo ""
    read -p "Continue? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    # Sync each secret
    for KEY in "${!SECRETS[@]}"; do
        VALUE="${SECRETS[$KEY]}"
        EXISTING_ID=$(echo "$EXISTING" | jq -r ".[] | select(.key == \"$KEY\") | .id" 2>/dev/null || echo "")

        if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
            log_info "Updating: $KEY"
            if ! bws secret edit --value "$VALUE" "$EXISTING_ID" -t "$ACCESS_TOKEN" -o none; then
                log_error "Failed to update $KEY"
                continue
            fi
            UUID_MAP[$KEY]="$EXISTING_ID"
        else
            log_info "Creating: $KEY"
            if ! RESULT=$(bws secret create "$KEY" "$VALUE" "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json); then
                log_error "Failed to create $KEY"
                continue
            fi
            SECRET_ID=$(echo "$RESULT" | jq -r '.id')
            UUID_MAP[$KEY]="$SECRET_ID"
        fi
    done

    log_success "Dev sync complete"

else
    # STAGING/PROD: Prompt for each value

    # Get list of keys from .env.example or existing secrets
    KEYS=()

    if keys_from_example=$(get_secret_keys); then
        while IFS= read -r key; do
            KEYS+=("$key")
        done <<< "$keys_from_example"
        log_info "Using keys from .env.example"
    else
        # Fall back to existing secrets in BWS
        while IFS= read -r key; do
            [[ -n "$key" ]] && KEYS+=("$key")
        done <<< "$(echo "$EXISTING" | jq -r '.[].key' 2>/dev/null)"
        log_info "Using keys from existing BWS secrets"
    fi

    if [[ ${#KEYS[@]} -eq 0 ]]; then
        log_error "No keys found. Create .env.example first."
        exit 1
    fi

    echo ""
    echo "Enter values for each secret (press Enter to skip, existing value kept):"
    echo ""

    for KEY in "${KEYS[@]}"; do
        # Get existing value (masked)
        EXISTING_ID=$(echo "$EXISTING" | jq -r ".[] | select(.key == \"$KEY\") | .id" 2>/dev/null || echo "")

        if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
            echo -e "${CYAN}?${NC} $KEY ${YELLOW}(has existing value)${NC}"
        else
            echo -e "${CYAN}?${NC} $KEY ${YELLOW}(new)${NC}"
        fi

        read -p "  Value: " VALUE

        if [[ -z "$VALUE" ]]; then
            if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
                log_info "Keeping existing: $KEY"
                UUID_MAP[$KEY]="$EXISTING_ID"
            else
                log_warn "Skipping: $KEY (no value)"
            fi
            continue
        fi

        if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
            log_info "Updating: $KEY"
            if ! bws secret edit --value "$VALUE" "$EXISTING_ID" -t "$ACCESS_TOKEN" -o none; then
                log_error "Failed to update $KEY"
                continue
            fi
            UUID_MAP[$KEY]="$EXISTING_ID"
        else
            log_info "Creating: $KEY"
            if ! RESULT=$(bws secret create "$KEY" "$VALUE" "$PROJECT_ID" -t "$ACCESS_TOKEN" -o json); then
                log_error "Failed to create $KEY"
                continue
            fi
            SECRET_ID=$(echo "$RESULT" | jq -r '.id')
            UUID_MAP[$KEY]="$SECRET_ID"
        fi
    done

    log_success "Secrets synced for $ENV"

    # Update workflow file
    WORKFLOW_FILE="$REPO_PATH/.github/workflows/deploy-${ENV}.yml"

    if [[ -f "$WORKFLOW_FILE" ]]; then
        log_info "Updating workflow: deploy-${ENV}.yml"

        # Build secrets block
        SECRETS_LINES=""
        for KEY in $(echo "${!UUID_MAP[@]}" | tr ' ' '\n' | sort); do
            UUID="${UUID_MAP[$KEY]}"
            SECRETS_LINES+="            ${UUID} > ${KEY}"$'\n'
        done
        SECRETS_LINES="${SECRETS_LINES%$'\n'}"

        # Replace secrets block
        TEMP_FILE=$(mktemp)

        awk -v new_secrets="$SECRETS_LINES" '
        BEGIN { in_secrets = 0; printed = 0 }
        /secrets: \|/ {
            print
            in_secrets = 1
            next
        }
        in_secrets {
            if (/^[[:space:]]+[a-f0-9-]+ >/ || /^[[:space:]]+[a-f0-9]+-xxxx/) {
                if (!printed) {
                    print new_secrets
                    printed = 1
                }
                next
            } else {
                in_secrets = 0
                printed = 0
            }
        }
        { print }
        ' "$WORKFLOW_FILE" > "$TEMP_FILE"

        mv "$TEMP_FILE" "$WORKFLOW_FILE"
        log_success "Workflow updated"
    else
        log_warn "Workflow not found: $WORKFLOW_FILE"
    fi

    # Configure GitHub
    GITHUB_REPO=""
    if [[ -d "$REPO_PATH/.git" ]]; then
        GITHUB_REPO=$(cd "$REPO_PATH" && git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/')
    fi

    if [[ -z "$GITHUB_REPO" ]]; then
        read -p "GitHub repo (owner/name): " GITHUB_REPO
    fi

    log_info "Checking GitHub environment..."

    # Check if environment exists
    if gh api "repos/$GITHUB_REPO/environments/$ENV" &>/dev/null; then
        log_success "Environment '$ENV' exists"
        ENV_READY="yes"
    else
        log_warn "Environment '$ENV' does not exist"
        read -p "  Create it? [y/N]: " create_env

        if [[ "$create_env" == "y" || "$create_env" == "Y" ]]; then
            if gh api --method PUT "repos/$GITHUB_REPO/environments/$ENV" &>/dev/null; then
                log_success "Environment created"
                ENV_READY="yes"
            else
                log_error "Failed to create environment"
                ENV_READY="no"
            fi
        else
            ENV_READY="no"
        fi
    fi

    if [[ "$ENV_READY" == "yes" ]]; then
        # List all secrets in environment
        ALL_SECRETS=$(gh secret list --repo "$GITHUB_REPO" --env "$ENV" 2>/dev/null | awk '{print $1}' || echo "")

        # Check for secrets that aren't BWS_ACCESS_TOKEN
        OTHER_SECRETS=""
        HAS_BWS_TOKEN="no"
        while IFS= read -r secret; do
            [[ -z "$secret" ]] && continue
            if [[ "$secret" == "BWS_ACCESS_TOKEN" ]]; then
                HAS_BWS_TOKEN="yes"
            else
                OTHER_SECRETS+="$secret "
            fi
        done <<< "$ALL_SECRETS"

        # Offer to delete other secrets
        if [[ -n "${OTHER_SECRETS// }" ]]; then
            log_warn "Found other secrets: $OTHER_SECRETS"
            read -p "  Delete them? (Only BWS_ACCESS_TOKEN needed) [y/N]: " delete_others

            if [[ "$delete_others" == "y" || "$delete_others" == "Y" ]]; then
                for secret in $OTHER_SECRETS; do
                    gh secret delete "$secret" --repo "$GITHUB_REPO" --env "$ENV" 2>/dev/null
                    log_info "Deleted: $secret"
                done
            fi
        fi

        # Set BWS_ACCESS_TOKEN if missing
        if [[ "$HAS_BWS_TOKEN" == "no" ]]; then
            log_warn "BWS_ACCESS_TOKEN not set"
            read -p "  Set it now? [y/N]: " set_token

            if [[ "$set_token" == "y" || "$set_token" == "Y" ]]; then
                if echo "$ACCESS_TOKEN" | gh secret set BWS_ACCESS_TOKEN --repo "$GITHUB_REPO" --env "$ENV"; then
                    log_success "BWS_ACCESS_TOKEN configured"
                else
                    log_error "Failed to set BWS_ACCESS_TOKEN"
                fi
            fi
        else
            log_success "BWS_ACCESS_TOKEN already configured"
        fi
    fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ "$ENV" != "dev" ]]; then
    echo "Next steps:"
    echo "  1. Review changes: git diff"
    echo "  2. Commit: git add -A && git commit -m 'chore: update BWS secret UUIDs'"
    echo "  3. Push: git push"
fi
