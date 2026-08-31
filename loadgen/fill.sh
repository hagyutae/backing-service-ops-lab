#!/usr/bin/env bash
# 실습용 적재.
#
# ops-1 에서 돌린다. 부하를 주는 쪽과 받는 쪽을 분리한다.
#
#   REDIS_HOST=10.0.1.5 ./fill.sh          300 MB 를 채우고 처리량을 출력
#   REDIS_HOST=10.0.1.5 ./fill.sh 64       64 MB 만 채움
#   REDIS_HOST=10.0.1.5 ./fill.sh 64 1     파이프라이닝 없이 채움
#
# ── 키 공간이 겹치는 것에 주의 ──────────────────────────────────
# 키 이름은 key:<번호> 이고 번호 범위가 MB 값으로 정해진다. 앞서 300 으로 채운 뒤
# 60 으로 다시 채우면 이미 있는 키를 덮어쓰기만 해서 메모리가 늘지 않는다.
# Eviction 을 일으키려면 앞서 채운 값보다 큰 값을 준다.
#
# ── fsync 정책을 비교할 때는 두 번째 인자를 1 로 둔다 ────────────
# appendfsync always 는 명령마다가 아니라 이벤트 루프 1회분마다 한 번 fsync 한다.
# 파이프라인 깊이가 16 이면 fsync 비용이 16분의 1로 희석돼 차이가 보이지 않는다.
#
# ── 요청을 목표 키 수의 3배로 보내는 이유 ────────────────────────
# redis-benchmark 의 -r 은 키를 무작위로 고른다. 요청 수와 후보 수가 같으면
# 중복 때문에 약 63% 만 실제로 만들어진다. 3배를 보내면 95% 가 채워진다.
set -uo pipefail

MB="${1:-300}"
PIPELINE="${2:-16}"
HOST="${REDIS_HOST:?REDIS_HOST 를 지정한다. 예: REDIS_HOST=10.0.1.5}"
PORT="${REDIS_PORT:-6379}"

# 값 1 KiB 짜리 키를 만든다. 1 MB 당 1024개.
KEYS=$(( MB * 1024 ))
REQUESTS=$(( KEYS * 3 ))

echo "적재 시작: 목표 ${MB} MB (키 ${KEYS}개, 요청 ${REQUESTS}건, 값 1 KiB, 파이프라인 ${PIPELINE})"
START=$(date +%s.%N)

# set -e 를 쓰지 않는다. 한도에 닿아 쓰기가 거부돼도 아래 결과를 출력해야 한다.
rc=0
redis-benchmark -h "$HOST" -p "$PORT" \
  -t set -n "$REQUESTS" -d 1024 -r "$KEYS" -P "$PIPELINE" -q || rc=$?

END=$(date +%s.%N)

# bc 는 기본 이미지에 없을 수 있다. awk 는 어디에나 있다.
echo "----"
awk -v c="$REQUESTS" -v s="$START" -v e="$END" 'BEGIN {
  d = e - s
  if (d <= 0) d = 0.001
  printf "소요 %.1f초, 초당 %.0f건\n", d, c / d
}'

if [ "$rc" -ne 0 ]; then
  echo "한도에 닿아 쓰기가 거부됐다. Eviction 실습에서는 이것이 정상이다."
fi
# fsync 비교는 파이프라인 깊이 1 로 돌릴 때만 뜻이 있다. 깊이 16 에서는 fsync 비용이
# 16분의 1로 희석돼 정책 차이가 드러나지 않는다. 그래서 그때만 안내한다.
if [ "$PIPELINE" -eq 1 ]; then
  echo "이 숫자를 기록해 두었다가 appendfsync 를 바꾼 뒤와 비교한다."
fi
