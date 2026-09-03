/* ****************************************************************************
   오라클 세션/락 운영 조회  —  [12] ~ [22] 추가분

   기존 [1]~[11] 파일 맨 뒤에 그대로 붙여 넣으면 번호가 이어진다.

   ── 원칙 ──
     · [12]~[17], [19]~[20] 은 전부 SELECT 다. 아무것도 바꾸지 않는다.
     · [18] 은 KILL / CANCEL "문장을 만들어 주기만" 한다.
       만들어진 문장을 실행할지는 사람이 판단해서 직접 복사해 붙여 넣는다.

   ── 추가로 쓰는 뷰 ──
     V$SESSION_LONGOPS   6초 넘게 걸리는 작업의 진행률
     GV$SESSION          RAC 전체 인스턴스 (단일 인스턴스면 [20] 은 무시)
     V$TRANSACTION       언두 사용량 = 킬했을 때 롤백에 걸릴 시간의 근거
     (V$PROCESS 는 접근 확인이 안 된 뷰라 여기서는 쓰지 않았다)

   ── LAST_CALL_ET 를 먼저 이해할 것 ──
     이 컬럼 하나를 STATUS 와 같이 봐야 의미가 생긴다. 헷갈리기 쉬운 부분이다.
       STATUS = ACTIVE   → LAST_CALL_ET 는 "지금 SQL 을 몇 초째 돌리는 중"
       STATUS = INACTIVE → LAST_CALL_ET 는 "몇 초째 아무것도 안 하고 노는 중"
     즉 같은 3600 이어도
       ACTIVE 3600   = 1시간짜리 쿼리가 돌고 있다 (무겁지만 일은 하는 중)
       INACTIVE 3600 = 1시간째 방치돼 있다
                       ↑ 여기에 열린 트랜잭션까지 있으면 그게 [15] 이고,
                         실무에서 남을 막는 원인의 대부분이 이 조합이다.
   **************************************************************************** */


/* ============================================================================
   [12] ★ 지금 실행 중인 것 ★  현재 돌고 있는 세션 한눈에

   "지금 뭐가 돌고 있냐" 는 질문에 대한 답. [1] 이 0건이어도 시스템이 느리면
   여기를 본다. 락이 아니라 그냥 무거운 쿼리가 도는 중일 수 있다.

   보는 법
     현재SQL경과초 가 큰 것부터 위로 온다. 이게 오래 도는 쿼리다.
     대기이벤트 가 비어 있거나 ON CPU 면 CPU 를 쓰며 계산 중 (정상적으로 일하는 중)
     대기이벤트 에 enq: 가 보이면 락 때문에 멈춰 있는 것 -> [1] 로 간다
     블로커SID 에 값이 있으면 그 세션이 나를 막고 있는 것
   TYPE='USER' 로 오라클 백그라운드 프로세스는 뺐다.
   ============================================================================ */
SELECT s.SID, s.SERIAL#,
       s.USERNAME, s.OSUSER, s.MACHINE, s.PROGRAM, s.MODULE, s.ACTION,
       s.STATUS,
       s.LAST_CALL_ET                AS 현재SQL경과초,
       ROUND(s.LAST_CALL_ET/60,1)    AS 현재SQL경과분,
       s.SECONDS_IN_WAIT             AS 대기초,
       s.WAIT_CLASS                  AS 대기분류,
       s.EVENT                       AS 대기이벤트,
       s.BLOCKING_SESSION            AS 블로커SID,
       TO_CHAR(s.SQL_EXEC_START,'MM-DD HH24:MI:SS') AS SQL시작시각,
       s.SQL_ID,
       (SELECT SUBSTR(q.SQL_TEXT,1,200) FROM V$SQL q
         WHERE q.SQL_ID = s.SQL_ID AND ROWNUM = 1)  AS SQL_TEXT
  FROM V$SESSION s
 WHERE s.STATUS = 'ACTIVE'
   AND s.TYPE   = 'USER'
   AND s.SID   <> SYS_CONTEXT('USERENV','SID')      /* 내 세션 제외 */
 ORDER BY s.LAST_CALL_ET DESC;


/* ============================================================================
   [13] 오래 걸리는 작업의 진행률과 남은 시간

   풀스캔, 정렬, 해시조인, 롤백 처럼 오라클이 "총량" 을 미리 아는 작업만
   여기에 올라온다. 6초 넘게 걸려야 등록된다.
     -> 여기 안 나온다고 안 도는 게 아니다. [12] 에는 있는데 [13] 에 없으면
        총량을 알 수 없는 형태의 작업(반복 실행되는 단건 DML 등)이라는 뜻이다.

   남은초(TIME_REMAINING) 는 지금 속도가 유지된다는 가정의 추정치다.
   그대로 믿지 말고 경향(줄고 있나)만 본다.
   TIME_REMAINING > 0 조건은 이미 끝난 이력을 걸러내기 위한 것이다.
   ============================================================================ */
SELECT l.SID, l.SERIAL#,
       s.USERNAME, s.MACHINE, s.PROGRAM,
       l.OPNAME                                        AS 작업,
       l.TARGET                                        AS 대상,
       l.SOFAR                                         AS 처리량,
       l.TOTALWORK                                     AS 총량,
       ROUND(l.SOFAR / NULLIF(l.TOTALWORK,0) * 100, 1) AS 진행률PCT,
       l.ELAPSED_SECONDS                               AS 경과초,
       l.TIME_REMAINING                                AS 남은초추정,
       ROUND(l.TIME_REMAINING/60,1)                    AS 남은분추정,
       TO_CHAR(l.START_TIME,'MM-DD HH24:MI:SS')        AS 시작시각,
       l.SQL_ID,
       l.MESSAGE
  FROM V$SESSION_LONGOPS l
  JOIN V$SESSION s ON s.SID = l.SID AND s.SERIAL# = l.SERIAL#
 WHERE l.TIME_REMAINING > 0
 ORDER BY l.TIME_REMAINING DESC;


/* ============================================================================
   [14] 접속 현황 요약 — 머신별 / 프로그램별

   락 문제가 아니라 "커넥션이 안 반납되고 쌓이는" 문제를 잡을 때 쓴다.
   WAS 커넥션풀이 새면 유휴 세션이 계속 늘어난다.

   보는 법
     유휴1시간이상 이 계속 커지면 커넥션 반납이 안 되고 있는 것이다.
     DBeaver, SQL Developer, Toad 같은 개발 툴이 여러 개 떠 있고
     그 중 유휴가 오래된 것이 있으면 [15] 에서 트랜잭션까지 열었는지 본다.
   ============================================================================ */
SELECT s.MACHINE, s.PROGRAM, s.USERNAME,
       COUNT(*)                                                        AS 세션수,
       SUM(CASE WHEN s.STATUS='ACTIVE'   THEN 1 ELSE 0 END)            AS 활성,
       SUM(CASE WHEN s.STATUS='INACTIVE' THEN 1 ELSE 0 END)            AS 유휴,
       SUM(CASE WHEN s.STATUS='INACTIVE' AND s.LAST_CALL_ET > 3600
                THEN 1 ELSE 0 END)                                     AS 유휴1시간이상,
       MAX(s.LAST_CALL_ET)                                             AS 최대유휴초,
       TO_CHAR(MIN(s.LOGON_TIME),'MM-DD HH24:MI')                      AS 가장오래된접속
  FROM V$SESSION s
 WHERE s.TYPE = 'USER'
 GROUP BY s.MACHINE, s.PROGRAM, s.USERNAME
 ORDER BY 4 DESC;


/* ============================================================================
   [15] ★ 킬 후보 1순위 ★  놀면서 트랜잭션만 붙잡고 있는 세션

   개발자가 DBeaver 나 SQL Developer 에서 UPDATE / DELETE 만 실행하고
   커밋을 안 한 채 퇴근하거나 창을 그냥 열어둔 경우가 여기에 잡힌다.
   [11-5] 주석에 적힌 "ASH 에 안 나오는 블로커" 가 바로 이것이다.
   ASH 는 ACTIVE 세션만 샘플링하므로 이 세션들은 ASH 에 흔적이 없다.

   막고있는세션수 컬럼이 핵심이다.
     0 이면  = 아직 피해는 없다. 지저분하지만 급하지 않다.
     1 이상  = 지금 그 수만큼의 업무가 이 세션 하나 때문에 멈춰 있다.
   ============================================================================ */
SELECT s.SID, s.SERIAL#,
       s.USERNAME, s.OSUSER, s.MACHINE, s.PROGRAM, s.MODULE,
       s.STATUS,
       s.LAST_CALL_ET                                        AS 유휴초,
       ROUND(s.LAST_CALL_ET/60,1)                            AS 유휴분,
       t.START_TIME                                          AS 트랜잭션시작,
       ROUND((SYSDATE - TO_DATE(t.START_TIME,'MM/DD/YY HH24:MI:SS'))*24*60, 1)
                                                             AS 트랜잭션경과분,
       t.USED_UBLK                                           AS 언두블록,
       t.USED_UREC                                           AS 언두레코드,
       (SELECT COUNT(*) FROM V$LOCKED_OBJECT lo
         WHERE lo.SESSION_ID = s.SID)                        AS 잠근객체수,
       (SELECT COUNT(*) FROM V$SESSION w
         WHERE w.BLOCKING_SESSION = s.SID)                   AS 막고있는세션수,
       s.PREV_SQL_ID                                         AS 마지막SQL_ID,
       (SELECT SUBSTR(q.SQL_TEXT,1,200) FROM V$SQL q
         WHERE q.SQL_ID = s.PREV_SQL_ID AND ROWNUM = 1)      AS 마지막SQL
  FROM V$SESSION s
  JOIN V$TRANSACTION t ON t.SES_ADDR = s.SADDR
 WHERE s.STATUS = 'INACTIVE'
 ORDER BY 막고있는세션수 DESC, s.LAST_CALL_ET DESC;


/* ============================================================================
   [16] ★ 킬 하기 전에 반드시 볼 것 ★  대상 세션 한 건 전수 조사

   SID 하나를 넣고 16-1 ~ 16-4 를 차례로 돌린다.
   네 개를 다 보고 나서야 "끊어도 되는 세션인가" 를 말할 수 있다.
   ============================================================================ */

/* --- [16-1] 누가, 어디서, 언제부터, 무엇을 --- */
SELECT s.SID, s.SERIAL#,
       s.USERNAME, s.OSUSER, s.MACHINE, s.PROGRAM, s.MODULE, s.ACTION,
       s.PROCESS                                             AS 클라이언트PID,
       s.STATUS,
       TO_CHAR(s.LOGON_TIME,'MM-DD HH24:MI:SS')              AS 접속시각,
       s.LAST_CALL_ET                                        AS 경과초,
       s.EVENT                                               AS 대기이벤트,
       s.BLOCKING_SESSION                                    AS 나를막는세션,
       s.SQL_ID, s.PREV_SQL_ID
  FROM V$SESSION s
 WHERE s.SID = &SID;                                        /* ← 대상 SID */

/* --- [16-2] 이 세션이 열어둔 트랜잭션 (없으면 0건 = 끊어도 유실 없음) --- */
SELECT s.SID, t.START_TIME AS 트랜잭션시작,
       ROUND((SYSDATE - TO_DATE(t.START_TIME,'MM/DD/YY HH24:MI:SS'))*24*60,1) AS 경과분,
       t.USED_UBLK AS 언두블록, t.USED_UREC AS 언두레코드,
       t.STATUS    AS 트랜잭션상태
  FROM V$SESSION s
  JOIN V$TRANSACTION t ON t.SES_ADDR = s.SADDR
 WHERE s.SID = &SID;

/* --- [16-3] 이 세션이 잠그고 있는 객체 --- */
SELECT o.OWNER, o.OBJECT_NAME, o.OBJECT_TYPE,
       DECODE(lo.LOCKED_MODE,2,'RS',3,'RX',4,'S',5,'SRX',6,'X',
              TO_CHAR(lo.LOCKED_MODE)) AS 락모드
  FROM V$LOCKED_OBJECT lo
  JOIN DBA_OBJECTS o ON o.OBJECT_ID = lo.OBJECT_ID
 WHERE lo.SESSION_ID = &SID
 ORDER BY o.OBJECT_NAME;

/* --- [16-4] ★ 피해 범위 ★ 이 세션 때문에 지금 막혀 있는 세션들 --- */
/*     0건이면 지금 아무도 피해를 안 보고 있다는 뜻이다.                */
/*     굳이 위험을 감수하고 끊을 이유가 있는지 다시 생각한다.            */
SELECT w.SID AS 막힌SID, w.USERNAME, w.MACHINE, w.PROGRAM,
       w.SECONDS_IN_WAIT AS 대기초,
       ROUND(w.SECONDS_IN_WAIT/60,1) AS 대기분,
       w.EVENT, w.SQL_ID
  FROM V$SESSION w
 WHERE w.BLOCKING_SESSION = &SID
 ORDER BY w.SECONDS_IN_WAIT DESC;


/* ============================================================================
   [17] ★ 킬의 비용 ★  끊으면 롤백에 얼마나 걸릴지

   여기서 오해가 많다. KILL SESSION 은 "즉시 락 해제" 가 아니다.
   오라클은 그 세션이 하던 작업을 언두를 읽어 되돌린 뒤에야 락을 푼다.
   되돌릴 양이 많으면 롤백에만 수십 분이 걸리고, 그동안 락은 그대로 잡혀 있다.
   심지어 롤백은 원래 작업보다 느린 경우도 흔하다.

   언두블록이 큰 세션(대량 배치 UPDATE/DELETE 중)이면
   끊는 것보다 그냥 끝나기를 기다리는 편이 빠를 수 있다. 이 판단을 위한 쿼리다.

   ※ 언두MB 는 블록 크기 8K 를 가정한 값이다. DB 블록 크기가 다르면
     아래 숫자 8192 를 실제 값으로 바꿔서 본다.
   ============================================================================ */
SELECT s.SID, s.SERIAL#, s.USERNAME, s.MACHINE, s.PROGRAM, s.STATUS,
       s.LAST_CALL_ET                              AS 경과초,
       t.USED_UBLK                                 AS 언두블록,
       t.USED_UREC                                 AS 언두레코드,
       ROUND(t.USED_UBLK * 8192 / 1024 / 1024, 1)  AS 언두MB_8K기준,
       CASE WHEN t.USED_UBLK > 100000 THEN '★★ 롤백 매우 오래 (수십분+). 끊지 말고 기다리는 쪽 검토'
            WHEN t.USED_UBLK >  10000 THEN '★ 롤백 수 분 예상'
            WHEN t.USED_UBLK >   1000 THEN '롤백 수십 초'
            ELSE '롤백 부담 거의 없음' END         AS 킬비용판단,
       (SELECT COUNT(*) FROM V$SESSION w WHERE w.BLOCKING_SESSION = s.SID)
                                                   AS 막고있는세션수
  FROM V$TRANSACTION t
  JOIN V$SESSION s ON s.SADDR = t.SES_ADDR
 ORDER BY t.USED_UBLK DESC;


/* ****************************************************************************
   [18] 종료 / 취소 문장 생성        ※ 생성만 한다. 실행은 사람이 판단한다.

   ── 세 가지 선택지, 위험한 순서대로 ──

   1) ALTER SYSTEM CANCEL SQL 'SID, SERIAL#';           (19c 이상)
        가장 덜 위험하다. 세션은 살려두고 지금 돌고 있는 SQL 만 취소한다.
        해당 SQL 만 롤백되고 커넥션은 유지되므로 애플리케이션이 에러를 받고
        정상적으로 재시도할 수 있다. 오래 도는 조회/DML 을 멈출 때 1순위.

   2) ALTER SYSTEM DISCONNECT SESSION 'SID, SERIAL#' POST_TRANSACTION;
        지금 트랜잭션이 끝날 때까지 기다렸다가 끊는다. 데이터 유실이 없다.
        단, 그 세션이 커밋을 영영 안 하면 영영 안 끊긴다.
        "다음 커밋 뒤에 정리하고 싶다" 는 상황에 쓴다.

   3) ALTER SYSTEM KILL SESSION 'SID, SERIAL#' IMMEDIATE;
        되돌릴 수 없다. 진행 중이던 트랜잭션은 롤백된다.
        IMMEDIATE 는 "롤백을 즉시 시작하고 제어권을 바로 돌려준다" 는 뜻이지
        "즉시 끝난다" 는 뜻이 아니다. 롤백 자체는 [17] 만큼 걸린다.

   ── 실행 전 확인 목록 ──
        [16-4] 로 실제 피해가 있는지 확인했다              → 0건이면 끊지 않는다
        [17] 로 롤백 비용을 확인했다
        [16-1] 로 어느 팀 무슨 작업인지 확인했다
        운영 담당자와 합의했다
        POS 실시간 트랜잭션(solbi_api*)이 아니다           → 매출 유실 위험
   **************************************************************************** */

/* --- [18-1] 특정 SID 하나에 대한 세 가지 문장 전부 생성 --- */
SELECT s.SID, s.SERIAL#, s.USERNAME, s.MACHINE, s.PROGRAM, s.STATUS,
       s.LAST_CALL_ET AS 경과초,
       'ALTER SYSTEM CANCEL SQL '''||s.SID||', '||s.SERIAL#||''';'
                                                  AS "①SQL만취소_19c",
       'ALTER SYSTEM DISCONNECT SESSION '''||s.SID||','||s.SERIAL#||''' POST_TRANSACTION;'
                                                  AS "②커밋후끊기_안전",
       'ALTER SYSTEM KILL SESSION '''||s.SID||','||s.SERIAL#||''' IMMEDIATE;'
                                                  AS "③즉시종료_비가역"
  FROM V$SESSION s
 WHERE s.SID = &SID;                                        /* ← 대상 SID */

/* --- [18-2] 유휴 트랜잭션 세션 중, 실제로 남을 막고 있는 것만 --- */
/*     조건을 일부러 좁게 걸어 두었다.                                   */
/*       INACTIVE   : 지금 일하는 중이 아님                              */
/*       유휴 30분+ : 실수로 방치된 것일 가능성이 높음                    */
/*       막는 세션 1건 이상 : 실제 피해가 발생 중                        */
/*     조건을 풀고 싶으면 아래 숫자만 바꾼다. 다 지우고 쓰지는 말 것.      */
SELECT s.SID, s.SERIAL#, s.USERNAME, s.OSUSER, s.MACHINE, s.PROGRAM,
       ROUND(s.LAST_CALL_ET/60,1)                 AS 유휴분,
       t.USED_UBLK                                AS 언두블록,
       (SELECT COUNT(*) FROM V$SESSION w WHERE w.BLOCKING_SESSION = s.SID)
                                                  AS 막고있는세션수,
       'ALTER SYSTEM KILL SESSION '''||s.SID||','||s.SERIAL#||''' IMMEDIATE;'
                                                  AS KILL_문
  FROM V$SESSION s
  JOIN V$TRANSACTION t ON t.SES_ADDR = s.SADDR
 WHERE s.STATUS = 'INACTIVE'
   AND s.LAST_CALL_ET > 1800                                /* ← 유휴 30분 */
   AND EXISTS (SELECT 1 FROM V$SESSION w WHERE w.BLOCKING_SESSION = s.SID)
 ORDER BY s.LAST_CALL_ET DESC;

/* --- [18-3] 특정 머신 / 프로그램의 세션 정리용 --- */
/*     예: 퇴근한 개발자 PC 의 DBeaver 세션만 골라낼 때.                  */
/*     WHERE 를 반드시 좁게 유지한다. 머신명을 지우면 전체가 나온다.       */
SELECT s.SID, s.SERIAL#, s.USERNAME, s.MACHINE, s.PROGRAM, s.STATUS,
       ROUND(s.LAST_CALL_ET/60,1) AS 유휴분,
       CASE WHEN t.SES_ADDR IS NULL THEN '트랜잭션 없음(안전)'
            ELSE '트랜잭션 열려있음 ★ 롤백 발생' END AS 트랜잭션여부,
       'ALTER SYSTEM KILL SESSION '''||s.SID||','||s.SERIAL#||''' IMMEDIATE;' AS KILL_문
  FROM V$SESSION s
  LEFT JOIN V$TRANSACTION t ON t.SES_ADDR = s.SADDR
 WHERE UPPER(s.MACHINE) LIKE '%LIMKJOO%'                    /* ← 머신 */
/* AND UPPER(s.PROGRAM) LIKE '%DBEAVER%' */                 /* ← 필요시 */
   AND s.STATUS = 'INACTIVE'
 ORDER BY s.LAST_CALL_ET DESC;

/* --- [18-4] RAC 인 경우 : 인스턴스 번호까지 붙인 KILL 문 --- */
/*     RAC 에서는 다른 인스턴스의 세션을 끊으려면 ,@INST_ID 가 필요하다.  */
/*     단일 인스턴스면 이 절은 무시한다.                                 */
SELECT s.INST_ID, s.SID, s.SERIAL#, s.USERNAME, s.MACHINE, s.PROGRAM,
       'ALTER SYSTEM KILL SESSION '''
         ||s.SID||','||s.SERIAL#||',@'||s.INST_ID||''' IMMEDIATE;' AS KILL_문_RAC
  FROM GV$SESSION s
 WHERE s.SID IN (SELECT BLOCKING_SESSION FROM GV$SESSION
                  WHERE BLOCKING_SESSION IS NOT NULL)
 ORDER BY s.INST_ID, s.LAST_CALL_ET DESC;


/* ============================================================================
   [19] 종료 후 확인 — 정말 정리됐는지

   KILL 직후 세션은 바로 사라지지 않는다. 다음 상태를 거친다.
     KILLED : 종료 표시가 붙었고 롤백 중이거나 정리 대기 중.
              클라이언트가 다시 접속을 시도해야 완전히 없어지는 경우도 있다.
     SNIPED : 리소스 프로파일의 유휴 시간 초과로 오라클이 끊어둔 상태.

   KILLED 인데 오래 남아 있으면 대부분 롤백 중이다. 19-2 로 진행률을 본다.
   기다리는 것 말고 할 수 있는 일이 없다. 다시 킬해도 빨라지지 않는다.
   ============================================================================ */

/* --- [19-1] 종료 표시가 붙은 세션 --- */
SELECT s.SID, s.SERIAL#, s.USERNAME, s.MACHINE, s.PROGRAM,
       s.STATUS,
       s.LAST_CALL_ET AS 경과초,
       TO_CHAR(s.LOGON_TIME,'MM-DD HH24:MI:SS') AS 접속시각,
       (SELECT t.USED_UBLK FROM V$TRANSACTION t WHERE t.SES_ADDR = s.SADDR)
              AS 남은언두블록
  FROM V$SESSION s
 WHERE s.STATUS IN ('KILLED','SNIPED')
 ORDER BY s.LAST_CALL_ET DESC;

/* --- [19-2] 롤백 진행률 --- */
/*     남은언두블록(19-1)이 줄고 있고 진행률이 오르면 정상 진행 중이다.    */
SELECT l.SID, l.SERIAL#,
       l.OPNAME                                        AS 작업,
       l.SOFAR, l.TOTALWORK,
       ROUND(l.SOFAR / NULLIF(l.TOTALWORK,0) * 100, 1) AS 진행률PCT,
       l.ELAPSED_SECONDS                               AS 경과초,
       l.TIME_REMAINING                                AS 남은초추정,
       TO_CHAR(l.START_TIME,'MM-DD HH24:MI:SS')        AS 시작
  FROM V$SESSION_LONGOPS l
 WHERE UPPER(l.OPNAME) LIKE '%ROLLBACK%'
   AND l.TIME_REMAINING > 0
 ORDER BY l.TIME_REMAINING DESC;

/* --- [19-3] 정리 후 락이 실제로 풀렸는지 재확인 --- */
/*     [1] 을 다시 돌리는 것과 같다. 0건이면 상황 종료.                   */
SELECT COUNT(*) AS 남은대기세션수,
       MAX(SECONDS_IN_WAIT) AS 최대대기초
  FROM V$SESSION
 WHERE BLOCKING_SESSION IS NOT NULL;


/* ============================================================================
   [20] RAC 전체 인스턴스에서 블로킹 보기

   단일 인스턴스면 [1] 과 결과가 같다. 넘어가도 된다.
   RAC 인 경우 대기 세션과 블로커가 서로 다른 인스턴스에 있을 수 있어서,
   V$ (내 인스턴스만) 로 보면 블로커가 안 보이는 일이 생긴다.
   BLOCKING_INSTANCE 가 블로커가 붙어 있는 인스턴스 번호다.
   ============================================================================ */
SELECT w.INST_ID                     AS 대기인스턴스,
       w.SID                         AS 대기SID,
       w.SERIAL#                     AS 대기SERIAL,
       w.USERNAME, w.MACHINE, w.PROGRAM,
       w.SECONDS_IN_WAIT             AS 대기초,
       w.EVENT                       AS 대기이벤트,
       w.BLOCKING_INSTANCE           AS 블로커인스턴스,
       w.BLOCKING_SESSION            AS 블로커SID,
       b.USERNAME                    AS 블로커USER,
       b.MACHINE                     AS 블로커MACHINE,
       b.PROGRAM                     AS 블로커PROGRAM,
       b.STATUS                      AS 블로커상태,
       b.LAST_CALL_ET                AS 블로커경과초
  FROM GV$SESSION w
  LEFT JOIN GV$SESSION b
         ON b.INST_ID = w.BLOCKING_INSTANCE
        AND b.SID     = w.BLOCKING_SESSION
 WHERE w.BLOCKING_SESSION IS NOT NULL
 ORDER BY w.SECONDS_IN_WAIT DESC;


/* ****************************************************************************
   [21] 상황별 판단 순서 정리 (실행할 SQL 없음, 읽는 용도)

   ── A. "화면이 안 넘어가요 / 저장이 안 돼요" 신고를 받았을 때 ──
     [1]  대기가 있나?
          0건  -> 락 문제가 아니다. [12] 로 무거운 쿼리를 찾거나 앱/네트워크를 본다.
          1건+ -> 블로커SID 를 확보하고 다음으로.
     [16] 그 블로커 SID 를 전수 조사한다. 누가 무엇을 하다 멈췄는지 확인.
     [16-4] 피해 세션이 몇 개인지 센다. 이게 급한 정도를 정한다.
     [17] 끊었을 때 롤백에 얼마나 걸릴지 본다.
     [18] 담당자 합의 후 문장을 만들어 실행한다.
     [19] 풀렸는지 확인한다.

   ── B. "아까 잠깐 느렸는데 지금은 괜찮아요" 일 때 ──
     지금 조회해도 안 나온다. 이미 끝난 일이다.
     [10] / [11] 의 ASH 로 과거를 본다. ASH 는 약 1시간 ~ 하루치가 남는다.
     그보다 과거는 AWR(DBA_HIST_*) 이 필요하고 별도 라이선스 대상이다.

   ── C. 블로커가 [1] 에는 SID 로 보이는데 ASH([11]) 에는 안 나올 때 ──
     ASH 는 ACTIVE 세션만 샘플링한다.
     즉 그 블로커는 놀고 있으면서 트랜잭션만 붙잡고 있는 세션이다.
     [15] 로 직행한다. 실무에서 가장 흔한 원인이다.

   ── D. 끊으면 안 되는 세션 ──
     · solbi_api* / solbi_was* 의 ACTIVE 상태 POS 실시간 트랜잭션
       -> 매출 데이터가 유실될 수 있다. 앱 담당자 없이 절대 끊지 않는다.
     · 언두블록이 매우 큰 대량 배치([17] 에서 ★★)
       -> 끊는 게 기다리는 것보다 느릴 수 있다.
     · SYS / 백그라운드 프로세스 (TYPE <> 'USER')
       -> 인스턴스가 내려갈 수 있다.

   ── E. 끊기 전에 먼저 해볼 것 ──
     · 19c 이상이면 [18-1] ① 로 SQL 만 취소해 본다. 커넥션은 살아 있으므로
       애플리케이션이 에러를 받고 스스로 재시도한다. 피해가 가장 작다.
     · WAS 커넥션풀이 원인이면 DB 세션을 끊어도 풀이 다시 만들어낸다.
       WAS 쪽 정리가 근본 조치인 경우가 많다.
     · 개발자 툴(DBeaver, SQL Developer)이면 그 사람에게 연락해
       커밋/롤백을 직접 하게 하는 것이 가장 안전하다. 1분이면 된다.

   ── F. 다시 안 생기게 하려면 ──
     · 개발 툴의 자동 커밋 설정을 확인시킨다. 수동 커밋 모드로 두고
       커밋을 잊는 것이 대부분의 원인이다.
     · 애플리케이션 트랜잭션 안에서 외부 호출(HTTP, 파일)을 하지 않는다.
       외부가 느려지면 트랜잭션이 그만큼 길게 열려 있게 된다.
     · [11] ① 처럼 같은 행을 여러 세션이 동시에 MERGE 하는 구간은
       처리 순서를 정하거나 배치 시간대를 분리한다.
     · FK 컬럼에 인덱스가 없으면 enq: TM - contention 이 난다.
       [6] 에 TM 경합이 보이면 인덱스 누락을 의심한다.
   **************************************************************************** */


/* ============================================================================
   [22] 참고 : 세션 조회를 위한 최소 권한

   지금 SBPORA 계정으로 위 뷰들이 보인다면 이미 필요한 권한은 있다.
   다만 KILL 은 조회 권한과 별개다.
     ALTER SYSTEM 권한이 없으면 [18] 의 문장을 만들 수는 있어도
     실행하면 ORA-01031: insufficient privileges 가 난다.
   그 경우 DBA 계정으로 실행하거나 DBA 에게 문장을 전달한다.
   문장을 만들어 두는 것 자체가 전달용으로 쓸모가 있다.

   아래는 지금 계정으로 무엇이 가능한지 확인하는 쿼리다.
   ============================================================================ */
SELECT PRIVILEGE
  FROM SESSION_PRIVS
 WHERE PRIVILEGE IN ('ALTER SYSTEM','SELECT ANY DICTIONARY','ALTER SESSION')
 ORDER BY PRIVILEGE;
