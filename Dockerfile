# Imagen propia para el almacén vectorial.
#
# ¿Por qué una imagen propia en vez de usar la imagen oficial directamente?
# Porque Coolify, al desplegar un "Docker Compose from a Git repository", NO copia
# el código fuente del repositorio dentro del directorio de despliegue. Los montajes
# relativos (por ejemplo `./db/init:/docker-entrypoint-initdb.d`) quedan VACÍOS y el
# script de inicialización nunca se ejecuta.
#
# La solución robusta: hornear el script dentro de la imagen con COPY. Así el esquema
# viaja dentro de la imagen y se aplica solo en el primer arranque, sin depender de
# ningún fichero externo.
#
# Versión fijada a propósito (nunca `latest`): pgvector 0.8.7 sobre PostgreSQL 17.
FROM pgvector/pgvector:0.8.7-pg17

# El entrypoint oficial de PostgreSQL ejecuta todo lo que haya en
# /docker-entrypoint-initdb.d solo la PRIMERA vez que arranca con el volumen vacío.
COPY db/init/01-schema.sql /docker-entrypoint-initdb.d/01-schema.sql
