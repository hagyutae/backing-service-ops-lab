#!/usr/bin/env bash
# 과반 상실 재현.
#
# ops-1 의 ~/ansible 에서 돌린다. 인벤토리가 거기 있어야 ansible 이 노드를 찾는다.
#
#   MONGO_HOST=10.0.1.5 ~/loadgen/wc-majority-loss.sh
#
# 인증을 켠 뒤에는 계정을 함께 준다.
#
#   MONGO_HOST=10.0.1.5 MONGO_USER=admin MONGO_PASS=... ~/loadgen/wc-majority-loss.sh
#
# ── 무엇을 재현하는가 ───────────────────────────────────────────
# 3멤버에서 투표 가능 멤버의 과반은 2다. SECONDARY 두 대를 차례로 내려 1대만
# 남기면 과반이 깨진다. 그 뒤 두 가지가 차례로 일어난다.
#   (1) 남은 노드는 아직 PRIMARY 라 쓰기를 받지만 과반을 확인하지 못해 wtimeout
#   (2) electionTimeoutMillis 가 지나면 스스로 강등되어 not primary
#
# ── 왜 스크립트가 하는가 ────────────────────────────────────────
# (1)과 (2) 사이가 십 초 안팎이다. 손으로 명령을 치고 결과를 읽는 사이에
# 지나간다. 스크립트가 쓰기를 계속 던져 놓은 채로 노드를 내리므로 두 전환점이
# 시각과 함께 한 화면에 남는다.
#
# ── PRIMARY 를 내리지 않는다 ────────────────────────────────────
# PRIMARY 를 내리면 그냥 선출 실습이 된다. PRIMARY 는 살아 있는데 쓰기가 안 되는
# 상태를 보는 것이 이 실습이다.
#
# ── 정상 종료가 아니라 SIGKILL 로 내린다 ────────────────────────
# systemd 의 정상 종료는 mongod 가 종료 전에 체크포인트를 돌려서 16초 넘게 걸린다.
# 1회차 검증에서 그 시간 때문에 두 번째 노드가 실제로 내려가기 전에 쓰기 루프가
# 끝나 과반 상실이 재현되지 않았다.
#
# 시간 문제만은 아니다. 과반을 잃는 상황은 계획된 점검이 아니라 노드가 죽는 것이다.
# SIGKILL 이 그 상황에 맞고 0.7초에 끝난다. 되살릴 때는 저널로 복구되어
# 1초 안에 SECONDARY 로 돌아온다.
#
# ── 노드 이름 ──────────────────────────────────────────────────
# rs.status() 는 10.0.1.6:27017 처럼 IP 를 돌려주는데 ansible 은 mongo-2 라는
# 이름을 쓴다. terraform/02-mongodb/main.tf 가 mongo-1·mongo-2·mongo-3 의 사설
# IP 를 10.0.1.5·10.0.1.6·10.0.1.7 로 고정하므로 마지막 옥텟으로 매핑한다.
#
# ── ansible 호출에 < /dev/null 을 붙인다 ────────────────────────
# 쓰기 루프를 백그라운드 파이프라인으로 띄우면 셸의 stdin 이 논블로킹이 된다.
# 그 뒤의 ansible 은 전부 아래 오류로 거부된다.
#
#   ERROR: Ansible requires blocking IO on stdin/stdout/stderr.
#          Non-blocking file handles detected: <stdin>
#
# 1회차 검증에서 이것 때문에 노드가 한 대도 내려가지 않았고, 출력을 /dev/null 로
# 보내고 있어서 화면에는 쓰기가 계속 성공하는 것으로만 보였다.
#
# ── 되살리기는 보장한다 ─────────────────────────────────────────
# 두 노드를 내린 채로 끝나면 다음 챕터가 전부 막힌다. trap 으로 어떤 경로로
# 끝나든 되살린다.
set -uo pipefail

HOST="${MONGO_HOST:?MONGO_HOST 를 지정한다. 현재 PRIMARY 여야 한다. 예: MONGO_HOST=10.0.1.5}"
PORT="${MONGO_PORT:-27017}"
DB="${MONGO_DB:-lab}"
USER="${MONGO_USER:-}"
PASS="${MONGO_PASS:-}"
AUTHDB="${MONGO_AUTHDB:-admin}"

# 두 번째 정지 뒤에 (1) wtimeout 과 (2) 강등을 모두 볼 수 있어야 한다.
# electionTimeoutMillis 기본값이 10초라 STOP2_AT 이후로 20초 넘게 남긴다.
STOP1_AT="${WC_STOP1_AT:-5}"
STOP2_AT="${WC_STOP2_AT:-15}"
DURATION="${WC_DURATION:-45}"

for c in mongosh ansible; do
  command -v "$c" >/dev/null 2>&1 || { echo "$c 가 없다. ops 노드에서 실행하고 있는지 확인한다."; exit 1; }
done

AUTH_ARGS=()
if [ -n "$USER" ]; then
  AUTH_ARGS=(-u "$USER" -p "$PASS" --authenticationDatabase "$AUTHDB")
fi

mongo_eval() {
  mongosh "mongodb://${HOST}:${PORT}/${DB}?directConnection=true" \
    --quiet "${AUTH_ARGS[@]}" --eval "$1"
}

# IP 의 마지막 옥텟을 ansible 인벤토리의 노드 이름으로 바꾼다.
host_name() {
  case "${1##*.}" in
    5) echo "mongo-1" ;;
    6) echo "mongo-2" ;;
    7) echo "mongo-3" ;;
    *) echo "" ;;
  esac
}

STOPPED=()
restore() {
  [ ${#STOPPED[@]} -eq 0 ] && return
  echo ""
  echo "[4/4] 정지시킨 노드를 되살립니다."
  local list
  list=$(IFS=,; echo "${STOPPED[*]}")
  ansible "$list" -m systemd -a "name=mongod state=started" --become < /dev/null >/dev/null 2>&1
  echo "  $(date +%H:%M:%S)  -- ${list} 복구 --"
  echo ""
  # 노드가 뜬 뒤 선출이 끝나기까지 몇 초가 걸린다. 곧바로 조회하면 셋 다
  # SECONDARY 로 보여 「복구가 안 됐다」로 읽힌다. PRIMARY 가 설 때까지 기다린다.
  echo "  선출을 기다립니다."
  local i
  for i in $(seq 1 30); do
    if mongo_eval 'rs.status().members.some(m => m.stateStr === "PRIMARY")' 2>/dev/null | grep -q true; then
      break
    fi
    sleep 2
  done
  echo ""
  echo "  복구 확인"
  mongo_eval 'rs.status().members.forEach(m => print("    " + m.name + "  " + m.stateStr))'
}
trap restore EXIT

echo ""
echo "== 과반 상실 재현 =="
echo ""
echo "[준비] 현재 Replica Set 상태를 확인합니다."

STATUS=$(mongo_eval 'rs.status().members.forEach(m => print(m.name + " " + m.stateStr))')
echo "$STATUS" | sed 's/^/  /'

PRIMARY_IP=$(echo "$STATUS" | awk '$2=="PRIMARY"{split($1,a,":"); print a[1]}')
mapfile -t SEC_IPS < <(echo "$STATUS" | awk '$2=="SECONDARY"{split($1,a,":"); print a[1]}')

if [ -z "$PRIMARY_IP" ] || [ "${#SEC_IPS[@]}" -lt 2 ]; then
  echo ""
  echo "PRIMARY 1대와 SECONDARY 2대가 있어야 시작할 수 있다."
  echo "rs.status() 로 상태를 확인하고 세 멤버가 모두 정상인지 본다."
  exit 1
fi
if [ "$PRIMARY_IP" != "$HOST" ]; then
  echo ""
  echo "MONGO_HOST 가 현재 PRIMARY 가 아니다. 현재 PRIMARY 는 ${PRIMARY_IP} 다."
  echo "MONGO_HOST=${PRIMARY_IP} 로 다시 실행한다."
  exit 1
fi

SEC1=$(host_name "${SEC_IPS[0]}")
SEC2=$(host_name "${SEC_IPS[1]}")
if [ -z "$SEC1" ] || [ -z "$SEC2" ]; then
  echo ""
  echo "SECONDARY 의 IP 를 인벤토리 이름으로 바꾸지 못했다."
  echo "사설 IP 가 10.0.1.5·10.0.1.6·10.0.1.7 이 아니면 이 스크립트의 host_name 을 고친다."
  exit 1
fi

echo "  투표 가능 멤버 3대. 과반은 2대입니다."
echo ""
echo "[1/4] PRIMARY 에 1초마다 한 건씩 씁니다."
echo "      Write Concern 은 w:majority, wtimeout 3000 입니다."
echo "      과반 2대가 받아야 성공으로 돌아옵니다."
echo ""

LOG="$(mktemp)"
trap 'rm -f "$LOG"; restore' EXIT

LOOP_JS="$(mktemp)"
cat > "$LOOP_JS" <<JSEOF
const wc = { w: "majority", wtimeout: 3000 };
db.wc_loss.drop();
for (let i = 0; i < ${DURATION}; i++) {
  const t = new Date().toISOString().substr(11, 8);
  try {
    db.wc_loss.insertOne({ i: i }, { writeConcern: wc });
    print(t + "  OK");
  } catch (e) {
    print(t + "  " + (e.codeName || e.name || "ERROR"));
  }
  sleep(1000);
}
JSEOF

# sed 와 tee 는 tty 가 아니면 줄 단위로 흘리지 않고 모아 둔다. 그러면 쓰기 결과가
# 노드를 내리는 안내보다 뒤에 한꺼번에 찍혀서, 어느 시점에 무엇이 바뀌었는지가
# 화면에서 사라진다. 1회차 검증에서 실제로 그렇게 나왔다.
stdbuf -oL mongosh "mongodb://${HOST}:${PORT}/${DB}?directConnection=true" \
  --quiet "${AUTH_ARGS[@]}" --file "$LOOP_JS" | stdbuf -oL sed 's/^/  /' | tee "$LOG" &
LOOP_PID=$!

sleep "$STOP1_AT"
echo ""
echo "[2/4] SECONDARY 한 대(${SEC1})를 정지시킵니다."
echo "      살아 있는 투표 멤버가 2대가 됩니다. 과반 2를 아직 채우므로 쓰기는 계속 성공합니다."
if ! ansible "$SEC1" -b -m command -a "systemctl kill -s KILL mongod" < /dev/null > "$LOG.kill" 2>&1; then
  echo "  정지에 실패했습니다. 아래를 확인하고 다시 실행합니다."
  sed 's/^/    /' "$LOG.kill"
  exit 1
fi
STOPPED+=("$SEC1")
echo "  $(date +%H:%M:%S)  -- ${SEC1} 정지 --"

sleep $(( STOP2_AT - STOP1_AT ))
echo ""
echo "[3/4] 남은 SECONDARY(${SEC2})를 정지시킵니다."
echo "      살아 있는 투표 멤버가 1대가 되어 과반이 깨집니다. 두 가지가 차례로 일어납니다."
echo "        (1) 아직 PRIMARY 라 쓰기는 받지만 과반을 확인하지 못해 wtimeout"
echo "        (2) electionTimeoutMillis 가 지나면 스스로 SECONDARY 로 강등되어 not primary"
if ! ansible "$SEC2" -b -m command -a "systemctl kill -s KILL mongod" < /dev/null > "$LOG.kill" 2>&1; then
  echo "  정지에 실패했습니다. 아래를 확인하고 다시 실행합니다."
  sed 's/^/    /' "$LOG.kill"
  exit 1
fi
STOPPED+=("$SEC2")
echo "  $(date +%H:%M:%S)  -- ${SEC2} 정지 --"

wait "$LOOP_PID" 2>/dev/null

echo ""
echo "== 확인할 것 =="
echo ""
echo "  1. 두 오류가 순서대로 나왔는지"
echo "       과반을 못 채움    PRIMARY 는 아직 살아 있음"
echo "       PRIMARY 가 강등됨  쓰기를 받을 자격 자체가 없어짐"
echo ""
echo "  2. wtimeout 이 난 문서가 PRIMARY 에 남아 있는지"
echo "       오류는 「과반이 받았는지 확인 못 했다」이지 「쓰지 않았다」가 아닙니다."
echo "       mongosh \"mongodb://${HOST}:${PORT}/${DB}\" --eval 'db.wc_loss.countDocuments()'"
echo ""
echo "  3. 복구 뒤의 현재 PRIMARY"
echo "       이후 챕터의 --host 는 그 노드를 씁니다."
rm -f "$LOOP_JS"
