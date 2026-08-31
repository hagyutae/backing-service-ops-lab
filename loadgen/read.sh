#!/usr/bin/env bash
# 실습용 읽기.
#
# ops-1 에서 돌린다. fill.sh 가 만든 키 공간을 그대로 읽어 히트율을 만든다.
#
#   REDIS_HOST=10.0.1.5 ./read.sh          300 MB 분량의 키 공간을 읽음
#   REDIS_HOST=10.0.1.5 ./read.sh 400      400 MB 분량을 읽음
#
# ── fill.sh 와 같은 인자를 준다 ─────────────────────────────────
# 키 이름과 번호 범위를 fill.sh 와 똑같이 계산한다. 다른 값을 주면 없는 키만
# 읽어 miss 가 100% 로 나오고, 축출 때문에 떨어진 히트율과 구분되지 않는다.
#
# ── 무엇을 보는가 ───────────────────────────────────────────────
# 상한보다 많이 적재하면 앞부분 키가 쫓겨난다. 그 키 공간을 전부 읽으면
# 살아남은 키는 keyspace_hits 로, 쫓겨난 키는 keyspace_misses 로 잡힌다.
# 둘의 비가 히트율이고, 축출이 캐시 효율을 떨어뜨린다는 것이 여기서 보인다.
set -uo pipefail

MB="${1:-300}"
PIPELINE="${2:-16}"
HOST="${REDIS_HOST:?REDIS_HOST 를 지정한다. 예: REDIS_HOST=10.0.1.5}"
PORT="${REDIS_PORT:-6379}"

# fill.sh 와 같은 계산이다. 값 1 KiB 짜리 키를 1 MB 당 1024개 만든다.
KEYS=$(( MB * 1024 ))
REQUESTS=$(( KEYS * 3 ))

echo "읽기 시작: 키 공간 ${KEYS}개, 요청 ${REQUESTS}건, 파이프라인 ${PIPELINE}"

rc=0
redis-benchmark -h "$HOST" -p "$PORT" \
  -t get -n "$REQUESTS" -r "$KEYS" -P "$PIPELINE" -q || rc=$?

echo "----"
redis-cli -h "$HOST" -p "$PORT" INFO stats \
  | awk -F: '/^keyspace_hits:|^keyspace_misses:/{gsub(/\r/,"",$2); print "  " $1 "=" $2}'

# 히트율을 그 자리에서 계산해 준다. Grafana 패널과 대조할 값이다.
redis-cli -h "$HOST" -p "$PORT" INFO stats \
  | awk -F: '
      /^keyspace_hits:/   {gsub(/\r/,"",$2); h=$2}
      /^keyspace_misses:/ {gsub(/\r/,"",$2); m=$2}
      END {
        t = h + m
        if (t > 0) printf "  히트율=%.1f%%\n", 100 * h / t
        else       printf "  히트율=계산 불가. 읽기가 한 건도 잡히지 않았다\n"
      }'

if [ "$rc" -ne 0 ]; then
  echo "읽기가 중간에 끊겼다. 서비스가 떠 있는지 본다."
fi
