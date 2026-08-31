/* ****************************************************************************
   PKG_CM_COPY_V2 : 기준정보 복사 통합 엔진
                    본사->본사 / 본사->매장 / 매장->매장 공용

   기존 두 구현을 합치고 아래를 고쳤습니다.

   [PKG_CM_COPY_GEN 에서 고친 것]
   1. 감사컬럼 타입 자동 판별
      REG_DT / MOD_DT 가 VARCHAR2 면 TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS'),
      DATE / TIMESTAMP 면 SYSDATE 를 씁니다.
      이전 버전은 무조건 SYSDATE 라 VARCHAR2(14) 컬럼에 '26/09/01' 이
      암묵변환되어 조용히 들어갔습니다.
   2. PK 없는 테이블 안전장치
      PK 가 없으면 NOT EXISTS 조건이 키 하나로만 만들어져 대상에 행이
      하나라도 있으면 전체가 걸러집니다. 이제는 건너뛰고 사유를 남깁니다.
   3. 교차복사(HQ->MS) 시 대상 PK 컬럼이 원본에 없으면 ORA-00904 로 죽던 것을
      실행 전에 검사해 사유와 함께 건너뜁니다.
   4. WHEN OTHERS 로 오류를 삼키지 않습니다. 백트레이스를 남기고,
      G_STOP_ON_ERR='Y' 면 즉시 중단합니다.
   5. 프로시저 안에서 COMMIT / ROLLBACK 하지 않습니다. 호출자가 결정합니다.
      (G_BATCH_SIZE > 0 인 나눠담기 모드만 예외. 아래 주의 참고)

   [PKG_MS_STORE_COPY 에서 가져온 것]
   6. 갱신 모드(M) : 기존 행이 있으면 MERGE 로 갱신합니다.
   7. 재적재 모드(R) : 대상 키 범위를 지우고 새로 넣습니다.
      기존 패키지의 DELETE + INSERT 방식과 같습니다. 운영 매장에 쓰면
      기존 설정이 사라지므로 신규 세팅에만 쓰십시오.
   8. 컬럼 별칭 : 원본에 없는 대상 컬럼을 다른 이름에서 끌어옵니다.
      기본으로 MS_BRAND_CD <-> HQ_BRAND_CD 가 등록돼 있습니다.

   [새로 넣은 것]
   9. 나눠담기 : G_BATCH_SIZE 만큼 끊어서 넣고 커밋합니다. 건수가 많을 때
      UNDO 와 락을 오래 잡지 않습니다. 신규(S) 모드에서만 동작합니다.
   10. SP_DIFF : 원본과 대상의 컬럼 차이를 미리 봅니다.
   11. 값 지정 : SP_MAP_ADD 로 특정 컬럼에 원하는 식을 넣습니다.

   ★★ 실행 주의 ★★
   - G_EXEC_YN 기본 'N' : SQL 을 출력만 하고 실행하지 않습니다.
   - G_BATCH_SIZE > 0 이면 매 묶음마다 COMMIT 합니다. 되돌릴 수 없습니다.
   - EXECUTE IMMEDIATE 로 DML 을 하므로 소유자(SBPORA) 계정으로 돌리거나,
     롤이 아닌 직접 권한을 받은 계정으로 돌려야 합니다.
   **************************************************************************** */

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 32767
SET TRIMSPOOL ON


CREATE OR REPLACE PACKAGE PKG_CM_COPY_V2 AS

    /* ---- 설정 ---------------------------------------------------------- */
    G_OWNER       VARCHAR2(128) := 'SBPORA';   /* 대상 스키마              */
    G_EXEC_YN     CHAR(1)       := 'N';        /* N=출력만, Y=실행         */
    G_USER_ID     VARCHAR2(30)  := 'COPYJOB';  /* REG_ID / MOD_ID 기록값   */
    G_MODE        CHAR(1)       := 'S';        /* S=신규만 M=갱신 R=재적재 */
    G_BATCH_SIZE  PLS_INTEGER   := 0;          /* >0 이면 나눠담기(S 전용) */
    G_SLEEP_SEC   NUMBER        := 0;          /* 묶음 사이 대기 초        */
    G_STOP_ON_ERR CHAR(1)       := 'Y';        /* 오류 시 즉시 중단        */
    G_PRINT_SQL   CHAR(1)       := 'Y';        /* 조립한 SQL 출력          */
    G_DT_FMT      VARCHAR2(30)  := 'YYYYMMDDHH24MISS';

    /* ---- 집계 ---------------------------------------------------------- */
    G_TOT_TAB   PLS_INTEGER := 0;
    G_TOT_ROW   PLS_INTEGER := 0;
    G_TOT_SKIP  PLS_INTEGER := 0;
    G_TOT_ERR   PLS_INTEGER := 0;

    /* ---- 제어 ---------------------------------------------------------- */
    PROCEDURE SP_RESET;
    PROCEDURE SP_SUMMARY;

    /* 다음 복사 1건에만 적용되는 컬럼 값 지정. 호출 뒤 자동으로 비워집니다.
       예) SP_MAP_ADD('REG_FG', '''H'''); */
    PROCEDURE SP_MAP_ADD   ( PI_COL IN VARCHAR2, PI_EXPR IN VARCHAR2 );
    PROCEDURE SP_MAP_CLEAR;

    /* 원본에 없는 대상 컬럼을 다른 이름에서 끌어옵니다. 세션 내내 유지됩니다. */
    PROCEDURE SP_ALIAS_ADD ( PI_TGT_COL IN VARCHAR2, PI_SRC_COL IN VARCHAR2 );

    /* 원본 / 대상 컬럼 차이 확인 (SELECT 만) */
    PROCEDURE SP_DIFF      ( PI_SRC_TABLE IN VARCHAR2
                           , PI_TGT_TABLE IN VARCHAR2 );

    /* 교차 복사 : 원본 테이블 -> 대상 테이블 (HQ->MS) */
    PROCEDURE SP_COPY      ( PI_SRC_TABLE   IN VARCHAR2
                           , PI_TGT_TABLE   IN VARCHAR2
                           , PI_SRC_KEY_COL IN VARCHAR2
                           , PI_TGT_KEY_COL IN VARCHAR2
                           , PI_SRC_KEY     IN VARCHAR2
                           , PI_TGT_KEY     IN VARCHAR2
                           , PI_EXTRA_WH    IN VARCHAR2 DEFAULT NULL );

    /* 동일 테이블 복사 : 키값만 교체 (HQ->HQ, MS->MS) */
    PROCEDURE SP_COPY_SAME ( PI_TABLE    IN VARCHAR2
                           , PI_KEY_COL  IN VARCHAR2
                           , PI_SRC_KEY  IN VARCHAR2
                           , PI_TGT_KEY  IN VARCHAR2
                           , PI_EXTRA_WH IN VARCHAR2 DEFAULT NULL );

END PKG_CM_COPY_V2;
/


CREATE OR REPLACE PACKAGE BODY PKG_CM_COPY_V2 AS

    TYPE T_STR_MAP IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(128);

    G_MAP    T_STR_MAP;    /* 1회용 컬럼 값 지정 */
    G_ALIAS  T_STR_MAP;    /* 대상컬럼 -> 원본컬럼 별칭 */


    /* ==================================================================
       출력
       ================================================================== */
    PROCEDURE P( PI_TEXT IN VARCHAR2 ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE( NVL(PI_TEXT, ' ') );
    END P;


    PROCEDURE P_CLOB( PI_TEXT IN CLOB ) IS
        V_LEN  PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(PI_TEXT), 0);
        V_POS  PLS_INTEGER := 1;
        V_NL   PLS_INTEGER;
    BEGIN
        WHILE V_POS <= V_LEN LOOP
            V_NL := DBMS_LOB.INSTR(PI_TEXT, CHR(10), V_POS);
            IF V_NL = 0 OR V_NL - V_POS > 3000 THEN
                P( DBMS_LOB.SUBSTR(PI_TEXT, LEAST(3000, V_LEN - V_POS + 1), V_POS) );
                V_POS := V_POS + LEAST(3000, V_LEN - V_POS + 1);
            ELSE
                P( DBMS_LOB.SUBSTR(PI_TEXT, V_NL - V_POS, V_POS) );
                V_POS := V_NL + 1;
            END IF;
        END LOOP;
    END P_CLOB;


    /* ==================================================================
       문자열 리터럴 (작은따옴표 이스케이프)
       ================================================================== */
    FUNCTION FN_Q( PI_S IN VARCHAR2 ) RETURN VARCHAR2 IS
    BEGIN
        RETURN '''' || REPLACE(PI_S, '''', '''''') || '''';
    END FN_Q;


    /* ==================================================================
       컬럼 타입 조회 (없으면 NULL)
       ================================================================== */
    FUNCTION FN_COL_TYPE( PI_TABLE IN VARCHAR2, PI_COL IN VARCHAR2 )
    RETURN VARCHAR2 IS
        V_TYPE VARCHAR2(128);
    BEGIN
        SELECT MAX(DATA_TYPE) INTO V_TYPE
          FROM ALL_TAB_COLUMNS
         WHERE OWNER       = G_OWNER
           AND TABLE_NAME  = PI_TABLE
           AND COLUMN_NAME = PI_COL;
        RETURN V_TYPE;
    END FN_COL_TYPE;


    FUNCTION FN_HAS_COL( PI_TABLE IN VARCHAR2, PI_COL IN VARCHAR2 )
    RETURN BOOLEAN IS
    BEGIN
        RETURN FN_COL_TYPE(PI_TABLE, PI_COL) IS NOT NULL;
    END FN_HAS_COL;


    FUNCTION FN_TAB_EXISTS( PI_TABLE IN VARCHAR2 ) RETURN BOOLEAN IS
        V_CNT PLS_INTEGER;
    BEGIN
        SELECT COUNT(*) INTO V_CNT
          FROM ALL_TABLES
         WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TABLE;
        RETURN V_CNT > 0;
    END FN_TAB_EXISTS;


    /* ==================================================================
       감사일자 컬럼 표현식 : 타입에 맞춰 결정
       ================================================================== */
    FUNCTION FN_DT_EXPR( PI_TABLE IN VARCHAR2, PI_COL IN VARCHAR2 )
    RETURN VARCHAR2 IS
        V_TYPE VARCHAR2(128) := FN_COL_TYPE(PI_TABLE, PI_COL);
    BEGIN
        IF V_TYPE = 'DATE' OR V_TYPE LIKE 'TIMESTAMP%' THEN
            RETURN 'SYSDATE';
        ELSE
            RETURN 'TO_CHAR(SYSDATE,' || FN_Q(G_DT_FMT) || ')';
        END IF;
    END FN_DT_EXPR;


    /* ==================================================================
       대상 PK 컬럼 목록
       ================================================================== */
    FUNCTION FN_PK_COLS( PI_TABLE IN VARCHAR2 )
    RETURN SYS.ODCIVARCHAR2LIST IS
        V_LIST SYS.ODCIVARCHAR2LIST;
    BEGIN
        SELECT CC.COLUMN_NAME
          BULK COLLECT INTO V_LIST
          FROM ALL_CONSTRAINTS  C
          JOIN ALL_CONS_COLUMNS CC
            ON  CC.OWNER           = C.OWNER
            AND CC.CONSTRAINT_NAME = C.CONSTRAINT_NAME
         WHERE C.OWNER           = G_OWNER
           AND C.TABLE_NAME      = PI_TABLE
           AND C.CONSTRAINT_TYPE = 'P'
         ORDER BY CC.POSITION;
        RETURN V_LIST;
    END FN_PK_COLS;


    FUNCTION FN_IN_LIST( PI_LIST IN SYS.ODCIVARCHAR2LIST
                       , PI_COL  IN VARCHAR2 ) RETURN BOOLEAN IS
    BEGIN
        IF PI_LIST IS NULL THEN RETURN FALSE; END IF;
        FOR I IN 1 .. PI_LIST.COUNT LOOP
            IF PI_LIST(I) = PI_COL THEN RETURN TRUE; END IF;
        END LOOP;
        RETURN FALSE;
    END FN_IN_LIST;


    /* ==================================================================
       대상 컬럼 하나의 원본 표현식.
       끌어올 곳이 없으면 NULL 을 돌려줍니다.
       ================================================================== */
    FUNCTION FN_EXPR( PI_SRC_TABLE   IN VARCHAR2
                    , PI_TGT_TABLE   IN VARCHAR2
                    , PI_COL         IN VARCHAR2
                    , PI_TGT_KEY_COL IN VARCHAR2
                    , PI_TGT_KEY     IN VARCHAR2 )
    RETURN VARCHAR2 IS
        V_SRC_COL VARCHAR2(128);
    BEGIN
        /* 1) 이번 건에 직접 지정한 값 */
        IF G_MAP.EXISTS(PI_COL) THEN
            RETURN G_MAP(PI_COL);
        END IF;

        /* 2) 키 컬럼 */
        IF PI_COL = PI_TGT_KEY_COL THEN
            RETURN FN_Q(PI_TGT_KEY);
        END IF;

        /* 3) 감사 컬럼 */
        IF PI_COL IN ('REG_DT', 'MOD_DT') THEN
            RETURN FN_DT_EXPR(PI_TGT_TABLE, PI_COL);
        END IF;
        IF PI_COL IN ('REG_ID', 'MOD_ID') THEN
            RETURN FN_Q(G_USER_ID);
        END IF;

        /* 4) 원본에 같은 이름이 있으면 그대로 */
        IF FN_HAS_COL(PI_SRC_TABLE, PI_COL) THEN
            RETURN 's."' || PI_COL || '"';
        END IF;

        /* 5) 별칭으로 끌어오기 */
        IF G_ALIAS.EXISTS(PI_COL) THEN
            V_SRC_COL := G_ALIAS(PI_COL);
            IF FN_HAS_COL(PI_SRC_TABLE, V_SRC_COL) THEN
                RETURN 's."' || V_SRC_COL || '"';
            END IF;
        END IF;

        RETURN NULL;
    END FN_EXPR;


    /* ==================================================================
       실행 / 출력
       ================================================================== */
    FUNCTION FN_RUN( PI_SQL IN CLOB ) RETURN PLS_INTEGER IS
        V_CNT PLS_INTEGER := 0;
    BEGIN
        IF G_PRINT_SQL = 'Y' THEN
            P_CLOB(PI_SQL);
            P(';');
        END IF;

        IF G_EXEC_YN = 'Y' THEN
            EXECUTE IMMEDIATE PI_SQL;
            V_CNT := SQL%ROWCOUNT;
        END IF;

        RETURN V_CNT;
    END FN_RUN;


    PROCEDURE SP_SLEEP IS
    BEGIN
        IF G_SLEEP_SEC > 0 THEN
            EXECUTE IMMEDIATE 'BEGIN DBMS_LOCK.SLEEP(:1); END;' USING G_SLEEP_SEC;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;   /* DBMS_LOCK 권한이 없으면 그냥 넘어갑니다 */
    END SP_SLEEP;


    /* ==================================================================
       제어
       ================================================================== */
    PROCEDURE SP_RESET IS
    BEGIN
        G_TOT_TAB  := 0;
        G_TOT_ROW  := 0;
        G_TOT_SKIP := 0;
        G_TOT_ERR  := 0;
        G_MAP.DELETE;
    END SP_RESET;


    PROCEDURE SP_MAP_ADD( PI_COL IN VARCHAR2, PI_EXPR IN VARCHAR2 ) IS
    BEGIN
        G_MAP(UPPER(PI_COL)) := PI_EXPR;
    END SP_MAP_ADD;


    PROCEDURE SP_MAP_CLEAR IS
    BEGIN
        G_MAP.DELETE;
    END SP_MAP_CLEAR;


    PROCEDURE SP_ALIAS_ADD( PI_TGT_COL IN VARCHAR2, PI_SRC_COL IN VARCHAR2 ) IS
    BEGIN
        G_ALIAS(UPPER(PI_TGT_COL)) := UPPER(PI_SRC_COL);
    END SP_ALIAS_ADD;


    PROCEDURE SP_SUMMARY IS
    BEGIN
        P('/* ======================================================== */');
        P('/*  모드         : ' || CASE G_MODE
                                     WHEN 'S' THEN 'S 신규만'
                                     WHEN 'M' THEN 'M 갱신'
                                     WHEN 'R' THEN 'R 재적재'
                                     ELSE G_MODE END
                              || CASE WHEN G_BATCH_SIZE > 0
                                      THEN '   나눠담기 ' || G_BATCH_SIZE || '건'
                                      ELSE '' END);
        P('/*  처리 테이블  : ' || G_TOT_TAB);
        P('/*  건너뛴 테이블: ' || G_TOT_SKIP);
        P('/*  처리 건수    : ' || G_TOT_ROW
                              || CASE WHEN G_EXEC_YN = 'N' THEN '   (미실행)' ELSE '' END);
        P('/*  오류         : ' || G_TOT_ERR);
        P('/* ======================================================== */');

        IF G_TOT_ERR > 0 THEN
            P('-- !! 오류가 있습니다. 위 로그를 확인하고 COMMIT 하지 마십시오.');
        END IF;
    END SP_SUMMARY;


    /* ==================================================================
       컬럼 차이 확인
       ================================================================== */
    PROCEDURE SP_DIFF( PI_SRC_TABLE IN VARCHAR2, PI_TGT_TABLE IN VARCHAR2 ) IS
        V_CNT PLS_INTEGER := 0;
    BEGIN
        P('/* ---- 컬럼 비교 : ' || PI_SRC_TABLE || ' -> ' || PI_TGT_TABLE || ' ---- */');

        IF NOT FN_TAB_EXISTS(PI_SRC_TABLE) OR NOT FN_TAB_EXISTS(PI_TGT_TABLE) THEN
            P('-- !! 테이블이 없습니다.');
            RETURN;
        END IF;

        P('-- 대상에만 있는 컬럼 (원본에서 못 끌어옴)');
        FOR C IN ( SELECT COLUMN_NAME, NULLABLE, DATA_TYPE, DEFAULT_LENGTH
                     FROM ALL_TAB_COLUMNS
                    WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TGT_TABLE
                    ORDER BY COLUMN_ID )
        LOOP
            IF NOT FN_HAS_COL(PI_SRC_TABLE, C.COLUMN_NAME)
               AND C.COLUMN_NAME NOT IN ('REG_DT','REG_ID','MOD_DT','MOD_ID')
               AND NOT (G_ALIAS.EXISTS(C.COLUMN_NAME)
                        AND FN_HAS_COL(PI_SRC_TABLE, G_ALIAS(C.COLUMN_NAME)))
            THEN
                V_CNT := V_CNT + 1;
                P('--   ' || RPAD(C.COLUMN_NAME, 34) || RPAD(C.DATA_TYPE, 14)
                  || CASE WHEN C.NULLABLE = 'N' AND C.DEFAULT_LENGTH IS NULL
                          THEN '<< NOT NULL, 기본값 없음. 값 지정 필요'
                          WHEN C.NULLABLE = 'N' THEN '   NOT NULL (기본값 있음)'
                          ELSE '' END);
            END IF;
        END LOOP;
        IF V_CNT = 0 THEN P('--   없음'); END IF;

        V_CNT := 0;
        P('-- 원본에만 있는 컬럼 (버려짐)');
        FOR C IN ( SELECT COLUMN_NAME, DATA_TYPE
                     FROM ALL_TAB_COLUMNS
                    WHERE OWNER = G_OWNER AND TABLE_NAME = PI_SRC_TABLE
                    ORDER BY COLUMN_ID )
        LOOP
            IF NOT FN_HAS_COL(PI_TGT_TABLE, C.COLUMN_NAME) THEN
                V_CNT := V_CNT + 1;
                P('--   ' || RPAD(C.COLUMN_NAME, 34) || C.DATA_TYPE);
            END IF;
        END LOOP;
        IF V_CNT = 0 THEN P('--   없음'); END IF;

        P('-- 대상 감사컬럼 타입');
        P('--   REG_DT ' || NVL(FN_COL_TYPE(PI_TGT_TABLE,'REG_DT'),'없음')
          || '   -> ' || FN_DT_EXPR(PI_TGT_TABLE,'REG_DT'));
        P(' ');
    END SP_DIFF;


    /* ==================================================================
       본체 : 교차 복사
       ================================================================== */
    PROCEDURE SP_COPY( PI_SRC_TABLE   IN VARCHAR2
                     , PI_TGT_TABLE   IN VARCHAR2
                     , PI_SRC_KEY_COL IN VARCHAR2
                     , PI_TGT_KEY_COL IN VARCHAR2
                     , PI_SRC_KEY     IN VARCHAR2
                     , PI_TGT_KEY     IN VARCHAR2
                     , PI_EXTRA_WH    IN VARCHAR2 DEFAULT NULL )
    IS
        V_LABEL   VARCHAR2(300) := PI_SRC_TABLE
                                || CASE WHEN PI_SRC_TABLE = PI_TGT_TABLE
                                        THEN '' ELSE ' -> ' || PI_TGT_TABLE END;
        V_COLS    CLOB;      /* "A", "B" ...                */
        V_SELS    CLOB;      /* expr, expr ...              */
        V_SELS_AS CLOB;      /* expr AS "A", ...  (MERGE용) */
        V_VALS    CLOB;      /* B."A", B."B" ...  (MERGE용) */
        V_SETS    CLOB;      /* MERGE UPDATE SET            */
        V_SQL     CLOB;
        V_SQL2    CLOB;
        V_WH      VARCHAR2(4000);
        V_PKCOND  VARCHAR2(4000);
        V_EXPR    VARCHAR2(4000);
        V_MISS_NN VARCHAR2(4000);
        V_PK      SYS.ODCIVARCHAR2LIST;
        V_FIRST   BOOLEAN := TRUE;
        V_SETFST  BOOLEAN := TRUE;
        V_CNT     PLS_INTEGER := 0;
        V_SUM     PLS_INTEGER := 0;
        V_SKIP    VARCHAR2(1000);
    BEGIN
        P('/* ---- ' || V_LABEL || '  [' || G_MODE || '] ---- */');

        /* ---- 1. 존재 확인 ---------------------------------------------- */
        IF NOT FN_TAB_EXISTS(PI_SRC_TABLE) THEN
            V_SKIP := '원본 테이블 ' || PI_SRC_TABLE || ' 없음';
        ELSIF NOT FN_TAB_EXISTS(PI_TGT_TABLE) THEN
            V_SKIP := '대상 테이블 ' || PI_TGT_TABLE || ' 없음';
        ELSIF NOT FN_HAS_COL(PI_SRC_TABLE, PI_SRC_KEY_COL) THEN
            V_SKIP := PI_SRC_TABLE || ' 에 ' || PI_SRC_KEY_COL || ' 컬럼 없음';
        ELSIF NOT FN_HAS_COL(PI_TGT_TABLE, PI_TGT_KEY_COL) THEN
            V_SKIP := PI_TGT_TABLE || ' 에 ' || PI_TGT_KEY_COL || ' 컬럼 없음';
        END IF;

        IF V_SKIP IS NOT NULL THEN
            P('-- >> SKIP : ' || V_SKIP);
            P(' ');
            G_TOT_SKIP := G_TOT_SKIP + 1;
            G_MAP.DELETE;
            RETURN;
        END IF;

        /* ---- 2. PK 확인 ------------------------------------------------- */
        V_PK := FN_PK_COLS(PI_TGT_TABLE);

        IF (V_PK IS NULL OR V_PK.COUNT = 0) AND G_MODE IN ('S','M') THEN
            P('-- >> SKIP : ' || PI_TGT_TABLE || ' PK 없음.');
            P('--           중복차단을 만들 수 없어 건너뜁니다.');
            P('--           재적재(G_MODE=''R'')로 하거나 개별 SQL 을 쓰십시오.');
            P(' ');
            G_TOT_SKIP := G_TOT_SKIP + 1;
            G_MAP.DELETE;
            RETURN;
        END IF;

        /* PK 컬럼을 원본에서 못 끌어오면 조건을 만들 수 없음 */
        IF V_PK IS NOT NULL THEN
            FOR I IN 1 .. V_PK.COUNT LOOP
                IF FN_EXPR(PI_SRC_TABLE, PI_TGT_TABLE, V_PK(I),
                           PI_TGT_KEY_COL, PI_TGT_KEY) IS NULL THEN
                    P('-- >> SKIP : 대상 PK 컬럼 ' || V_PK(I)
                      || ' 을(를) 원본에서 끌어올 수 없습니다.');
                    P('--           SP_MAP_ADD 로 값을 지정하거나 개별 SQL 을 쓰십시오.');
                    P(' ');
                    G_TOT_SKIP := G_TOT_SKIP + 1;
                    G_MAP.DELETE;
                    RETURN;
                END IF;
            END LOOP;
        END IF;

        /* ---- 3. 컬럼 조립 ----------------------------------------------- */
        FOR C IN ( SELECT COLUMN_NAME, NULLABLE, DEFAULT_LENGTH
                     FROM ALL_TAB_COLUMNS
                    WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TGT_TABLE
                    ORDER BY COLUMN_ID )
        LOOP
            V_EXPR := FN_EXPR(PI_SRC_TABLE, PI_TGT_TABLE, C.COLUMN_NAME,
                              PI_TGT_KEY_COL, PI_TGT_KEY);

            IF V_EXPR IS NULL THEN
                V_EXPR := 'NULL';
                IF C.NULLABLE = 'N' AND C.DEFAULT_LENGTH IS NULL THEN
                    V_MISS_NN := V_MISS_NN || C.COLUMN_NAME || ' ';
                END IF;
            END IF;

            IF NOT V_FIRST THEN
                V_COLS    := V_COLS    || ', ';
                V_SELS    := V_SELS    || ', ';
                V_SELS_AS := V_SELS_AS || ', ';
                V_VALS    := V_VALS    || ', ';
            END IF;
            V_FIRST := FALSE;

            V_COLS    := V_COLS    || '"' || C.COLUMN_NAME || '"';
            V_SELS    := V_SELS    || V_EXPR;
            V_SELS_AS := V_SELS_AS || V_EXPR || ' AS "' || C.COLUMN_NAME || '"';
            V_VALS    := V_VALS    || 'B."' || C.COLUMN_NAME || '"';

            /* MERGE 갱신 대상 : PK 와 등록정보 제외 */
            IF NOT FN_IN_LIST(V_PK, C.COLUMN_NAME)
               AND C.COLUMN_NAME NOT IN ('REG_DT', 'REG_ID')
            THEN
                IF NOT V_SETFST THEN V_SETS := V_SETS || ', '; END IF;
                V_SETFST := FALSE;
                V_SETS := V_SETS || 'A."' || C.COLUMN_NAME || '" = B."' || C.COLUMN_NAME || '"';
            END IF;
        END LOOP;

        IF V_MISS_NN IS NOT NULL THEN
            P('-- !! WARN : NOT NULL 인데 값을 못 채운 컬럼 -> ' || V_MISS_NN);
            P('--           SP_MAP_ADD 로 값을 지정하지 않으면 INSERT 가 실패합니다.');
        END IF;

        /* ---- 4. 원본 조건 ----------------------------------------------- */
        V_WH := ' WHERE s."' || PI_SRC_KEY_COL || '" = ' || FN_Q(PI_SRC_KEY)
             || CASE WHEN PI_EXTRA_WH IS NOT NULL
                     THEN CHR(10) || '   AND ' || PI_EXTRA_WH
                     ELSE '' END;

        /* ---- 5. 모드별 SQL ---------------------------------------------- */
        IF G_MODE = 'M' THEN

            V_PKCOND := NULL;
            FOR I IN 1 .. V_PK.COUNT LOOP
                V_PKCOND := V_PKCOND
                         || CASE WHEN I = 1 THEN '' ELSE CHR(10) || '   AND ' END
                         || 'A."' || V_PK(I) || '" = B."' || V_PK(I) || '"';
            END LOOP;

            V_SQL := 'MERGE INTO ' || G_OWNER || '.' || PI_TGT_TABLE || ' A' || CHR(10)
                  || 'USING ( SELECT ' || V_SELS_AS                            || CHR(10)
                  || '          FROM ' || G_OWNER || '.' || PI_SRC_TABLE || ' s' || CHR(10)
                  || '        ' || V_WH                                        || CHR(10)
                  || '      ) B'                                               || CHR(10)
                  || '   ON ( ' || V_PKCOND || ' )'                            || CHR(10);

            IF V_SETS IS NOT NULL THEN
                V_SQL := V_SQL || ' WHEN MATCHED THEN UPDATE SET ' || V_SETS || CHR(10);
            END IF;

            V_SQL := V_SQL
                  || ' WHEN NOT MATCHED THEN INSERT ( ' || V_COLS || ' )' || CHR(10)
                  || '      VALUES ( ' || V_VALS || ' )';

            V_SUM := FN_RUN(V_SQL);

        ELSIF G_MODE = 'R' THEN

            V_SQL2 := 'DELETE FROM ' || G_OWNER || '.' || PI_TGT_TABLE
                   || ' WHERE "' || PI_TGT_KEY_COL || '" = ' || FN_Q(PI_TGT_KEY);
            V_CNT := FN_RUN(V_SQL2);
            P('-- >> DELETED ' || V_CNT || ' rows');

            V_SQL := 'INSERT INTO ' || G_OWNER || '.' || PI_TGT_TABLE       || CHR(10)
                  || '       ( ' || V_COLS || ' )'                          || CHR(10)
                  || 'SELECT ' || V_SELS                                    || CHR(10)
                  || '  FROM ' || G_OWNER || '.' || PI_SRC_TABLE || ' s'    || CHR(10)
                  || V_WH;

            V_SUM := FN_RUN(V_SQL);

        ELSE  /* S : 신규만 */

            V_PKCOND := NULL;
            FOR I IN 1 .. V_PK.COUNT LOOP
                V_PKCOND := V_PKCOND || CHR(10)
                         || '                       AND x."' || V_PK(I) || '" = '
                         || FN_EXPR(PI_SRC_TABLE, PI_TGT_TABLE, V_PK(I),
                                    PI_TGT_KEY_COL, PI_TGT_KEY);
            END LOOP;

            V_SQL := 'INSERT INTO ' || G_OWNER || '.' || PI_TGT_TABLE       || CHR(10)
                  || '       ( ' || V_COLS || ' )'                          || CHR(10)
                  || 'SELECT ' || V_SELS                                    || CHR(10)
                  || '  FROM ' || G_OWNER || '.' || PI_SRC_TABLE || ' s'    || CHR(10)
                  || V_WH                                                   || CHR(10)
                  || '   AND NOT EXISTS ( SELECT 1'                         || CHR(10)
                  || '                      FROM ' || G_OWNER || '.' || PI_TGT_TABLE || ' x'
                  || '                     WHERE 1 = 1' || V_PKCOND         || CHR(10)
                  || '                   )';

            IF G_BATCH_SIZE > 0 THEN
                V_SQL := V_SQL || CHR(10) || '   AND ROWNUM <= ' || G_BATCH_SIZE;

                IF G_EXEC_YN = 'Y' THEN
                    LOOP
                        EXECUTE IMMEDIATE V_SQL;
                        V_CNT := SQL%ROWCOUNT;
                        V_SUM := V_SUM + V_CNT;
                        EXIT WHEN V_CNT = 0;
                        COMMIT;
                        P('-- >> ' || V_CNT || ' rows / 누적 ' || V_SUM || '  (COMMIT)');
                        SP_SLEEP;
                    END LOOP;
                    IF G_PRINT_SQL = 'Y' THEN P_CLOB(V_SQL); P(';'); END IF;
                ELSE
                    V_SUM := FN_RUN(V_SQL);
                    P('-- >> 나눠담기 : 0 건이 될 때까지 반복하며 묶음마다 COMMIT 합니다.');
                END IF;
            ELSE
                V_SUM := FN_RUN(V_SQL);
            END IF;

        END IF;

        /* ---- 6. 마무리 -------------------------------------------------- */
        IF G_EXEC_YN = 'Y' THEN
            P('-- >> ' || V_SUM || ' rows');
        ELSE
            P('-- >> 미실행 (G_EXEC_YN = N)');
        END IF;
        P(' ');

        G_TOT_TAB := G_TOT_TAB + 1;
        G_TOT_ROW := G_TOT_ROW + V_SUM;
        G_MAP.DELETE;

    EXCEPTION
        WHEN OTHERS THEN
            G_TOT_ERR := G_TOT_ERR + 1;
            G_MAP.DELETE;
            P('-- !! ERROR ' || V_LABEL || ' : ' || SQLERRM);
            P('-- !! ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            P(' ');
            IF G_STOP_ON_ERR = 'Y' THEN
                RAISE;
            END IF;
    END SP_COPY;


    /* ==================================================================
       동일 테이블 복사
       ================================================================== */
    PROCEDURE SP_COPY_SAME( PI_TABLE    IN VARCHAR2
                          , PI_KEY_COL  IN VARCHAR2
                          , PI_SRC_KEY  IN VARCHAR2
                          , PI_TGT_KEY  IN VARCHAR2
                          , PI_EXTRA_WH IN VARCHAR2 DEFAULT NULL )
    IS
    BEGIN
        SP_COPY( PI_TABLE, PI_TABLE
               , PI_KEY_COL, PI_KEY_COL
               , PI_SRC_KEY, PI_TGT_KEY
               , PI_EXTRA_WH );
    END SP_COPY_SAME;


/* 세션 시작 시 기본 별칭 등록 */
BEGIN
    G_ALIAS('MS_BRAND_CD') := 'HQ_BRAND_CD';
    G_ALIAS('HQ_BRAND_CD') := 'MS_BRAND_CD';
END PKG_CM_COPY_V2;
/

SHOW ERRORS PACKAGE BODY PKG_CM_COPY_V2


/* ============================================================================
   설치 확인
   ============================================================================ */
SELECT OBJECT_NAME, OBJECT_TYPE, STATUS, LAST_DDL_TIME
  FROM ALL_OBJECTS
 WHERE OBJECT_NAME = 'PKG_CM_COPY_V2'
 ORDER BY OBJECT_TYPE;
