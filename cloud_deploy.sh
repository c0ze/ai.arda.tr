#!/bin/bash

# Load configuration from .env file
if [ -f .env ]; then
  # Export variables from .env
  export $(grep -v '^#' .env | xargs)
else
  echo "Error: .env file not found"
  exit 1
fi

# Default values if not set in .env
# You can set GCP_PROJECT_ID and GCP_REGION in your .env file
PROJECT_ID=${GCP_PROJECT_ID:-""}
REGION=${GCP_REGION:-"asia-northeast1"}
SERVICE_NAME="ai-arda-tr-api"

# Check for required GEMINI_API_KEY
if [ -z "$GEMINI_API_KEY" ]; then
  echo "Error: GEMINI_API_KEY is not set in .env"
  exit 1
fi

echo "Deploying $SERVICE_NAME to Cloud Run ($REGION)..."

# Construct deployment command
DEPLOY_CMD="gcloud run deploy $SERVICE_NAME \
  --source . \
  --region $REGION \
  --allow-unauthenticated \
  --set-env-vars "GEMINI_API_KEY=$GEMINI_API_KEY,ALLOWED_ORIGINS='${ALLOWED_ORIGINS:-*}'"

# Add Project ID if specified
if [ -n "$PROJECT_ID" ]; then
  DEPLOY_CMD="$DEPLOY_CMD --project $PROJECT_ID"
fi

# Execute
eval $DEPLOY_CMD

echo "Deployment complete!"