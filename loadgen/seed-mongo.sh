#!/usr/bin/env bash
# 실습용 문서 적재.
#
# ops-1 에서 돌린다. 부하를 주는 쪽과 받는 쪽을 분리한다.
#
#   MONGO_HOST=10.0.1.5 ./seed-mongo.sh                 lab.orders 에 200,000건
#   MONGO_HOST=10.0.1.5 ./seed-mongo.sh 50000           건수 지정
#   MONGO_HOST=10.0.1.5 ./seed-mongo.sh 50000 events    컬렉션 이름 지정
#   MONGO_DB=shop MONGO_HOST=10.0.1.5 ./seed-mongo.sh   데이터베이스 지정
#   SEED_DROP=1 MONGO_HOST=10.0.1.5 ./seed-mongo.sh     적재 전에 컬렉션을 지운다
#
# 인증을 켠 뒤에는 계정을 함께 준다.
#
#   MONGO_HOST=10.0.1.5 MONGO_USER=admin MONGO_PASS=... ./seed-mongo.sh
#
# ── 어느 실습에서 쓰는가 ────────────────────────────────────────
# 저장 구조 확인, 캐시 확인, 인덱스 실습이 같은 컬렉션을 쓴다. 세 번 다 이 스크립트로
# 만든다. 수강생이 문서를 직접 지어내지 않는다.
#
# ── 문서 구조가 인덱스 실습을 정한다 ────────────────────────────
# status · amount · createdAt 세 필드가 ESR 예시의 조회 조건이다.
#   status 가 refunded 이고 amount 가 90000 이상인 주문을 createdAt 내림차순으로 조회
# 이 조회에 맞는 인덱스가 { status: 1, createdAt: -1, amount: 1 } 이다.
# 필드 이름을 바꾸면 인덱스 실습의 조회 조건과 예시 인덱스가 이 데이터와 어긋난다.
#
# ── 조회 조건이 refunded 인 이유 ────────────────────────────────
# paid 는 전체의 절반이라 인덱스를 걸어도 검사 건수가 절반으로만 준다.
# refunded 는 6분의 1이고 amount 90000 이상이 10분의 1이라, 20만 건에서 약 3,300건이
# 남는다. COLLSCAN 20만 대 IXSCAN 3.3만의 대비가 화면에서 보인다.
#
# ── customerId 가 Shard Key 다 ─────────────────────────────────
# 값이 5,000 가지라 카디널리티가 있고 단조 증가가 아니다. 챕터 12 에서 이 필드로
# 컬렉션을 나눈다. 가짓수를 줄이면 Chunk 가 더 쪼개지지 않는다.
#
# ── 값을 무작위로 만들지 않는 이유 ──────────────────────────────
# 수강생 전원이 같은 데이터를 봐야 explain() 출력을 서로 대조할 수 있다.
# 그래서 순번에서 값을 계산한다. 같은 인자로 돌리면 같은 데이터가 나온다.
#
# ── 삭제는 기본 동작이 아니다 ───────────────────────────────────
# SEED_DROP=1 을 줄 때만 컬렉션을 지운다. 두 번 돌리면 그만큼 문서가 늘어난다.
set -uo pipefail

COUNT="${1:-200000}"
COLL="${2:-orders}"
HOST="${MONGO_HOST:?MONGO_HOST 를 지정한다. 예: MONGO_HOST=10.0.1.5}"
PORT="${MONGO_PORT:-27017}"
DB="${MONGO_DB:-lab}"
BATCH="${SEED_BATCH:-1000}"
DROP="${SEED_DROP:-0}"
USER="${MONGO_USER:-}"
PASS="${MONGO_PASS:-}"
AUTHDB="${MONGO_AUTHDB:-admin}"

if ! command -v mongosh >/dev/null 2>&1; then
  echo "mongosh 가 없다. ops 노드에서 실행하고 있는지 확인한다."
  exit 1
fi

if [ "$DROP" = "1" ]; then
  echo "주의: ${DB}.${COLL} 을 지우고 적재한다. 되돌릴 수 없다."
fi

JS="$(mktemp)"
trap 'rm -f "$JS"' EXIT

cat > "$JS" <<JSEOF
const COUNT = ${COUNT};
const BATCH = ${BATCH};
const COLL  = "${COLL}";
const DROP  = ${DROP};

const coll = db.getCollection(COLL);
if (DROP === 1) {
  coll.drop();
}

// paid 가 절반, refunded 가 6분의 1이다. 인덱스 실습의 조회 조건이 refunded 라
// 걸러 내는 비율이 커서 COLLSCAN 과 IXSCAN 의 차이가 화면에 드러난다.
const STATUS = ["paid", "paid", "paid", "pending", "cancelled", "refunded"];
const REGION = ["seoul", "busan", "daegu", "gwangju"];
const DAY = 86400000;
const base = Date.now();

let done = 0;
const started = new Date();

while (done < COUNT) {
  const n = Math.min(BATCH, COUNT - done);
  const docs = [];
  for (let i = 0; i < n; i++) {
    const seq = done + i;
    docs.push({
      customerId: "C" + String(seq % 5000).padStart(6, "0"),
      status:     STATUS[seq % STATUS.length],
      amount:     (seq * 7919) % 100000,
      createdAt:  new Date(base - ((seq * 37) % 90) * DAY - (seq % 86400) * 1000),
      region:     REGION[seq % REGION.length],
      items:      1 + (seq % 5),
      note:       "order " + seq + " placed by customer " + (seq % 5000) +
                  " via channel " + (seq % 17)
    });
  }
  coll.insertMany(docs, { ordered: false });
  done += n;
  if (done % 50000 === 0) {
    print("  " + done + " / " + COUNT);
  }
}

const elapsed = (new Date() - started) / 1000;

// 체크포인트를 강제한 뒤에 stats() 를 읽는다.
//
// WiredTiger 는 60초마다 체크포인트를 돌린다. 적재가 끝난 직후에 읽으면 아직
// 디스크로 내려간 것이 없어 storageSize 가 4096, 즉 페이지 하나로 나온다.
// 그 값으로 size 와의 비를 내면 압축률이 9000배가 되어 버린다.
//
// 1회차 검증에서 실제로 그렇게 나왔다. fsync 뒤에는 10.7 MB 가 나온다.
db.adminCommand({ fsync: 1 });

const s = coll.stats();

print("----");
print("적재 " + done + "건, 소요 " + elapsed.toFixed(1) + "초, 초당 " +
      Math.round(done / (elapsed > 0 ? elapsed : 0.001)) + "건");
print("----");
print("count           " + s.count);
print("size            " + s.size);
print("storageSize     " + s.storageSize);
print("totalIndexSize  " + s.totalIndexSize);
print("nindexes        " + s.nindexes);
JSEOF

AUTH_ARGS=()
if [ -n "$USER" ]; then
  AUTH_ARGS=(-u "$USER" -p "$PASS" --authenticationDatabase "$AUTHDB")
fi

echo "적재 시작: ${DB}.${COLL} 에 ${COUNT}건 (묶음 ${BATCH}건)"
mongosh "mongodb://${HOST}:${PORT}/${DB}" --quiet "${AUTH_ARGS[@]}" --file "$JS"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "----"
  echo "적재가 끝나지 않았다. 아래 둘을 확인한다."
  echo "  1. PRIMARY 에 접속했는가. rs.status() 로 현재 PRIMARY 를 확인하고"
  echo "     MONGO_HOST 를 그 노드로 지정한다."
  echo "  2. 인증을 켠 뒤라면 MONGO_USER 와 MONGO_PASS 를 함께 준다."
  exit "$rc"
fi

echo "----"
echo "size 와 storageSize 를 기록해 둔다. 두 값의 비가 압축률이다."
