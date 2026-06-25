#!/usr/bin/env bash
#
# configure.sh — Vault.AI configuration
#
# Prompts for the four values Vault.AI needs and writes them to a .env
# file in the project root:
#
#   GEMINI_API_KEY=...
#   SUPABASE_URL=...
#   SUPABASE_KEY=...
#   OBSIDIAN_VAULT=/path/to/vault
#
# Re-running shows your previous values as defaults — press Enter to keep them.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"

echo "=== Vault.AI configuration ==="
echo "Enter the values below. They'll be saved to '$ENV_FILE'."
echo "If a value already exists, press Enter to keep it."
echo ""

# ── Load existing values so re-running is non-destructive ──────────────
EXISTING_GEMINI_API_KEY=""
EXISTING_SUPABASE_URL=""
EXISTING_SUPABASE_KEY=""
EXISTING_OBSIDIAN_VAULT=""

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$ENV_FILE"
  EXISTING_GEMINI_API_KEY="${GEMINI_API_KEY:-}"
  EXISTING_SUPABASE_URL="${SUPABASE_URL:-}"
  EXISTING_SUPABASE_KEY="${SUPABASE_KEY:-}"
  EXISTING_OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-}"
fi

# ── 1. Gemini API key ────────────────────────────────────────────────────
while true; do
  if [ -n "$EXISTING_GEMINI_API_KEY" ]; then
    read -r -s -p "Gemini API key [press Enter to keep existing]: " GEMINI_API_KEY
  else
    read -r -s -p "Gemini API key: " GEMINI_API_KEY
  fi
  echo ""
  GEMINI_API_KEY="${GEMINI_API_KEY:-$EXISTING_GEMINI_API_KEY}"
  if [ -n "$GEMINI_API_KEY" ]; then break; fi
  echo "  Cannot be empty. Get a key at https://aistudio.google.com/apikey"
done

# ── 2. Supabase URL ──────────────────────────────────────────────────────
while true; do
  if [ -n "$EXISTING_SUPABASE_URL" ]; then
    read -r -p "Supabase URL [$EXISTING_SUPABASE_URL]: " SUPABASE_URL
    SUPABASE_URL="${SUPABASE_URL:-$EXISTING_SUPABASE_URL}"
  else
    read -r -p "Supabase URL (e.g. https://xxxxx.supabase.co): " SUPABASE_URL
  fi
  if [ -n "$SUPABASE_URL" ]; then break; fi
  echo "  Cannot be empty. Find it in your Supabase project settings."
done

# ── 3. Supabase key ──────────────────────────────────────────────────────
while true; do
  if [ -n "$EXISTING_SUPABASE_KEY" ]; then
    read -r -s -p "Supabase service key [press Enter to keep existing]: " SUPABASE_KEY
  else
    read -r -s -p "Supabase service key: " SUPABASE_KEY
  fi
  echo ""
  SUPABASE_KEY="${SUPABASE_KEY:-$EXISTING_SUPABASE_KEY}"
  if [ -n "$SUPABASE_KEY" ]; then break; fi
  echo "  Cannot be empty. Find it in your Supabase API settings."
done

# ── 4. Obsidian vault path ───────────────────────────────────────────────
while true; do
  if [ -n "$EXISTING_OBSIDIAN_VAULT" ]; then
    read -r -p "Obsidian vault path [$EXISTING_OBSIDIAN_VAULT]: " OBSIDIAN_VAULT
    OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-$EXISTING_OBSIDIAN_VAULT}"
  else
    read -r -p "Obsidian vault path (folder containing your .md notes): " OBSIDIAN_VAULT
  fi

  OBSIDIAN_VAULT="${OBSIDIAN_VAULT/#\~/$HOME}"

  if [ -z "$OBSIDIAN_VAULT" ]; then
    echo "  Cannot be empty."
    continue
  fi
  if [ ! -d "$OBSIDIAN_VAULT" ]; then
    echo "  '$OBSIDIAN_VAULT' doesn't exist or isn't a directory. Check the path and try again."
    continue
  fi
  break
done

# ── Write .env ───────────────────────────────────────────────────────────
cat > "$ENV_FILE" <<ENVEOF
GEMINI_API_KEY=$GEMINI_API_KEY
SUPABASE_URL=$SUPABASE_URL
SUPABASE_KEY=$SUPABASE_KEY
OBSIDIAN_VAULT=$OBSIDIAN_VAULT
ENVEOF

chmod 600 "$ENV_FILE"

echo ""
echo "✅ Configuration saved to $ENV_FILE"
echo "Next: run ./deploy.sh"
