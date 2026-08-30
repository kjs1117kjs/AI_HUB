#!/bin/bash
# ============================================================================
# geoip_auto.sh — 월간 GeoIP 재적재 무인 실행 (DB 서버용, python 불필요)
#
#   다운로드 → 변환 → 대기 테이블 적재 → 게이트 5개 → 시노님 스위치
#   사용 도구: curl, unzip, awk(gawk), sort, sqlplus, sqlldr  (RHEL7 + Oracle 기본)
#
# 사용법:
#   ./geoip_auto.sh                : 전체 무인 실행 (게이트 전부 통과 시 스위치)
#   ./geoip_auto.sh --no-switch    : 적재·검증까지만 (첫 테스트용)
#   ./geoip_auto.sh --skip-download: 폴더의 기존 CSV 사용
#
# 안전 설계:
#   - 시노님 스위치 전의 모든 실패는 무해 (서비스는 기존 테이블로 계속 동작)
#   - 게이트: G1 건수하한 / G2 적재전 샘플판정 / G3 적재건수일치 / G4 기존×0.9 / G5 스위치전 리허설
#   - 실패 시 exit 1 + logs/auto_*_FAIL.log, 스위치 안 함
#   - 롤백: CREATE OR REPLACE SYNONYM TB_CM_GEOIP_RANGE FOR <이전 테이블>;
#
# 설정: 같은 폴더의 geoip.conf (chmod 600) — geoip.conf.example 참고
# ============================================================================

set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
CONF="$BASE/geoip.conf"

# ---------------------------------------------------------------- 옵션
NO_SWITCH=0; SKIP_DL=0
for a in "$@"; do
  case "$a" in
    --no-switch)     NO_SWITCH=1 ;;
    --skip-download) SKIP_DL=1 ;;
    *) echo "알 수 없는 옵션: $a"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 설정 로드
if [ ! -f "$CONF" ]; then
  echo "geoip.conf 가 없습니다 — geoip.conf.example 을 복사해 만들어 주세요."; exit 1
fi
# conf 항목: LICENSE_KEY / DB_USER / DB_PASS / ORACLE_HOME / ORACLE_SID / MIN_ROWS
. "$CONF"
: "${LICENSE_KEY:?conf에 LICENSE_KEY 필요}"
: "${DB_USER:?conf에 DB_USER 필요}"
: "${DB_PASS:?conf에 DB_PASS 필요}"
: "${ORACLE_HOME:?conf에 ORACLE_HOME 필요}"
: "${ORACLE_SID:?conf에 ORACLE_SID 필요}"
MIN_ROWS="${MIN_ROWS:-300000}"

export ORACLE_HOME ORACLE_SID
export PATH="$ORACLE_HOME/bin:$PATH"
export NLS_LANG="${NLS_LANG:-KOREAN_KOREA.AL32UTF8}"

WORK="$BASE"
LOGDIR="$WORK/logs"; mkdir -p "$LOGDIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$LOGDIR/auto_${TS}_RUN.log"
LOCK="$WORK/.geoip_auto.lock"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGFILE"; }

finish(){ # $1 = OK|FAIL|LOADED
  mv "$LOGFILE" "$LOGDIR/auto_${TS}_$1.log" 2>/dev/null
  rm -f "$LOCK"
}
die(){
  log "■ 중단: $*"
  log "■ 시노님은 변경되지 않았습니다. 서비스는 기존 테이블로 정상 동작합니다."
  finish FAIL
  exit 1
}

# ---------------------------------------------------------------- 중복 실행 방지
if [ -f "$LOCK" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK") ))
  if [ "$AGE" -lt 21600 ]; then
    echo "이미 실행 중입니다 (락 ${AGE}s 경과) — 종료"; exit 1
  fi
  echo "오래된 락 무시 (${AGE}s 경과)"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ---------------------------------------------------------------- sqlplus 헬퍼
run_sql(){ # 표준출력으로 결과, 오류 시 리턴코드 1
  sqlplus -s "$DB_USER/$DB_PASS" <<EOF
whenever sqlerror exit 1
set heading off feedback off pagesize 0 verify off echo off trimspool on linesize 200
$1
exit
EOF
}

log "=== GeoIP 무인 재적재 시작 (no_switch=$NO_SWITCH skip_download=$SKIP_DL) ==="

# DB 접속 사전 확인
PING="$(run_sql "SELECT 'DB_OK' FROM DUAL;")" || die "DB 접속 실패 — conf의 계정/ORACLE_SID 확인: $PING"
log "DB 접속 확인: $(echo "$PING" | tr -d '[:space:]')"

# ---------------------------------------------------------------- ① 다운로드
BLOCKS="$WORK/GeoLite2-Country-Blocks-IPv4.csv"
LOCS="$WORK/GeoLite2-Country-Locations-en.csv"

if [ "$SKIP_DL" -eq 1 ]; then
  log "① 다운로드 생략 — 폴더의 기존 CSV 사용"
  [ -f "$BLOCKS" ] || die "Blocks-IPv4.csv 없음"
  [ -f "$LOCS" ]   || die "Locations-en.csv 없음"
else
  log "① MaxMind GeoLite2-Country-CSV 다운로드..."
  ZIP="$WORK/GeoLite2-Country-CSV.zip"
  curl -fsSL --max-time 300 -o "$ZIP" \
    "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&license_key=${LICENSE_KEY}&suffix=zip" \
    || die "다운로드 실패 — 라이선스 키/네트워크 확인"
  log "   zip 저장 ($(stat -c %s "$ZIP") bytes)"
  rm -f "$BLOCKS" "$LOCS"
  unzip -o -j -q "$ZIP" "*Blocks-IPv4.csv" "*Locations-en.csv" -d "$WORK" \
    || die "압축 해제 실패"
  [ -f "$BLOCKS" ] && [ -f "$LOCS" ] || die "zip 안에 필요한 CSV 없음"
  log "   압축 해제 완료"
fi

# ---------------------------------------------------------------- ② 변환 + G1·G2
log "② CIDR → 숫자 변환 + 국가 조인 (awk)..."
DAT="$WORK/geoip_load.dat"

awk '
BEGIN { FPAT = "([^,]*)|(\"[^\"]*\")" }
FNR==1 { next }
FNR==NR {   # Locations-en: geoname_id, ..., country_iso_code(5), country_name(6)
  gid=$1; iso=$5; name=$6
  gsub(/"/,"",iso); gsub(/"/,"",name)
  CC[gid]=iso; CN[gid]=name
  next
}
{           # Blocks-IPv4: network(1), geoname_id(2), registered_country_geoname_id(3)
  gid = ($2 != "") ? $2 : $3
  if (gid=="" || !(gid in CC) || CC[gid]=="") next
  split($1, np, "/"); split(np[1], o, ".")
  start = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
  size = 2 ^ (32 - np[2])
  printf "%s|%d|%d|%s|%s\n", $1, start, start+size-1, CC[gid], CN[gid]
}' "$LOCS" "$BLOCKS" | sort -t'|' -k2,2n > "$DAT" || die "변환 실패"

CNT=$(wc -l < "$DAT")
log "   변환 완료: ${CNT}건"

# G1: 건수 하한
[ "$CNT" -ge "$MIN_ROWS" ] || die "G1 실패 — 변환 건수 $CNT < 하한 $MIN_ROWS"
log "   G1 통과 (>= $MIN_ROWS)"

# G2: 적재 전 로컬 샘플 판정
ip2num(){ echo "$1" | awk -F. '{print $1*16777216+$2*65536+$3*256+$4}'; }
local_cc(){ awk -F'|' -v v="$1" '$2<=v && $3>=v {print $4; exit}' "$DAT"; }
for pair in "223.62.180.1:KR" "8.8.8.8:US"; do
  IP="${pair%%:*}"; EXP="${pair##*:}"
  GOT="$(local_cc "$(ip2num "$IP")")"
  [ "$GOT" = "$EXP" ] || die "G2 실패 — $IP 기대 $EXP, 실제 '${GOT}' (데이터 이상)"
done
log "   G2 통과 (샘플 IP 국가 판정: KR/US 정상)"

# ---------------------------------------------------------------- ③ 활성/대기 판별 + sqlldr 적재 + G3
ACTIVE="$(run_sql "SELECT table_name FROM user_synonyms WHERE synonym_name='TB_CM_GEOIP_RANGE';" | tr -d '[:space:]')" \
  || die "시노님 조회 실패"
[ -n "$ACTIVE" ] || die "시노님 TB_CM_GEOIP_RANGE 없음"
case "$ACTIVE" in
  *_A) STANDBY="TB_CM_GEOIP_RANGE_B" ;;
  *_B) STANDBY="TB_CM_GEOIP_RANGE_A" ;;
  *)   die "활성 테이블명 형식 이상: $ACTIVE" ;;
esac
log "③ 현재 활성: $ACTIVE / 대기(적재 대상): $STANDBY"

CTL="$WORK/geoip_load.ctl"
cat > "$CTL" <<EOF
LOAD DATA
CHARACTERSET UTF8
INFILE '$DAT'
TRUNCATE
INTO TABLE $STANDBY
FIELDS TERMINATED BY '|'
TRAILING NULLCOLS
(NETWORK, START_IP_NUM, END_IP_NUM, COUNTRY_CODE, COUNTRY_NAME)
EOF

log "   sqlldr 적재 (conventional path — 인덱스 유지)..."
sqlldr "$DB_USER/$DB_PASS" control="$CTL" log="$WORK/geoip_load.log" \
       bad="$WORK/geoip_load.bad" errors=0 rows=10000 silent=header,feedback \
       >> "$LOGFILE" 2>&1
RC=$?
[ "$RC" -eq 0 ] || die "sqlldr 실패 (rc=$RC) — geoip_load.log / geoip_load.bad 확인"

DB_CNT="$(run_sql "SELECT COUNT(*) FROM $STANDBY;" | tr -d '[:space:]')" || die "적재 건수 조회 실패"
[ "$DB_CNT" = "$CNT" ] || die "G3 실패 — DB $DB_CNT != 파일 $CNT"
log "   G3 통과 (DB 건수 일치: $DB_CNT)"

# ---------------------------------------------------------------- ④ G4 + 통계 + G5
OLD_CNT="$(run_sql "SELECT COUNT(*) FROM $ACTIVE;" | tr -d '[:space:]')" || die "기존 건수 조회 실패"
if [ "$OLD_CNT" -gt 0 ] && [ $((DB_CNT * 10)) -lt $((OLD_CNT * 9)) ]; then
  die "G4 실패 — 신규 $DB_CNT < 기존 $OLD_CNT × 0.9"
fi
log "④ G4 통과 (기존 $OLD_CNT → 신규 $DB_CNT)"

log "   DBMS_STATS 수집: $STANDBY ..."
run_sql "EXEC DBMS_STATS.GATHER_TABLE_STATS(ownname=>'${DB_USER}', tabname=>'${STANDBY}', cascade=>TRUE);" \
  >> "$LOGFILE" 2>&1 || die "통계수집 실패"
log "   통계수집 완료"

# G5: 대기 테이블 직접 샘플 판정 + 속도 (스위치 전 리허설)
for pair in "223.62.180.1:KR" "8.8.8.8:US"; do
  IP="${pair%%:*}"; EXP="${pair##*:}"
  OUT="$(sqlplus -s "$DB_USER/$DB_PASS" <<EOF
whenever sqlerror exit 1
set heading off feedback off pagesize 0 serveroutput on
DECLARE
  t0 NUMBER; cc VARCHAR2(10); v NUMBER := $(ip2num "$IP");
BEGIN
  t0 := DBMS_UTILITY.GET_TIME;
  BEGIN
    SELECT country_code INTO cc FROM (
      SELECT country_code, end_ip_num FROM $STANDBY
      WHERE start_ip_num <= v ORDER BY start_ip_num DESC
    ) WHERE ROWNUM = 1 AND end_ip_num >= v;
  EXCEPTION WHEN NO_DATA_FOUND THEN cc := 'NONE';
  END;
  DBMS_OUTPUT.PUT_LINE(cc || '|' || (DBMS_UTILITY.GET_TIME - t0));
END;
/
exit
EOF
)" || die "G5 실행 오류"
  GOT="$(echo "$OUT" | grep '|' | cut -d'|' -f1 | tr -d '[:space:]')"
  ELAPSED_CS="$(echo "$OUT" | grep '|' | cut -d'|' -f2 | tr -d '[:space:]')"
  [ "$GOT" = "$EXP" ] || die "G5 실패 — $STANDBY 에서 $IP 기대 $EXP, 실제 '$GOT'"
  [ "${ELAPSED_CS:-999}" -le 50 ] || die "G5 실패 — $IP 조회 ${ELAPSED_CS}cs (>0.5s, 통계/인덱스 확인)"
  log "   G5 $IP → $GOT (${ELAPSED_CS}0ms) OK"
done

# ---------------------------------------------------------------- ⑤ 스위치
if [ "$NO_SWITCH" -eq 1 ]; then
  log "--no-switch: 여기까지. 수동 스위치 SQL:"
  log "  CREATE OR REPLACE SYNONYM TB_CM_GEOIP_RANGE FOR $STANDBY;"
  finish LOADED
  trap - EXIT
  exit 0
fi

log "게이트 5개 전부 통과 — 스위치: $ACTIVE ($OLD_CNT) → $STANDBY ($DB_CNT)"
run_sql "CREATE OR REPLACE SYNONYM TB_CM_GEOIP_RANGE FOR $STANDBY;" >> "$LOGFILE" 2>&1 \
  || die "시노님 스위치 실패"
log "⑤ 시노님 스위치 완료 → $STANDBY"

# 스위치 후 확인
V1="$(run_sql "SELECT IS_KOREA_IP('223.62.180.1') || '/' || IS_KOREA_IP('8.8.8.8') FROM DUAL;" | tr -d '[:space:]')"
if [ "$V1" = "Y/N" ]; then
  log "   IS_KOREA_IP 동작 확인 (KR=Y / 8.8.8.8=N)"
else
  log "   ⚠ 스위치 후 판정 이상 ($V1) — 롤백 검토!"
  log "   롤백: CREATE OR REPLACE SYNONYM TB_CM_GEOIP_RANGE FOR $ACTIVE;"
fi
log "롤백이 필요하면: CREATE OR REPLACE SYNONYM TB_CM_GEOIP_RANGE FOR $ACTIVE;"
log "=== 완료 ==="
finish OK
trap - EXIT
exit 0
