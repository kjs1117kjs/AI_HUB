#!/bin/bash
umask 077
# =============================================
# FN_GET_MENU_CHK_YN / YN2 실시간 누적 모니터 + 두레이 + 백오피스 웹훅 동시 전송
# + 로그인 시도 실시간 모니터
# + 현재메뉴 불일치(_menu_check_err_) 모니터 (1분 주기 웹훅 → [메뉴권한체크분석] 탭)
#
# ▶ v2 구조 변경
#   · 로그인 모니터를 catalina.out 직접 파싱으로 변경
#     (기존: LOGIN_CHK_LOG_*.OUT → FIFO → awk, 날짜 전환 루프 필요)
#     (변경: catalina.out → tail -F | awk, 메뉴권한체크와 동일한 tail 하나로 통합)
#   · 날짜 전환 루프 / FIFO / TAIL_PID / AWK_PID / LOGIN_AWK_FILE 전부 제거
#   · catalina.out은 rotate 없이 계속 append되므로 날짜 자정 전환 문제 없음
#   · 재시작 시 복잡한 파일 대기 로직 불필요
# ▶ v3 (2026-09-23) 조회건수 집계에 URL별 건수(URLD) 추가
#   · 사용자별 5분 메시지 마지막에 "| URLD:url=총/실,url=총/실" 필드 추가 (행 수·웹훅 호출 수 불변)
#   · YN 호출(URL 없음)은 NOURL, CHK_URL_MAX 초과분은 ETC 버킷 → 버킷 합 = D_TOT
# 실행: bash menu_chk_monitor_webhook.sh
# 종료: Ctrl+C
# =============================================

# ── catalina.out 로그 파일 ──
CATALINA_LOGS=(
    "/usr/local/tomcat-8.0.47-neo1/logs/catalina.out"
    "/usr/local/tomcat-8.0.47-neo2/logs/catalina.out"
)

# ── 메뉴권한체크 설정 ──
THRESHOLD=200       # 10분 슬라이딩 윈도우 임계치
TOP_N=10            # 터미널 표시 최대 아이디 수
WINDOW_SEC=600      # 슬라이딩 윈도우 (10분)
ALERT_COOL=300      # 같은 아이디 재알림 쿨타임 (5분)

# ── 로그인 설정 ──
LOGIN_THRESHOLD=100   # 당일 누적 강조 임계치
LOGIN_SEND_SEC=60     # 웹훅 전송 주기 (1분)
LOGIN_DOORAY_COOL=300 # 두레이 재알림 쿨타임 (초)

# ══════════════════════════════════════════════════════════════════
# ── USER_ID 별 조회건수 집계 설정 ──
#   "메뉴권한체크(FN_GET_MENU_CHK_YN / YN2) 호출 = 조회 1건" 으로 간주하고
#   로그인 시도 집계와 동일하게 "일자 + USER_ID" 기준 당일 누적으로 쌓는다.
#     · 총건수(TOT)  : 메뉴권한체크 호출 전체
#     · 예외건수(EXC): 아래 제외 URL(메인/콤보/트리 등 화면 진입 부수 호출)에 해당하는 건
#     · 실건수(REAL) : 총건수 - 예외건수  ← 실제 사용자가 "조회" 한 것으로 보는 수치
#   전송: 웹훅만 (두레이 알림 없음) → TB_MONITOR_ALARM 누적
#   ALARM_TITLE : "[서버] 조회건수 집계"
#   ALARM_MSG   : COLLECT_DT:.. | SEND_DT:.. | DATE:yyyymmdd | USER:.. |
#                 TOT:n | EXC:n | REAL:n | D_TOT:n | D_EXC:n | D_REAL:n |
#                 YN:n | YN2:n | IP:마지막IP | IP_CNT:당일IP종류수 | IPS:구간IP목록 |
#                 IPD:ip=총건수/실건수,ip=총건수/실건수 | FIRST:.. | LAST:.. | WIN:초 |
#                 URLD:url=총건수/실건수,url=총건수/실건수
#   IPD  버킷 규칙: IP 파라미터가 없는 YN 호출은 "NOIP", 서로 다른 IP 가 CHK_IP_MAX 를
#                  넘으면 초과분은 "ETC" 로 합산 → 버킷 건수의 합 = D_TOT (항상 정합)
#   URLD 버킷 규칙: URL 이 없는 YN 호출은 "NOURL", 서로 다른 URL 이 CHK_URL_MAX 를
#                  넘으면 초과분은 "ETC" 로 합산 → 버킷 건수의 합 = D_TOT (항상 정합)
#                  URL 은 쿼리스트링·스킴/호스트 제거 후 집계. 예외 URL 도 총건수엔 포함(실건수 0)
#   ※ TOT/EXC/REAL = 당일 누적(프로세스 기동 이후), D_* = 직전 전송 이후 증가분.
#     쿼리에서는 D_* 합계를 쓰는 것이 재기동/멀티 WAS 에도 안전하다.
CHK_SEND_SEC=300     # 웹훅 전송 주기 (초) — 기본 5분. 로그인(1분)보다 길게 잡아 알람테이블 폭증 방지
CHK_MIN_DELTA=1      # 직전 전송 이후 증가분이 이 값 미만이면 전송 생략 (0건 유저 재전송 방지)
CHK_IP_MAX=10        # IPS/IPD 에 개별 표기할 최대 IP 개수 (초과분은 "ETC" 버킷으로 합산)
CHK_URL_MAX=20       # URLD 에 개별 표기할 최대 URL 개수 (초과분은 "ETC" 버킷으로 합산)
                     #   URL 1개 ≈ 60~80자 → 20개면 약 1,400자. ALARM_MSG 가 VARCHAR2(4000)이면 여유.

# 제외 URL — ① 완전일치 목록
#   ※ 원문 요건의 "AND URL IN (...) AND URL LIKE ..." 는 동시 만족이 불가능하므로
#     OR 조건(= 목록 중 하나라도 일치하면 예외)으로 해석해 구현함.
#   ※ etc050_01.jsp 의 CHK_EXC_EQ / CHK_EXC_PRE 와 반드시 동일하게 유지할 것
CHK_EXC_URL_EQ_LIST=(
    "/main.sb"
    "/popup/getProdClassTree.sb"
    "/common/getComboData.sb"
    "/mobile/menu/menuList.sb"
    "/mobile/main.sb"
    "/adi/sms/sendStatus/cmmMainTopSmsSend/getCmmMainTopStoreCount.sb"
    "/store/manage/storeManage/storeManage/getHqNmcodeComboList.sb"
    "/common/getDeployNoticeStatus.sb"
    "/sale/moms/prodSaleDayStoreMoms/prodSaleDayStoreMoms/getDivisionExcelDownloadSaveUpdate.sb"
)
# 제외 URL — ② 앞자리 일치(LIKE 'xxx%') 목록
CHK_EXC_URL_PREFIX_LIST=(
    "/application/main"
    "/sale/main/mainContext"
    "/base/prod"
    "/mobile/application/main"
    "/common/popup/selectStore"
)
# 배열 → 콤마 결합 문자열 (awk 전달용)
CHK_EXC_URL_EQ="$(IFS=,; printf '%s' "${CHK_EXC_URL_EQ_LIST[*]}")"
CHK_EXC_URL_PRE="$(IFS=,; printf '%s' "${CHK_EXC_URL_PREFIX_LIST[*]}")"
# ══════════════════════════════════════════════════════════════════

# ── Oracle 오류(ORA-xxxxx) 감시 설정 ──
#   대상: catalina.out 안의 예외 스택트레이스에 포함된 ORA-xxxxx (대소문자 무관)
#   블록 단위로 첫 ORA- 1건만 채택 (같은 예외가 Cause/nested 등으로 3~4회 반복 출력되므로 중복 제거)
#   전송: 즉시(실시간) — 단, 같은 (코드+아이디) 조합은 쿨타임 내 재알림 안 함
ORAERR_COOL=60   # 같은 오류(코드+아이디) 재알림 쿨타임 (초)
OOM_COOL=300     # 같은 WAS+오류 유형 재알림 쿨타임 (초)

# ── 현재메뉴 불일치(_menu_check_err_) 감시 설정 ──
#   대상 로그 라인 2종:
#     _menu_check_err_<user>,<YYYYMMDDHHMMSS>,접근URL:<url>      (최근접속메뉴와 현재메뉴 불일치)
#     _menu_check_err_<user>,<YYYYMMDDHHMMSS>,accessMenu:<url>   (메뉴 접근 없이 조회)
#   전송 조건: 사용자 아이디가 MENUERR_USER_ID_LIST 에 포함되면 전송 (URL은 더 이상 필터링하지 않음)
#   전송 주기: 로그인 집계와 동일 타이머(LOGIN_SEND_SEC) — 1분마다 변경분만 웹훅
#   화면 표시: etc050.jsp [메뉴권한체크분석] 탭 (IP 칼럼에 "현재메뉴 불일치" 표기)
#   ※ 대상 추가 시 아래 배열에 한 줄씩 추가 (콤마 불필요, 줄 끝 주석 가능)
MENUERR_USER_ID_LIST=(
    "h0268"
    "kjsun1117"
)
# ※ URL 필터는 더 이상 사용하지 않음 (아이디만으로 전송 여부 판단).
#    배열을 비워두면 URL 조건 없이 해당 아이디의 모든 URL이 집계된다.
MENUERR_URL_LIST=(
)

# 배열 → 콤마 결합 문자열 (awk 전달용 — awk 쪽 수정 불필요)
MENUERR_USER_IDS="$(IFS=,; printf '%s' "${MENUERR_USER_ID_LIST[*]}")"
MENUERR_URLS="$(IFS=,; printf '%s' "${MENUERR_URL_LIST[*]}")"

# ── 두레이 설정 ──
DOORAY_URL="https://nhnent.dooray.com/services/3898710244970049535/4356913320965840727/ShLIdsWTRVmGjMN-MSeepA"
DOORAY_URL_ER="https://nhnent.dooray.com/services/3898710244970049535/4335148166583900561/2xPSDFQITm-GJ8_Jru-yuw"

# ── 백오피스 웹훅 설정 ──
WEBHOOK_URL="http://localhost:22001/mobile/etc/api/webhook.jsp"
WEBHOOK_TOKEN='S_SECRET_TOKEN_2026_!ABCD'
SERVER_NM=$(hostname)

# ── 감시 가능한 catalina 로그만 추출 ──
EXIST_LOGS=()
for LG in "${CATALINA_LOGS[@]}"; do
    [ -f "$LG" ] && EXIST_LOGS+=("$LG")
done

if [ ${#EXIST_LOGS[@]} -eq 0 ]; then
    echo "[오류] 감시 가능한 catalina 로그파일 없음"
    exit 1
fi

# ── 로그인 당일 누적 복원용 시드 파일 목록 ──
#   재시작/자정전환 시 tail -F 는 파일 끝부터 읽으므로 그날 이전 누적이 사라진다.
#   AuthController 가 카탈리나와 별도로 계속 쓰는 LOGIN_CHK_LOG_YYYYMMDD.OUT(당일 파일)을
#   기동 시 한 번 훑어 login_cnt 를 복원한다. 파일이 없어도(=오늘 로그인 0) 조용히 건너뜀.
TODAY_YMD=$(date +%Y%m%d)
LOGIN_SEED_FILES=()
for LG in "${EXIST_LOGS[@]}"; do
    SEEDF="$(dirname "$LG")/LOGIN_CHK_LOG_${TODAY_YMD}.OUT"
    [ -f "$SEEDF" ] && LOGIN_SEED_FILES+=("$SEEDF")
done
# 콜론(:)으로 결합 — 하나도 없으면 빈 문자열(awk 쪽에서 안전 처리)
SEED_LIST="$(IFS=:; printf '%s' "${LOGIN_SEED_FILES[*]}")"

echo "[시작] 서버: ${SERVER_NM}"
echo "[메뉴권한체크] 임계치: ${THRESHOLD}회 | 윈도우: $((WINDOW_SEC/60))분 | 쿨타임: $((ALERT_COOL/60))분"
echo "[로그인] 임계치(강조): ${LOGIN_THRESHOLD}건 | 전송주기: $((LOGIN_SEND_SEC/60))분 | 과다시도 두레이 알림: 미전송(웹훅만)"
echo "[현재메뉴불일치] 대상ID: ${MENUERR_USER_IDS} | 전송조건: 아이디매칭(URL무관) | 전송주기: $((LOGIN_SEND_SEC/60))분"
echo "[조회건수] 기준: 메뉴권한체크(YN/YN2) 호출 | 일자+USER_ID 당일누적 | 전송주기: $((CHK_SEND_SEC/60))분 | 최소증가분: ${CHK_MIN_DELTA}건 | 제외URL: 완전일치 ${#CHK_EXC_URL_EQ_LIST[@]}개 / 앞자리일치 ${#CHK_EXC_URL_PREFIX_LIST[@]}개 | IP표기: 최대 ${CHK_IP_MAX}개 | URL표기: 최대 ${CHK_URL_MAX}개 | 알림: 웹훅만(두레이 미전송)"
echo "[Oracle오류] 패턴: ORA-nnnnn(대소문자무관) | 전송: 즉시(블록당 1건) | 쿨타임: ${ORAERR_COOL}초 | Login Blocked: Security Violation → 두레이 제외(웹훅만)"
echo "[로그파일] ${EXIST_LOGS[*]}"
echo "[로그인시드] ${#LOGIN_SEED_FILES[@]}개 파일: ${LOGIN_SEED_FILES[*]:-(없음, 0부터 시작)}"

# ── 두레이 전송 함수 (일반) ──
send_dooray() {
    local text="$1"
    curl -s -X POST "$DOORAY_URL" \
         -H "Content-Type: application/json" \
         -d "{\"botName\":\"MenuChkBot\",\"text\":\"${text}\"}" > /dev/null &
}

# ── 두레이 전송 함수 (에러용) ──
send_dooray_er() {
    local text="$1"
    curl -s -X POST "$DOORAY_URL_ER" \
         -H "Content-Type: application/json" \
         -d "{\"botName\":\"MenuChkBot\",\"text\":\"${text}\"}" > /dev/null &
}

# ── 백오피스 웹훅 전송 함수 ──
send_webhook() {
    local title="$1"
    local msg="$2"
    curl -s --connect-timeout 10 --max-time 15 \
         "$WEBHOOK_URL" \
         -H "X-Webhook-Token: $WEBHOOK_TOKEN" \
         --data-urlencode "alarm_title=${title}" \
         --data-urlencode "alarm_msg=${msg}" \
         --data-urlencode "src_system=${SERVER_NM}" > /dev/null &
}

export -f send_dooray
export -f send_dooray_er
export -f send_webhook
export DOORAY_URL DOORAY_URL_ER WEBHOOK_URL WEBHOOK_TOKEN SERVER_NM
WEBHOOK_LOGFILE="${WEBHOOK_LOGFILE:-/dev/null}"
export WEBHOOK_LOGFILE

# ── 웹훅 로그 파일을 날짜별로 자동 분리 ──
#   기존: WEBHOOK_LOGFILE(고정 경로)을 프로세스 시작 시 1회 캡처 → 자정이 지나도
#         재시작 전까지 계속 어제 파일에 기록됨(그래서 매일 00:40 재시작으로 굴려왔음).
#   변경: "디렉터리 + 접두어"만 넘기고, 실제 파일명은 awk 내부에서 기록할 때마다
#         오늘 날짜(strftime)로 생성 → 재시작 없이 자정에 자동으로 새 파일로 넘어감.
#   로그 디렉터리 우선순위:
#     1) WEBHOOK_LOG_DIR (명시)  2) 기존 WEBHOOK_LOGFILE의 디렉터리(하위호환)  3) 스크립트 위치
if [ -n "$WEBHOOK_LOG_DIR" ]; then
    _WH_LOG_DIR="$WEBHOOK_LOG_DIR"
elif [ -n "$WEBHOOK_LOGFILE" ] && [ "$WEBHOOK_LOGFILE" != "/dev/null" ]; then
    _WH_LOG_DIR="$(dirname "$WEBHOOK_LOGFILE")"
else
    _WH_LOG_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
_WH_LOG_PREFIX="${WEBHOOK_LOG_PREFIX:-webhook_monitor_}"
echo "[웹훅로그] 디렉터리: ${_WH_LOG_DIR} | 파일: ${_WH_LOG_PREFIX}YYYYMMDD.log (날짜 자동 전환)"

# ══════════════════════════════════════════════════════════════════
# [통합] 메뉴권한체크 + 로그인시도 — catalina.out tail -F 하나로 처리
#   · 메뉴권한체크 : FN_GET_MENU_CHK_YN / YN2 패턴 — 10분 슬라이딩 윈도우
#   · 로그인시도   : _login_chk_log_ 패턴 — 당일 누적, 1분 주기 웹훅 전송
#   · tail 하나 → awk 하나 → 두 로직 동시 처리 (리소스 최소화)
# ══════════════════════════════════════════════════════════════════
# ── tail + 하트비트를 하나의 스트림으로 awk 에 공급 ──
#   1분 전송 타이머가 "새 로그 라인이 들어올 때만" 체크되면 새벽 등 조용한 시간엔
#   집계 전송이 지연/누락됨. __HEARTBEAT__ 라인을 10초마다 주입해 타이머가 항상 돌게 한다.
#   (하트비트 라인은 메뉴/로그인 어떤 패턴에도 매칭되지 않고, 타이머 블록만 깨운다.)
# ── 터미널 대시보드 출력 여부 판단 ──
#   stdout이 실제 터미널(tty)일 때만 clear+현황판을 찍는다.
if [ -t 1 ]; then IS_TTY=1; else IS_TTY=0; fi
echo "[대시보드] stdout tty 여부: $([ "$IS_TTY" = 1 ] && echo '터미널(출력함)' || echo '파일/파이프(생략함, 알림은 webhook_monitor_*.log 로 계속 기록)')"

{ while true; do echo "__HEARTBEAT__ $(date +%s)"; sleep 10; done &
  tail -F "${EXIST_LOGS[@]}" 2>/dev/null; } | awk \
    -v thr="$THRESHOLD" \
    -v topn="$TOP_N" \
    -v win="$WINDOW_SEC" \
    -v cool="$ALERT_COOL" \
    -v server="$SERVER_NM" \
    -v login_thr="$LOGIN_THRESHOLD" \
    -v login_send_sec="$LOGIN_SEND_SEC" \
    -v login_dooray_cool="$LOGIN_DOORAY_COOL" \
    -v wh_url="$WEBHOOK_URL" \
    -v wh_token="$WEBHOOK_TOKEN" \
    -v seed_files="$SEED_LIST" \
    -v menuerr_ids="$MENUERR_USER_IDS" \
    -v menuerr_urls="$MENUERR_URLS" \
    -v oraerr_cool="$ORAERR_COOL" \
    -v oom_cool="$OOM_COOL" \
    -v chk_send_sec="$CHK_SEND_SEC" \
    -v chk_min_delta="$CHK_MIN_DELTA" \
    -v chk_ip_max="$CHK_IP_MAX" \
    -v chk_url_max="$CHK_URL_MAX" \
    -v chk_exc_eq="$CHK_EXC_URL_EQ" \
    -v chk_exc_pre="$CHK_EXC_URL_PRE" \
    -v log_dir="$_WH_LOG_DIR" \
    -v log_prefix="$_WH_LOG_PREFIX" \
    -v is_tty="$IS_TTY" \
'
# ════════════════════════════════════════════════════════
# 로그인 집계 전송 함수
#   · 변경분(diff)만 전송 — prev_tot 과 비교해 변경된 아이디만 웹훅
#   · 임시 sh 파일로 curl 병렬 실행 → awk 블로킹 최소화
# ════════════════════════════════════════════════════════
function do_login_send(    k, collect_dt, now, send_dt,
                           kp, s_succ, s_err1, s_err2, s_err3, s_err4, s_err5, err_tot,
                           wh_title, wh_msg, cfg, sh, sent_cnt,
                           cur_tot, err_a, log_over, sh_opened, safe_id) {
    now        = systime()
    collect_dt = strftime("%Y%m%d%H%M%S", now)
    send_dt    = strftime("%Y-%m-%d %H:%M:%S", now)
    sent_cnt   = 0
    sh         = sprintf("/tmp/.lgin_send_%d.sh", now)
    sh_opened  = 0

    for (k in login_cnt) {
        cur_tot = login_cnt[k]
        if ((k in login_prev) && login_prev[k] == cur_tot) continue

        if (!sh_opened) {
            print "#!/bin/sh" > sh
            sh_opened = 1
        }

        split(k, kp, SUBSEP)
        s_succ  = (login_t[k SUBSEP "succ"] != "") ? login_t[k SUBSEP "succ"] : 0
        s_err1  = (login_t[k SUBSEP "err1"] != "") ? login_t[k SUBSEP "err1"] : 0
        s_err2  = (login_t[k SUBSEP "err2"] != "") ? login_t[k SUBSEP "err2"] : 0
        s_err3  = (login_t[k SUBSEP "err3"] != "") ? login_t[k SUBSEP "err3"] : 0
        s_err4  = (login_t[k SUBSEP "err4"] != "") ? login_t[k SUBSEP "err4"] : 0
        s_err5  = (login_t[k SUBSEP "err5"] != "") ? login_t[k SUBSEP "err5"] : 0
        err_tot = s_err1 + s_err2 + s_err3 + s_err4 + s_err5

        wh_title = sprintf("[%s] 로그인 시도 집계", server)
        wh_msg   = sprintf("COLLECT_DT:%s | SEND_DT:%s | DATE:%s | USER:%s | TOT:%d | SUCC:%d | ERR1:%d | ERR2:%d | ERR3:%d | ERR4:%d | ERR5:%d | ERR_TOT:%d | FIRST:%s | LAST:%s",
                           collect_dt, send_dt, kp[1], kp[2], cur_tot,
                           s_succ, s_err1, s_err2, s_err3, s_err4, s_err5, err_tot,
                           login_first[k], login_last[k])

        safe_id = kp[2]; gsub(/[^A-Za-z0-9]/, "_", safe_id)
        cfg = sprintf("/tmp/.lgin_cfg_%s_%d_%d.cfg", safe_id, sent_cnt, now)
        print "url = \"" wh_url "\""                            > cfg
        print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
        print "data-urlencode = \"alarm_title=" wh_title "\""  >> cfg
        print "data-urlencode = \"alarm_msg=" wh_msg "\""      >> cfg
        print "data-urlencode = \"src_system=" server "\""     >> cfg
        close(cfg)
        print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh

        login_prev[k] = cur_tot
        sent_cnt++

        # ── 로그인 과다시도: 두레이 미전송, 웹훅 로그로만 기록 ──
        if (cur_tot >= login_thr) {
            if (!(k in login_alerted) || (now - login_alerted[k]) >= login_dooray_cool) {
                login_alerted[k] = now
                err_a = cur_tot - s_succ
                log_over = sprintf("[%s] [로그인초과·두레이제외] USER:%s | 합계:%d(성공:%d/실패:%d)",
                                   strftime("%Y-%m-%d %H:%M:%S"), kp[2], cur_tot, s_succ, err_a)
                wlog(log_over)
            }
        }
    }

    login_last_send = now

    if (!sh_opened) return

    print "wait" >> sh
    print "rm -f /tmp/.lgin_cfg_*_" now ".cfg" >> sh
    print "rm -f " sh >> sh
    close(sh)
    system("bash " sh " &")

    log_line = sprintf("[%s] [로그인집계] 변경 %d명 전송 (집계시각: %s)",
                       strftime("%Y-%m-%d %H:%M:%S"), sent_cnt, collect_dt)
    wlog(log_line)
}

# ════════════════════════════════════════════════════════
# 현재메뉴 불일치 집계 전송 함수 (1분 주기, 로그인 집계와 동일 타이머)
#   · 키: 1분구간(YYYYMMDDHHMM) SUBSEP 사용자ID SUBSEP URL — 1분 구간별 건수
#   · 변경분(diff)만 전송 — menuerr_prev 와 비교해 변경된 키만 웹훅
# ════════════════════════════════════════════════════════
function do_menuerr_send(    k, kp, now, collect_dt, send_dt,
                             wh_title, wh_msg, cfg, sh, sent_cnt,
                             cur, sh_opened, safe_id, log_line) {
    now        = systime()
    collect_dt = strftime("%Y%m%d%H%M%S", now)
    send_dt    = strftime("%Y-%m-%d %H:%M:%S", now)
    sent_cnt   = 0
    sh         = sprintf("/tmp/.mnuerr_send_%d.sh", now)
    sh_opened  = 0

    for (k in menuerr_cnt) {
        cur = menuerr_cnt[k]
        if ((k in menuerr_prev) && menuerr_prev[k] == cur) continue

        if (!sh_opened) {
            print "#!/bin/sh" > sh
            sh_opened = 1
        }

        split(k, kp, SUBSEP)   # kp[1]=1분구간(YYYYMMDDHHMM) kp[2]=사용자ID kp[3]=URL

        wh_title = sprintf("[%s] 현재메뉴 불일치 감지", server)
        wh_msg   = sprintf("COLLECT_DT:%s | SEND_DT:%s | DATE:%s | MIN:%s | USER:%s | URL:%s | CNT:%d | FIRST:%s | LAST:%s",
                           collect_dt, send_dt, substr(kp[1], 1, 8), kp[1], kp[2], kp[3], cur,
                           menuerr_first[k], menuerr_last[k])

        safe_id = kp[2]; gsub(/[^A-Za-z0-9]/, "_", safe_id)
        cfg = sprintf("/tmp/.mnuerr_cfg_%s_%d_%d.cfg", safe_id, sent_cnt, now)
        print "url = \"" wh_url "\""                           > cfg
        print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
        print "data-urlencode = \"alarm_title=" wh_title "\""  >> cfg
        print "data-urlencode = \"alarm_msg=" wh_msg "\""      >> cfg
        print "data-urlencode = \"src_system=" server "\""     >> cfg
        close(cfg)
        print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh

        menuerr_prev[k] = cur
        sent_cnt++
    }

    if (!sh_opened) return

    print "wait" >> sh
    print "rm -f /tmp/.mnuerr_cfg_*_" now ".cfg" >> sh
    print "rm -f " sh >> sh
    close(sh)
    system("bash " sh " &")

    log_line = sprintf("[%s] [현재메뉴불일치] 변경 %d건 전송 (집계시각: %s)",
                       strftime("%Y-%m-%d %H:%M:%S"), sent_cnt, collect_dt)
    wlog(log_line)
}

# ════════════════════════════════════════════════════════
# 조회건수 — 제외 URL 판정
#   · 쿼리스트링(?이후) 제거 후 판정
#   · 완전일치 목록(chk_exc_eq_set) 또는 앞자리일치 목록(chk_exc_pre_a) 중 하나라도 걸리면 예외
# ════════════════════════════════════════════════════════
function chk_is_exc(url,    u, i) {
    if (url == "") return 0
    u = url
    sub(/\?.*$/, "", u)
    if (u in chk_exc_eq_set) return 1
    for (i = 1; i <= chk_exc_pre_n; i++) {
        if (index(u, chk_exc_pre_a[i]) == 1) return 1
    }
    return 0
}

# ════════════════════════════════════════════════════════
# 조회건수 — 메뉴권한체크 1건을 당일 누적에 반영
#   키: 일자(YYYYMMDD) SUBSEP USER_ID  (로그인 집계와 동일한 키 구조)
#   · 총건수 : YN + YN2 전부 (제외 URL 포함 — "몇 번 호출했나" 그대로)
#   · 예외건수: YN2 이면서 제외 URL 인 건
#   · YN 은 URL 파라미터가 없어(2번째 인자가 컬럼명) 예외 판정 불가 → 항상 실건수로 집계
# ════════════════════════════════════════════════════════
function chk_collect(user, fn, url, ip, fmt_now,    day, ckey, ikey, bkey, isexc, bucket,
                                                  u, ubucket, ukey) {
    if (user == "" || user ~ /[ \t,]/) return
    day = substr(fmt_now, 1, 4) substr(fmt_now, 6, 2) substr(fmt_now, 9, 2)
    if (length(day) != 8 || day !~ /^[0-9]{8}$/) day = strftime("%Y%m%d", systime())

    ckey  = day SUBSEP user
    isexc = (fn == "YN2" && chk_is_exc(url)) ? 1 : 0

    chk_tot[ckey]++
    if (fn == "YN2") {
        chk_yn2[ckey]++
        if (isexc) chk_exc[ckey]++
    } else {
        chk_yn[ckey]++
    }
    if (!(ckey in chk_first)) chk_first[ckey] = fmt_now
    chk_last[ckey] = fmt_now

    # ══════════════════════════════════════════════════════════════
    # IP 별 집계
    #   · YN2 만 IP 파라미터를 가짐. YN(=IP 없음)은 "NOIP" 버킷으로 모아
    #     IP별 건수의 합 = 전체 건수 가 되도록 맞춘다(누락 없이 정합).
    #   · 서로 다른 IP 가 chk_ip_max 개를 넘으면 초과분은 "ETC" 버킷으로 합산.
    #   · 버킷별 건수는 "이번 전송 구간"의 증가분 — 전송 시 초기화된다.
    # ══════════════════════════════════════════════════════════════
    bucket = "NOIP"
    if (fn == "YN2" && ip != "" && ip != "-") {
        gsub(/^[ \t]+|[ \t]+$/, "", ip)
        gsub(/[,=\/|]/, ".", ip)          # 메시지 구분자(, = / |) 방어
        if (ip != "") {
            chk_ip[ckey] = ip
            ikey = ckey SUBSEP ip
            if (!(ikey in chk_ipall)) { chk_ipall[ikey] = 1; chk_ipn[ckey]++ }

            if (index("," chk_ipl[ckey] ",", "," ip ",") > 0) {
                bucket = ip
            } else if (chk_ipl_n[ckey] < chk_ip_max) {
                bucket = ip
            } else {
                bucket = "ETC"
            }
        }
    }

    if (index("," chk_ipl[ckey] ",", "," bucket ",") == 0) {
        chk_ipl[ckey]   = (chk_ipl[ckey] == "") ? bucket : chk_ipl[ckey] "," bucket
        chk_ipl_n[ckey]++
    }

    bkey = ckey SUBSEP bucket
    chk_ipt[bkey]++                       # 버킷 총건수
    if (!isexc) chk_ipr[bkey]++           # 버킷 실건수(예외 제외)

    # ══════════════════════════════════════════════════════════════
    # [v3] URL 별 집계 — IPD 와 동일 규칙
    #   · YN2 만 URL 을 가짐. YN(URL 없음)은 "NOURL" 버킷 → 합계 = D_TOT
    #   · 쿼리스트링·스킴/호스트 제거, 메시지 구분자(| , =) 제거 ("/" 는 URL 이므로 유지)
    #   · 서로 다른 URL 이 chk_url_max 를 넘으면 초과분은 "ETC"
    #   · 버킷 건수는 "이번 전송 구간" 증가분 — 전송 시 초기화
    #   · 예외 URL 도 총건수엔 포함되고 실건수는 0 → 화면에서 예외 표기 가능
    # ══════════════════════════════════════════════════════════════
    ubucket = "NOURL"
    if (fn == "YN2" && url != "" && url != "-") {
        u = url
        sub(/\?.*$/, "", u)                           # 쿼리스트링 제거
        sub(/^[A-Za-z]+:\/\/[^\/]+/, "", u)           # http://host 제거
        gsub(/^[ \t]+|[ \t]+$/, "", u)
        gsub(/[|,=]/, ".", u)                         # 메시지 구분자 방어
        if (length(u) > 120) u = substr(u, 1, 120)    # 비정상 긴 URL 방어
        if (u != "") {
            if (index("," chk_ul[ckey] ",", "," u ",") > 0) {
                ubucket = u
            } else if (chk_ul_n[ckey] < chk_url_max) {
                ubucket = u
            } else {
                ubucket = "ETC"
            }
        }
    }

    if (index("," chk_ul[ckey] ",", "," ubucket ",") == 0) {
        chk_ul[ckey]   = (chk_ul[ckey] == "") ? ubucket : chk_ul[ckey] "," ubucket
        chk_ul_n[ckey]++
    }

    ukey = ckey SUBSEP ubucket
    chk_ut[ukey]++                        # URL 버킷 총건수
    if (!isexc) chk_ur[ukey]++            # URL 버킷 실건수(예외 제외)
}

# ════════════════════════════════════════════════════════
# 조회건수 집계 전송 함수 (CHK_SEND_SEC 주기)
#   · 증가분(D_TOT)이 chk_min_delta 미만인 아이디는 스킵 → 변경분만 전송
#   · 임시 sh + curl -K cfg 병렬 실행 (로그인/현재메뉴불일치와 동일 구조)
#   · 두레이 전송 없음 — 백오피스 웹훅(TB_MONITOR_ALARM)만
# ════════════════════════════════════════════════════════
function do_chk_send(    k, kp, now, collect_dt, send_dt,
                         cur, prev, p_exc, exc, real, d_tot, d_exc, d_real,
                         yn, yn2, ip_last, ip_cnt, ip_win, ip_det,
                         bn, bkts, bi, bb, bt, br,
                         un, ubkts, ui, ub, ut, ur, url_det,
                         wh_title, wh_msg, cfg, sh, sent_cnt,
                         sh_opened, safe_id, log_line) {
    now        = systime()
    collect_dt = strftime("%Y%m%d%H%M%S", now)
    send_dt    = strftime("%Y-%m-%d %H:%M:%S", now)
    sent_cnt   = 0
    sh         = sprintf("/tmp/.chkcnt_send_%d.sh", now)
    sh_opened  = 0

    for (k in chk_tot) {
        cur   = chk_tot[k]
        prev  = (k in chk_prev)     ? chk_prev[k]     : 0
        d_tot = cur - prev
        if (d_tot < chk_min_delta) continue

        exc    = (k in chk_exc) ? chk_exc[k] : 0
        yn     = (k in chk_yn)  ? chk_yn[k]  : 0
        yn2    = (k in chk_yn2) ? chk_yn2[k] : 0
        real   = cur - exc
        p_exc  = (k in chk_prev_exc) ? chk_prev_exc[k] : 0
        d_exc  = exc - p_exc
        d_real = d_tot - d_exc

        # ── IP 정보 ──
        ip_last = (k in chk_ip)  ? chk_ip[k]  : "-"
        ip_cnt  = (k in chk_ipn) ? chk_ipn[k] : 0
        ip_win  = ((k in chk_ipl) && chk_ipl[k] != "") ? chk_ipl[k] : "-"
        ip_det  = "-"
        if (ip_win != "-") {
            ip_det = ""
            bn = split(chk_ipl[k], bkts, ",")
            for (bi = 1; bi <= bn; bi++) {
                bb = bkts[bi]
                bt = (k SUBSEP bb) in chk_ipt ? chk_ipt[k SUBSEP bb] : 0
                br = (k SUBSEP bb) in chk_ipr ? chk_ipr[k SUBSEP bb] : 0
                ip_det = ip_det ((ip_det == "") ? "" : ",") sprintf("%s=%d/%d", bb, bt, br)
            }
            if (ip_det == "") ip_det = "-"
        }

        # ── [v3] URL 정보 ──  URLD : url=총건수/실건수,url=총건수/실건수  (NOURL / ETC 포함)
        url_det = "-"
        if ((k in chk_ul) && chk_ul[k] != "") {
            url_det = ""
            un = split(chk_ul[k], ubkts, ",")
            for (ui = 1; ui <= un; ui++) {
                ub = ubkts[ui]
                ut = (k SUBSEP ub) in chk_ut ? chk_ut[k SUBSEP ub] : 0
                ur = (k SUBSEP ub) in chk_ur ? chk_ur[k SUBSEP ub] : 0
                url_det = url_det ((url_det == "") ? "" : ",") sprintf("%s=%d/%d", ub, ut, ur)
            }
            if (url_det == "") url_det = "-"
        }

        if (!sh_opened) {
            print "#!/bin/sh" > sh
            sh_opened = 1
        }

        split(k, kp, SUBSEP)   # kp[1]=일자(YYYYMMDD)  kp[2]=USER_ID

        wh_title = sprintf("[%s] 조회건수 집계", server)
        wh_msg   = sprintf("COLLECT_DT:%s | SEND_DT:%s | DATE:%s | USER:%s | TOT:%d | EXC:%d | REAL:%d | D_TOT:%d | D_EXC:%d | D_REAL:%d | YN:%d | YN2:%d | IP:%s | IP_CNT:%d | IPS:%s | IPD:%s | FIRST:%s | LAST:%s | WIN:%d | URLD:%s",
                           collect_dt, send_dt, kp[1], kp[2],
                           cur, exc, real, d_tot, d_exc, d_real,
                           yn, yn2, ip_last, ip_cnt, ip_win, ip_det,
                           chk_first[k], chk_last[k], chk_send_sec, url_det)

        safe_id = kp[2]; gsub(/[^A-Za-z0-9]/, "_", safe_id)
        cfg = sprintf("/tmp/.chkcnt_cfg_%s_%d_%d.cfg", safe_id, sent_cnt, now)
        print "url = \"" wh_url "\""                           > cfg
        print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
        print "data-urlencode = \"alarm_title=" wh_title "\""  >> cfg
        print "data-urlencode = \"alarm_msg=" wh_msg "\""      >> cfg
        print "data-urlencode = \"src_system=" server "\""     >> cfg
        close(cfg)
        print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh

        chk_prev[k]     = cur
        chk_prev_exc[k] = exc

        # 이번 구간 IP 버킷 초기화 — 다음 구간은 새로 수집 (당일 누적 IP 종류수는 유지)
        if ((k in chk_ipl) && chk_ipl[k] != "") {
            bn = split(chk_ipl[k], bkts, ",")
            for (bi = 1; bi <= bn; bi++) {
                delete chk_ipt[k SUBSEP bkts[bi]]
                delete chk_ipr[k SUBSEP bkts[bi]]
            }
        }
        chk_ipl[k]   = ""
        chk_ipl_n[k] = 0

        # [v3] 이번 구간 URL 버킷 초기화 — 다음 구간은 새로 수집
        if ((k in chk_ul) && chk_ul[k] != "") {
            un = split(chk_ul[k], ubkts, ",")
            for (ui = 1; ui <= un; ui++) {
                delete chk_ut[k SUBSEP ubkts[ui]]
                delete chk_ur[k SUBSEP ubkts[ui]]
            }
        }
        chk_ul[k]   = ""
        chk_ul_n[k] = 0

        sent_cnt++
    }

    chk_purge()

    if (!sh_opened) return

    print "wait" >> sh
    print "rm -f /tmp/.chkcnt_cfg_*_" now ".cfg" >> sh
    print "rm -f " sh >> sh
    close(sh)
    system("bash " sh " &")

    log_line = sprintf("[%s] [조회건수집계] 변경 %d명 전송 (집계시각: %s)",
                       strftime("%Y-%m-%d %H:%M:%S"), sent_cnt, collect_dt)
    wlog(log_line)
}

# ════════════════════════════════════════════════════════
# 조회건수 — 오래된 일자 키 정리 (당일/전일만 유지, 메모리 무한증가 방지)
# ════════════════════════════════════════════════════════
function chk_purge(    k, kp, d0, d1) {
    d0 = strftime("%Y%m%d", systime())
    d1 = strftime("%Y%m%d", systime() - 86400)
    for (k in chk_tot) {
        split(k, kp, SUBSEP)
        if (kp[1] != d0 && kp[1] != d1) {
            delete chk_tot[k];      delete chk_exc[k]
            delete chk_yn[k];       delete chk_yn2[k]
            delete chk_first[k];    delete chk_last[k]
            delete chk_prev[k];     delete chk_prev_exc[k]
            delete chk_ip[k];       delete chk_ipn[k]
            delete chk_ipl[k];      delete chk_ipl_n[k]
            delete chk_ul[k];       delete chk_ul_n[k]
        }
    }
    # IP 중복판정 셋 / 버킷 카운트도 같이 정리 (키 = 일자 SUBSEP USER_ID SUBSEP IP)
    for (k in chk_ipall) {
        split(k, kp, SUBSEP)
        if (kp[1] != d0 && kp[1] != d1) delete chk_ipall[k]
    }
    for (k in chk_ipt) {
        split(k, kp, SUBSEP)
        if (kp[1] != d0 && kp[1] != d1) { delete chk_ipt[k]; delete chk_ipr[k] }
    }
    # [v3] URL 버킷 카운트 정리 (키 = 일자 SUBSEP USER_ID SUBSEP URL)
    for (k in chk_ut) {
        split(k, kp, SUBSEP)
        if (kp[1] != d0 && kp[1] != d1) { delete chk_ut[k]; delete chk_ur[k] }
    }
}

# ════════════════════════════════════════════════════════
# Oracle 오류(ORA-xxxxx) 전송 — 후보 저장 + 블록 마감 시 확정 전송
# ════════════════════════════════════════════════════════
function store_ora_candidate(line,    low, pos, rest, code, msg) {
    low = tolower(line)
    pos = index(low, "ora-")
    if (pos == 0) return
    rest = substr(line, pos)

    if (match(rest, /^[Oo][Rr][Aa]-[0-9]+/)) {
        code = substr(rest, RSTART, RLENGTH)
        msg  = substr(rest, RLENGTH + 1)
    } else {
        code = "ORA-UNKNOWN"
        msg  = rest
    }
    sub(/^[: \t]+/, "", msg)
    gsub(/[ \t]+$/, "", msg)
    if (length(msg) > 200) msg = substr(msg, 1, 200) "..."

    if (!ora_has_match || length(msg) > length(ora_msg)) {
        ora_code      = code
        ora_msg       = msg
        ora_has_match = 1
    }
}

function close_ora_block(    key, now, safe_msg, dooray_json, wh_title, wh_msg, cfg, sh, json, log_line, skip_dooray) {
    if (!ora_has_match) return

    key = ora_code SUBSEP ora_user
    now = systime()
    if ((key in oraerr_alerted) && (now - oraerr_alerted[key]) < oraerr_cool) return
    oraerr_alerted[key] = now

    safe_msg = ora_msg
    gsub(/\\/, "\\\\", safe_msg)
    gsub(/"/, "\\\"", safe_msg)

    # "Login Blocked: Security Violation" 포함 시 두레이 전송 제외 (웹훅은 전송)
    skip_dooray = (index(tolower(ora_msg), tolower("Login Blocked: Security Violation")) > 0)

    if (!skip_dooray) {
        dooray_json = sprintf("{\"botName\":\"MenuChkBot\",\"text\":\"" \
                              "\u274c **[WAS] Oracle 오류 감지**\\\\n" \
                              "코드: %s\\\\n" \
                              "내용: %s\\\\n" \
                              "아이디: %s\\\\n" \
                              "발생시각: %s\"}",
                              ora_code, safe_msg, ora_user, ora_ts)
    }

    wh_title = sprintf("[%s] Oracle Job 오류 감지", server)
    wh_msg   = sprintf("오류건수: 1건 | 조회시각: %s | %s >> %s (USER:%s)",
                       ora_ts, ora_code, safe_msg, ora_user)

    sh   = sprintf("/tmp/.oraerr_send_%d_%s.sh", now, ora_code)
    cfg  = sprintf("/tmp/.oraerr_cfg_%d_%s.cfg", now, ora_code)
    json = sprintf("/tmp/.oraerr_body_%d_%s.json", now, ora_code)

    print "#!/bin/bash" > sh

    if (!skip_dooray) {
        printf "%s", dooray_json > json
        close(json)
        print "curl -s -X POST \"" ENVIRON["DOORAY_URL_ER"] "\"" \
              " -H \"Content-Type: application/json\"" \
              " -d @" json \
              " > /dev/null &" >> sh
    }

    print "url = \"" wh_url "\""                            > cfg
    print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
    print "data-urlencode = \"alarm_title=" wh_title "\""  >> cfg
    print "data-urlencode = \"alarm_msg=" wh_msg "\""      >> cfg
    print "data-urlencode = \"src_system=" server "\""     >> cfg
    close(cfg)
    print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh

    print "wait" >> sh
    print "rm -f " cfg >> sh
    print "rm -f " json >> sh
    print "rm -f " sh >> sh
    close(sh)
    system("bash " sh " &")

    log_line = sprintf("[%s] [Oracle오류%s] %s | %s",
                       strftime("%Y-%m-%d %H:%M:%S"),
                       (skip_dooray ? "·두레이제외" : ""), wh_title, wh_msg)
    wlog(log_line)
}

# ════════════════════════════════════════════════════════
# 현재메뉴 불일치 한 줄 파싱 → 카운트 반영
# ════════════════════════════════════════════════════════
function parse_menuerr_line(line,    p, rest, n, parts, userId, dt14, url,
                                     min12, ts_fmt, key) {
    p = index(line, "_menu_check_err_")
    if (p == 0) return
    rest = substr(line, p + length("_menu_check_err_"))
    n = split(rest, parts, ",")
    if (n < 3) return

    userId = parts[1]
    dt14   = parts[2]
    if (userId == "" || length(dt14) < 14) return

    if (index(parts[3], "접근URL:") != 1 && index(parts[3], "accessMenu:") != 1) return
    url = parts[3]; sub(/^[^:]*:/, "", url)
    if (url == "" || url == "NULL") return

    sub(/\?.*$/, "", url)
    if (!(tolower(userId) in me_id_set)) return

    min12  = substr(dt14, 1, 12)
    ts_fmt = substr(dt14,1,4)"-"substr(dt14,5,2)"-"substr(dt14,7,2) \
             " "substr(dt14,9,2)":"substr(dt14,11,2)":"substr(dt14,13,2)

    key = min12 SUBSEP userId SUBSEP url
    menuerr_cnt[key]++
    if (!(key in menuerr_first)) menuerr_first[key] = ts_fmt
    menuerr_last[key] = ts_fmt
}

# ════════════════════════════════════════════════
# [공용] 로그인 한 줄 파싱 → 카운트 반영 (라이브/시드 공용, 전송 안 함)
# ════════════════════════════════════════════════
function parse_login_line(line,    type_cd, n, parts, pref, nf, pp,
                          userId, dt14, day, ts_fmt, key_id) {
    if (index(line, "_login_chk_log_") == 0) return
    if (index(line, ",처리여부:")     == 0) return

    if      (index(line, "_login_chk_log_succ_") > 0) type_cd = "succ"
    else if (index(line, "_login_chk_log_err1_") > 0) type_cd = "err1"
    else if (index(line, "_login_chk_log_err2_") > 0) type_cd = "err2"
    else if (index(line, "_login_chk_log_err3_") > 0) type_cd = "err3"
    else if (index(line, "_login_chk_log_err4_") > 0) type_cd = "err4"
    else if (index(line, "_login_chk_log_err5_") > 0) type_cd = "err5"
    else                                              type_cd = "etc"

    n = split(line, parts, ",")
    if (n < 2) return

    pref   = parts[1]
    nf     = split(pref, pp, "_")
    userId = pp[nf]
    if (userId == "" || userId ~ /^[-]/) return

    dt14 = parts[2]
    if (length(dt14) < 14) return

    day    = substr(dt14, 1, 8)
    ts_fmt = substr(dt14,1,4)"-"substr(dt14,5,2)"-"substr(dt14,7,2) \
             " "substr(dt14,9,2)":"substr(dt14,11,2)":"substr(dt14,13,2)

    key_id = day SUBSEP userId

    login_cnt[key_id]++
    login_t[key_id SUBSEP type_cd]++

    if (!(key_id in login_first)) login_first[key_id] = ts_fmt
    login_last[key_id] = ts_fmt
}

# ════════════════════════════════════════════════
# [시드] 기동 시 오늘자 LOGIN_CHK_LOG 파일들을 훑어 당일 누적 복원
# ════════════════════════════════════════════════
function seed_login(files,    n, arr, i, line, k, rc) {
    if (files == "") return
    n = split(files, arr, ":")
    for (i = 1; i <= n; i++) {
        while ((rc = (getline line < arr[i])) > 0) parse_login_line(line)
        close(arr[i])
    }
    for (k in login_cnt) login_prev[k] = login_cnt[k]
    print "[시드완료] 로그인 당일 누적 " length(login_cnt) " 키 복원" > "/dev/stderr"
}

# ════════════════════════════════════════════════
# 웹훅 로그 기록 — 기록 시점의 날짜로 파일명 생성
# ════════════════════════════════════════════════
function send_oom_alert(line,    now, ts, was, type, key, body, wh_title, wh_msg, sh, cfg, json) {
    now = systime()
    ts  = strftime("%Y-%m-%d %H:%M:%S", now)

    was = "unknown"
    if (match(cur_log, /neo[0-9]+/)) was = substr(cur_log, RSTART, RLENGTH)

    type = line
    sub(/^.*java\.lang\.OutOfMemoryError:?[ \t]*/, "", type)
    gsub(/[^A-Za-z0-9 ._-]/, "", type)
    type = substr(type, 1, 80)
    if (type == "") type = "unknown"

    key = was SUBSEP type
    if ((key in oom_alerted) && (now - oom_alerted[key]) < oom_cool) return
    oom_alerted[key] = now
    oom_seq++

    body = "{\"botName\":\"MenuChkBot\",\"text\":\"**[WAS] OutOfMemoryError 감지**\\n" \
           "서버: " server "\\nWAS: " was "\\n유형: " type "\\n감지시각: " ts "\"}"
    wh_title = sprintf("[%s] OutOfMemoryError 감지", server)
    wh_msg   = sprintf("WAS:%s | TYPE:%s | DETECT_DT:%s", was, type, ts)

    sh   = sprintf("/tmp/.oom_send_%d_%d.sh", now, oom_seq)
    cfg  = sprintf("/tmp/.oom_cfg_%d_%d.cfg", now, oom_seq)
    json = sprintf("/tmp/.oom_body_%d_%d.json", now, oom_seq)

    printf "%s", body > json
    close(json)

    print "url = \"" wh_url "\""                           > cfg
    print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
    print "data-urlencode = \"alarm_title=" wh_title "\"" >> cfg
    print "data-urlencode = \"alarm_msg=" wh_msg "\""     >> cfg
    print "data-urlencode = \"src_system=" server "\""    >> cfg
    close(cfg)

    print "#!/bin/bash" > sh
    print "curl -s -X POST \"" ENVIRON["DOORAY_URL_ER"] "\" -H \"Content-Type: application/json\" -d @" json " > /dev/null 2>&1 &" >> sh
    print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh
    print "wait" >> sh
    print "rm -f " cfg " " json " " sh >> sh
    close(sh)
    system("bash " sh " &")

    wlog(sprintf("[%s] [OOM] %s | %s", ts, wh_title, wh_msg))
}

function wlog(msg,    fn) {
    if (log_dir == "") return
    fn = log_dir "/" log_prefix strftime("%Y%m%d") ".log"
    print msg >> fn
    close(fn)
}

# ════════════════════════════════════════════════
# 초기화
# ════════════════════════════════════════════════
BEGIN {
    q            = sprintf("%c", 39)
    head_idx     = 0
    tail_idx     = 0
    PAT1         = "FN_GET_MENU_CHK_YN(" q
    PAT2         = "FN_GET_MENU_CHK_YN2(" q
    login_last_send = systime()
    cur_ts       = ""
    print "[통합모니터] awk 시작" > "/dev/stderr"

    # 배열 타입 확정 (타이머 블록이 매 줄 length() 호출 → 스칼라로 굳는 것 방지)
    split("", menuerr_cnt)
    split("", menuerr_prev)
    split("", menuerr_first)
    split("", menuerr_last)

    # Oracle 오류 감시 상태 초기화
    ora_active    = 0
    ora_has_match = 0
    ora_user      = "-"
    ora_ts        = ""
    ora_code      = ""
    ora_msg       = ""
    split("", oraerr_alerted)

    # 현재메뉴 불일치 감시 대상 셋 구성 (아이디는 소문자 비교)
    me_n = split(menuerr_ids, me_a, ",")
    for (me_i = 1; me_i <= me_n; me_i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", me_a[me_i])
        if (me_a[me_i] != "") me_id_set[tolower(me_a[me_i])] = 1
    }
    me_n = split(menuerr_urls, me_a, ",")
    for (me_i = 1; me_i <= me_n; me_i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", me_a[me_i])
        if (me_a[me_i] != "") me_url_set[me_a[me_i]] = 1
    }

    # 조회건수 집계 상태 초기화
    split("", chk_tot)      # 당일 누적 총건수      key = 일자 SUBSEP USER_ID
    split("", chk_exc)      # 당일 누적 예외건수
    split("", chk_yn)       # YN  호출수 (URL 없음)
    split("", chk_yn2)      # YN2 호출수
    split("", chk_first)    # 최초 감지시각
    split("", chk_last)     # 최종 감지시각
    split("", chk_prev)     # 직전 전송 시점의 총건수 (증가분 계산용)
    split("", chk_prev_exc) # 직전 전송 시점의 예외건수
    split("", chk_ip)       # 마지막 관측 IP (YN2 만)
    split("", chk_ipn)      # 당일 서로 다른 IP 개수
    split("", chk_ipall)    # IP 중복판정 셋  key = 일자 SUBSEP USER_ID SUBSEP IP
    split("", chk_ipl)      # 이번 전송구간 IP 버킷 목록 (콤마 구분, NOIP/ETC 포함)
    split("", chk_ipl_n)    # 이번 전송구간 버킷 개수
    split("", chk_ipt)      # 버킷별 총건수  key = 일자 SUBSEP USER_ID SUBSEP 버킷
    split("", chk_ipr)      # 버킷별 실건수
    split("", chk_ul)       # [v3] 이번 전송구간 URL 버킷 목록 (콤마 구분, NOURL/ETC 포함)
    split("", chk_ul_n)     # [v3] 이번 전송구간 URL 버킷 개수
    split("", chk_ut)       # [v3] URL 버킷별 총건수  key = 일자 SUBSEP USER_ID SUBSEP URL
    split("", chk_ur)       # [v3] URL 버킷별 실건수
    chk_last_send = systime()

    # 제외 URL 셋 구성 — ① 완전일치
    split("", chk_exc_eq_set)
    ck_n = split(chk_exc_eq, ck_a, ",")
    for (ck_i = 1; ck_i <= ck_n; ck_i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", ck_a[ck_i])
        if (ck_a[ck_i] != "") chk_exc_eq_set[ck_a[ck_i]] = 1
    }
    # 제외 URL 셋 구성 — ② 앞자리일치
    chk_exc_pre_n = 0
    ck_n = split(chk_exc_pre, ck_a, ",")
    for (ck_i = 1; ck_i <= ck_n; ck_i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", ck_a[ck_i])
        if (ck_a[ck_i] != "") chk_exc_pre_a[++chk_exc_pre_n] = ck_a[ck_i]
    }
    if (chk_send_sec  == "" || chk_send_sec  + 0 <= 0) chk_send_sec  = 300
    if (chk_min_delta == "")                           chk_min_delta = 1
    if (chk_ip_max    == "" || chk_ip_max    + 0 <= 0) chk_ip_max    = 5
    if (chk_url_max   == "" || chk_url_max   + 0 <= 0) chk_url_max   = 20

    # 당일 누적 복원 (재시작/자정전환 대비)
    seed_login(seed_files)
}

# ════════════════════════════════════════════════
# 타임스탬프 추출 (catalina.out 로그 헤더 라인)
# ════════════════════════════════════════════════
/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    cur_ts = $1 " " $2
}
/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/ && !/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    cur_ts = $1 " " $2 ":00"
}

# ════════════════════════════════════════════════
# Oracle 오류(ORA-xxxxx) 블록 추적
# ════════════════════════════════════════════════
/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    if (ora_active && ora_has_match) close_ora_block()
    ora_active    = 0
    ora_has_match = 0
}

/ERROR/ && /Exception/ {
    ora_active = 1
    ora_ts     = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", systime())
    ora_user   = "-"
    if (match($0, /id:[ \t]*[^ \t]+/)) {
        ora_user = substr($0, RSTART + 3, RLENGTH - 3)
        gsub(/^[ \t]+|[ \t]+$/, "", ora_user)
    }
}

tolower($0) ~ /ora-[0-9]+/ {
    if (!ora_active) {
        ora_active = 1
        ora_ts     = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", systime())
        ora_user   = "-"
    }
    store_ora_candidate($0)
}

/^==> .* <==$/ { cur_log = $2 }

/java\.lang\.OutOfMemoryError/ { send_oom_alert($0) }

END {
    if (ora_active && ora_has_match) close_ora_block()
}

# ════════════════════════════════════════════════
# 모든 라인 — 1분 타이머 체크 (로그인 집계 + 현재메뉴 불일치 전송)
# ════════════════════════════════════════════════
{
    now = systime()
    if ((now - login_last_send) >= login_send_sec && (length(login_cnt) > 0 || length(menuerr_cnt) > 0)) {
        if (length(login_cnt)   > 0) do_login_send()
        if (length(menuerr_cnt) > 0) do_menuerr_send()
        login_last_send = now
    }

    # 조회건수 집계 전송 타이머 (기본 5분 — 로그인 타이머와 독립)
    if ((now - chk_last_send) >= chk_send_sec) {
        if (length(chk_tot) > 0) do_chk_send()
        chk_last_send = now
    }
}

# ════════════════════════════════════════════════
# [1] 메뉴권한체크 파싱
#   FN_GET_MENU_CHK_YN  : 파라미터 2개 (user, column) — IP 없음
#   FN_GET_MENU_CHK_YN2 : 파라미터 3개 (user, url, ip) — a[6]이 IP
# ════════════════════════════════════════════════
index($0, PAT1) || index($0, PAT2) {
    fn = index($0, PAT2) ? "YN2" : "YN"

    split($0, a, q)
    user = a[2]
    ip  = (fn == "YN2") ? a[6] : "-"
    url = (fn == "YN2") ? a[4] : ""

    now     = systime()
    fmt_now = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", now)

    # 조회건수 집계 — 아래 제외(next)보다 먼저 호출
    chk_collect(user, fn, url, ip, fmt_now)

    # YN2 제외 URL — 해당 URL은 (과다호출 감시용) 슬라이딩 윈도우 집계에서 스킵
    if (fn == "YN2") {
        if (index(url, "/common/popup/selectStore/getSelectHqNmcodeMomsList.sb") > 0 ||
            index(url, "/common/popup/selectStore/getSelectBrandMomsList.sb")    > 0 ||
            index(url, "/common/popup/selectStore/getSelectBranchMomsList.sb")   > 0) next
    }

    q_time[tail_idx] = now
    q_user[tail_idx] = user
    q_fn[tail_idx]   = fn
    q_fmt[tail_idx]  = fmt_now
    tail_idx++

    if (!(user in last_ip)) last_ip[user] = "-"
    if (fn == "YN2" && ip != "" && ip != "-") last_ip[user] = ip
    last_ts[user] = fmt_now

    # 슬라이딩 윈도우 — 10분 지난 항목 제거
    cutoff = now - win
    while (head_idx < tail_idx && q_time[head_idx] <= cutoff) {
        u = q_user[head_idx]
        f = q_fn[head_idx]
        cnt[u]--
        cnt_fn[u, f]--
        if (cnt_fn[u, f] <= 0) delete cnt_fn[u, f]
        if (cnt[u] <= 0) {
            delete cnt[u]
            delete last_ip[u]
            delete last_ts[u]
            delete first_ts[u]
            delete alerted[u]
        }
        delete q_time[head_idx]
        delete q_user[head_idx]
        delete q_fn[head_idx]
        delete q_fmt[head_idx]
        head_idx++
    }

    cnt[user]++
    cnt_fn[user, fn]++

    for (i = head_idx; i < tail_idx; i++) {
        if (q_user[i] == user) { first_ts[user] = q_fmt[i]; break }
    }

    # 임계치 초과 → 두레이 + 웹훅
    if (cnt[user] >= thr) {
        if (!(user in alerted) || (now - alerted[user]) >= cool) {
            alerted[user] = now
            c1 = (cnt_fn[user, "YN"]  != "") ? cnt_fn[user, "YN"]  : 0
            c2 = (cnt_fn[user, "YN2"] != "") ? cnt_fn[user, "YN2"] : 0

            dooray_msg = sprintf("⚠️ **[WAS] 메뉴권한체크 과다호출 감지**\\\\n" \
                                 "아이디: %s\\\\n" \
                                 "10분 누적: %d회 (YN: %d / YN2: %d)\\\\n" \
                                 "IP: %s\\\\n" \
                                 "첫감지: %s  마지막: %s\\\\n" \
                                 "임계치: %d회 이상 (최근 10분)",
                                 user, cnt[user], c1, c2,
                                 last_ip[user], first_ts[user], last_ts[user], thr)

            wh_title = sprintf("[%s] 메뉴권한체크 과다호출 감지", server)
            wh_msg   = sprintf("USER:%s | 10min:%d(YN:%d/YN2:%d) | IP:%s | FIRST:%s | LAST:%s | THR:%d",
                               user, cnt[user], c1, c2,
                               last_ip[user], first_ts[user], last_ts[user], thr)

            dooray_cmd = "send_dooray " q dooray_msg q
            system(dooray_cmd)

            wh_cmd = "send_webhook " q wh_title q " " q wh_msg q
            system(wh_cmd)

            log_line = sprintf("[%s] [메뉴권한체크] %s | %s",
                               strftime("%Y-%m-%d %H:%M:%S"), wh_title, wh_msg)
            wlog(log_line)
        }
    }

    # 터미널 현황 출력 — stdout이 tty일 때만
    if (is_tty) {
        n = 0
        for (u in cnt) keys[++n] = u
        for (i = 1; i <= n; i++)
            for (j = i+1; j <= n; j++)
                if (cnt[keys[i]] < cnt[keys[j]]) {
                    tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
                }

        system("clear")
        printf "\033[1m서버: %s\033[0m\n", server
        printf "\033[1m%-22s %8s  %6s %6s  %-16s  %-20s %-20s  %s\033[0m\n",
               "USER_ID", "10분누적", "YN", "YN2", "LAST_IP", "첫감지", "마지막감지", "상태"
        print  "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

        shown = (n < topn) ? n : topn
        for (i = 1; i <= shown; i++) {
            u  = keys[i]
            c1 = (cnt_fn[u, "YN"]  != "") ? cnt_fn[u, "YN"]  : 0
            c2 = (cnt_fn[u, "YN2"] != "") ? cnt_fn[u, "YN2"] : 0

            if (cnt[u] >= thr)
                flag = "\033[31m[초과→두레이+웹훅]\033[0m"
            else if (cnt[u] >= int(thr/2))
                flag = "\033[33m[주의]\033[0m"
            else
                flag = "      "

            printf "%-22s %8d  %6d %6d  %-16s  %-20s %-20s  %s\n",
                   u, cnt[u], c1, c2, last_ip[u], first_ts[u], last_ts[u], flag
        }
        if (n > topn)
            printf "\033[90m  ... 외 %d개 아이디\033[0m\n", n - topn

        print  "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

        total_yn = 0; total_yn2 = 0; over = 0
        for (u in cnt) {
            total_yn  += (cnt_fn[u, "YN"]  != "") ? cnt_fn[u, "YN"]  : 0
            total_yn2 += (cnt_fn[u, "YN2"] != "") ? cnt_fn[u, "YN2"] : 0
            if (cnt[u] >= thr) over++
        }
        printf "윈도우: 최근 %d분  |  YN: %d건  YN2: %d건  |  전체 %d개 아이디  |  임계치(%d회) 초과: %d  |  갱신: %s\n",
               int(win/60), total_yn, total_yn2, n, thr, over, strftime("%Y-%m-%d %H:%M:%S")
        printf "알림: 두레이 + 백오피스 웹훅 동시 전송 (쿨타임 %d분)\n", int(cool/60)

        chk_d0 = strftime("%Y%m%d")
        ck_users = 0; ck_tot_s = 0; ck_exc_s = 0
        for (u in chk_tot) {
            split(u, ckp, SUBSEP)
            if (ckp[1] != chk_d0) continue
            ck_users++
            ck_tot_s += chk_tot[u]
            ck_exc_s += (u in chk_exc) ? chk_exc[u] : 0
        }
        printf "조회건수(당일누적): 총 %d건 / 예외 %d건 / 실 %d건  |  대상 %d개 아이디  |  전송주기 %d분  |  다음전송 %d초 후\n",
               ck_tot_s, ck_exc_s, ck_tot_s - ck_exc_s, ck_users,
               int(chk_send_sec/60), (chk_send_sec - (systime() - chk_last_send))

        for (i = 1; i <= n; i++) delete keys[i]
    }
}

# ════════════════════════════════════════════════
# [2] 로그인 시도 파싱 (_login_chk_log_ 패턴)
# ════════════════════════════════════════════════
/_login_chk_log_/ && /,처리여부:/ {
    parse_login_line($0)
}

# ════════════════════════════════════════════════
# [3] 현재메뉴 불일치 파싱 (_menu_check_err_ 패턴)
# ════════════════════════════════════════════════
/_menu_check_err_/ && (/,접근URL:/ || /,accessMenu:/) {
    parse_menuerr_line($0)
}

' &

# 종료 시 정리
trap 'echo "[모니터링 종료]"; kill 0' EXIT TERM INT

# 프로세스 종료될 때까지 대기
wait