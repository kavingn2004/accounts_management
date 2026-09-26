#!/usr/bin/env bash
# Build the production web app into build/web, connected to Supabase.
#
# The bash counterpart of tool/build_web.ps1, and the same flags Netlify uses
# (see netlify.toml) so a local build matches what deploys.
#
# Only the anon key is baked in. It is a public client key — row-level security
# is what protects the data, not the secrecy of this string. The database
# password must never appear here.
#
# Usage:
#   ./tool/build_web.sh
#   ./tool/build_web.sh --base-href /app/     # any flutter build web args
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root/supabase.env"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file — copy supabase.env.example and fill it in." >&2
  exit 1
fi

url="$(sed -n 's/^SUPABASE_URL=//p' "$env_file" | tr -d '[:space:]')"
key="$(sed -n 's/^SUPABASE_ANON_KEY=//p' "$env_file" | tr -d '[:space:]')"
[[ -n "$url" && -n "$key" ]] || { echo "supabase.env is incomplete" >&2; exit 1; }

# The Ask model, read from supabase.env (or the environment, which wins).
#
# A deployed page cannot reach localhost:11434 — that address belongs to
# whoever opens the site, and a browser blocks http from an https page anyway.
# Left empty, the app answers from its keyword router instantly, which is the
# right behaviour for a static deploy.
read_env() { sed -n "s/^$1=//p" "$env_file" | tr -d '[:space:]'; }
ask_url="${ASK_LLM_URL-$(read_env ASK_LLM_URL)}"
ask_model="${ASK_LLM_MODEL-$(read_env ASK_LLM_MODEL)}"
ask_key="${ASK_LLM_KEY-$(read_env ASK_LLM_KEY)}"

# A web build is public. Every --dart-define value is readable in
# main.dart.js — the Supabase anon key is meant to be (row-level security is
# what protects the data), but an LLM provider key is not: anyone who opens
# the site can read it and spend your credits. The URL and model name are
# fine; the key needs a server. Set ALLOW_PUBLIC_KEY=1 to override knowingly.
if [[ -n "$ask_key" && "${ALLOW_PUBLIC_KEY:-}" != "1" ]]; then
  cat >&2 <<'WARN'
Refusing to build: ASK_LLM_KEY would be readable by anyone who opens the site.

  Put the key in a proxy you control (Supabase Edge Function / Cloudflare
  Worker) and set ASK_LLM_URL to that proxy instead.

  To build with the key embedded anyway:  ALLOW_PUBLIC_KEY=1 ./tool/build_web.sh
WARN
  exit 1
fi

cd "$root"
echo "Building for $url"
echo "Ask model: ${ask_url:-none (keyword routing only)}${ask_model:+ · $ask_model}"
[[ -n "$ask_key" ]] && echo "WARNING: embedding an API key in a public bundle"

flutter build web --release \
  --no-tree-shake-icons \
  --dart-define=SUPABASE_URL="$url" \
  --dart-define=SUPABASE_ANON_KEY="$key" \
  --dart-define=ASK_LLM_URL="$ask_url" \
  --dart-define=ASK_LLM_MODEL="${ask_model:-qwen2.5-coder:7b}" \
  --dart-define=ASK_LLM_KEY="$ask_key" \
  "$@"

echo
echo "Built to build/web ($(du -sh build/web | cut -f1))"
echo "Preview locally:  cd build/web && python3 -m http.server 8080"
