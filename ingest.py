#!/usr/bin/env python3
"""
ingest.py — Reads your Obsidian vault, embeds it with Gemini, uploads to Supabase.
Run this once (and again whenever you update your vault).

Install deps first:
  pip install google-generativeai supabase python-dotenv
"""

import os
import re
import glob
import time
from dotenv import load_dotenv
from google import genai
from google.genai import types
from supabase import create_client

load_dotenv()

GEMINI_API_KEY  = os.getenv("GEMINI_API_KEY")
SUPABASE_URL    = os.getenv("SUPABASE_URL")
SUPABASE_KEY    = os.getenv("SUPABASE_KEY")
VAULT_PATH      = os.getenv("OBSIDIAN_VAULT")

CHUNK_SIZE      = 1500
CHUNK_OVERLAP   = 100

MAX_RETRIES  = 6
BASE_BACKOFF = 2

# ── Setup ────────────────────────────────────────────────────────────────────

client = genai.Client(api_key=GEMINI_API_KEY)
supabase = create_client(SUPABASE_URL, SUPABASE_KEY)

# ── Helpers ──────────────────────────────────────────────────────────────────

def load_vault(vault_path):
    """Read all .md files from the vault and return list of (filename, text)."""
    files = glob.glob(f"{vault_path}/**/*.md", recursive=True)
    docs = []
    for f in files:
        try:
            with open(f, "r", encoding="utf-8") as fp:
                text = fp.read().strip()
                if text:
                    docs.append((os.path.basename(f), text))
        except Exception as e:
            print(f"  Skipping {f}: {e}")
    return docs


def chunk_text(filename, text, size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    """Split text into overlapping chunks."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        chunk = text[start:end].strip()
        if chunk:
            chunks.append({
                "source": filename,
                "content": chunk,
            })
        start += size - overlap
    return chunks


import re


def embed(text):
    backoff = BASE_BACKOFF
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            result = client.models.embed_content(
                model="gemini-embedding-001",
                contents=text,
            )
            return result.embeddings[0].values
        except Exception as e:
            msg = str(e)
            if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
                match = re.search(r"(\d+(?:\.\d+)?)\s*s", msg)
                wait = float(match.group(1)) + 1 if match else 60
                print(f"   Rate limited — waiting {wait:.0f}s (attempt {attempt}/{MAX_RETRIES})...")
                time.sleep(wait)
            elif "503" in msg or "UNAVAILABLE" in msg:
                if attempt == MAX_RETRIES:
                    raise
                print(f"   503 unavailable — retrying in {backoff}s (attempt {attempt}/{MAX_RETRIES})...")
                time.sleep(backoff)
                backoff *= 2
            else:
                raise
    raise RuntimeError(f"Failed to embed after {MAX_RETRIES} attempts.")

def setup_supabase_table():
    """
    Run this SQL once in Supabase SQL Editor to create the table:

    create extension if not exists vector;

    create table if not exists vault_chunks (
      id bigserial primary key,
      source text,
      content text,
      embedding vector(3072)
    );

    create or replace function match_chunks(
      query_embedding vector(3072),
      match_count int default 5
    )
    returns table (source text, content text, similarity float)
    language sql stable
    as $$
      select source, content,
             1 - (embedding <=> query_embedding) as similarity
      from vault_chunks
      order by embedding <=> query_embedding
      limit match_count;
    $$;
    """
    print("⚠️  Make sure you've run the SQL in Supabase first! (see setup_supabase_table docstring)")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    print(f"📂 Loading vault from: {VAULT_PATH}")
    docs = load_vault(VAULT_PATH)
    print(f"   Found {len(docs)} markdown files")

    all_chunks = []
    for filename, text in docs:
        all_chunks.extend(chunk_text(filename, text))
    print(f"   Split into {len(all_chunks)} chunks")

    print("\n🧹 Clearing old chunks from Supabase...")
    supabase.table("vault_chunks").delete().neq("id", 0).execute()

    print(f"\n🔢 Embedding and uploading {len(all_chunks)} chunks...")
    batch = []
    for i, chunk in enumerate(all_chunks):
        try:
            embedding = embed(chunk["content"])
            batch.append({
                "source":    chunk["source"],
                "content":   chunk["content"],
                "embedding": embedding,
            })

            # Upload in batches of 50 to avoid timeouts
            if len(batch) >= 50:
                supabase.table("vault_chunks").insert(batch).execute()
                print(f"   Uploaded {i + 1}/{len(all_chunks)} chunks...")
                batch = []
                time.sleep(0.5)  # gentle rate limiting

        except Exception as e:
            print(f"   Error on chunk {i}: {e}")
            time.sleep(2)

    # Upload any remaining
    if batch:
        supabase.table("vault_chunks").insert(batch).execute()

    print(f"\n✅ Done! {len(all_chunks)} chunks uploaded to Supabase.")


if __name__ == "__main__":
    setup_supabase_table()
    main()
