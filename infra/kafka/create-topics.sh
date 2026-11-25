#!/bin/sh
# Cria os tópicos de infra/kafka/topics.yml que ainda não existem (docs/10, seções 3.7 e 6).
# Roda no contêiner de uso único kafka-init, com a imagem oficial do Kafka. Idempotente.
#
#   KAFKA_BOOTSTRAP=kafka:9092 sh create-topics.sh [topics.yml]
#   DRY_RUN=1 sh create-topics.sh   # só imprime os comandos (usado nos testes)
#   TOPIC_PARTITIONS=192 sh create-topics.sh   # mesma lista com outro número de partições
set -eu

FILE="${1:-$(dirname "$0")/topics.yml}"
BOOTSTRAP="${KAFKA_BOOTSTRAP:-localhost:9092}"
KAFKA_TOPICS="${KAFKA_TOPICS:-/opt/kafka/bin/kafka-topics.sh}"

# Uma linha por tópico: nome partições réplicas chave=valor,...
awk '
  function flush() { if (name != "") print name, partitions, replication, (configs == "" ? "-" : configs) }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*- name:/ { flush(); name = $3; partitions = ""; replication = 1; configs = ""; next }
  /^[[:space:]]*partitions:/ { partitions = $2; next }
  /^[[:space:]]*replication_factor:/ { replication = $2; next }
  /^[[:space:]]+[a-z]+\.[a-z.]+:/ { key = $1; sub(/:$/, "", key); value = $2; gsub(/"/, "", value)
                                    configs = configs (configs == "" ? "" : ",") key "=" value; next }
  END { flush() }
' "$FILE" | while read -r name partitions replication configs; do
  # TOPIC_PARTITIONS sobrepõe as partições na criação (teste de carga, ADR-034); sem ela vale o topics.yml.
  partitions="${TOPIC_PARTITIONS:-$partitions}"
  set -- --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$name" \
    --partitions "$partitions" --replication-factor "$replication"
  if [ "$configs" != "-" ]; then
    for pair in $(echo "$configs" | tr ',' ' '); do set -- "$@" --config "$pair"; done
  fi
  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "$KAFKA_TOPICS $*"
  else
    "$KAFKA_TOPICS" "$@"
  fi
done
