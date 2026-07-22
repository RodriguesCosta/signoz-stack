#!/usr/bin/env bash
#
# Gera o arquivo .env necessário para subir a stack e cria as pastas de dados.
# Uso:
#   ./generate-env.sh            # gera .env (não sobrescreve se já existir)
#   ./generate-env.sh --force    # regenera o .env do zero (novo segredo JWT)
#
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"
FORCE="${1:-}"

# --- pastas de dados (bind mounts) -----------------------------------------
mkdir -p data/clickhouse data/zookeeper data/sqlite
echo "→ pastas de dados garantidas em ./data/{clickhouse,zookeeper,sqlite}"

# --- .env -------------------------------------------------------------------
if [ -f "$ENV_FILE" ] && [ "$FORCE" != "--force" ]; then
  echo "→ $ENV_FILE já existe — mantido. Use '--force' para regenerar."
  exit 0
fi

# gera um segredo JWT forte
if command -v openssl >/dev/null 2>&1; then
  SECRET="$(openssl rand -base64 32)"
else
  SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
fi

# monta o .env a partir do .env.example, preenchendo o segredo
if [ -f "$EXAMPLE_FILE" ]; then
  grep -v '^SIGNOZ_JWT_SECRET=' "$EXAMPLE_FILE" > "$ENV_FILE"
else
  : > "$ENV_FILE"
fi
printf 'SIGNOZ_JWT_SECRET=%s\n' "$SECRET" >> "$ENV_FILE"

echo "→ $ENV_FILE gerado com um novo SIGNOZ_JWT_SECRET ✅"
echo ""
echo "Pronto. Agora suba a stack:"
echo "  docker compose up -d"
