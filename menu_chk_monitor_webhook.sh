#!/bin/bash
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
# 실행: bash menu_chk_monitor_webhook.sh
# 종료: Ctrl+C
# =============================================

# ── catalina.out 로그 파일 ──
CATALINA_LOGS=(
    "/usr/local/tomcat-8.0.47-neo1/logs/catalina.out"
    "/usr/local/tomcat-8.0.47-neo2/logs/catalina.out"
)

# ── 메뉴권한체크 설정 ──
THRESHOLD=100       # 10분 슬라이딩 윈도우 임계치
TOP_N=10            # 터미널 표시 최대 아이디 수
WINDOW_SEC=600      # 슬라이딩 윈도우 (10분)
ALERT_COOL=300      # 같은 아이디 재알림 쿨타임 (5분)

# ── 로그인 설정 ──
LOGIN_THRESHOLD=50    # 당일 누적 강조 임계치
LOGIN_SEND_SEC=60     # 웹훅 전송 주기 (1분)
LOGIN_DOORAY_COOL=300 # 두레이 재알림 쿨타임 (초)

# ── [추가] Oracle 오류(ORA-xxxxx) 감시 설정 ──
#   대상: catalina.out 안의 예외 스택트레이스에 포함된 ORA-xxxxx (대소문자 무관)
#   블록 단위로 첫 ORA- 1건만 채택 (같은 예외가 Cause/nested 등으로 3~4회 반복 출력되므로 중복 제거)
#   전송: 즉시(실시간) — 단, 같은 (코드+아이디) 조합은 쿨타임 내 재알림 안 함
ORAERR_COOL=60   # 같은 오류(코드+아이디) 재알림 쿨타임 (초)

# ── [추가] 현재메뉴 불일치(_menu_check_err_) 감시 설정 ──
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

# ── [추가] 로그인 당일 누적 복원용 시드 파일 목록 ──
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

# ── [변경] 웹훅 로그 파일을 날짜별로 자동 분리 ──
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
# ── [변경] tail + 하트비트를 하나의 스트림으로 awk 에 공급 ──
#   기존: 1분 전송 타이머가 "새 로그 라인이 들어올 때만" 체크됨 → 새벽 등 조용한 시간엔
#         집계 전송이 지연/누락됨. __HEARTBEAT__ 라인을 10초마다 주입해 타이머가 항상 돌게 한다.
#   (하트비트 라인은 메뉴/로그인 어떤 패턴에도 매칭되지 않고, 타이머 블록만 깨운다.)
# ── [추가] 터미널 대시보드 출력 여부 판단 ──
#   stdout이 실제 터미널(tty)일 때만 clear+현황판을 찍는다.
#   nohup/파일 리다이렉트(webhook_ctl.sh start 등)로 실행되면 매 매칭 라인마다
#   풀스크린 프레임이 그대로 로그 파일에 append되어 디스크/CPU만 낭비하고
#   tail -f로 봐도 스크롤이 너무 빨라 실질적으로 못 읽는다 → tty가 아니면 스킵.
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
                           cur_tot, err_a, log_over, sh_opened) {
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

        cfg = sprintf("/tmp/.lgin_cfg_%s_%d.cfg", kp[2], now)
        print "url = \"" wh_url "\""                            > cfg
        print "header = \"X-Webhook-Token: " wh_token "\""    >> cfg
        print "data-urlencode = \"alarm_title=" wh_title "\""  >> cfg
        print "data-urlencode = \"alarm_msg=" wh_msg "\""      >> cfg
        print "data-urlencode = \"src_system=" server "\""     >> cfg
        close(cfg)
        print "curl -s --connect-timeout 10 --max-time 15 -K " cfg " > /dev/null 2>&1 &" >> sh

        login_prev[k] = cur_tot
        sent_cnt++

        # ── [변경] 로그인 과다시도 두레이 알림 제거 ──
        #   임계치(login_thr) 초과 시 두레이(DOORAY_URL_ER)로 보내던 알림을 전송하지 않음.
        #   백오피스 웹훅 집계 전송은 위에서 그대로 유지되며, 초과 여부는 웹훅 로그로만 기록.
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
# [추가] 현재메뉴 불일치 집계 전송 함수 (1분 주기, 로그인 집계와 동일 타이머)
#   · 키: 1분구간(YYYYMMDDHHMM) SUBSEP 사용자ID SUBSEP URL — 1분 구간별 건수
#   · 변경분(diff)만 전송 — menuerr_prev 와 비교해 변경된 키만 웹훅
#   · 임시 sh 파일로 curl 병렬 실행 → awk 블로킹 최소화 (로그인 집계와 동일 구조)
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

        # cfg 파일명: 사용자ID(영숫자 외 치환) + 순번 + 시각 — 같은 초 내 다건도 충돌 없음
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
# [추가] Oracle 오류(ORA-xxxxx) 전송 — 후보 저장 + 블록 마감 시 확정 전송
#   · store_ora_candidate: 블록 안 ORA- 매칭 라인마다 호출. 지금까지 저장된 것보다 메시지가
#     더 길면(더 완전하면) 교체 — 버퍼 분할로 짤린 줄이 먼저 잡혀도 뒤에 완전한 줄이 나오면 대체됨
#   · close_ora_block: 블록이 끝나는 시점(다음 타임스탬프 라인 도달)에 호출, 그 블록의 최종 후보 1건 전송
#   · dedupe 키는 "코드"만 사용(사용자 무관) — 같은 오류를 서로 다른 로거가 각각 찍어
#     블록이 2개로 나뉘어도(사용자ID가 다르게 잡히거나 하나는 "-" 로 잡혀도) 쿨타임 안이면 1번만 전송
#   · 두레이는 에러 채널(DOORAY_URL_ER), 웹훅은 기존 "Oracle Job 오류 감지" 포맷과 동일하게
#     (10분 배치 잡 send_dooray.sh 가 쌓아온 데이터와 같은 화면에서 보이도록 포맷 통일)
#   · 전송은 로그인집계/현재메뉴불일치와 동일하게 "임시 sh파일 + system(\"bash 파일 &\")" 방식 사용.
#     system(\"함수명 ...\")으로 exported bash 함수를 직접 부르는 방식은 system()이 내부적으로
#     /bin/sh 를 쓰기 때문에(서버의 /bin/sh 가 dash 등 bash가 아니면) 조용히 실패할 수 있어 지양.
#     ENVIRON["DOORAY_URL_ER"] 로 URL을 직접 읽어 curl 커맨드를 파일에 쓰고 "bash 파일"로 명시 실행하면
#     쉘 종류와 무관하게 항상 동작 — 로그인 과다시도 두레이 알림(위 do_login_send)과 동일한 검증된 패턴.
# ════════════════════════════════════════════════════════
function store_ora_candidate(line,    low, pos, rest, code, msg) {
    low = tolower(line)
    pos = index(low, "ora-")
    if (pos == 0) return
    rest = substr(line, pos)

    # 코드 추출: ORA- 뒤 숫자 (원본 표기 그대로 보존)
    if (match(rest, /^[Oo][Rr][Aa]-[0-9]+/)) {
        code = substr(rest, RSTART, RLENGTH)
        msg  = substr(rest, RLENGTH + 1)
    } else {
        code = "ORA-UNKNOWN"
        msg  = rest
    }
    sub(/^[: \t]+/, "", msg)
    gsub(/[ \t]+$/, "", msg)
    if (length(msg) > 200) msg = substr(msg, 1, 200) "..."   # 메시지 과도한 길이 방지

    # 이번 블록에서 처음 찾은 경우, 또는 이번 줄의 메시지가 지금까지 저장된 것보다 더 길면(더 완전하면) 교체
    if (!ora_has_match || length(msg) > length(ora_msg)) {
        ora_code      = code
        ora_msg       = msg
        ora_has_match = 1
    }
}

function close_ora_block(    key, now, safe_msg, dooray_json, wh_title, wh_msg, cfg, sh, json, log_line, skip_dooray) {
    if (!ora_has_match) return

    key = ora_code
    now = systime()
    if ((key in oraerr_alerted) && (now - oraerr_alerted[key]) < oraerr_cool) return
    oraerr_alerted[key] = now

    # Oracle 메시지에 흔한 "TABLE"."COLUMN" 같은 큰따옴표를 JSON 문자열 안에 그대로 넣으면 안 되므로
    # JSON 표준 이스케이프 처리 (백슬래시 → 큰따옴표 순서로).
    safe_msg = ora_msg
    gsub(/\\/, "\\\\", safe_msg)
    gsub(/"/, "\\\"", safe_msg)

    # ── [추가] "Login Blocked: Security Violation" 포함 시 두레이 전송 제외 ──
    #   (계정 잠금 정책에 의한 정상 차단이므로 두레이 알림 불필요 — 백오피스 웹훅은 그대로 전송)
    #   대소문자 무관 비교: 로거/DB 트리거 표기 차이에도 안전하게 매칭
    skip_dooray = (index(tolower(ora_msg), tolower("Login Blocked: Security Violation")) > 0)

    # ── 두레이 JSON payload는 "파일에 써서 curl -d @파일" 로 전송 ──
    #   전에는 -d "{...}" 처럼 JSON을 통째로 bash 커맨드라인에 인라인으로 넣었는데,
    #   그러면 JSON 이스케이프(\")가 bash 큰따옴표 파싱을 한 번 더 거치면서 백슬래시가
    #   먹혀버려(이중 이스케이프 필요) 결과적으로 안 깨진 것처럼 보여도 실제로는 깨진 JSON이
    #   전송되는 문제가 있었음(실제 재현됨: 웹훅은 가는데 두레이만 조용히 실패).
    #   파일로 분리하면 bash 인용부호 해석을 아예 안 거치므로 JSON 이스케이프가 그대로 살아남는다.
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

    # 두레이(에러 채널) — JSON 본문을 파일에 그대로 써서 curl -d @파일 로 전송 (bash 파싱 우회)
    #   Login Blocked: Security Violation 은 두레이 전송 제외 (웹훅만 전송)
    if (!skip_dooray) {
        printf "%s", dooray_json > json
        close(json)
        print "curl -s -X POST \"" ENVIRON["DOORAY_URL_ER"] "\"" \
              " -H \"Content-Type: application/json\"" \
              " -d @" json \
              " > /dev/null &" >> sh
    }

    # 백오피스 웹훅 — 로그인/현재메뉴불일치와 동일한 -K cfg 파일 방식
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
# [추가] 현재메뉴 불일치 한 줄 파싱 → 카운트 반영
#   대상 라인 2종만 집계 (같은 블록의 현재URL:/사용자ID:/URL: 등 다른 라인은 무시):
#     _menu_check_err_<user>,<dt14>,접근URL:<url>
#     _menu_check_err_<user>,<dt14>,accessMenu:<url>
#   전송 조건: (아이디 ∈ me_id_set) — URL은 더 이상 필터링에 사용하지 않음
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

    # 3번째 필드가 접근URL:/accessMenu: 로 시작하는 라인만 대상
    if (index(parts[3], "접근URL:") != 1 && index(parts[3], "accessMenu:") != 1) return
    url = parts[3]; sub(/^[^:]*:/, "", url)
    if (url == "" || url == "NULL") return

    # ── 전송 조건: (아이디 매칭) 만으로 판단 — URL 필터는 제거됨 ──
    sub(/\?.*$/, "", url)                          # 쿼리스트링 제거 (표시용)
    if (!(tolower(userId) in me_id_set)) return

    min12  = substr(dt14, 1, 12)                   # YYYYMMDDHHMM — 1분 구간 키
    ts_fmt = substr(dt14,1,4)"-"substr(dt14,5,2)"-"substr(dt14,7,2) \
             " "substr(dt14,9,2)":"substr(dt14,11,2)":"substr(dt14,13,2)

    key = min12 SUBSEP userId SUBSEP url           # (분 · 아이디 · URL) 별 1분 집계
    menuerr_cnt[key]++
    if (!(key in menuerr_first)) menuerr_first[key] = ts_fmt
    menuerr_last[key] = ts_fmt
}

# ════════════════════════════════════════════════
# [공용] 로그인 한 줄 파싱 → 카운트 반영 (라이브/시드 공용, 전송 안 함)
#   라이브 블록과 시드가 동일 함수를 써야 파싱 버그가 갈라지지 않는다.
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
#   · getline < 파일 : 파일이 없으면 -1 반환 → while 미진입 → 에러/중단 전혀 없음
#   · 복원 후 login_prev 를 현재값과 동기화 → 재시작을 "무음"으로(이미 보낸 값 재전송 안 함)
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
# [변경] 웹훅 로그 기록 — 기록 시점의 날짜로 파일명 생성
#   · print >> 변수  형태로 매 호출 시 오늘 날짜 파일명을 계산 → 자정 자동 전환
#   · 기록 후 close() 로 즉시 flush(= tail -f 실시간 반영) + fd 누수 방지
#   · log_dir 가 비면 조용히 건너뜀(과거 /dev/null 동작 대체)
# ════════════════════════════════════════════════
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

    # ── [수정] menuerr_cnt 등을 배열로 명시 초기화 ──
    #   원인: "모든 라인" 타이머 블록이 매 줄마다 length(menuerr_cnt)를 호출하는데,
    #         실제 _menu_check_err_ 로그가 아직 한 번도 안 들어온 시점(기동 직후)에는
    #         menuerr_cnt가 배열로 확정된 적이 없어 gawk가 스칼라로 타입을 굳혀버림.
    #         이후 첫 매칭 라인에서 menuerr_cnt[key]++ 를 시도하면
    #         "attempt to use scalar as array" fatal error로 awk 전체가 죽음
    #         (login_cnt는 seed_login()이 기동 시 먼저 배열로 써서 우연히 안전했음).
    #   해결: split("", arr) 로 처음부터 빈 배열임을 명시 → 타입 확정을 배열로 고정.
    split("", menuerr_cnt)
    split("", menuerr_prev)
    split("", menuerr_first)
    split("", menuerr_last)

    # ── [추가] Oracle 오류 감시 상태 초기화 ──
    ora_active    = 0     # 현재 예외 블록(ERROR+Exception 헤더 ~ 다음 타임스탬프 라인) 안인지 여부
    ora_has_match = 0     # 이 블록에서 ORA- 라인을 한 번이라도 찾았는지
    ora_user      = "-"
    ora_ts        = ""
    ora_code      = ""
    ora_msg       = ""
    split("", oraerr_alerted)   # 코드별 마지막 전송 시각 — 쿨타임 판단용 (사용자 무관, 코드만으로 dedupe)

    # ── [추가] 현재메뉴 불일치 감시 대상 셋 구성 (아이디는 소문자 비교) ──
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

    # ── [추가] 당일 누적 복원 (재시작/자정전환 대비) ──
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
# [추가] Oracle 오류(ORA-xxxxx) 블록 추적
#   · 새 타임스탬프 라인 = 새 로그 문장 시작 → 이전 예외 블록 "마감"(그때 전송)
#   · continuation 라인(###, Caused by: 등)은 타임스탬프가 없어 블록이 유지됨
#   · 블록 안에서 ORA- 라인이 여러 번 나오면(반복/두 로거가 각각 기록 등) "가장 메시지가 긴(완전한) 것" 하나만 채택
#     → I/O 버퍼 분할로 어떤 줄이 "ORA-12899:" 까지만 끊겨 들어와도, 뒤이어 상세 메시지가 붙은
#       다른 줄이 나오면 그걸로 교체되어 전송됨 (짤린 메시지 그대로 나가는 문제 방지)
# ════════════════════════════════════════════════
/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    if (ora_active && ora_has_match) close_ora_block()
    ora_active    = 0
    ora_has_match = 0
}

# 예외 블록 시작 — ERROR 레벨 + Exception 키워드가 함께 있는 헤더 라인이면 사용자ID까지 확보
/ERROR/ && /Exception/ {
    ora_active = 1
    ora_ts     = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", systime())
    ora_user   = "-"
    if (match($0, /id:[ \t]*[^ \t]+/)) {
        ora_user = substr($0, RSTART + 3, RLENGTH - 3)
        gsub(/^[ \t]+|[ \t]+$/, "", ora_user)
    }
}

# ORA- 라인 감지 (대소문자 무관, "### Cause:" / "Caused by:" 등 표현과 무관하게 전부 매칭)
#   · 헤더(ERROR+Exception)를 못 잡았어도(로그 포맷이 다르거나 tail이 블록 중간부터 시작한 경우)
#     이 줄 자체가 블록을 새로 연다 — 사용자ID는 확보 못했으므로 "-" 로 처리, 절대 누락되지 않게
#   · 전송은 여기서 바로 하지 않고 후보로만 저장 — 블록이 닫힐 때(close_ora_block) 확정 전송
tolower($0) ~ /ora-[0-9]+/ {
    if (!ora_active) {
        ora_active = 1
        ora_ts     = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", systime())
        ora_user   = "-"
    }
    store_ora_candidate($0)
}

# 스크립트 종료 시점 — 마지막 블록이 전송 안 된 채 남아있으면 마저 전송
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
    # YN  : 2번째 파라미터가 컬럼명(작은따옴표 없음) → a[6] 없음 → "-"
    # YN2 : 3번째 파라미터가 IP → a[6]
    ip = (fn == "YN2") ? a[6] : "-"

    # YN2 제외 URL — 해당 URL은 집계에서 스킵
    if (fn == "YN2") {
        url = a[4]
        if (index(url, "/common/popup/selectStore/getSelectHqNmcodeMomsList.sb") > 0 ||
            index(url, "/common/popup/selectStore/getSelectBrandMomsList.sb")    > 0 ||
            index(url, "/common/popup/selectStore/getSelectBranchMomsList.sb")   > 0) next
    }

    now = systime()

    fmt_now = (cur_ts != "") ? cur_ts : strftime("%Y-%m-%d %H:%M:%S", now)

    q_time[tail_idx] = now
    q_user[tail_idx] = user
    q_fn[tail_idx]   = fn
    q_fmt[tail_idx]  = fmt_now
    tail_idx++

    # IP 갱신 — YN2일 때만 (YN 마지막 진입 시 IP 덮어쓰기 방지)
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

    # 터미널 현황 출력 — stdout이 tty일 때만 (파일/파이프로 리다이렉트되면 스킵)
    #   nohup으로 돌 때 매 매칭 라인마다 풀스크린을 로그에 append하는 걸 방지.
    #   알림(두레이/웹훅)과 wlog() 기록은 위에서 이미 처리되어 이 블록과 무관하게 항상 동작함.
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

        for (i = 1; i <= n; i++) delete keys[i]
    }
}

# ════════════════════════════════════════════════
# [2] 로그인 시도 파싱 (_login_chk_log_ 패턴)
#   catalina.out 에서 직접 파싱 (v2 변경)
#   형식: _login_chk_log_succ_userid,YYYYMMDDHHMMSS,처리여부:성공
# ════════════════════════════════════════════════
/_login_chk_log_/ && /,처리여부:/ {
    parse_login_line($0)
}

# ════════════════════════════════════════════════
# [3] 현재메뉴 불일치 파싱 (_menu_check_err_ 패턴)
#   대상 라인 2종 (접근URL: / accessMenu: 라인만 — 블록 내 다른 라인은 무시)
# ════════════════════════════════════════════════
/_menu_check_err_/ && (/,접근URL:/ || /,accessMenu:/) {
    parse_menuerr_line($0)
}

' &

# 종료 시 정리
trap 'echo "[모니터링 종료]"; kill 0' EXIT TERM INT

# 프로세스 종료될 때까지 대기
wait