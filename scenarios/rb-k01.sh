#!/usr/bin/env bash
# 장애 주입 · Consumer Lag 급증, 원인은 Rebalance 반복 (RB-K01)
#
# ops-1 에서 돌린다. Topic 을 만들고 Producer 로 밀어 넣으면서,
# poll 간격을 못 지키는 Consumer 를 띄워 Rebalance 를 반복시킨다.
#
#   ./rb-k01.sh              재현
#   ./rb-k01.sh --restore    Consumer 와 Producer 를 정리한다
#   ./rb-k01.sh --status     Lag 분포를 본다
#
# ── Consumer 로그가 남는 곳 ─────────────────────────────────
#   /tmp/rkm-consumer-1.log · -2.log · -3.log
#
# 감별에서 이 파일을 읽는다. Rebalance 반복은 지표로 나오지 않는다.
# Consumer JVM 에 별도 agent 를 붙이지 않기 때문이다.
#
# ── 어떻게 Rebalance 를 일으키는가 ──────────────────────────
# max.poll.interval.ms 를 짧게 주고, 콘솔 Consumer 의 출력을 느리게 읽는
# 파이프로 흘린다. 파이프가 막히면 Consumer 의 poll 루프가 멈추고,
# 그 간격이 max.poll.interval.ms 를 넘으면 그룹에서 제외된다. 남은 Consumer
# 에게 재할당이 일어나고, 쫓겨난 Consumer 가 다시 들어오면서 또 일어난다.
#
# ── 검증 결과 ───────────────────────────────────────────────
# 실습 검증 2회차에서 이 방식으로 Rebalance 가 반복되는 것을 확인했다.
# POLL_MS 를 5000 에서 20000 으로 올렸다. 5000 에서는 Rebalance 가 너무 잦아
# kafka-consumer-groups.sh --describe 가 표 대신 「is rebalancing」 한 줄만
# 내놓고, 그러면 수강생이 Lag 열을 볼 수 없다.
#
#   대안 A  Consumer 하나를 주기적으로 죽였다 살려 멤버 변경을 일으킨다.
#           CHURN=1 로 켠다. 지금은 쓰지 않는다. 원인이 「멤버 변경」이라
#           로그가 조금 다르고, 위 방식으로 이미 재현되기 때문이다.
#
# ── 무엇을 하고 무엇을 안 하는가 ────────────────────────────
# 재현과 부하 생성까지만 한다. 진단과 복구는 수강생이 손으로 한다.
set -uo pipefail

# ansible.cfg 는 그 디렉터리에서 돌 때만 읽힌다. 이 스크립트는 홈에서
# 실행되므로 경로를 못 찾고, host_key_checking 이 켜진 채로 돈다.
# 단계가 바뀌면 새 노드가 앞 단계와 같은 사설 IP 를 쓰므로 호스트 키가
# 달라지고, 그 자리에서 SSH 가 막힌다.
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$HOME/ansible/ansible.cfg}"

INV="${INV:-$HOME/ansible/inventory/hosts.ini}"
TOPIC="${TOPIC:-lab.events}"
PARTITIONS="${PARTITIONS:-3}"
GROUP="${GROUP:-lab-cg}"
CONSUMERS="${CONSUMERS:-3}"
POLL_MS="${POLL_MS:-20000}"       # max.poll.interval.ms.
# 5000 으로 두면 Rebalance 가 너무 잦아 kafka-consumer-groups.sh --describe 가
# 「is rebalancing」만 내고 Lag 분포를 내지 않는다. RB-K01 감별의 첫 단계가
# 분포를 보는 것이라 그 자리에서 막힌다. 20000 이면 Rebalance 는
# 반복되면서도 그 사이에 --describe 가 스냅샷을 잡는다. 실습 검증 1회차 실측.
SLOW_SEC="${SLOW_SEC:-2}"         # 한 줄 읽고 쉬는 시간
RECORDS="${RECORDS:-2000000}"
THROUGHPUT="${THROUGHPUT:-2000}"  # 초당 메시지
CHURN="${CHURN:-0}"               # 1 이면 대안 A
KDIR="${KDIR:-/opt/kafka/bin}"
LOGDIR=/tmp
STATE="$HOME/.rb-k01"

die() { echo "오류: $*" >&2; exit 1; }

kafka_hosts() {
  awk '/^\[kafka\]/{f=1;next} /^\[/{f=0} f && NF {print $1}' "$INV"
}
host_ip() {
  awk -v n="$1" '$1==n {for(i=2;i<=NF;i++) if($i ~ /^ansible_host=/){sub(/^ansible_host=/,"",$i); print $i}}' "$INV"
}
bootstrap() {
  local h; h="$(kafka_hosts | head -1)"
  [ -n "$h" ] || die "인벤토리에 [kafka] 그룹이 없다. 지금 단계가 3단계가 맞는지 본다."
  echo "$(host_ip "$h"):9092"
}

show_status() {
  local bs; bs="$(bootstrap)"
  echo "── Consumer Group 과 Lag 분포 ──"
  "$KDIR/kafka-consumer-groups.sh" --bootstrap-server "$bs" --describe --group "$GROUP" 2>/dev/null \
    || echo "  그룹이 아직 없다."
  echo
  echo "── Consumer 로그의 Rebalance 흔적 ──"
  for i in $(seq 1 "$CONSUMERS"); do
    local f="$LOGDIR/rkm-consumer-$i.log"
    [ -f "$f" ] || continue
    # 실제 증거는 아래 세 문구다. 'rebalance' 만 세면 기동할 때 한 번 뜨는
    # KIP-848 안내 배너가 잡혀 늘 1 이 나온다. 3회차 검증에서 확인했다.
    printf '  %s  poll 초과 %s · 그룹 제외 %s · 재가입 %s\n' "$f" \
      "$(grep -c 'poll timeout has expired' "$f" 2>/dev/null || echo 0)" \
      "$(grep -c 'kicked out of the group' "$f" 2>/dev/null || echo 0)" \
      "$(grep -c 'Will continue to join group' "$f" 2>/dev/null || echo 0)"
  done
}

case "${1:-inject}" in
  --status)
    show_status
    ;;

  --restore)
    echo "── Consumer 와 Producer 를 정리한다 ──"
    # 패턴을 대괄호로 감싸 자기 자신에 걸리지 않게 한다.
    # 감싸지 않으면 pkill 이 자기 명령줄을 찾아 이 셸까지 죽인다.
    pkill -f '[k]afka-console-consumer' 2>/dev/null
    # 셸 래퍼가 java 를 exec 하므로 명령줄에 스크립트 이름이 남지 않는다.
    # 실제로 보이는 것은 main 클래스 이름이다. 3회차 검증에서 확인했다.
    pkill -f '[o]rg.apache.kafka.tools.ProducerPerformance' 2>/dev/null
    pkill -f '[r]km-consumer-churn' 2>/dev/null
    sleep 2
    rm -f "$STATE"
    echo "정리했다. 로그는 $LOGDIR/rkm-consumer-*.log 에 남겨 둔다."
    echo
    echo "Topic 을 지우려면 아래를 직접 친다. 되돌릴 수 없다."
    echo "  $KDIR/kafka-topics.sh --bootstrap-server $(bootstrap) --delete --topic $TOPIC"
    ;;

  inject)
    [ -f "$STATE" ] && die "이미 돌고 있다. --restore 로 정리한 뒤 다시 돌린다."
    bs="$(bootstrap)"

    echo "── Topic 준비 ──"
    "$KDIR/kafka-topics.sh" --bootstrap-server "$bs" --create --if-not-exists \
      --topic "$TOPIC" --partitions "$PARTITIONS" --replication-factor 3 \
      --config min.insync.replicas=2 >/dev/null 2>&1
    "$KDIR/kafka-topics.sh" --bootstrap-server "$bs" --describe --topic "$TOPIC"

    echo
    echo "── 느린 Consumer $CONSUMERS 개를 띄운다 (max.poll.interval.ms=$POLL_MS) ──"
    # setsid 로 세션을 떼고 표준 입출력을 전부 파일로 돌린다. 이렇게 하지
    # 않으면 두 가지가 함께 깨진다. 백그라운드 작업이 터미널을 붙잡아
    # 스크립트가 프롬프트를 돌려주지 않고, SSH 를 끊으면 SIGHUP 이 Consumer
    # 까지 내려가 재현이 그 자리에서 멈춘다. 3회차 검증에서 둘 다 겪었다.
    for i in $(seq 1 "$CONSUMERS"); do
      # 출력을 느리게 읽는 파이프로 흘린다. 파이프가 막히면 poll 이 멈춘다.
      setsid nohup sh -c "
        '$KDIR/kafka-console-consumer.sh' --bootstrap-server '$bs' \
          --topic '$TOPIC' --group '$GROUP' \
          --consumer-property 'max.poll.interval.ms=$POLL_MS' \
          --consumer-property 'session.timeout.ms=10000' \
          --consumer-property 'heartbeat.interval.ms=3000' \
          --consumer-property 'max.poll.records=500' \
        | while IFS= read -r _; do sleep $SLOW_SEC; done
      " </dev/null >>"$LOGDIR/rkm-consumer-$i.log" 2>&1 &
      echo "  consumer-$i 시작. 로그 $LOGDIR/rkm-consumer-$i.log"
    done

    if [ "$CHURN" = "1" ]; then
      echo "  대안 A 켜짐. consumer-1 을 30초마다 죽였다 살린다."
      setsid nohup sh -c "
        while true; do
          sleep 30
          pkill -f '[k]afka-console-consumer' -n 2>/dev/null
        done
      " </dev/null >/dev/null 2>&1 &
      echo "$!" > "$LOGDIR/rkm-consumer-churn.pid"
    fi

    echo
    echo "── Producer 로 밀어 넣는다 (초당 $THROUGHPUT) ──"
    setsid nohup "$KDIR/kafka-producer-perf-test.sh" \
      --topic "$TOPIC" --num-records "$RECORDS" --record-size 512 \
      --throughput "$THROUGHPUT" \
      --producer-props "bootstrap.servers=$bs" "acks=all" \
      </dev/null > "$LOGDIR/rkm-producer.log" 2>&1 &

    date +%s > "$STATE"
    echo
    echo "Lag 이 오르기까지 잠시 걸린다. Grafana Kafka 대시보드를 본다."
    echo "정리는 --restore 로 한다."
    ;;

  *)
    die "쓰는 법은 파일 머리 주석에 있다."
    ;;
esac
