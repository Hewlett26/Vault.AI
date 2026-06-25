#!/usr/bin/env bash
#
# setup.sh — Vault.AI environment setup
#
# Responsibilities:
#   1. Check that Python 3 and pip are available
#   2. Create (or reuse) a Python virtual environment in .venv
#   3. Install Python dependencies needed by ingest.py
#   4. Check for the Wrangler CLI (Cloudflare's deploy tool) and offer to
#      install it if missing
#   5. Verify everything is in place
#
# This script is safe to re-run — it skips steps that are already done.

set -euo pipefail

# Always run from the directory this script lives in, so it works no
# matter where the user calls it from.
cd "$(dirname "$0")"

echo "=== Vault.AI setup ==="
echo ""

# ── 1. Check Python 3 ────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 was not found on your PATH."
  echo "Install Python 3.9+ from https://www.python.org/downloads/ and re-run this script."
  exit 1
fi
echo "✓ python3 found: $(python3 --version)"

# ── 2. Check pip ─────────────────────────────────────────────────────────
if ! python3 -m pip --version >/dev/null 2>&1; then
  echo "ERROR: pip was not found for your python3 install."
  echo "Try: python3 -m ensurepip --upgrade"
  exit 1
fi
echo "✓ pip found: $(python3 -m pip --version | cut -d' ' -f1-2)"

# ── 3. Create the virtual environment (idempotent) ─────────────────────
if [ -d ".venv" ]; then
  echo "✓ Virtual environment .venv already exists — skipping creation."
else
  echo "Creating virtual environment in .venv ..."
  python3 -m venv .venv
  echo "✓ Virtual environment created."
fi

# ── 4. Activate the virtual environment ─────────────────────────────────
# shellcheck disable=SC1091
source .venv/bin/activate
echo "✓ Virtual environment activated (.venv)."

# ── 5. Generate requirements.txt if it doesn't exist ────────────────────
# These are the packages ingest.py imports:
#   - google-genai     (the Gemini SDK, "from google import genai")
#   - supabase         (Supabase Python client)
#   - python-dotenv    (loads the .env file created by configure.sh)
if [ -f "requirements.txt" ]; then
  echo "✓ requirements.txt already exists — skipping generation."
else
  echo "Generating requirements.txt ..."
  cat > requirements.txt <<'EOF'
google-genai
supabase
python-dotenv
EOF
  echo "✓ requirements.txt created."
fi

# ── 6. Install Python dependencies ──────────────────────────────────────
echo "Installing Python dependencies (this may take a minute)..."
# --no-cache-dir avoids "Cache entry deserialization failed" warnings that
# can show up if an older/incompatible pip cache exists on this machine.
pip install --upgrade pip --quiet --no-cache-dir
pip install -r requirements.txt --quiet --no-cache-dir
echo "✓ Python dependencies installed."

# ── 7. Check for the Wrangler CLI ───────────────────────────────────────
echo ""
if command -v wrangler >/dev/null 2>&1; then
  echo "✓ Wrangler CLI found: $(wrangler --version)"
else
  echo "⚠ Wrangler CLI not found."
  echo "  Wrangler is Cloudflare's CLI and is required to deploy the Worker."
  echo ""

  if command -v npm >/dev/null 2>&1; then
    read -r -p "  Install it now with 'npm install -g wrangler'? [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
      npm install -g wrangler
      echo "✓ Wrangler installed."
    else
      echo "  Skipped. You can install it later with:"
      echo "    npm install -g wrangler"
    fi
  else
    echo "  npm was not found, so Wrangler can't be installed automatically."
    echo "  Install Node.js (https://nodejs.org), then run:"
    echo "    npm install -g wrangler"
  fi
fi

# ── 8. Final verification ───────────────────────────────────────────────
echo ""
echo "=== Verification ==="

ALL_OK=1

if command -v python3 >/dev/null 2>&1; then
  echo "  ✓ python3"
else
  echo "  ✗ python3 (missing)"
  ALL_OK=0
fi

if [ -d ".venv" ]; then
  echo "  ✓ .venv"
else
  echo "  ✗ .venv (missing)"
  ALL_OK=0
fi

if command -v wrangler >/dev/null 2>&1; then
  echo "  ✓ wrangler"
  # Wrangler needs to be logged in to Cloudflare to deploy later.
  if wrangler whoami 2>/dev/null | grep -qi "you are not authenticated"; then
    echo "    ⚠ Not logged in yet. Before running ./deploy.sh, run: wrangler login"
  fi
else
  echo "  ✗ wrangler (missing)"
  ALL_OK=0
fi

echo ""
if [ "$ALL_OK" -eq 1 ]; then
  echo "✅ Setup complete!"
  echo "Next: run ./configure.sh"
else
  echo "⚠ Setup finished with missing tools — resolve the items above,"
  echo "  then re-run ./setup.sh before continuing."
  exit 1
fi
