#!/usr/bin/env bash
# 장애 주입 · Redis 복제본 이탈 (RB-R01)
#
# ops-1 에서 돌린다. replica 한 대의 Redis 프로세스를 정지시킨다.
#
#   ./rb-r01.sh              replica 하나를 정지
#   ./rb-r01.sh --restore    되돌린다
#   ./rb-r01.sh --status     지금 상태를 본다
#
# ── 무엇을 하고 무엇을 안 하는가 ────────────────────────────
# 재현까지만 한다. 무엇이 잘못됐는지 찾고 되돌리는 것은 수강생이 손으로 한다.
# 그 손 명령이 곧 런북의 재료다.
#
# ── 무엇을 고르는가 ─────────────────────────────────────────
# master 가 아닌 노드 하나를 고른다. master 를 내리면 Sentinel 이 전환을
# 시작해 「복제본 이탈」이 아니라 「자동 전환」 실습이 된다. 그것은 세션 1 에서
# 이미 다뤘다.
#
# ── 왜 프로세스만 내리는가 ──────────────────────────────────
# 노드를 통째로 내리면 node_exporter 도 함께 끊긴다. 그러면 감별의 첫 갈래
# (프로세스인가 노드인가)가 성립하지 않고 답이 바로 나온다.
set -uo pipefail

# ansible.cfg 는 그 디렉터리에서 돌 때만 읽힌다. 이 스크립트는 홈에서
# 실행되므로 경로를 못 찾고, host_key_checking 이 켜진 채로 돈다.
# 단계가 바뀌면 새 노드가 앞 단계와 같은 사설 IP 를 쓰므로 호스트 키가
# 달라지고, 그 자리에서 SSH 가 막힌다.
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$HOME/ansible/ansible.cfg}"

SENTINEL_PORT="${SENTINEL_PORT:-26379}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
INV="${INV:-$HOME/ansible/inventory/hosts.ini}"
STATE="$HOME/.rb-r01"

die() { echo "오류: $*" >&2; exit 1; }

# 인벤토리에서 redis 그룹의 노드 이름을 읽는다.
redis_hosts() {
  awk '/^\[redis\]/{f=1;next} /^\[/{f=0} f && NF {print $1}' "$INV"
}

# Sentinel 에게 지금 master 가 누구인지 묻는다. 전환이 일어났을 수 있다.
current_master_ip() {
  local h
  h="$(redis_hosts | head -1)"
  [ -n "$h" ] || die "인벤토리에 [redis] 그룹이 없다. 지금 단계가 1단계가 맞는지 본다."
  local ip
  ip="$(awk -v n="$h" '$1==n {for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i); print $i}}' "$INV")"
  # --no-raw 를 쓰지 않는다. 그것을 붙이면 출력이 '1) "10.0.1.5"' 형태가 되어
  # 인벤토리의 IP 와 비교가 어긋난다. master 를 replica 로 보고 정지시키면
  # Sentinel 이 전환을 시작해 「복제본 이탈」이 아니라 「자동 전환」 실습이 된다.
  # 실습 검증 2회차에서 두 번 그렇게 됐다.
  redis-cli -h "$ip" -p "$SENTINEL_PORT" \
    sentinel get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | head -1 | tr -d '"\r'
}

host_ip() {
  awk -v n="$1" '$1==n {for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i); print $i}}' "$INV" | tr -d '\r'
}

show_status() {
  echo "── 지금 상태 ──"
  for h in $(redis_hosts); do
    local ip role link
    ip="$(host_ip "$h")"
    role="$(redis-cli -h "$ip" info replication 2>/dev/null | awk -F: '/^role:/{print $2}' | tr -d '\r')"
    link="$(redis-cli -h "$ip" info replication 2>/dev/null | awk -F: '/^master_link_status:/{print $2}' | tr -d '\r')"
    printf '  %-9s %-16s role=%-8s %s\n' "$h" "$ip" "${role:-응답없음}" "${link:+master_link_status=$link}"
  done
}

case "${1:-inject}" in
  --status)
    show_status
    ;;

  --restore)
    [ -f "$STATE" ] || die "정지시킨 기록이 없다. --status 로 상태를 먼저 본다."
    target="$(cat "$STATE")"
    echo "── $target 의 Redis 를 다시 띄운다 ──"
    ansible "$target" -i "$INV" -b -m systemd -a "name=redis-server state=started" \
      >/dev/null 2>&1 || die "재기동 실패"
    rm -f "$STATE"
    echo
    echo "복제가 다시 붙기까지 잠시 걸린다. 아래로 확인한다."
    echo "  redis-cli -h <master 사설 IP> info replication | grep connected_slaves"
    ;;

  inject)
    [ -f "$STATE" ] && die "이미 $(cat "$STATE") 를 정지시킨 상태다. --restore 로 되돌린 뒤 다시 돌린다."
    mip="$(current_master_ip)"
    [ -n "$mip" ] || die "Sentinel 에서 master 를 못 찾았다. 서비스가 떠 있는지 본다."

    target=""
    for h in $(redis_hosts); do
      [ "$(host_ip "$h")" = "$mip" ] && continue
      target="$h"; break
    done
    [ -n "$target" ] || die "정지시킬 replica 를 못 찾았다."

    echo "master 는 $mip 다. replica $target 을 정지시킨다."
    ansible "$target" -i "$INV" -b -m systemd -a "name=redis-server state=stopped" \
      >/dev/null 2>&1 || die "정지 실패"
    echo "$target" > "$STATE"
    echo
    echo "증상이 나타나기까지 잠시 걸린다. Grafana 의 Redis 대시보드를 본다."
    ;;

  *)
    die "쓰는 법은 파일 머리 주석에 있다."
    ;;
esac
