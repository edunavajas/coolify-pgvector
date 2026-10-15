-- Esquema del almacén vectorial para RAG (n8n + pgvector).
-- Se ejecuta una sola vez, en el primer arranque del contenedor.

CREATE EXTENSION IF NOT EXISTS vector;

-- Documentos de origen (una fila por página de Outline, archivo de repo, etc.).
CREATE TABLE IF NOT EXISTS knowledge_documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_type   text NOT NULL,
    external_id   text NOT NULL,
    title         text,
    collection    text,
    content       text,
    content_hash  text,
    canonical_url text,
    metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_type, external_id)
);

-- Fragmentos (chunks) de cada documento, con su embedding.
CREATE TABLE IF NOT EXISTS knowledge_chunks (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     uuid NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE,
    chunk_index     integer NOT NULL,
    content         text,
    token_count     integer,
    embedding_model text,
    -- vector(384) corresponde al modelo intfloat/multilingual-e5-small (384 dimensiones).
    -- IMPORTANTE: si cambias de modelo de embeddings, debes cambiar la dimensión aquí
    -- Y volver a generar todos los embeddings. La dimensión debe coincidir con la salida
    -- del modelo; un vector de otra dimensión no se puede insertar en esta columna.
    embedding       vector(384),
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index)
);

-- Índice HNSW para búsqueda por similitud coseno.
-- m=16 y ef_construction=64 son valores por defecto razonables; ver README para el tradeoff con ivfflat.
CREATE INDEX IF NOT EXISTS knowledge_chunks_embedding_hnsw
    ON knowledge_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Índices auxiliares para las consultas del pipeline.
CREATE INDEX IF NOT EXISTS knowledge_chunks_document_id_idx
    ON knowledge_chunks (document_id);
CREATE INDEX IF NOT EXISTS knowledge_documents_source_type_idx
    ON knowledge_documents (source_type);
CREATE INDEX IF NOT EXISTS knowledge_documents_collection_idx
    ON knowledge_documents (collection);


-- Registro de fallos del indexado.
-- Cuando el servidor de embeddings no responde para un fragmento, el flujo de n8n NO
-- aborta: guarda aqui el motivo y sigue con el resto. Sirve para saber que quedo sin
-- indexar y poder revisarlo.
CREATE TABLE IF NOT EXISTS knowledge_index_failures (
    id           bigserial PRIMARY KEY,
    created_at   timestamptz NOT NULL DEFAULT now(),
    source_type  text,
    external_id  text,
    chunk_index  integer,
    reason       text
);
