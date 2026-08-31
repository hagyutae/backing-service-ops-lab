#!/usr/bin/env bash
# 장애 주입 · MongoDB 복제 지연 (RB-M01)
#
# ops-1 에서 돌린다. SECONDARY 한 대를 멈춰 세우고 PRIMARY 에 쓰기를 밀어
# 넣어 지연을 만든다.
#
#   ./rb-m01.sh              지연을 만든다
#   ./rb-m01.sh --restore    되돌린다
#   ./rb-m01.sh --status     지금 지연을 본다
#
# ── 왜 프로세스를 멈춰 세우는가 ─────────────────────────────
# 부하만으로는 지연이 안 생긴다. 실습 데이터가 20만 건 규모라 SECONDARY 가
# 즉시 따라잡는다. SIGSTOP 으로 mongod 를 멈추면 그 노드가 oplog 를 읽지
# 못하는 동안 지연이 쌓이고, SIGCONT 로 풀면 따라잡는 과정이 그래프에 남는다.
#
# 프로세스를 죽이지 않고 멈추는 이유는 두 가지다. 첫째, 죽이면 rs.status()
# 에서 unreachable 이 되어 「이탈」로 읽힌다. 이 시나리오는 「지연」이다.
# 둘째, 멈춘 노드는 여전히 살아 있어 node_exporter 지표가 계속 나온다.
# 감별의 첫 갈래(프로세스인가 노드인가)가 그대로 성립한다.
#
# ── 무엇을 하고 무엇을 안 하는가 ────────────────────────────
# 재현과 부하 생성까지만 한다. 진단과 복구는 수강생이 손으로 한다.
#
# ── 검증 결과 ───────────────────────────────────────────────
# 실습 검증 1회차에서 값을 확정했다. mongod 를 계속 멈춰 두면 Replica Set 이
# 그 멤버를 「닿지 않는다」로 판정해 지연이 아니라 장애가 된다.
# heartbeatTimeoutSecs 와 electionTimeoutMillis 를 올려도 같았다.
# 그래서 STOP_SEC 와 CONT_SEC 를 번갈아 주는 방식으로 바꿨다.
# 푸는 1 초 사이에 heartbeat 에 답하므로 멤버로 남은 채 지연만 쌓인다.
set -uo pipefail

# ansible.cfg 는 그 디렉터리에서 돌 때만 읽힌다. 이 스크립트는 홈에서
# 실행되므로 경로를 못 찾고, host_key_checking 이 켜진 채로 돈다.
# 단계가 바뀌면 새 노드가 앞 단계와 같은 사설 IP 를 쓰므로 호스트 키가
# 달라지고, 그 자리에서 SSH 가 막힌다.
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$HOME/ansible/ansible.cfg}"

INV="${INV:-$HOME/ansible/inventory/hosts.ini}"
STOP_SEC="${STOP_SEC:-9}"   # 한 번에 멈추는 시간. 판정 시간보다 짧아야 한다
CONT_SEC="${CONT_SEC:-1}"   # 푸는 시간. 이 사이에 heartbeat 에 답한다
# 3회차 검증에서 4 초 멈추고 1 초 푸는 값으로는 지연이 6 초까지만 올랐다.
# 푸는 1 초에 SECONDARY 가 밀린 것을 거의 따라잡기 때문이다. RB-M01 은 지연이
# 우상향하는 것을 보는 시나리오라 그 값으로는 실습이 성립하지 않는다.
# 멈춤과 푸는 시간의 비를 9 대 1 로 키우고 시간을 늘려 지연이 쌓이게 한다.
PAUSE_SEC="${PAUSE_SEC:-240}"    # 멈췄다 푸는 것을 되풀이하는 총 시간
WRITE_SEC="${WRITE_SEC:-240}"    # 쓰기를 미는 시간. PAUSE_SEC 내내 밀어야 지연이 쌓인다
DB="${DB:-lab}"
COLL="${COLL:-lagprobe}"
STATE="$HOME/.rb-m01"

die() { echo "오류: $*" >&2; exit 1; }

mongo_hosts() {
  awk '/^\[mongo\]/{f=1;next} /^\[/{f=0} f && NF {print $1}' "$INV"
}
host_ip() {
  awk -v n="$1" '$1==n {for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i); print $i}}' "$INV"
}
any_ip() {
  local h; h="$(mongo_hosts | head -1)"
  [ -n "$h" ] || die "인벤토리에 [mongo] 그룹이 없다. 지금 단계가 2단계가 맞는지 본다."
  host_ip "$h"
}
primary_ip() {
  mongosh --quiet --host "$(any_ip)" --eval \
    'const s=rs.status(); const p=s.members.find(m=>m.stateStr==="PRIMARY"); print(p?p.name.split(":")[0]:"")' 2>/dev/null
}

show_status() {
  echo "── 멤버 상태와 지연 ──"
  mongosh --quiet --host "$(any_ip)" --eval '
    const s = rs.status();
    const p = s.members.find(m => m.stateStr === "PRIMARY");
    s.members.forEach(m => {
      const lag = p ? Math.round((p.optimeDate - m.optimeDate) / 1000) : "?";
      print("  " + m.name.padEnd(22) + m.stateStr.padEnd(12) +
            "health=" + m.health + "  지연=" + lag + "초");
    });
    // RB-M01 감별 절차가 쓰는 명령과 같은 것을 쓴다.
    // oplog.rs 의 ts 는 BSON Timestamp 라 getTime() 이 없다.
    const ri = db.getReplicationInfo();
    print("  oplog 윈도우 = " + ri.timeDiff + "초 (" + ri.timeDiffHours + "시간)");
  ' 2>/dev/null || die "상태 조회 실패. 인증이 켜져 있으면 계정을 준다."
}

case "${1:-inject}" in
  --status)
    show_status
    ;;

  --restore)
    [ -f "$STATE" ] || die "멈춰 세운 기록이 없다. --status 로 상태를 먼저 본다."
    target="$(cat "$STATE")"
    echo "── $target 의 mongod 를 재개한다 ──"
    ansible "$target" -i "$INV" -b -m shell -a "pkill -CONT -x mongod" \
      || die "재개 실패. 노드에서 직접 pkill -CONT -x mongod 를 친다."
    rm -f "$STATE"

    echo
    echo "따라잡는 데 잠시 걸린다. 지연이 0으로 수렴하는 것을 본다."
    show_status
    ;;

  inject)
    [ -f "$STATE" ] && die "이미 $(cat "$STATE") 를 멈춘 상태다. --restore 로 되돌린 뒤 다시 돌린다."
    pip="$(primary_ip)"
    [ -n "$pip" ] || die "PRIMARY 를 못 찾았다. Replica Set 이 떠 있는지 본다."

    target=""
    for h in $(mongo_hosts); do
      [ "$(host_ip "$h")" = "$pip" ] && continue
      target="$h"; break
    done
    [ -n "$target" ] || die "멈춰 세울 SECONDARY 를 못 찾았다."

    # 한 번에 오래 멈추면 heartbeat 에 답하지 못해 rs.status() 가 그 멤버를
    # unreachable 로 판정한다. 그러면 「이탈」로 보이고 이 시나리오가 만들려는
    # 「지연」이 아니다. heartbeatTimeoutSecs 와 electionTimeoutMillis 를 함께
    # 올려도 같았다. 실습 검증 1회차에서 확인했다.
    #
    # 짧게 멈추고 잠깐 푸는 것을 반복한다. 풀린 사이에 heartbeat 에 답해
    # SECONDARY 를 유지하고, 멈춘 사이에 oplog 를 못 읽어 지연이 쌓인다.
    echo "PRIMARY 는 $pip 다. $target 의 mongod 를 ${STOP_SEC}초 멈추고 ${CONT_SEC}초 푸는 것을"
    echo "${PAUSE_SEC}초 동안 반복한다."
    echo "$target" > "$STATE"
    (
      end=$(( $(date +%s) + PAUSE_SEC ))
      while [ "$(date +%s)" -lt "$end" ]; do
        ansible "$target" -i "$INV" -b -m shell -a "pkill -STOP -x mongod" >/dev/null 2>&1
        sleep "$STOP_SEC"
        ansible "$target" -i "$INV" -b -m shell -a "pkill -CONT -x mongod" >/dev/null 2>&1
        sleep "$CONT_SEC"
      done
      # 마지막은 멈춘 채로 둔다. --restore 가 푼다.
      ansible "$target" -i "$INV" -b -m shell -a "pkill -STOP -x mongod" >/dev/null 2>&1
    ) &


    echo "PRIMARY 에 ${WRITE_SEC}초 동안 쓰기를 민다."
    mongosh --quiet --host "$pip" --eval "
      const end = Date.now() + ${WRITE_SEC} * 1000;
      const c = db.getSiblingDB('${DB}').${COLL};
      let n = 0;
      while (Date.now() < end) {
        const batch = [];
        for (let i = 0; i < 500; i++) batch.push({ n: n++, pad: 'x'.repeat(512) });
        c.insertMany(batch);
      }
      print('  넣은 문서 ' + n + '건');
    " 2>/dev/null || echo "  쓰기가 일부만 들어갔다. 상태를 확인한다."

    echo
    show_status
    echo
    echo "지연이 벌어지는 것을 Grafana MongoDB 대시보드에서 본다."
    echo "되돌릴 때는 --restore 를 쓴다."
    ;;

  *)
    die "쓰는 법은 파일 머리 주석에 있다."
    ;;
esac
