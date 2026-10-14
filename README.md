# PostgreSQL + pgvector para RAG en Coolify

Repositorio listo para desplegar un **almacén vectorial** en Coolify. Es la pieza
que falta tras el episodio 1 (Coolify + Outline): aquí montamos la base de datos
donde vivirá el índice de embeddings que usará el sistema RAG construido con n8n.

- Imagen base: `pgvector/pgvector:0.8.7-pg17` (versión fijada, nunca `latest`)
- Un único servicio `postgres` con volumen persistente
- Esquema de dos tablas: `knowledge_documents` y `knowledge_chunks`
- Índice HNSW para búsqueda por similitud coseno
- Un `Dockerfile` mínimo que hornea el esquema dentro de la imagen (ver sección 3)

Todo funciona importando el repositorio en Coolify **sin editar nada** salvo las
variables de entorno.

---

## 1. Qué es pgvector y por qué lo necesita este RAG

**pgvector** es una extensión de PostgreSQL que añade un tipo de dato `vector` y
operadores para medir distancias (coseno, L2, producto interno). Nos permite
guardar los embeddings y buscar "lo más parecido" dentro de la propia base de
datos, sin montar un motor vectorial aparte.

### El almacén vectorial es un ÍNDICE DERIVADO, no la fuente de verdad

Esto es lo más importante del episodio. Distingue dos cosas:

- **Fuente de verdad**: los documentos originales (las páginas de Outline, los
  archivos del repositorio, etc.). Son el contenido canónico.
- **Índice derivado**: la tabla `knowledge_chunks` con sus embeddings. Se
  *calcula* a partir de los documentos. Si borras todo este índice, no pierdes
  información: lo vuelves a generar.

Por eso el pipeline (los workflows de n8n) hace *upsert* y limpieza en lugar de
tratar esta base como si fuera el original. Si cambias el modelo de embeddings,
o la dimensión, o el troceado, lo correcto es **regenerar** el índice, no
parchearlo. Esta base de datos es desechable y reconstruible por diseño.

---

## 2. Por qué HNSW y no ivfflat

Ambos son índices de búsqueda aproximada (ANN) para vectores. La diferencia:

| | HNSW | ivfflat |
|---|---|---|
| Recuerdo (recall) | Mejor | Algo peor |
| Entrenamiento | No necesita | Necesita datos presentes para entrenar |
| Parámetro clave | `m`, `ef_construction` | `lists` (hay que ajustarlo) |
| Inserciones incrementales | Muy buenas | Empeoran hasta reindexar |
| Construcción | Más lenta | Más rápida |
| RAM | Más consumo | Menos consumo |

**Por qué elegimos HNSW aquí**: el pipeline de n8n indexa de forma incremental
(documentos nuevos, páginas que cambian). HNSW da mejor recuerdo y no requiere
reentrenamiento, así que se adapta bien a ese flujo constante. Su coste es más
RAM y una construcción más lenta.

**Tradeoff honesto**: ivfflat es una alternativa totalmente válida si vas muy
justo de RAM. Construye antes y ocupa menos, pero debes tener datos cargados
antes de entrenarlo (por eso en una base recién creada y vacía no te sirve) y
ajustar bien su parámetro `lists`. Para pocos miles de fragmentos, como en este
tutorial, HNSW es la opción cómoda y con mejor calidad de búsqueda.

El índice se construye con `m = 16` y `ef_construction = 64` (valores seguros por
defecto). Si necesitas más precisión a cambio de más tiempo/RAM, sube
`ef_construction`; si necesitas menos memoria, baja `m`.

---

## 3. Por qué hay un Dockerfile (y no solo un compose)

Esta es la primera trampa real del episodio y merece explicación.

Al desplegar un **"Docker Compose from a Git repository"**, Coolify **no copia el
código del repositorio** dentro del directorio donde ejecuta el compose. Solo
renderiza el `docker-compose.yaml` con tus variables. Es decir: los montajes
relativos a ficheros del repo, como

```yaml
volumes:
  - ./db/init:/docker-entrypoint-initdb.d   # ❌ NO funciona en Coolify
```

dejan ese directorio **vacío** dentro del contenedor, y PostgreSQL termina arrancando
sin ejecutar el `01-schema.sql`. La base queda sin extensión `vector` ni tablas, y
te enteras cuando el primer workflow de n8n falla.

La solución robusta es **hornear el esquema dentro de la imagen** con un `Dockerfile`
de dos líneas:

```dockerfile
FROM pgvector/pgvector:0.8.7-pg17
COPY db/init/01-schema.sql /docker-entrypoint-initdb.d/01-schema.sql
```

Y en el compose, construir esa imagen en lugar de usar la oficial directamente:

```yaml
services:
  postgres:
    build: .        # ← construye el Dockerfile de este repo
```

Coolify construye la imagen (en segundos, la capa base ya está cacheada) y el script
se ejecuta solo en el primer arranque. **No dependes de ningún fichero externo.**

---

## 4. Despliegue en Coolify

El flujo es idéntico al del episodio 1: **Docker Compose desde un repositorio
de Git**.

1. En Coolify, crea un nuevo recurso: **+ New → Resource → Docker Compose from a
   Git repository** (o "Docker Compose Empty" no; aquí queremos desde Git).
2. Elige el proveedor de Git y este repositorio.
3. Comprueba que Coolify detecta **/docker-compose.yaml** como ruta del compose.
4. Ve a la pestaña **Environment Variables** del recurso y define:
   - `POSTGRES_USER` (por defecto `knowledge`)
   - `POSTGRES_PASSWORD` → **ponle una tuya** (o genera una con Coolify). No
     dejes el valor por defecto.
   - `POSTGRES_DB` (por defecto `knowledge`)
   - `POSTGRES_DEBUG_PORT` → déjalo sin tocar salvo que quieras depurar.
5. Pulsa **Deploy**. Coolify construye, arranca el contenedor y gestiona la red:
   **no añadas etiquetas de Traefik a mano**, Coolify se encarga del enrutado. El
   script `db/init/01-schema.sql` se ejecuta automáticamente en el primer arranque.
6. Cuando el contenedor esté en estado *running*/*healthy*, ya tienes el almacén
   vectorial listo para que n8n se conecte por la red interna.

### Puerto público (solo para depurar)

Por defecto **no** se publica ningún puerto: no hace falta, n8n llega por la red
interna. Si necesitas conectarte con un cliente SQL desde fuera para inspeccionar,
descomenta el bloque `ports` en `docker-compose.yaml`:

```yaml
ports:
  - "${POSTGRES_DEBUG_PORT:-5432}:5432"
```

Esto es **solo para depuración**; en producción déjalo cerrado.

---

## 5. Cómo verificar que funciona

Con el stack levantado, ejecuta el script incluido desde la raíz del repositorio:

```bash
./scripts/verify.sh
```

O a mano, entrando a `psql` en el contenedor:

```bash
docker compose exec postgres psql -U knowledge -d knowledge
```

Y dentro de `psql`:

```sql
-- Extensión instalada y su versión
SELECT extversion FROM pg_extension WHERE extname = 'vector';   -- 0.8.7

-- Tablas creadas
\dt

-- El índice HNSW debe aparecer en la lista de índices
\d knowledge_chunks
```

### Prueba de inserción y consulta de similitud

Inserta un documento y un fragmento con un embedding de 384 dimensiones de
mentira. Usa valores **no nulos**: un vector todo ceros tiene norma 0 y la
distancia coseno `<=>` da `NaN` (la búsqueda no devolvería filas). Aquí basta un
vector de prueba para validar el tipo y el índice:

```sql
INSERT INTO knowledge_documents (source_type, external_id, title)
VALUES ('outline', 'demo-1', 'Documento de prueba');

INSERT INTO knowledge_chunks (document_id, chunk_index, content, token_count, embedding_model, embedding)
SELECT id, 0, 'contenido de prueba', 3, 'intfloat/multilingual-e5-small',
       (SELECT array_fill(0.01, ARRAY[384])::vector)
FROM knowledge_documents WHERE external_id = 'demo-1';

-- Consulta por distancia coseno: devuelve 1 fila (el chunk anterior)
SELECT c.chunk_index, c.content,
       ROUND((1 - (c.embedding <=> (SELECT array_fill(0.01, ARRAY[384])::vector)))::numeric, 6) AS score
FROM knowledge_chunks c
ORDER BY c.embedding <=> (SELECT array_fill(0.01, ARRAY[384])::vector)
LIMIT 5;
```

El operador `<=>` es la distancia coseno (a menor valor, más parecidos). En la
práctica los embeddings reales del modelo nunca son cero, así que este caso no
aparece con datos de verdad.

---

## 6. Uso de recursos (referencia realista)

Números para una base de conocimiento de **unos pocos miles de fragmentos**
(por ejemplo ~2.000–5.000 chunks de 384 dimensiones), medidos en un VPS pequeño:

- **En reposo (idle)**: ~25–60 MB de RAM. El proceso de PostgreSQL con este
  volumen de datos es muy ligero; el índice HNSW de 384 dimensiones para pocos
  miles de filas también ocupa poco. (En la prueba de este repositorio, el
  contenedor se quedó en torno a 26 MB en reposo.)
- **Durante la indexación**: sube de forma transitoria, típicamente ~150–300 MB,
  porque hay que construir/mantener el índice HNSW y calcular distancias. Vuelve
  al nivel de reposo al terminar.
- **Disco**: cada embedding `vector(384)` ocupa ~1.5 KB en crudo (384 × 4 bytes)
  más el contenido del chunk. Para pocos miles de chunks hablamos de decenas de
  MB.

El consumo escala con el número de chunks y con el parámetro `m` del índice. Para
una base mucho mayor (cientos de miles a millones), revisa RAM y considera subir
el `shared_buffers` de PostgreSQL.

---

## 7. Cómo cambiar la dimensión del vector

La columna `embedding` está definida como `vector(384)` porque el modelo
`intfloat/multilingual-e5-small` produce 384 dimensiones.

Si cambias de modelo de embeddings, la dimensión DEBE coincidir con la salida de
ese modelo. Por ejemplo, si pasas a un modelo de 768 dimensiones:

1. Edita `db/init/01-schema.sql` y cambia `vector(384)` por `vector(768)`.
2. **Borra y recrea el volumen** (el script de init solo corre en el primer
   arranque): `docker compose down -v` y vuelve a desplegar.
3. Vuelve a indexar todos los documentos para regenerar los embeddings con la
   nueva dimensión.

**Importante**: un vector de 384 dimensiones no se puede insertar en una columna
`vector(768)` ni al contrario. Cambiar la dimensión implica regenerar todo el
índice; no hay conversión posible. Por eso conviene fijar el modelo de embeddings
antes de indexar en serio.

---

## Estructura del repositorio

```
.
├── docker-compose.yaml        # Servicio postgres, volumen, healthcheck
├── Dockerfile                # Imagen propia: hornea el esquema dentro (ver sección 3)
├── db/init/01-schema.sql     # Esquema + extensión + índices (primer arranque)
├── .env.example              # Plantilla de variables de entorno
├── scripts/verify.sh         # Verificación rápida del almacén
├── LICENSE                   # MIT
└── README.md
```

Licencia MIT © Eduardo Navajas.
