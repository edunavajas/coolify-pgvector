#!/usr/bin/env bash
# Verificación rápida del almacén vectorial.
# Uso: ./scripts/verify.sh   (desde la raíz del repositorio, con el stack levantado)
set -euo pipefail

# Nos situamos en la raíz del proyecto (donde está docker-compose.yml).
cd "$(dirname "$0")/.."

DB_USER="${POSTGRES_USER:-knowledge}"
DB_NAME="${POSTGRES_DB:-knowledge}"
COMPOSE="docker compose"

psql_run() {
  $COMPOSE exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

echo "== Versión de pgvector =="
psql_run -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';"

echo -e "\n== Tablas =="
psql_run -c "\dt"

echo -e "\n== Índices de knowledge_chunks (debe aparecer el HNSW) =="
psql_run -c "\d knowledge_chunks"

echo -e "\n== Recuento =="
psql_run -c "SELECT (SELECT count(*) FROM knowledge_documents) AS documents, (SELECT count(*) FROM knowledge_chunks) AS chunks;"

echo -e "\nVerificación completada."
