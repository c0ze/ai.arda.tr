#!/bin/bash

set -euo pipefail

load_env_file() {
  local env_file="$1"
  local line
  local key
  local value

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}

    case "$line" in
      ""|\#*)
        continue
        ;;
    esac

    key=${line%%=*}
    value=${line#*=}

    if [ -z "$key" ] || [ "$key" = "$line" ]; then
      echo "Error: Invalid line in $env_file: $line" >&2
      exit 1
    fi

    export "$key=$value"
  done < "$env_file"
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Error: $name is not set in .env" >&2
    exit 1
  fi
}

# Load configuration from .env file
if [ ! -f .env ]; then
  echo "Error: .env file not found" >&2
  exit 1
fi

load_env_file .env

# Required settings
require_env GCP_PROJECT_ID
require_env GEMINI_API_KEY
require_env ALLOWED_ORIGINS

REGION=${GCP_REGION:-"asia-northeast1"}
SERVICE_NAME="ai-arda-tr-api"
PROJECT_ID="$GCP_PROJECT_ID"

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI is required but not installed" >&2
  exit 1
fi

current_project="$(gcloud config get-value project 2>/dev/null || true)"
if [ "$current_project" != "$PROJECT_ID" ]; then
  if [ -n "$current_project" ]; then
    echo "Active gcloud project is '$current_project'. Switching to '$PROJECT_ID' from .env..."
  else
    echo "No active gcloud project is set. Setting it to '$PROJECT_ID' from .env..."
  fi
  gcloud config set project "$PROJECT_ID" >/dev/null
fi

verified_project="$(gcloud config get-value project 2>/dev/null || true)"
if [ "$verified_project" != "$PROJECT_ID" ]; then
  echo "Error: Failed to set gcloud project to '$PROJECT_ID'" >&2
  exit 1
fi

echo "Deploying $SERVICE_NAME to Cloud Run ($REGION) in project $PROJECT_ID..."

env_vars=(
  "GEMINI_API_KEY=$GEMINI_API_KEY"
  "ALLOWED_ORIGINS=$ALLOWED_ORIGINS"
)

if [ -n "${GMAIL_USER:-}" ]; then
  env_vars+=("GMAIL_USER=$GMAIL_USER")
fi

if [ -n "${GMAIL_APP_PASSWORD:-}" ]; then
  env_vars+=("GMAIL_APP_PASSWORD=$GMAIL_APP_PASSWORD")
fi

if [ -n "${CONTACT_ADDRESS:-}" ]; then
  env_vars+=("CONTACT_ADDRESS=$CONTACT_ADDRESS")
fi

env_vars_csv="$(IFS=,; printf '%s' "${env_vars[*]}")"

gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --allow-unauthenticated \
  --set-env-vars "$env_vars_csv"

echo "Deployment complete!"
