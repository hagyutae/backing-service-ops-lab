#!/usr/bin/env bash
# 같은 문서 경합 만들기.
#
# ops-1 에서 돌린다. 부하를 주는 쪽과 받는 쪽을 분리한다.
#
#   MONGO_HOST=10.0.1.5 ./contend-mongo.sh          프로세스 8개로 60초
#   MONGO_HOST=10.0.1.5 ./contend-mongo.sh 8 120    프로세스 수와 지속 시간(초)
#   MONGO_HOST=10.0.1.5 MONGO_DB=loadtest ./contend-mongo.sh   데이터베이스 지정
#
# 인증을 켠 뒤에는 계정을 함께 준다.
#
#   MONGO_HOST=10.0.1.5 MONGO_USER=admin MONGO_PASS=... ./contend-mongo.sh
#
# ── 어느 실습에서 쓰는가 ────────────────────────────────────────
# 동시성 제어 챕터의 경합 실습에서만 쓴다. 문서 하나를 여러 프로세스가 동시에
# 고쳐 WriteConflict 를 만든다.
#
# ── 왜 문서 하나인가 ────────────────────────────────────────────
# 낙관적 동시성 제어는 같은 문서를 동시에 고칠 때만 충돌을 낸다. 서로 다른 문서를
# 넣는 부하는 아무리 많이 보내도 WriteConflict 가 0 이다. 적재 스크립트로는
# 이 실습이 성립하지 않는다.
#
# ── 왜 시간으로 끊는가 ──────────────────────────────────────────
# 건수로 끊으면 노드 성능에 따라 끝나는 시각이 달라져 20명이 함께 진행하기 어렵다.
# Prometheus 가 15초마다 긁으므로 60초면 그래프에 점이 네댓 찍힌다.
#
# ── 정리를 하지 않는 이유 ───────────────────────────────────────
# dropDatabase 는 되돌릴 수 없다. 수강생이 경고를 보고 직접 친다.
set -uo pipefail

PROCS="${1:-8}"
DURATION="${2:-60}"
HOST="${MONGO_HOST:?MONGO_HOST 를 지정한다. 예: MONGO_HOST=10.0.1.5}"
PORT="${MONGO_PORT:-27017}"
DB="${MONGO_DB:-loadtest}"
COLL="${MONGO_COLL:-hot}"
USER="${MONGO_USER:-}"
PASS="${MONGO_PASS:-}"
AUTHDB="${MONGO_AUTHDB:-admin}"

if ! command -v mongosh >/dev/null 2>&1; then
  echo "mongosh 가 없다. ops 노드에서 실행하고 있는지 확인한다."
  exit 1
fi

AUTH_ARGS=()
if [ -n "$USER" ]; then
  AUTH_ARGS=(-u "$USER" -p "$PASS" --authenticationDatabase "$AUTHDB")
fi

URI="mongodb://${HOST}:${PORT}/${DB}"

# 경합 대상 문서 하나. 이미 있으면 그대로 쓴다.
mongosh "$URI" --quiet "${AUTH_ARGS[@]}" --eval \
  "db.getCollection('${COLL}').updateOne({_id:1},{\$setOnInsert:{n:0}},{upsert:true})" >/dev/null

# 부하 전 충돌 누계. serverStatus 는 어느 데이터베이스에서 읽어도 값이 같다.
before=$(mongosh "$URI" --quiet "${AUTH_ARGS[@]}" --eval \
  "db.serverStatus().metrics.operation.writeConflicts")

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "경합 시작: ${DB}.${COLL} 의 _id:1 에 프로세스 ${PROCS}개로 ${DURATION}초"

START=$(date +%s.%N)

for i in $(seq 1 "$PROCS"); do
  mongosh "$URI" --quiet "${AUTH_ARGS[@]}" --eval "
    const until = Date.now() + ${DURATION} * 1000;
    let n = 0;
    while (Date.now() < until) {
      db.getCollection('${COLL}').updateOne({_id:1}, {\$inc:{n:1}});
      n++;
    }
    print(n);
  " > "${WORKDIR}/w${i}" 2>/dev/null &
done
wait

END=$(date +%s.%N)

after=$(mongosh "$URI" --quiet "${AUTH_ARGS[@]}" --eval \
  "db.serverStatus().metrics.operation.writeConflicts")

# 워커가 각자 찍은 갱신 횟수를 더한다.
updates=$(cat "${WORKDIR}"/w* 2>/dev/null | awk '{s+=$1} END {print s+0}')

echo "----"
awk -v u="$updates" -v b="$before" -v a="$after" -v s="$START" -v e="$END" 'BEGIN {
  el = e - s;
  if (el <= 0) el = 0.001;
  printf "갱신 %d회, 소요 %.1f초, 초당 %d회\n", u, el, u / el;
  printf "쓰기 충돌 %d회 (%d 에서 %d 으로)\n", a - b, b, a;
  if (u > 0) printf "갱신 100회당 충돌 %.1f회\n", (a - b) * 100 / u;
}'
