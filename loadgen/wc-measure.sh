#!/usr/bin/env bash
# Write Concern 세 조합의 소요 시간 측정.
#
# ops-1 에서 돌린다. PRIMARY 에 붙어 건별로 순차 삽입하고 조합마다 소요를 잰다.
#
#   MONGO_HOST=10.0.1.5 ./wc-measure.sh
#   WC_COUNT=5000 MONGO_HOST=10.0.1.5 ./wc-measure.sh
#
# 인증을 켠 뒤에는 계정을 함께 준다.
#
#   MONGO_HOST=10.0.1.5 MONGO_USER=admin MONGO_PASS=... ./wc-measure.sh
#
# ── 왜 건별로 넣는가 ────────────────────────────────────────────
# Write Concern 은 요청 하나에 한 번 적용된다. insertMany 로 1,000건을 한 번에
# 보내면 대기도 한 번뿐이라 세 조합의 값이 거의 같게 나온다. 건별로 넣어야
# 대기 비용이 건수만큼 쌓여 차이가 보인다. 그래서 이 방식을 스크립트가 고정한다.
#
# ── 세 조합을 이렇게 고른 이유 ──────────────────────────────────
# 기본 설정에서 w:majority 는 j:true 를 함의한다. 그래서 w:majority 와
# w:majority + j:true 를 나란히 재면 같은 설정을 두 번 재는 셈이 된다.
# 아래 세 조합은 1번과 2번의 차이가 저널 비용, 2번과 3번의 차이가 복제 비용이라
# 각 증가분의 정체가 분명하다.
#
# ── 컬렉션 ─────────────────────────────────────────────────────
# 조합마다 다른 컬렉션에 넣는다. 앞 조합이 만든 인덱스나 문서가 뒤에 영향을
# 주지 않게 한다. 돌릴 때마다 지우고 시작한다.
set -uo pipefail

COUNT="${WC_COUNT:-1000}"
HOST="${MONGO_HOST:?MONGO_HOST 를 지정한다. 현재 PRIMARY 여야 한다. 예: MONGO_HOST=10.0.1.5}"
PORT="${MONGO_PORT:-27017}"
DB="${MONGO_DB:-lab}"
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

JS="$(mktemp)"
trap 'rm -f "$JS"' EXIT

cat > "$JS" <<JSEOF
const COUNT = ${COUNT};

const isPrimary = db.hello().isWritablePrimary;
if (!isPrimary) {
  print("이 노드는 PRIMARY 가 아니다. rs.status() 로 현재 PRIMARY 를 확인하고");
  print("MONGO_HOST 를 그 노드로 지정한다.");
  quit(1);
}

const CASES = [
  { name: "w:1",           wc: { w: 1 },                              waits: "없음" },
  { name: "w:1, j:true",   wc: { w: 1, j: true, wtimeout: 5000 },     waits: "PRIMARY 의 저널 기록" },
  { name: "w:majority",    wc: { w: "majority", wtimeout: 5000 },     waits: "과반의 저널 기록과 복제 왕복" }
];

print("");
print("== Write Concern 세 조합 측정 ==");
print("");
print("조합마다 " + COUNT + "건을 건별로 순차 삽입하고 소요를 잽니다.");
print("한 번에 넣지 않는 이유는 Write Concern 이 요청 하나에 한 번만 적용되기 때문입니다.");
print("");

const results = [];
for (const c of CASES) {
  const coll = db.getCollection("wc_measure_" + results.length);
  coll.drop();
  print("[" + (results.length + 1) + "/3] " + c.name + " 으로 " + COUNT + "건 삽입");
  print("      추가로 기다리는 것: " + c.waits);
  const started = new Date();
  let failed = 0;
  for (let i = 0; i < COUNT; i++) {
    try {
      coll.insertOne({ i: i }, { writeConcern: c.wc });
    } catch (e) {
      failed++;
    }
  }
  const sec = (new Date() - started) / 1000;
  results.push({ name: c.name, waits: c.waits, sec: sec, failed: failed });
  print("      " + sec.toFixed(1) + "초" + (failed ? "  (실패 " + failed + "건)" : ""));
  print("");
}

print("== 결과 ==");
print("");
// padEnd 는 글자 수로 세는데 한글은 터미널에서 두 칸을 차지한다. 그래서 한글이
// 섞인 열은 그대로 두면 어긋난다. 화면 폭 기준으로 채운다.
const width = (t) => [...t].reduce((n, ch) => n + (ch.charCodeAt(0) > 0x1100 ? 2 : 1), 0);
const pad = (t, w) => t + " ".repeat(Math.max(1, w - width(t)));

print("  " + pad("설정", 16) + pad("추가로 기다리는 것", 34) + "소요");
for (const r of results) {
  print("  " + pad(r.name, 16) + pad(r.waits, 34) + r.sec.toFixed(1) + "초");
}
print("");

const d1 = results[1].sec - results[0].sec;
const d2 = results[2].sec - results[1].sec;
print("  1번과 2번의 차이 " + d1.toFixed(1) + "초가 저널 비용입니다.");
print("  2번과 3번의 차이 " + d2.toFixed(1) + "초가 복제 비용입니다.");
print("");
if (!(results[0].sec <= results[1].sec && results[1].sec <= results[2].sec)) {
  print("  순서가 뒤집혔습니다. 건수가 적어 측정 오차에 묻힌 것입니다.");
  print("  WC_COUNT 를 늘려 다시 돌립니다.");
} else if (d1 < 0.3 && d2 < 0.3) {
  print("  차이가 뚜렷하지 않습니다. WC_COUNT 를 늘려 다시 돌립니다.");
} else {
  print("  세 값을 기록합니다.");
}
print("");
JSEOF

mongosh "mongodb://${HOST}:${PORT}/${DB}" --quiet "${AUTH_ARGS[@]}" --file "$JS"
