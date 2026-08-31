#!/usr/bin/env bash
# 장애 주입 · Redis 메모리 압박 (RB-R02)
#
# ops-1 에서 돌린다. 두 단계로 나뉜다.
#
#   ./rb-r02.sh 1          maxmemory 를 낮춰 eviction 을 일으킨다
#   ./rb-r02.sh 2          정책을 noeviction 으로 바꿔 쓰기를 거부시킨다
#   ./rb-r02.sh --restore  두 값을 모두 되돌린다
#   ./rb-r02.sh --status   지금 값을 본다
#
# ── 두 단계인 이유 ──────────────────────────────────────────
# 같은 「메모리 부족」이 정책에 따라 정반대로 보인다.
#
#   allkeys-lru   쓰기는 되지만 히트율이 떨어진다
#   noeviction    OOM command not allowed 로 쓰기가 거부된다
#
# 커리큘럼이 두 증상을 모두 재현 대상으로 두었고, 둘은 같은 정책에서 동시에
# 나오지 않는다. 그래서 정책을 바꿔 가며 두 번 본다.
#
# ── 적재량을 늘리지 않고 상한을 낮춘다 ──────────────────────
# 롤 기본값이 maxmemory 8gb 다. 그것을 넘기게 채우면 시간이 오래 걸리고
# 16 GiB 노드에서 fork 여유까지 위협한다. 상한을 내리는 쪽이 빠르고 안전하다.
#
# ── 반드시 되돌린다 ─────────────────────────────────────────
# 2단계의 noeviction 을 남겨 두면 이후 실습에서 Redis 쓰기가 계속 거부된다.
# --restore 가 maxmemory 와 정책을 모두 원래 값으로 돌린다.
#
# ── CONFIG SET 은 실행 중 값만 바꾼다 ───────────────────────
# 설정 파일은 그대로다. 노드를 재기동하면 파일 값으로 돌아간다.
# 이 실습에서는 실행 중 값으로 충분하다.
set -uo pipefail

# ansible.cfg 는 그 디렉터리에서 돌 때만 읽힌다. 이 스크립트는 홈에서
# 실행되므로 경로를 못 찾고, host_key_checking 이 켜진 채로 돈다.
# 단계가 바뀌면 새 노드가 앞 단계와 같은 사설 IP 를 쓰므로 호스트 키가
# 달라지고, 그 자리에서 SSH 가 막힌다.
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$HOME/ansible/ansible.cfg}"

INV="${INV:-$HOME/ansible/inventory/hosts.ini}"
SMALL="${SMALL:-256mb}"        # 낮출 상한. 실측으로 확정한다
FILL_MB="${FILL_MB:-400}"      # 적재량. 상한보다 넉넉히 크게 준다
STATE="$HOME/.rb-r02"

die() { echo "오류: $*" >&2; exit 1; }

redis_hosts() {
  awk '/^\[redis\]/{f=1;next} /^\[/{f=0} f && NF {print $1}' "$INV"
}
host_ip() {
  awk -v n="$1" '$1==n {for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i); print $i}}' "$INV"
}
master_ip() {
  local h ip
  h="$(redis_hosts | head -1)"
  [ -n "$h" ] || die "인벤토리에 [redis] 그룹이 없다. 지금 단계가 1단계가 맞는지 본다."
  ip="$(host_ip "$h")"
  # --no-raw 를 쓰지 않는다. 붙이면 출력이 '1) "10.0.1.5"' 형태라 번호 접두사가
  # 남는다. 실습 검증 2회차에서 안내 문구에 그대로 찍혔다.
  redis-cli -h "$ip" -p 26379 sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1 | tr -d '"\r'
}

show_status() {
  echo "── 지금 값 ──"
  for h in $(redis_hosts); do
    local ip mm pol used ev
    ip="$(host_ip "$h")"
    mm="$(redis-cli -h "$ip" config get maxmemory 2>/dev/null | tail -1)"
    pol="$(redis-cli -h "$ip" config get maxmemory-policy 2>/dev/null | tail -1)"
    used="$(redis-cli -h "$ip" info memory 2>/dev/null | awk -F: '/^used_memory:/{print $2}' | tr -d '\r')"
    ev="$(redis-cli -h "$ip" info stats 2>/dev/null | awk -F: '/^evicted_keys:/{print $2}' | tr -d '\r')"
    printf '  %-9s maxmemory=%-12s policy=%-14s used=%-12s evicted=%s\n' \
      "$h" "${mm:-?}" "${pol:-?}" "${used:-?}" "${ev:-?}"
  done
}

# 세 노드 전부에 같은 값을 건다. master 만 바꾸면 전환이 일어났을 때
# 새 master 가 원래 값을 그대로 갖고 있어 증상이 사라진다.
set_all() {
  local key="$1" val="$2"
  for h in $(redis_hosts); do
    redis-cli -h "$(host_ip "$h")" config set "$key" "$val" >/dev/null \
      || die "$h 에 $key 설정 실패"
  done
}

case "${1:-}" in
  --status)
    show_status
    ;;

  --restore)
    [ -f "$STATE" ] || die "바꾼 기록이 없다. --status 로 지금 값을 본다."
    # shellcheck disable=SC1090
    . "$STATE"
    echo "── 원래 값으로 되돌린다 ──"
    set_all maxmemory-policy "${ORIG_POLICY}"
    # 값이 비었거나 0 이면 되돌리지 않는다. 그대로 넣으면 상한이 무제한이 되어
    # 원래 값과 달라지고, 그것을 원복으로 착각한다. 실습 검증 2회차에서
    # maxmemory=0 policy=noeviction 으로 남았다.
    if [ -z "${ORIG_MAXMEMORY:-}" ] || [ "${ORIG_MAXMEMORY}" = "0" ]; then
      die "기록된 원래 maxmemory 가 비었거나 0 이다. 손으로 되돌린다.
  ansible redis -m shell -a \"redis-cli CONFIG SET maxmemory 8gb\"
  ansible redis -m shell -a \"redis-cli CONFIG SET maxmemory-policy allkeys-lru\""
    fi
    set_all maxmemory "${ORIG_MAXMEMORY}"
    rm -f "$STATE"
    show_status
    echo
    echo "maxmemory 와 정책이 원래 값인지 위에서 확인한다."
    echo "되돌리지 않으면 이후 실습에서 쓰기가 계속 거부된다."
    ;;

  1)
    [ -f "$STATE" ] && die "이미 주입한 상태다. --restore 로 되돌린 뒤 다시 돌린다."
    mip="$(master_ip)"
    [ -n "$mip" ] || die "master 를 못 찾았다. 서비스가 떠 있는지 본다."

    orig_mm="$(redis-cli -h "$mip" config get maxmemory | tail -1 | tr -d '"\r')"
    orig_pol="$(redis-cli -h "$mip" config get maxmemory-policy | tail -1 | tr -d '"\r')"
    # 이미 낮춰 둔 상태에서 다시 1단계를 돌리면 낮춘 값이 「원래 값」으로 기록된다.
    # 그러면 원복해도 원래대로 돌아가지 않는다.
    if [ "$orig_mm" = "0" ] || [ "$orig_mm" = "$SMALL" ]; then
      die "지금 maxmemory 가 $orig_mm 다. 원래 값이 아닌 것 같으니 먼저 손으로 되돌린다."
    fi
    printf 'ORIG_MAXMEMORY=%s\nORIG_POLICY=%s\n' "$orig_mm" "$orig_pol" > "$STATE"
    echo "원래 값을 $STATE 에 적었다. maxmemory=$orig_mm policy=$orig_pol"

    echo "── 1단계 · 상한을 $SMALL 로 낮추고 $FILL_MB MB 를 적재한다 ──"
    set_all maxmemory "$SMALL"
    REDIS_HOST="$mip" "$HOME/loadgen/fill.sh" "$FILL_MB" || die "적재 실패"

    # 적재만 하면 히트율이 움직이지 않는다. redis-benchmark 의 -t set 은 읽지
    # 않으므로 keyspace_hits 와 keyspace_misses 가 둘 다 0 으로 남고 히트율
    # 패널이 빈 채로 있다. 축출이 히트율을 떨어뜨린다는 것을 보려면 적재한
    # 키 공간을 그대로 읽어야 한다. 살아남은 키는 hit, 쫓겨난 키는 miss 다.
    echo
    echo "── 적재한 키 공간을 읽는다. 쫓겨난 키가 miss 로 잡힌다 ──"
    REDIS_HOST="$mip" "$HOME/loadgen/read.sh" "$FILL_MB" || die "읽기 실패"

    echo
    show_status
    echo
    echo "evicted_keys 가 오르고 히트율이 떨어진다. Grafana 에서 확인한다."
    ;;

  2)
    [ -f "$STATE" ] || die "1단계를 먼저 돌린다."
    echo "── 2단계 · 정책을 noeviction 으로 바꾼다 ──"
    set_all maxmemory-policy noeviction

    # 정책만 바꾸면 쓰기가 거부되지 않는다. allkeys-lru 로 도는 동안
    # used_memory 가 상한 바로 아래에 맞춰져 있어 작은 쓰기는 통과한다.
    # 상한을 지금 사용량 아래로 내려야 OOM 이 실제로 난다.
    # 실습 검증 2회차에서 확인했다.
    mip="$(master_ip)"
    used="$(redis-cli -h "$mip" INFO memory 2>/dev/null \
      | awk -F: '/^used_memory:/{print $2}' | tr -d '[:space:]')"
    [ -n "$used" ] || die "used_memory 를 읽지 못했다."
    echo "상한을 지금 사용량($used)의 90% 로 내린다."
    set_all maxmemory "$(( used * 9 / 10 ))"
    echo
    echo "쓰기가 거부되는 것을 본다."
    echo "  redis-cli -h $mip set probe:oom 1"
    echo
    echo "OOM command not allowed when used memory > 'maxmemory' 가 나온다."
    ;;

  *)
    die "쓰는 법은 파일 머리 주석에 있다."
    ;;
esac
