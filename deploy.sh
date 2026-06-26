#!/usr/bin/env bash
#
# deploy.sh — Vault.AI deployment
#
# Steps:
#   1. Activate the virtual environment and load .env
#   2. Index the Obsidian vault  (python ingest.py)
#   3. Deploy the Cloudflare Worker  (wrangler deploy)
#   4. Inject the Worker URL into ui/app.built.js
#   5. Print the final summary

set -euo pipefail

cd "$(dirname "$0")"

WORKER_NAME="vault-ai-worker"

echo "=== Vault.AI deployment ==="
echo ""

# ── Sanity checks ──────────────────────────────────────────────────────────
if [ ! -f ".env" ]; then
  echo "ERROR: .env not found. Run ./configure.sh first."
  exit 1
fi

if [ ! -d ".venv" ]; then
  echo "ERROR: .venv not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -f "worker.js" ]; then
  echo "ERROR: worker.js not found in this directory."
  exit 1
fi

if ! command -v wrangler >/dev/null 2>&1; then
  echo "ERROR: Wrangler CLI not found. Run ./setup.sh to install it."
  exit 1
fi

# ── Step 0: activate venv and load .env ───────────────────────────────────
# shellcheck disable=SC1091
source .venv/bin/activate
echo "✓ Virtual environment activated."

set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

for var in GEMINI_API_KEY SUPABASE_URL SUPABASE_KEY OBSIDIAN_VAULT; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is missing from .env. Run ./configure.sh again."
    exit 1
  fi
done

# ── Step 1/4: Index the vault ──────────────────────────────────────────────
echo ""
echo "--- Step 1/4: Indexing your Obsidian vault ---"
python ingest.py
echo "✓ Vault indexed and uploaded to Supabase."

# ── Step 2/4: Deploy the Cloudflare Worker ────────────────────────────────
echo ""
echo "--- Step 2/4: Deploying the Cloudflare Worker ---"

if [ ! -f "wrangler.toml" ]; then
  cat > wrangler.toml <<TOMLEOF
name = "$WORKER_NAME"
main = "worker.js"
compatibility_date = "2024-09-01"
TOMLEOF
  echo "✓ Generated wrangler.toml"
else
  echo "✓ Using existing wrangler.toml"
fi

echo "Uploading secrets to Cloudflare..."
echo "$GEMINI_API_KEY" | wrangler secret put GEMINI_API_KEY >/dev/null
echo "$SUPABASE_URL"   | wrangler secret put SUPABASE_URL   >/dev/null
echo "$SUPABASE_KEY"   | wrangler secret put SUPABASE_KEY   >/dev/null
echo "✓ Secrets uploaded."

echo "Deploying worker..."
DEPLOY_OUTPUT=$(wrangler deploy 2>&1 | tee /dev/stderr)

WORKER_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -n1)

if [ -z "$WORKER_URL" ]; then
  echo ""
  echo "⚠ Couldn't detect the Worker URL automatically."
  read -r -p "Paste your deployed Worker URL here: " WORKER_URL
fi

echo "✓ Worker deployed at: $WORKER_URL"

# ── Step 3/4: Build the web UI ────────────────────────────────────────────
echo ""
echo "--- Step 3/4: Building the web UI ---"

if [ ! -d "ui" ]; then
  echo "ERROR: ui/ directory not found."
  exit 1
fi

# Inject the Worker URL into index.html (the single-file UI).
# ui/index.html contains __API_URL__ as a placeholder — we write the
# result to ui/index.built.html so the template is never overwritten.
sed "s|__API_URL__|$WORKER_URL|g" ui/template.html > ui/index.html

echo "✓ ui/index.html ready — open this file in your browser."
echo "✓ Worker URL injected: $WORKER_URL"

# ── Step 4/4: Done ────────────────────────────────────────────────────────
echo ""
echo "--- Step 4/4: Done ---"
echo ""
echo "Vault.AI successfully deployed!"
echo ""
echo "Worker URL:"
echo "  $WORKER_URL"
echo ""
echo "Open:"
echo "  ui/index.built.html"
echo ""
echo "Your AI knowledge agent is ready."
