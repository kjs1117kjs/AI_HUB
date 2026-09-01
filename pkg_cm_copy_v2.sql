/* ****************************************************************************
   PKG_CM_COPY_V2 : 기준정보 복사 통합 엔진 (단독 실행형)
                    본사->본사 / 본사->매장 / 매장->매장

   이 패키지 하나만 설치하면 됩니다.
   복사 순서, 사전검증, 백업, 검증까지 전부 안에 들어 있습니다.

       EXEC PKG_CM_COPY_V2.SP_CHECK_ENV('H0514','S611429')     -- 환경 점검
       EXEC PKG_CM_COPY_V2.SP_HQ2HQ('H0393','H0514')           -- 본사->본사
       EXEC PKG_CM_COPY_V2.SP_HQ2MS('H0393','S611429')         -- 본사->매장
       EXEC PKG_CM_COPY_V2.SP_MS2MS('S611428','S611429')       -- 매장->매장

   기본값이 G_EXEC_YN='N' 이라 위 호출은 SQL 을 출력만 합니다.
   반영하려면 G_EXEC_YN='Y', 확정하려면 G_COMMIT_YN='Y' 로 둡니다.

   [기존 PKG_CM_COPY_GEN 에서 고친 것]
   1. 감사컬럼 타입 자동 판별. VARCHAR2 면 TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS'),
      DATE 면 SYSDATE. 이전 버전은 무조건 SYSDATE 라 VARCHAR2(14) 컬럼에
      '26/09/01' 이 암묵변환되어 조용히 들어갔습니다.
   2. PK 없는 테이블은 중복차단을 만들 수 없어 0건으로 끝나던 것을
      사유를 남기고 건너뜁니다.
   3. 대상 PK 컬럼을 원본에서 못 끌어오면 실행 중 ORA-00904 로 죽던 것을
      조립 전에 검사합니다.
   4. WHEN OTHERS 로 오류를 삼키지 않습니다. 백트레이스를 남깁니다.

   [기존 PKG_MS_STORE_COPY 에서 고친 것]
   5. POS 관련 테이블은 원본에 POS 가 없으면 아무것도 하지 않습니다.
      기존 구현은 DELETE 를 IF 밖에 둬서 대상 설정만 지우고 끝났습니다.
   6. POS 번호 매핑을 대상 POS 기준으로 합니다.
   7. RAISE_APPLICATION_ERROR 뒤의 죽은 ROLLBACK 을 없앴습니다.
   8. 트랜잭션은 G_COMMIT_YN 하나로 결정합니다.

   ---------------------------------------------------------------------------
   [ 동작 방식 ]

   이 엔진은 컬럼 목록을 손으로 들고 있지 않습니다. 실행할 때마다 딕셔너리에서
   대상 테이블의 컬럼을 읽어 INSERT / MERGE 문을 조립합니다. 그래서 컬럼이
   추가돼도 스크립트를 고칠 필요가 없습니다.

   컬럼 하나하나의 값은 아래 순서로 정합니다. 먼저 걸리는 것이 이깁니다.

       1) SP_MAP_ADD 로 이번 건에 직접 지정한 값
       2) 키 컬럼            -> 대상 키값 리터럴
       3) REG_DT / MOD_DT    -> 컬럼 타입을 보고 TO_CHAR(SYSDATE,..) 또는 SYSDATE
       4) REG_ID / MOD_ID    -> G_USER_ID
       5) 원본에 같은 이름   -> s."컬럼"
       6) 등록된 별칭        -> s."다른이름"   (예: MS_BRAND_CD <- HQ_BRAND_CD)
       7) 아무것도 없으면    -> NULL. NOT NULL 이면 경고를 찍습니다.

   ---------------------------------------------------------------------------
   [ 모드 ]

     S  신규만    대상에 없는 행만 넣습니다. 기존 값은 손대지 않습니다.
                  중복 판단은 아래 [키 결정] 규칙을 씁니다.
     M  갱신      키가 같으면 UPDATE, 없으면 INSERT (MERGE).
                  REG_DT / REG_ID 는 갱신하지 않아 등록 이력이 남습니다.
     R  재적재    대상 키 범위를 DELETE 한 뒤 전부 넣습니다.
                  키가 없어도 동작하지만 운영 중인 곳에는 쓰지 마십시오.

   ---------------------------------------------------------------------------
   [ 키 결정 ]

   중복 차단(NOT EXISTS)과 MERGE 의 ON 절에 쓸 키를 아래 순서로 찾습니다.

       1) SP_KEY_SET 으로 직접 지정한 컬럼
       2) 기본키(PK)
       3) UNIQUE 제약
       4) UNIQUE 인덱스 (제약이 안 걸린 것)

   3, 4 는 여러 개일 수 있습니다. 그럴 때는 이렇게 고릅니다.

       가) 복사 키 컬럼(HQ_OFFICE_CD / STORE_CD)을 포함한 것을 먼저
       나) 컬럼 수가 적은 것을 먼저
       다) 그래도 같으면 이름 순

   고른 결과와 후보 개수를 매번 출력합니다. 다르게 쓰고 싶으면
   SP_KEY_SET('TB_XXX', 'COL1,COL2') 로 지정하십시오.
   SP_KEY_REPORT 로 테이블별 후보를 미리 볼 수 있습니다.

   NULL 을 허용하는 컬럼이 키에 끼면 NOT EXISTS 비교가 NULL 이 되어
   중복 차단이 새어나갑니다. 이 경우 경고를 찍습니다.

   ---------------------------------------------------------------------------
   [ 실행 전에 보는 것 ]

   전부 SELECT 만 합니다. 데이터를 건드리지 않습니다.

     SP_CHECK_ENV   권한 · 감사컬럼 타입 · 뿌리 행 · 키 상태
     SP_KEY_REPORT  테이블별로 어떤 키를 중복 판단에 쓸지
     SP_DIFF        원본과 대상의 컬럼 차이, 타입 · 길이 불일치
     SP_REF_CHECK   원본이 참조하는 값이 대상에 있는지 (FK 기준)

     G_PREVIEW_YN='Y' 로 두고 SP_HQ2HQ 등을 부르면 실제로 넣지 않고
     테이블별 예상 건수만 셉니다.

         -- 예상 : 원본  3,412 / 대상 현재      0 / 신규  3,412 / 이미있음      0
         --        S 모드 -> 3,412 건 INSERT
         --        나눠담기 1000 건씩 -> 약 4 회 반복

   ---------------------------------------------------------------------------
   [ 실행되는 쿼리 확인 ]

   G_EXEC_YN='N' 이면 조립한 SQL 을 출력만 합니다. 출력이 길어 화면에서 잘리면
   아래 두 가지를 쓰십시오.

     - 파일로   : SQL*Plus 에서 SPOOL c:\copy.log ... SPOOL OFF
     - 조회로   : SELECT * FROM TABLE(PKG_CM_COPY_V2.FN_LOG);
                  같은 세션에서 방금 나온 출력을 행으로 돌려줍니다.
                  SQL Developer 의 DBMS_OUTPUT 버퍼 제한을 피할 수 있습니다.

   ---------------------------------------------------------------------------
   [ 출력 메시지 읽는 법 ]

     -- >> SKIP :        건너뛴 것. 뒤에 사유가 붙습니다.
     -- !! WARN :        진행은 하지만 확인이 필요한 것.
     -- !! ERROR :       실패. 백트레이스가 함께 나옵니다.
     -- 키 :             이번에 쓴 중복 판단 기준.
     -- >> N rows        실제 반영 건수. 미실행이면 '미실행' 이라고 나옵니다.

   ★★ 실행 주의 ★★
   - EXECUTE IMMEDIATE 로 DML 을 하므로 소유자 계정으로 돌리거나
     롤이 아닌 직접 권한을 받은 계정으로 돌려야 합니다.
   - G_BATCH_SIZE > 0 이면 묶음마다 COMMIT 합니다. 되돌릴 수 없습니다.
   - SP_BACKUP 은 DDL 이라 각 CREATE TABLE 이 곧 COMMIT 입니다.
   - 이 엔진은 FK 를 검사하지 않습니다. 복사 순서가 곧 FK 순서입니다.
   **************************************************************************** */

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 32767
SET TRIMSPOOL ON


CREATE OR REPLACE PACKAGE PKG_CM_COPY_V2 AS

    /* ---- 설정 ---------------------------------------------------------- */
    G_OWNER       VARCHAR2(128) := 'SBPORA';   /* 대상 스키마               */
    G_EXEC_YN     CHAR(1)       := 'N';        /* N=출력만, Y=실행          */
    G_COMMIT_YN   CHAR(1)       := 'N';        /* 묶음 작업 끝의 확정 여부  */
    G_USER_ID     VARCHAR2(30)  := 'COPYJOB';  /* REG_ID / MOD_ID 기록값    */
    G_MODE        CHAR(1)       := 'S';        /* S=신규만 M=갱신 R=재적재  */
    G_BATCH_SIZE  PLS_INTEGER   := 0;          /* >0 이면 나눠담기 (S 전용) */
    G_SLEEP_SEC   NUMBER        := 0;          /* 묶음 사이 대기 초         */
    G_STOP_ON_ERR CHAR(1)       := 'Y';        /* 오류 시 즉시 중단         */
    G_PRINT_SQL   CHAR(1)       := 'Y';        /* 조립한 SQL 출력           */
    G_PROD_FILTER CHAR(1)       := 'Y';        /* 본사->매장 상품 매핑 필터 */
    G_DT_FMT      VARCHAR2(30)  := 'YYYYMMDDHH24MISS';
    G_PREVIEW_YN  CHAR(1)       := 'N';        /* Y = 건수만 세고 끝냄       */
    G_LOG_YN      CHAR(1)       := 'Y';        /* 출력을 메모리에도 보관     */
    G_LOG_MAX     PLS_INTEGER   := 50000;      /* 보관 줄 수 상한            */

    /* ---- 집계 ---------------------------------------------------------- */
    G_TOT_TAB   PLS_INTEGER := 0;
    G_TOT_ROW   PLS_INTEGER := 0;
    G_TOT_SKIP  PLS_INTEGER := 0;
    G_TOT_ERR   PLS_INTEGER := 0;

    /* ================= 한 줄 실행 ======================================== */
    PROCEDURE SP_CHECK_ENV ( PI_HQ    IN VARCHAR2 DEFAULT NULL
                           , PI_STORE IN VARCHAR2 DEFAULT NULL );

    PROCEDURE SP_HQ2HQ     ( PI_SRC_HQ    IN VARCHAR2
                           , PI_TGT_HQ    IN VARCHAR2
                           , PI_TABLES    IN SYS.ODCIVARCHAR2LIST DEFAULT NULL );

    PROCEDURE SP_HQ2MS     ( PI_SRC_HQ    IN VARCHAR2
                           , PI_TGT_STORE IN VARCHAR2
                           , PI_TABLES    IN SYS.ODCIVARCHAR2LIST DEFAULT NULL );

    PROCEDURE SP_MS2MS     ( PI_SRC_STORE IN VARCHAR2
                           , PI_TGT_STORE IN VARCHAR2
                           , PI_TABLES    IN SYS.ODCIVARCHAR2LIST DEFAULT NULL );

    /* ================= 부속 ============================================== */
    /* 매장 공통코드 : 본사 코드가 아니라 TB_CM_NMCODE 기준으로 만듭니다 */
    PROCEDURE SP_NMCODE_STORE ( PI_TGT_STORE IN VARCHAR2 );

    /* 백업 : 대상 키 범위를 테이블명_접미어 로 떠 둡니다 (DDL) */
    PROCEDURE SP_BACKUP    ( PI_KEY_COL IN VARCHAR2
                           , PI_KEY_VAL IN VARCHAR2
                           , PI_SUFFIX  IN VARCHAR2
                           , PI_TABLES  IN SYS.ODCIVARCHAR2LIST );

    /* 참조 점검 : 복사할 원본이 참조하는 값이 대상에 있는지 (FK 기준)
       같은 테이블끼리 복사(HQ->HQ, MS->MS)에서만 뜻이 있습니다. */
    PROCEDURE SP_REF_CHECK ( PI_KEY_COL IN VARCHAR2
                           , PI_SRC_KEY IN VARCHAR2
                           , PI_TGT_KEY IN VARCHAR2
                           , PI_TABLES  IN SYS.ODCIVARCHAR2LIST );

    /* 검증 : 원본 / 대상 건수 비교 */
    PROCEDURE SP_VERIFY    ( PI_KEY_COL IN VARCHAR2
                           , PI_SRC_KEY IN VARCHAR2
                           , PI_TGT_KEY IN VARCHAR2
                           , PI_TABLES  IN SYS.ODCIVARCHAR2LIST );

    /* 실행된(또는 조립된) 출력을 행으로 돌려줍니다.
       SELECT * FROM TABLE(PKG_CM_COPY_V2.FN_LOG); */
    FUNCTION  FN_LOG RETURN SYS.ODCIVARCHAR2LIST PIPELINED;
    PROCEDURE SP_LOG_CLEAR;

    /* 중복 판단에 쓸 키를 직접 지정 (세션 내내 유지)
       SP_KEY_SET('TB_MS_XXX', 'STORE_CD,PROD_CD') */
    PROCEDURE SP_KEY_SET    ( PI_TABLE IN VARCHAR2, PI_COLS IN VARCHAR2 );
    PROCEDURE SP_KEY_UNSET  ( PI_TABLE IN VARCHAR2 );

    /* 테이블별 키 후보(PK / UNIQUE 제약 / UNIQUE 인덱스) 보기 */
    PROCEDURE SP_KEY_REPORT ( PI_TABLES  IN SYS.ODCIVARCHAR2LIST
                            , PI_KEY_COL IN VARCHAR2 DEFAULT NULL );

    /* 기본 복사 순서 (부모 -> 자식) */
    FUNCTION FN_LIST_H2H RETURN SYS.ODCIVARCHAR2LIST;
    FUNCTION FN_LIST_H2M RETURN SYS.ODCIVARCHAR2LIST;   /* 본사 테이블명 */
    FUNCTION FN_LIST_M2M RETURN SYS.ODCIVARCHAR2LIST;
    FUNCTION FN_MS_OF    ( PI_HQ_TABLE IN VARCHAR2 ) RETURN VARCHAR2;

    /* ================= 낱개 ============================================== */
    PROCEDURE SP_RESET;
    PROCEDURE SP_SUMMARY;
    PROCEDURE SP_MAP_ADD   ( PI_COL IN VARCHAR2, PI_EXPR IN VARCHAR2 );
    PROCEDURE SP_MAP_CLEAR;
    PROCEDURE SP_FROM_SET  ( PI_TEXT IN VARCHAR2 );
    PROCEDURE SP_ALIAS_ADD ( PI_TGT_COL IN VARCHAR2, PI_SRC_COL IN VARCHAR2 );
    PROCEDURE SP_DIFF      ( PI_SRC_TABLE IN VARCHAR2, PI_TGT_TABLE IN VARCHAR2 );

    PROCEDURE SP_COPY      ( PI_SRC_TABLE   IN VARCHAR2
                           , PI_TGT_TABLE   IN VARCHAR2
                           , PI_SRC_KEY_COL IN VARCHAR2
                           , PI_TGT_KEY_COL IN VARCHAR2
                           , PI_SRC_KEY     IN VARCHAR2
                           , PI_TGT_KEY     IN VARCHAR2
                           , PI_EXTRA_WH    IN VARCHAR2 DEFAULT NULL );

    PROCEDURE SP_COPY_SAME ( PI_TABLE    IN VARCHAR2
                           , PI_KEY_COL  IN VARCHAR2
                           , PI_SRC_KEY  IN VARCHAR2
                           , PI_TGT_KEY  IN VARCHAR2
                           , PI_EXTRA_WH IN VARCHAR2 DEFAULT NULL );

    /* POS 번호를 대상 매장 기준으로 매핑해서 복사 */
    PROCEDURE SP_COPY_POS  ( PI_TABLE     IN VARCHAR2
                           , PI_SRC_STORE IN VARCHAR2
                           , PI_TGT_STORE IN VARCHAR2 );

END PKG_CM_COPY_V2;
/


CREATE OR REPLACE PACKAGE BODY PKG_CM_COPY_V2 AS

    TYPE T_STR_MAP IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(128);

    G_MAP        T_STR_MAP;      /* 1회용 컬럼 값 지정         */
    G_ALIAS      T_STR_MAP;      /* 대상컬럼 -> 원본컬럼 별칭  */
    G_PAIR       T_STR_MAP;      /* 본사 테이블 -> 매장 테이블 */
    G_POSTAB     T_STR_MAP;      /* POS 번호 매핑이 필요한 표  */
    G_EXTRA_FROM VARCHAR2(4000); /* 1회용 FROM 추가            */
    G_KEY        T_STR_MAP;      /* 직접 지정한 중복판단 키    */
    G_LOG        SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();


    /* ==================================================================
       출력
       ================================================================== */
    PROCEDURE P( PI_TEXT IN VARCHAR2 ) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE( NVL(PI_TEXT, ' ') );

        /* 화면 버퍼가 잘려도 FN_LOG 로 다시 볼 수 있게 보관 */
        IF G_LOG_YN = 'Y' AND G_LOG.COUNT < G_LOG_MAX THEN
            G_LOG.EXTEND;
            G_LOG(G_LOG.COUNT) := SUBSTR(NVL(PI_TEXT, ' '), 1, 4000);
        END IF;
    END P;


    FUNCTION FN_LOG RETURN SYS.ODCIVARCHAR2LIST PIPELINED IS
    BEGIN
        FOR I IN 1 .. G_LOG.COUNT LOOP
            PIPE ROW ( G_LOG(I) );
        END LOOP;
        RETURN;
    END FN_LOG;


    PROCEDURE SP_LOG_CLEAR IS
    BEGIN
        G_LOG := SYS.ODCIVARCHAR2LIST();
    END SP_LOG_CLEAR;


    PROCEDURE P_CLOB( PI_TEXT IN CLOB ) IS
        V_LEN  PLS_INTEGER := NVL(DBMS_LOB.GETLENGTH(PI_TEXT), 0);
        V_POS  PLS_INTEGER := 1;
        V_NL   PLS_INTEGER;
        V_TAKE PLS_INTEGER;
    BEGIN
        WHILE V_POS <= V_LEN LOOP
            V_NL := DBMS_LOB.INSTR(PI_TEXT, CHR(10), V_POS);
            IF V_NL = 0 OR V_NL - V_POS > 3000 THEN
                V_TAKE := LEAST(3000, V_LEN - V_POS + 1);
                P( DBMS_LOB.SUBSTR(PI_TEXT, V_TAKE, V_POS) );
                V_POS := V_POS + V_TAKE;
            ELSIF V_NL = V_POS THEN
                P(' ');
                V_POS := V_POS + 1;
            ELSE
                P( DBMS_LOB.SUBSTR(PI_TEXT, V_NL - V_POS, V_POS) );
                V_POS := V_NL + 1;
            END IF;
        END LOOP;
    END P_CLOB;


    PROCEDURE P_HEAD( PI_TEXT IN VARCHAR2 ) IS
    BEGIN
        P('/* ' || RPAD('=', 70, '=') || ' */');
        P('/*  ' || PI_TEXT);
        P('/* ' || RPAD('=', 70, '=') || ' */');
    END P_HEAD;


    /* ==================================================================
       기본 도구
       ================================================================== */
    FUNCTION FN_Q( PI_S IN VARCHAR2 ) RETURN VARCHAR2 IS
    BEGIN
        RETURN '''' || REPLACE(PI_S, '''', '''''') || '''';
    END FN_Q;


    FUNCTION FN_COL_TYPE( PI_TABLE IN VARCHAR2, PI_COL IN VARCHAR2 )
    RETURN VARCHAR2 IS
        V_TYPE VARCHAR2(128);
    BEGIN
        SELECT MAX(DATA_TYPE) INTO V_TYPE
          FROM ALL_TAB_COLUMNS
         WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TABLE AND COLUMN_NAME = PI_COL;
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
          FROM ALL_TABLES WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TABLE;
        RETURN V_CNT > 0;
    END FN_TAB_EXISTS;


    FUNCTION FN_CNT( PI_TABLE IN VARCHAR2, PI_WH IN VARCHAR2 )
    RETURN PLS_INTEGER IS
        V_CNT PLS_INTEGER := -1;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || G_OWNER || '.' || PI_TABLE
                          || ' WHERE ' || PI_WH
                     INTO V_CNT;
        RETURN V_CNT;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN -1;
    END FN_CNT;


    FUNCTION FN_CNT_SQL( PI_SQL IN CLOB ) RETURN PLS_INTEGER IS
        V_CNT NUMBER := -1;
    BEGIN
        EXECUTE IMMEDIATE PI_SQL INTO V_CNT;
        RETURN V_CNT;
    EXCEPTION
        WHEN OTHERS THEN
            P('-- !! 건수 조회 실패 : ' || SQLERRM);
            RETURN -1;
    END FN_CNT_SQL;


    FUNCTION FN_N( PI_N IN PLS_INTEGER ) RETURN VARCHAR2 IS
    BEGIN
        IF PI_N IS NULL OR PI_N < 0 THEN RETURN '?'; END IF;
        RETURN TRIM(TO_CHAR(PI_N, 'FM999,999,999,999'));
    END FN_N;


    /* 컬럼 타입 표기 : VARCHAR2(50) · NUMBER(10,2) 형태 */
    FUNCTION FN_TYPE_TXT( PI_TYPE IN VARCHAR2
                        , PI_LEN  IN NUMBER
                        , PI_P    IN NUMBER
                        , PI_S    IN NUMBER ) RETURN VARCHAR2 IS
    BEGIN
        IF PI_TYPE IN ('CHAR','VARCHAR2','NCHAR','NVARCHAR2') THEN
            RETURN PI_TYPE || '(' || TO_CHAR(PI_LEN) || ')';
        ELSIF PI_TYPE = 'NUMBER' AND PI_P IS NOT NULL THEN
            RETURN PI_TYPE || '(' || TO_CHAR(PI_P)
                 || CASE WHEN NVL(PI_S,0) > 0 THEN ',' || TO_CHAR(PI_S) ELSE '' END || ')';
        END IF;
        RETURN PI_TYPE;
    END FN_TYPE_TXT;


    /* 같은 이름인데 타입이 다르거나 대상이 더 좁은 컬럼을 찾습니다.
       그대로 두면 실행 중 ORA-12899 / ORA-01438 로 죽습니다. */
    FUNCTION FN_TYPE_WARN( PI_SRC_TABLE IN VARCHAR2
                         , PI_TGT_TABLE IN VARCHAR2
                         , PI_PRINT     IN BOOLEAN DEFAULT TRUE )
    RETURN PLS_INTEGER IS
        V_CNT PLS_INTEGER := 0;
    BEGIN
        IF PI_SRC_TABLE = PI_TGT_TABLE THEN RETURN 0; END IF;

        FOR C IN ( SELECT S.COLUMN_NAME
                        , S.DATA_TYPE AS S_TYPE, S.CHAR_LENGTH AS S_LEN
                        , S.DATA_PRECISION AS S_P, S.DATA_SCALE AS S_S
                        , T.DATA_TYPE AS T_TYPE, T.CHAR_LENGTH AS T_LEN
                        , T.DATA_PRECISION AS T_P, T.DATA_SCALE AS T_S
                     FROM ALL_TAB_COLUMNS S
                        , ALL_TAB_COLUMNS T
                    WHERE S.OWNER       = G_OWNER
                      AND S.TABLE_NAME  = PI_SRC_TABLE
                      AND T.OWNER       = G_OWNER
                      AND T.TABLE_NAME  = PI_TGT_TABLE
                      AND T.COLUMN_NAME = S.COLUMN_NAME
                      AND ( S.DATA_TYPE <> T.DATA_TYPE
                         OR ( S.DATA_TYPE IN ('CHAR','VARCHAR2','NCHAR','NVARCHAR2')
                              AND NVL(T.CHAR_LENGTH,0) < NVL(S.CHAR_LENGTH,0) )
                         OR ( S.DATA_TYPE = 'NUMBER'
                              AND NVL(T.DATA_PRECISION,38) < NVL(S.DATA_PRECISION,38) ) )
                    ORDER BY S.COLUMN_ID )
        LOOP
            V_CNT := V_CNT + 1;
            IF PI_PRINT THEN
                P('-- !! 타입 : ' || RPAD(C.COLUMN_NAME, 30)
                  || RPAD(FN_TYPE_TXT(C.S_TYPE, C.S_LEN, C.S_P, C.S_S), 18)
                  || ' -> ' || RPAD(FN_TYPE_TXT(C.T_TYPE, C.T_LEN, C.T_P, C.T_S), 18)
                  || CASE WHEN C.S_TYPE = C.T_TYPE THEN '<< 대상이 좁음. 잘리면 실패'
                          ELSE '<< 타입 다름. 변환 실패 가능' END);
            END IF;
        END LOOP;

        RETURN V_CNT;
    END FN_TYPE_WARN;


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


    FUNCTION FN_PK_COLS( PI_TABLE IN VARCHAR2 )
    RETURN SYS.ODCIVARCHAR2LIST IS
        V_LIST SYS.ODCIVARCHAR2LIST;
    BEGIN
        SELECT CC.COLUMN_NAME
          BULK COLLECT INTO V_LIST
          FROM ALL_CONSTRAINTS C
          JOIN ALL_CONS_COLUMNS CC
            ON  CC.OWNER           = C.OWNER
            AND CC.CONSTRAINT_NAME = C.CONSTRAINT_NAME
         WHERE C.OWNER           = G_OWNER
           AND C.TABLE_NAME      = PI_TABLE
           AND C.CONSTRAINT_TYPE = 'P'
         ORDER BY CC.POSITION;
        RETURN V_LIST;
    END FN_PK_COLS;


    PROCEDURE SP_KEY_SET( PI_TABLE IN VARCHAR2, PI_COLS IN VARCHAR2 ) IS
    BEGIN
        G_KEY(UPPER(PI_TABLE)) := UPPER(PI_COLS);
    END SP_KEY_SET;


    PROCEDURE SP_KEY_UNSET( PI_TABLE IN VARCHAR2 ) IS
    BEGIN
        IF G_KEY.EXISTS(UPPER(PI_TABLE)) THEN
            G_KEY.DELETE(UPPER(PI_TABLE));
        END IF;
    END SP_KEY_UNSET;


    /* ==================================================================
       중복 판단 키 결정

       찾는 순서
         1) SP_KEY_SET 으로 지정한 것
         2) 기본키(PK)
         3) UNIQUE 제약        - 여러 개면 아래 규칙으로 하나 고름
         4) UNIQUE 인덱스      - 제약이 안 걸린 것만. 여러 개면 같은 규칙

       고르는 규칙 (여러 개일 때)
         가) 복사 키 컬럼을 포함한 것 우선
         나) 컬럼 수가 적은 것 우선
         다) 이름 순

       함수기반 인덱스(SYS_NC 로 시작하는 숨은 컬럼)는 후보에서 뺍니다.
       ================================================================== */
    PROCEDURE SP_KEY_COLS( PI_TABLE   IN  VARCHAR2
                         , PI_KEY_COL IN  VARCHAR2
                         , PO_COLS    OUT SYS.ODCIVARCHAR2LIST
                         , PO_SOURCE  OUT VARCHAR2
                         , PO_CANDS   OUT PLS_INTEGER )
    IS
        V_TXT   VARCHAR2(4000);
        V_KIND  VARCHAR2(30);
        V_NAME  VARCHAR2(128);
    BEGIN
        PO_COLS   := SYS.ODCIVARCHAR2LIST();
        PO_SOURCE := NULL;
        PO_CANDS  := 0;

        /* 1) 직접 지정 */
        IF G_KEY.EXISTS(PI_TABLE) THEN
            V_TXT := G_KEY(PI_TABLE);
            SELECT TRIM(REGEXP_SUBSTR(V_TXT, '[^,]+', 1, LEVEL))
              BULK COLLECT INTO PO_COLS
              FROM DUAL
            CONNECT BY REGEXP_SUBSTR(V_TXT, '[^,]+', 1, LEVEL) IS NOT NULL;
            PO_SOURCE := '직접 지정';
            PO_CANDS  := 1;
            RETURN;
        END IF;

        /* 2) 기본키 */
        PO_COLS := FN_PK_COLS(PI_TABLE);
        IF PO_COLS IS NOT NULL AND PO_COLS.COUNT > 0 THEN
            SELECT MAX(CONSTRAINT_NAME) INTO V_NAME
              FROM ALL_CONSTRAINTS
             WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TABLE
               AND CONSTRAINT_TYPE = 'P';
            PO_SOURCE := 'PK ' || V_NAME;
            PO_CANDS  := 1;
            RETURN;
        END IF;

        /* 3) 4) UNIQUE 제약 / UNIQUE 인덱스 후보 */
        FOR C IN (
            SELECT KIND, KEY_NAME, COL_CNT, HAS_KEYCOL
              FROM (
                    SELECT 'UNIQUE 제약'  AS KIND
                         , C.CONSTRAINT_NAME AS KEY_NAME
                         , COUNT(*)          AS COL_CNT
                         , MAX(CASE WHEN CC.COLUMN_NAME = PI_KEY_COL THEN 1 ELSE 0 END) AS HAS_KEYCOL
                         , MAX(CASE WHEN SUBSTR(CC.COLUMN_NAME, 1, 6) = 'SYS_NC' THEN 1 ELSE 0 END) AS HAS_FBI
                      FROM ALL_CONSTRAINTS  C
                      JOIN ALL_CONS_COLUMNS CC
                        ON  CC.OWNER           = C.OWNER
                        AND CC.CONSTRAINT_NAME = C.CONSTRAINT_NAME
                     WHERE C.OWNER           = G_OWNER
                       AND C.TABLE_NAME      = PI_TABLE
                       AND C.CONSTRAINT_TYPE = 'U'
                       AND C.STATUS          = 'ENABLED'
                     GROUP BY C.CONSTRAINT_NAME
                    UNION ALL
                    SELECT 'UNIQUE 인덱스'
                         , I.INDEX_NAME
                         , COUNT(*)
                         , MAX(CASE WHEN IC.COLUMN_NAME = PI_KEY_COL THEN 1 ELSE 0 END)
                         , MAX(CASE WHEN SUBSTR(IC.COLUMN_NAME, 1, 6) = 'SYS_NC' THEN 1 ELSE 0 END)
                      FROM ALL_INDEXES     I
                      JOIN ALL_IND_COLUMNS IC
                        ON  IC.INDEX_OWNER = I.OWNER
                        AND IC.INDEX_NAME  = I.INDEX_NAME
                     WHERE I.TABLE_OWNER = G_OWNER
                       AND I.TABLE_NAME  = PI_TABLE
                       AND I.UNIQUENESS  = 'UNIQUE'
                       AND NOT EXISTS ( SELECT 1
                                          FROM ALL_CONSTRAINTS C2
                                         WHERE C2.OWNER           = I.OWNER
                                           AND C2.INDEX_NAME      = I.INDEX_NAME
                                           AND C2.CONSTRAINT_TYPE IN ('P','U') )
                     GROUP BY I.INDEX_NAME
                   )
             WHERE HAS_FBI = 0
             ORDER BY HAS_KEYCOL DESC, COL_CNT, KEY_NAME )
        LOOP
            PO_CANDS := PO_CANDS + 1;
            IF PO_CANDS = 1 THEN
                V_KIND := C.KIND;
                V_NAME := C.KEY_NAME;
            END IF;
        END LOOP;

        IF PO_CANDS = 0 THEN
            PO_COLS := SYS.ODCIVARCHAR2LIST();
            RETURN;
        END IF;

        IF V_KIND = 'UNIQUE 제약' THEN
            SELECT CC.COLUMN_NAME BULK COLLECT INTO PO_COLS
              FROM ALL_CONS_COLUMNS CC
             WHERE CC.OWNER = G_OWNER AND CC.CONSTRAINT_NAME = V_NAME
             ORDER BY CC.POSITION;
        ELSE
            SELECT IC.COLUMN_NAME BULK COLLECT INTO PO_COLS
              FROM ALL_IND_COLUMNS IC
             WHERE IC.INDEX_OWNER = G_OWNER AND IC.INDEX_NAME = V_NAME
             ORDER BY IC.COLUMN_POSITION;
        END IF;

        PO_SOURCE := V_KIND || ' ' || V_NAME;
    END SP_KEY_COLS;


    /* NULL 을 허용하는 키 컬럼이 있으면 중복차단이 새어나갑니다 */
    FUNCTION FN_NULLABLE_KEYS( PI_TABLE IN VARCHAR2
                             , PI_COLS  IN SYS.ODCIVARCHAR2LIST )
    RETURN VARCHAR2 IS
        V_NULLABLE VARCHAR2(1);
        V_OUT      VARCHAR2(4000);
    BEGIN
        IF PI_COLS IS NULL THEN RETURN NULL; END IF;
        FOR I IN 1 .. PI_COLS.COUNT LOOP
            SELECT MAX(NULLABLE) INTO V_NULLABLE
              FROM ALL_TAB_COLUMNS
             WHERE OWNER = G_OWNER AND TABLE_NAME = PI_TABLE
               AND COLUMN_NAME = PI_COLS(I);
            IF V_NULLABLE = 'Y' THEN
                V_OUT := V_OUT || PI_COLS(I) || ' ';
            END IF;
        END LOOP;
        RETURN V_OUT;
    END FN_NULLABLE_KEYS;


    FUNCTION FN_JOIN( PI_LIST IN SYS.ODCIVARCHAR2LIST ) RETURN VARCHAR2 IS
        V_OUT VARCHAR2(4000);
    BEGIN
        IF PI_LIST IS NULL THEN RETURN NULL; END IF;
        FOR I IN 1 .. PI_LIST.COUNT LOOP
            V_OUT := V_OUT || CASE WHEN I = 1 THEN '' ELSE ', ' END || PI_LIST(I);
        END LOOP;
        RETURN V_OUT;
    END FN_JOIN;


    FUNCTION FN_IN_LIST( PI_LIST IN SYS.ODCIVARCHAR2LIST, PI_COL IN VARCHAR2 )
    RETURN BOOLEAN IS
    BEGIN
        IF PI_LIST IS NULL THEN RETURN FALSE; END IF;
        FOR I IN 1 .. PI_LIST.COUNT LOOP
            IF PI_LIST(I) = PI_COL THEN RETURN TRUE; END IF;
        END LOOP;
        RETURN FALSE;
    END FN_IN_LIST;


    /* ==================================================================
       1회용 설정
       ================================================================== */
    PROCEDURE SP_MAP_ADD( PI_COL IN VARCHAR2, PI_EXPR IN VARCHAR2 ) IS
    BEGIN
        G_MAP(UPPER(PI_COL)) := PI_EXPR;
    END SP_MAP_ADD;

    PROCEDURE SP_MAP_CLEAR IS
    BEGIN
        G_MAP.DELETE;
        G_EXTRA_FROM := NULL;
    END SP_MAP_CLEAR;

    PROCEDURE SP_FROM_SET( PI_TEXT IN VARCHAR2 ) IS
    BEGIN
        G_EXTRA_FROM := PI_TEXT;
    END SP_FROM_SET;

    PROCEDURE SP_ALIAS_ADD( PI_TGT_COL IN VARCHAR2, PI_SRC_COL IN VARCHAR2 ) IS
    BEGIN
        G_ALIAS(UPPER(PI_TGT_COL)) := UPPER(PI_SRC_COL);
    END SP_ALIAS_ADD;


    PROCEDURE SP_RESET IS
    BEGIN
        G_TOT_TAB  := 0;
        G_TOT_ROW  := 0;
        G_TOT_SKIP := 0;
        G_TOT_ERR  := 0;
        SP_MAP_CLEAR;
    END SP_RESET;


    PROCEDURE SP_SUMMARY IS
    BEGIN
        P('/* ---------------------------------------------------------- */');
        P('/*  모드          : ' || CASE G_MODE WHEN 'S' THEN 'S 신규만'
                                                WHEN 'M' THEN 'M 갱신'
                                                WHEN 'R' THEN 'R 재적재'
                                                ELSE G_MODE END
                               || CASE WHEN G_BATCH_SIZE > 0
                                       THEN '   나눠담기 ' || G_BATCH_SIZE || '건'
                                       ELSE '' END);
        P('/*  처리 테이블   : ' || G_TOT_TAB);
        P('/*  건너뛴 테이블 : ' || G_TOT_SKIP);
        P('/*  ' || CASE WHEN G_PREVIEW_YN = 'Y' THEN '예상 건수     : ' ELSE '처리 건수     : ' END
                  || G_TOT_ROW
                  || CASE WHEN G_PREVIEW_YN = 'Y' THEN '   (세어만 봤습니다)'
                          WHEN G_EXEC_YN = 'N'    THEN '   (미실행)'
                          ELSE '' END);
        P('/*  오류          : ' || G_TOT_ERR);
        P('/* ---------------------------------------------------------- */');
        IF G_TOT_ERR > 0 THEN
            P('-- !! 오류가 있습니다. 로그를 확인하고 확정하지 마십시오.');
        END IF;
    END SP_SUMMARY;


    /* ==================================================================
       컬럼 표현식
       ================================================================== */
    FUNCTION FN_EXPR( PI_SRC_TABLE   IN VARCHAR2
                    , PI_TGT_TABLE   IN VARCHAR2
                    , PI_COL         IN VARCHAR2
                    , PI_TGT_KEY_COL IN VARCHAR2
                    , PI_TGT_KEY     IN VARCHAR2 )
    RETURN VARCHAR2 IS
        V_SRC_COL VARCHAR2(128);
    BEGIN
        IF G_MAP.EXISTS(PI_COL) THEN
            RETURN G_MAP(PI_COL);
        END IF;

        IF PI_COL = PI_TGT_KEY_COL THEN
            RETURN FN_Q(PI_TGT_KEY);
        END IF;

        IF PI_COL IN ('REG_DT', 'MOD_DT') THEN
            RETURN FN_DT_EXPR(PI_TGT_TABLE, PI_COL);
        END IF;

        IF PI_COL IN ('REG_ID', 'MOD_ID') THEN
            RETURN FN_Q(G_USER_ID);
        END IF;

        IF FN_HAS_COL(PI_SRC_TABLE, PI_COL) THEN
            RETURN 's."' || PI_COL || '"';
        END IF;

        IF G_ALIAS.EXISTS(PI_COL) THEN
            V_SRC_COL := G_ALIAS(PI_COL);
            IF FN_HAS_COL(PI_SRC_TABLE, V_SRC_COL) THEN
                RETURN 's."' || V_SRC_COL || '"';
            END IF;
        END IF;

        RETURN NULL;
    END FN_EXPR;


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
        WHEN OTHERS THEN NULL;   /* DBMS_LOCK 권한이 없으면 대기 없이 진행 */
    END SP_SLEEP;


    /* ==================================================================
       컬럼 차이 확인
       ================================================================== */
    PROCEDURE SP_DIFF( PI_SRC_TABLE IN VARCHAR2, PI_TGT_TABLE IN VARCHAR2 ) IS
        V_CNT PLS_INTEGER := 0;
    BEGIN
        P('/* ---- 컬럼 비교 : ' || PI_SRC_TABLE || ' -> ' || PI_TGT_TABLE || ' ---- */');

        IF NOT FN_TAB_EXISTS(PI_SRC_TABLE) OR NOT FN_TAB_EXISTS(PI_TGT_TABLE) THEN
            P('-- !! 테이블이 없거나 권한이 없습니다.');
            P(' ');
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
               AND NOT ( G_ALIAS.EXISTS(C.COLUMN_NAME)
                         AND FN_HAS_COL(PI_SRC_TABLE, G_ALIAS(C.COLUMN_NAME)) )
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

        P('-- 감사컬럼 REG_DT : ' || NVL(FN_COL_TYPE(PI_TGT_TABLE,'REG_DT'),'없음')
          || '  ->  ' || FN_DT_EXPR(PI_TGT_TABLE,'REG_DT'));
        P(' ');
    END SP_DIFF;


    /* ==================================================================
       본체
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
        V_COLS    CLOB;
        V_SELS    CLOB;
        V_SELS_AS CLOB;
        V_VALS    CLOB;
        V_SETS    CLOB;
        V_SQL     CLOB;
        V_SQL2    CLOB;
        V_FROM    VARCHAR2(4000);
        V_WH      VARCHAR2(4000);
        V_PKCOND  VARCHAR2(4000);
        V_EXPR    VARCHAR2(4000);
        V_MISS_NN VARCHAR2(4000);
        V_PK      SYS.ODCIVARCHAR2LIST;
        V_KEYSRC  VARCHAR2(300);
        V_NULLKEY VARCHAR2(4000);
        V_CANDS   PLS_INTEGER := 0;
        V_FIRST   BOOLEAN := TRUE;
        V_SETFST  BOOLEAN := TRUE;
        V_CNT     PLS_INTEGER := 0;
        V_SUM     PLS_INTEGER := 0;
        V_SKIP    VARCHAR2(1000);
        V_BASE    CLOB;
        V_SRCCNT  PLS_INTEGER;
        V_NEWCNT  PLS_INTEGER;
        V_TGTCNT  PLS_INTEGER;
    BEGIN
        P('/* ---- ' || V_LABEL || '  [' || G_MODE || '] ---- */');

        /* 1. 존재 확인 */
        IF NOT FN_TAB_EXISTS(PI_SRC_TABLE) THEN
            V_SKIP := '원본 테이블 ' || PI_SRC_TABLE || ' 없음 (또는 권한 없음)';
        ELSIF NOT FN_TAB_EXISTS(PI_TGT_TABLE) THEN
            V_SKIP := '대상 테이블 ' || PI_TGT_TABLE || ' 없음 (또는 권한 없음)';
        ELSIF PI_SRC_KEY_COL IS NOT NULL
              AND NOT FN_HAS_COL(PI_SRC_TABLE, PI_SRC_KEY_COL) THEN
            V_SKIP := PI_SRC_TABLE || ' 에 ' || PI_SRC_KEY_COL || ' 컬럼 없음';
        ELSIF NOT FN_HAS_COL(PI_TGT_TABLE, PI_TGT_KEY_COL) THEN
            V_SKIP := PI_TGT_TABLE || ' 에 ' || PI_TGT_KEY_COL || ' 컬럼 없음';
        END IF;

        IF V_SKIP IS NOT NULL THEN
            P('-- >> SKIP : ' || V_SKIP);
            P(' ');
            G_TOT_SKIP := G_TOT_SKIP + 1;
            SP_MAP_CLEAR;
            RETURN;
        END IF;

        /* 2. 중복 판단 키 결정 : PK -> UNIQUE 제약 -> UNIQUE 인덱스 */
        SP_KEY_COLS(PI_TGT_TABLE, PI_TGT_KEY_COL, V_PK, V_KEYSRC, V_CANDS);

        IF (V_PK IS NULL OR V_PK.COUNT = 0) AND G_MODE IN ('S','M') THEN
            P('-- >> SKIP : ' || PI_TGT_TABLE || ' 에 PK 도 UNIQUE 도 없습니다.');
            P('--           중복 판단 기준이 없어 건너뜁니다.');
            P('--           SP_KEY_SET(''' || PI_TGT_TABLE || ''', ''컬럼1,컬럼2'') 로 지정하거나');
            P('--           재적재(G_MODE=''R'')로 하십시오.');
            P(' ');
            G_TOT_SKIP := G_TOT_SKIP + 1;
            SP_MAP_CLEAR;
            RETURN;
        END IF;

        IF V_PK IS NOT NULL AND V_PK.COUNT > 0 THEN
            P('-- 키 : ' || RPAD(NVL(V_KEYSRC,'-'), 34) || '( ' || FN_JOIN(V_PK) || ' )');

            IF V_CANDS > 1 THEN
                P('-- !! WARN : 키 후보가 ' || V_CANDS || ' 개입니다. 위 것을 골랐습니다.');
                P('--           다른 것을 쓰려면 SP_KEY_SET 으로 지정하고,');
                P('--           후보 전체는 SP_KEY_REPORT 로 보십시오.');
            END IF;

            V_NULLKEY := FN_NULLABLE_KEYS(PI_TGT_TABLE, V_PK);
            IF V_NULLKEY IS NOT NULL THEN
                P('-- !! WARN : NULL 을 허용하는 키 컬럼 -> ' || V_NULLKEY);
                P('--           그 값이 NULL 인 행은 중복 차단이 되지 않습니다.');
            END IF;
        END IF;

        IF V_PK IS NOT NULL THEN
            FOR I IN 1 .. V_PK.COUNT LOOP
                IF FN_EXPR(PI_SRC_TABLE, PI_TGT_TABLE, V_PK(I),
                           PI_TGT_KEY_COL, PI_TGT_KEY) IS NULL THEN
                    P('-- >> SKIP : 키 컬럼 ' || V_PK(I) || ' 을(를) 원본에서 못 끌어옵니다.');
                    P('--           SP_MAP_ADD 로 값을 지정하거나 개별 SQL 을 쓰십시오.');
                    P(' ');
                    G_TOT_SKIP := G_TOT_SKIP + 1;
                    SP_MAP_CLEAR;
                    RETURN;
                END IF;
            END LOOP;
        END IF;

        /* 3. 컬럼 조립 */
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
            P('--           SP_MAP_ADD 로 지정하지 않으면 INSERT 가 실패합니다.');
        END IF;

        /* 3-1. 타입 · 길이 검사 (이종 테이블일 때만) */
        V_CNT := FN_TYPE_WARN(PI_SRC_TABLE, PI_TGT_TABLE);
        IF V_CNT > 0 THEN
            P('--           위 ' || V_CNT || ' 개 컬럼은 값이 길면 INSERT 가 실패합니다.');
        END IF;
        V_CNT := 0;

        /* 4. FROM / WHERE */
        V_FROM := G_OWNER || '.' || PI_SRC_TABLE || ' s' || G_EXTRA_FROM;

        V_WH := ' WHERE '
             || CASE WHEN PI_SRC_KEY_COL IS NULL THEN '1 = 1'
                     ELSE 's."' || PI_SRC_KEY_COL || '" = ' || FN_Q(PI_SRC_KEY) END
             || CASE WHEN PI_EXTRA_WH IS NOT NULL
                     THEN CHR(10) || '   AND ' || PI_EXTRA_WH ELSE '' END;

        /* 4-1. 예상 건수만 보고 끝낸다 (SELECT 만 합니다) */
        IF G_PREVIEW_YN = 'Y' THEN
            V_BASE := 'FROM ' || V_FROM || CHR(10) || V_WH;

            V_SRCCNT := FN_CNT_SQL('SELECT COUNT(*) ' || V_BASE);
            V_TGTCNT := FN_CNT(PI_TGT_TABLE,
                               '"' || PI_TGT_KEY_COL || '" = ' || FN_Q(PI_TGT_KEY));

            V_NEWCNT := -1;
            IF V_PK IS NOT NULL AND V_PK.COUNT > 0 THEN
                V_PKCOND := NULL;
                FOR I IN 1 .. V_PK.COUNT LOOP
                    V_PKCOND := V_PKCOND || CHR(10)
                             || '                       AND x."' || V_PK(I) || '" = '
                             || FN_EXPR(PI_SRC_TABLE, PI_TGT_TABLE, V_PK(I),
                                        PI_TGT_KEY_COL, PI_TGT_KEY);
                END LOOP;

                V_NEWCNT := FN_CNT_SQL('SELECT COUNT(*) ' || V_BASE || CHR(10)
                         || '   AND NOT EXISTS ( SELECT 1' || CHR(10)
                         || '                      FROM ' || G_OWNER || '.' || PI_TGT_TABLE || ' x' || CHR(10)
                         || '                     WHERE 1 = 1' || V_PKCOND || CHR(10)
                         || '                   )');
            END IF;

            P('-- 예상 : 원본 ' || LPAD(FN_N(V_SRCCNT), 10)
              || ' / 대상 현재 ' || LPAD(FN_N(V_TGTCNT), 10)
              || CASE WHEN V_NEWCNT >= 0
                      THEN ' / 신규 ' || LPAD(FN_N(V_NEWCNT), 10)
                        || ' / 이미있음 ' || LPAD(FN_N(V_SRCCNT - V_NEWCNT), 10)
                      ELSE '' END);

            IF G_MODE = 'S' THEN
                V_SUM := GREATEST(NVL(V_NEWCNT, 0), 0);
                P('--        S 모드 -> ' || FN_N(V_SUM) || ' 건 INSERT');
                IF G_BATCH_SIZE > 0 AND V_SUM > 0 THEN
                    P('--        나눠담기 ' || G_BATCH_SIZE || ' 건씩 -> 약 '
                      || CEIL(V_SUM / G_BATCH_SIZE) || ' 회 반복');
                END IF;
            ELSIF G_MODE = 'M' THEN
                P('--        M 모드 -> ' || FN_N(GREATEST(NVL(V_NEWCNT,0),0)) || ' 건 INSERT + '
                  || FN_N(GREATEST(NVL(V_SRCCNT,0) - GREATEST(NVL(V_NEWCNT,0),0), 0)) || ' 건 UPDATE');
                V_SUM := GREATEST(NVL(V_SRCCNT,0), 0);
            ELSE
                P('--        R 모드 -> ' || FN_N(V_TGTCNT) || ' 건 DELETE 후 '
                  || FN_N(V_SRCCNT) || ' 건 INSERT');
                V_SUM := GREATEST(NVL(V_SRCCNT,0), 0);
            END IF;
            P(' ');

            G_TOT_TAB := G_TOT_TAB + 1;
            G_TOT_ROW := G_TOT_ROW + V_SUM;
            SP_MAP_CLEAR;
            RETURN;
        END IF;

        /* 5. 모드별 조립 */
        IF G_MODE = 'M' THEN

            V_PKCOND := NULL;
            FOR I IN 1 .. V_PK.COUNT LOOP
                V_PKCOND := V_PKCOND
                         || CASE WHEN I = 1 THEN '' ELSE CHR(10) || '        AND ' END
                         || 'A."' || V_PK(I) || '" = B."' || V_PK(I) || '"';
            END LOOP;

            V_SQL := 'MERGE INTO ' || G_OWNER || '.' || PI_TGT_TABLE || ' A' || CHR(10)
                  || 'USING ( SELECT ' || V_SELS_AS                            || CHR(10)
                  || '          FROM ' || V_FROM                               || CHR(10)
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
            IF G_EXEC_YN = 'Y' THEN
                P('-- >> DELETED ' || V_CNT || ' rows');
            END IF;

            V_SQL := 'INSERT INTO ' || G_OWNER || '.' || PI_TGT_TABLE || CHR(10)
                  || '       ( ' || V_COLS || ' )'                    || CHR(10)
                  || 'SELECT ' || V_SELS                              || CHR(10)
                  || '  FROM ' || V_FROM                              || CHR(10)
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

            V_SQL := 'INSERT INTO ' || G_OWNER || '.' || PI_TGT_TABLE || CHR(10)
                  || '       ( ' || V_COLS || ' )'                    || CHR(10)
                  || 'SELECT ' || V_SELS                              || CHR(10)
                  || '  FROM ' || V_FROM                              || CHR(10)
                  || V_WH                                             || CHR(10)
                  || '   AND NOT EXISTS ( SELECT 1'                   || CHR(10)
                  || '                      FROM ' || G_OWNER || '.' || PI_TGT_TABLE || ' x' || CHR(10)
                  || '                     WHERE 1 = 1' || V_PKCOND   || CHR(10)
                  || '                   )';

            IF G_BATCH_SIZE > 0 THEN
                V_SQL := V_SQL || CHR(10) || '   AND ROWNUM <= ' || G_BATCH_SIZE;

                IF G_EXEC_YN = 'Y' THEN
                    IF G_PRINT_SQL = 'Y' THEN P_CLOB(V_SQL); P(';'); END IF;
                    LOOP
                        EXECUTE IMMEDIATE V_SQL;
                        V_CNT := SQL%ROWCOUNT;
                        V_SUM := V_SUM + V_CNT;
                        EXIT WHEN V_CNT = 0;
                        COMMIT;
                        P('-- >> ' || V_CNT || ' rows / 누적 ' || V_SUM || '  (COMMIT)');
                        SP_SLEEP;
                    END LOOP;
                ELSE
                    V_SUM := FN_RUN(V_SQL);
                    P('-- >> 나눠담기 : 0 건이 될 때까지 반복하며 묶음마다 COMMIT 합니다.');
                END IF;
            ELSE
                V_SUM := FN_RUN(V_SQL);
            END IF;

        END IF;

        IF G_EXEC_YN = 'Y' THEN
            P('-- >> ' || V_SUM || ' rows');
        ELSE
            P('-- >> 미실행 (G_EXEC_YN = N)');
        END IF;
        P(' ');

        G_TOT_TAB := G_TOT_TAB + 1;
        G_TOT_ROW := G_TOT_ROW + V_SUM;
        SP_MAP_CLEAR;

    EXCEPTION
        WHEN OTHERS THEN
            G_TOT_ERR := G_TOT_ERR + 1;
            SP_MAP_CLEAR;
            P('-- !! ERROR ' || V_LABEL || ' : ' || SQLERRM);
            P('-- !! ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            P(' ');
            IF G_STOP_ON_ERR = 'Y' THEN
                RAISE;
            END IF;
    END SP_COPY;


    PROCEDURE SP_COPY_SAME( PI_TABLE    IN VARCHAR2
                          , PI_KEY_COL  IN VARCHAR2
                          , PI_SRC_KEY  IN VARCHAR2
                          , PI_TGT_KEY  IN VARCHAR2
                          , PI_EXTRA_WH IN VARCHAR2 DEFAULT NULL )
    IS
    BEGIN
        SP_COPY( PI_TABLE, PI_TABLE, PI_KEY_COL, PI_KEY_COL,
                 PI_SRC_KEY, PI_TGT_KEY, PI_EXTRA_WH );
    END SP_COPY_SAME;


    /* ==================================================================
       POS 번호 매핑 복사
       - 원본 POS 가 없으면 아무것도 하지 않습니다.
       - 대상 POS 번호가 원본 최대치를 넘으면 원본 최대 POS 를 씁니다.
       ================================================================== */
    PROCEDURE SP_COPY_POS( PI_TABLE     IN VARCHAR2
                         , PI_SRC_STORE IN VARCHAR2
                         , PI_TGT_STORE IN VARCHAR2 )
    IS
        V_SRC_POS PLS_INTEGER;
        V_TGT_POS PLS_INTEGER;
    BEGIN
        V_SRC_POS := FN_CNT('TB_MS_POS', 'STORE_CD = ' || FN_Q(PI_SRC_STORE));
        V_TGT_POS := FN_CNT('TB_MS_POS', 'STORE_CD = ' || FN_Q(PI_TGT_STORE));

        IF V_SRC_POS <= 0 OR V_TGT_POS <= 0 THEN
            P('/* ---- ' || PI_TABLE || ' ---- */');
            P('-- >> SKIP : POS 대수 원본 ' || V_SRC_POS || ' / 대상 ' || V_TGT_POS
              || ' -> 매핑할 수 없습니다.');
            P('--           (기존 구현은 여기서 대상 설정만 지웠습니다)');
            P(' ');
            G_TOT_SKIP := G_TOT_SKIP + 1;
            RETURN;
        END IF;

        SP_FROM_SET(
            CHR(10) || '     , ( SELECT p."POS_NO"'
         || CHR(10) || '              , CASE WHEN p."POS_NO" > m.MAX_NO THEN m.MAX_NO'
         || CHR(10) || '                     ELSE p."POS_NO" END AS O_POS_NO'
         || CHR(10) || '           FROM ' || G_OWNER || '.TB_MS_POS p'
         || CHR(10) || '              , ( SELECT MAX("POS_NO") AS MAX_NO'
         || CHR(10) || '                    FROM ' || G_OWNER || '.TB_MS_POS'
         || CHR(10) || '                   WHERE "STORE_CD" = ' || FN_Q(PI_SRC_STORE) || ' ) m'
         || CHR(10) || '          WHERE p."STORE_CD" = ' || FN_Q(PI_TGT_STORE) || ' ) t' );

        SP_MAP_ADD('POS_NO', 't."POS_NO"');

        SP_COPY_SAME( PI_TABLE, 'STORE_CD', PI_SRC_STORE, PI_TGT_STORE,
                      's."POS_NO" = t."O_POS_NO"' );
    END SP_COPY_POS;


    /* ==================================================================
       매장 공통코드 : TB_CM_NMCODE 기준
       ================================================================== */
    PROCEDURE SP_NMCODE_STORE( PI_TGT_STORE IN VARCHAR2 ) IS
    BEGIN
        P_HEAD('매장 공통코드  ->  ' || PI_TGT_STORE);
        P('-- 본사 코드를 내리지 않고 TB_CM_NMCODE 에서 매장용만 만듭니다.');
        P('--   본사 = USE_TARGET_FG IN (''C'',''H'')');
        P('--   매장 = USE_TARGET_FG IN (''C'',''S'')');
        P(' ');

        SP_COPY( 'TB_CM_NMCODE', 'TB_MS_STORE_NMCODE'
               , NULL, 'STORE_CD'
               , NULL, PI_TGT_STORE
               , 's."USE_TARGET_FG" IN (''C'',''S'')' );
    END SP_NMCODE_STORE;


    /* ==================================================================
       백업 / 검증
       ================================================================== */
    PROCEDURE SP_BACKUP( PI_KEY_COL IN VARCHAR2
                       , PI_KEY_VAL IN VARCHAR2
                       , PI_SUFFIX  IN VARCHAR2
                       , PI_TABLES  IN SYS.ODCIVARCHAR2LIST )
    IS
        V_NEW VARCHAR2(200);
        V_SQL VARCHAR2(4000);
    BEGIN
        P_HEAD('백업  ' || PI_KEY_COL || ' = ' || PI_KEY_VAL || '   접미어 _' || PI_SUFFIX);
        P('-- CREATE TABLE 은 DDL 이라 한 건마다 COMMIT 됩니다.');
        P(' ');

        FOR I IN 1 .. PI_TABLES.COUNT LOOP
            V_NEW := PI_TABLES(I) || '_' || PI_SUFFIX;
            V_SQL := 'CREATE TABLE ' || G_OWNER || '.' || V_NEW
                  || ' AS SELECT * FROM ' || G_OWNER || '.' || PI_TABLES(I)
                  || ' WHERE "' || PI_KEY_COL || '" = ' || FN_Q(PI_KEY_VAL);

            IF NOT FN_TAB_EXISTS(PI_TABLES(I)) THEN
                P('-- >> SKIP : ' || PI_TABLES(I) || ' 없음');
            ELSIF FN_TAB_EXISTS(V_NEW) THEN
                P('-- >> SKIP : ' || V_NEW || ' 이미 있음. 접미어를 바꾸세요.');
            ELSE
                P(V_SQL || ';');
                IF G_EXEC_YN = 'Y' THEN
                    BEGIN
                        EXECUTE IMMEDIATE V_SQL;
                        P('-- >> ' || V_NEW || ' 생성');
                    EXCEPTION
                        WHEN OTHERS THEN
                            G_TOT_ERR := G_TOT_ERR + 1;
                            P('-- !! ERROR ' || V_NEW || ' : ' || SQLERRM);
                            IF G_STOP_ON_ERR = 'Y' THEN RAISE; END IF;
                    END;
                END IF;
            END IF;
        END LOOP;
        P(' ');
    END SP_BACKUP;


    /* ==================================================================
       참조 점검

       복사할 원본 행이 참조하는 값이 대상 쪽에 있는지 봅니다.
       FK 제약을 읽어 자동으로 만듭니다. 예를 들어 TB_HQ_PRODUCT 의
       HQ_BRAND_CD 가 가리키는 브랜드가 대상 본사에 없으면 여기서 잡힙니다.

       같은 테이블끼리 복사(HQ->HQ, MS->MS)를 전제로 합니다.
       부모의 키 컬럼은 대상 키값으로, 나머지는 자식의 값으로 맞춰 봅니다.
       ================================================================== */
    PROCEDURE SP_REF_CHECK( PI_KEY_COL IN VARCHAR2
                          , PI_SRC_KEY IN VARCHAR2
                          , PI_TGT_KEY IN VARCHAR2
                          , PI_TABLES  IN SYS.ODCIVARCHAR2LIST )
    IS
        V_CCOLS  SYS.ODCIVARCHAR2LIST;
        V_PCOLS  SYS.ODCIVARCHAR2LIST;
        V_ON     VARCHAR2(4000);
        V_NOTNUL VARCHAR2(4000);
        V_SQL    CLOB;
        V_CNT    PLS_INTEGER;
        V_BAD    PLS_INTEGER := 0;
        V_CHECKED PLS_INTEGER := 0;
    BEGIN
        P_HEAD('참조 점검   ' || PI_SRC_KEY || '  ->  ' || PI_TGT_KEY);
        P('-- 원본이 참조하는 코드값이 대상에 있는지 FK 기준으로 봅니다.');
        P('-- 없는 값이 있으면 복사 후 그 행은 붕 뜨거나 FK 위반이 납니다.');
        P(' ');

        FOR I IN 1 .. PI_TABLES.COUNT LOOP
            IF FN_TAB_EXISTS(PI_TABLES(I)) THEN

                FOR R IN ( SELECT C.CONSTRAINT_NAME AS CH_CONS
                                , RC.CONSTRAINT_NAME AS PA_CONS
                                , RC.TABLE_NAME      AS PARENT
                             FROM ALL_CONSTRAINTS C
                             JOIN ALL_CONSTRAINTS RC
                               ON  RC.OWNER           = C.R_OWNER
                               AND RC.CONSTRAINT_NAME = C.R_CONSTRAINT_NAME
                            WHERE C.OWNER           = G_OWNER
                              AND C.TABLE_NAME      = PI_TABLES(I)
                              AND C.CONSTRAINT_TYPE = 'R'
                              AND C.STATUS          = 'ENABLED'
                            ORDER BY C.CONSTRAINT_NAME )
                LOOP
                    SELECT COLUMN_NAME BULK COLLECT INTO V_CCOLS
                      FROM ALL_CONS_COLUMNS
                     WHERE OWNER = G_OWNER AND CONSTRAINT_NAME = R.CH_CONS
                     ORDER BY POSITION;

                    SELECT COLUMN_NAME BULK COLLECT INTO V_PCOLS
                      FROM ALL_CONS_COLUMNS
                     WHERE OWNER = G_OWNER AND CONSTRAINT_NAME = R.PA_CONS
                     ORDER BY POSITION;

                    IF V_CCOLS.COUNT = V_PCOLS.COUNT AND V_CCOLS.COUNT > 0 THEN

                        V_ON     := NULL;
                        V_NOTNUL := NULL;

                        FOR K IN 1 .. V_PCOLS.COUNT LOOP
                            V_ON := V_ON || CHR(10) || '                       AND p."' || V_PCOLS(K) || '" = '
                                 || CASE WHEN V_PCOLS(K) = PI_KEY_COL
                                         THEN FN_Q(PI_TGT_KEY)
                                         ELSE 's."' || V_CCOLS(K) || '"' END;

                            IF V_CCOLS(K) <> PI_KEY_COL THEN
                                V_NOTNUL := V_NOTNUL || CHR(10)
                                         || '   AND s."' || V_CCOLS(K) || '" IS NOT NULL';
                            END IF;
                        END LOOP;

                        V_SQL := 'SELECT COUNT(*)'                                     || CHR(10)
                              || '  FROM ' || G_OWNER || '.' || PI_TABLES(I) || ' s'   || CHR(10)
                              || ' WHERE s."' || PI_KEY_COL || '" = ' || FN_Q(PI_SRC_KEY)
                              || V_NOTNUL                                              || CHR(10)
                              || '   AND NOT EXISTS ( SELECT 1'                        || CHR(10)
                              || '                      FROM ' || G_OWNER || '.' || R.PARENT || ' p' || CHR(10)
                              || '                     WHERE 1 = 1' || V_ON            || CHR(10)
                              || '                   )';

                        V_CNT := FN_CNT_SQL(V_SQL);
                        V_CHECKED := V_CHECKED + 1;

                        IF V_CNT > 0 THEN
                            V_BAD := V_BAD + 1;
                            P('-- !! ' || RPAD(PI_TABLES(I), 34)
                              || ' -> ' || RPAD(R.PARENT, 30)
                              || FN_N(V_CNT) || ' 건이 대상에 없는 값을 참조합니다');
                            P('--    참조 컬럼 : ' || FN_JOIN(V_CCOLS));
                            IF G_PRINT_SQL = 'Y' THEN
                                P('--    확인 : ');
                                P_CLOB(V_SQL);
                                P(';');
                            END IF;
                            P(' ');
                        END IF;
                    END IF;
                END LOOP;
            END IF;
        END LOOP;

        P(' ');
        P('-- FK ' || V_CHECKED || ' 개 확인, 문제 ' || V_BAD || ' 건');
        IF V_BAD = 0 THEN
            P('-- 이상 없음. 참조하는 값이 모두 대상에 있습니다.');
        ELSE
            P('-- << 위 부모 테이블을 먼저 복사하거나 값을 만들어 두십시오.');
        END IF;
        P(' ');
    END SP_REF_CHECK;


    PROCEDURE SP_VERIFY( PI_KEY_COL IN VARCHAR2
                       , PI_SRC_KEY IN VARCHAR2
                       , PI_TGT_KEY IN VARCHAR2
                       , PI_TABLES  IN SYS.ODCIVARCHAR2LIST )
    IS
        V_S PLS_INTEGER;
        V_T PLS_INTEGER;
    BEGIN
        P_HEAD('건수 비교  ' || NVL(PI_SRC_KEY,'-') || '  ->  ' || PI_TGT_KEY);
        P('-- ' || RPAD('TABLE', 38) || LPAD('SRC', 10) || LPAD('TGT', 10) || '   차이');

        FOR I IN 1 .. PI_TABLES.COUNT LOOP
            IF FN_TAB_EXISTS(PI_TABLES(I)) THEN
                V_S := CASE WHEN PI_SRC_KEY IS NULL THEN -1
                            ELSE FN_CNT(PI_TABLES(I),
                                 '"' || PI_KEY_COL || '" = ' || FN_Q(PI_SRC_KEY)) END;
                V_T := FN_CNT(PI_TABLES(I),
                              '"' || PI_KEY_COL || '" = ' || FN_Q(PI_TGT_KEY));

                P('-- ' || RPAD(PI_TABLES(I), 38)
                  || LPAD(CASE WHEN V_S < 0 THEN '-' ELSE TO_CHAR(V_S) END, 10)
                  || LPAD(TO_CHAR(V_T), 10)
                  || CASE WHEN V_S < 0 THEN ''
                          WHEN V_S = V_T THEN '   같음'
                          ELSE '   ' || TO_CHAR(V_T - V_S) END);
            ELSE
                P('-- ' || RPAD(PI_TABLES(I), 38) || '   테이블 없음');
            END IF;
        END LOOP;
        P(' ');
    END SP_VERIFY;


    /* ==================================================================
       키 후보 보기
       ================================================================== */
    PROCEDURE SP_KEY_REPORT( PI_TABLES  IN SYS.ODCIVARCHAR2LIST
                           , PI_KEY_COL IN VARCHAR2 DEFAULT NULL )
    IS
        V_COLS  SYS.ODCIVARCHAR2LIST;
        V_SRC   VARCHAR2(300);
        V_CANDS PLS_INTEGER;
        V_NULLK VARCHAR2(4000);
    BEGIN
        P_HEAD('키 후보 점검' || CASE WHEN PI_KEY_COL IS NOT NULL
                                      THEN '   (복사 키 : ' || PI_KEY_COL || ')' ELSE '' END);
        P('-- 엔진이 무엇을 중복 판단 기준으로 쓸지 미리 보여줍니다.');
        P('-- 마음에 안 들면 SP_KEY_SET(테이블, ''컬럼1,컬럼2'') 로 바꾸십시오.');
        P(' ');

        FOR I IN 1 .. PI_TABLES.COUNT LOOP
            IF NOT FN_TAB_EXISTS(PI_TABLES(I)) THEN
                P('-- ' || RPAD(PI_TABLES(I), 36) || '테이블 없음');
            ELSE
                SP_KEY_COLS(PI_TABLES(I), PI_KEY_COL, V_COLS, V_SRC, V_CANDS);

                IF V_COLS IS NULL OR V_COLS.COUNT = 0 THEN
                    P('-- ' || RPAD(PI_TABLES(I), 36) || '<< 키 없음. S / M 모드에서 건너뜁니다');
                ELSE
                    P('-- ' || RPAD(PI_TABLES(I), 36) || RPAD(V_SRC, 32)
                      || '( ' || FN_JOIN(V_COLS) || ' )');

                    IF V_CANDS > 1 THEN
                        P('--   ' || RPAD(' ', 34) || '후보 ' || V_CANDS || ' 개 중 선택됨');
                        /* 나머지 후보도 보여준다 */
                        FOR C IN ( SELECT KIND, KEY_NAME, COL_CNT, HAS_KEYCOL
                                     FROM ( SELECT 'UNIQUE 제약' AS KIND
                                                 , C.CONSTRAINT_NAME AS KEY_NAME
                                                 , COUNT(*) AS COL_CNT
                                                 , MAX(CASE WHEN CC.COLUMN_NAME = PI_KEY_COL
                                                            THEN 1 ELSE 0 END) AS HAS_KEYCOL
                                              FROM ALL_CONSTRAINTS C
                                              JOIN ALL_CONS_COLUMNS CC
                                                ON  CC.OWNER           = C.OWNER
                                                AND CC.CONSTRAINT_NAME = C.CONSTRAINT_NAME
                                             WHERE C.OWNER           = G_OWNER
                                               AND C.TABLE_NAME      = PI_TABLES(I)
                                               AND C.CONSTRAINT_TYPE = 'U'
                                               AND C.STATUS          = 'ENABLED'
                                             GROUP BY C.CONSTRAINT_NAME
                                            UNION ALL
                                            SELECT 'UNIQUE 인덱스', I2.INDEX_NAME, COUNT(*)
                                                 , MAX(CASE WHEN IC.COLUMN_NAME = PI_KEY_COL
                                                            THEN 1 ELSE 0 END)
                                              FROM ALL_INDEXES I2
                                              JOIN ALL_IND_COLUMNS IC
                                                ON  IC.INDEX_OWNER = I2.OWNER
                                                AND IC.INDEX_NAME  = I2.INDEX_NAME
                                             WHERE I2.TABLE_OWNER = G_OWNER
                                               AND I2.TABLE_NAME  = PI_TABLES(I)
                                               AND I2.UNIQUENESS  = 'UNIQUE'
                                               AND NOT EXISTS ( SELECT 1 FROM ALL_CONSTRAINTS C2
                                                                 WHERE C2.OWNER      = I2.OWNER
                                                                   AND C2.INDEX_NAME = I2.INDEX_NAME
                                                                   AND C2.CONSTRAINT_TYPE IN ('P','U') )
                                             GROUP BY I2.INDEX_NAME )
                                    ORDER BY HAS_KEYCOL DESC, COL_CNT, KEY_NAME )
                        LOOP
                            P('--   ' || RPAD(' ', 34) || '· ' || RPAD(C.KIND, 14)
                              || RPAD(C.KEY_NAME, 32) || C.COL_CNT || ' 컬럼');
                        END LOOP;
                    END IF;

                    V_NULLK := FN_NULLABLE_KEYS(PI_TABLES(I), V_COLS);
                    IF V_NULLK IS NOT NULL THEN
                        P('--   ' || RPAD(' ', 34) || '<< NULL 허용 컬럼 : ' || V_NULLK);
                    END IF;
                END IF;
            END IF;
        END LOOP;
        P(' ');
    END SP_KEY_REPORT;


    /* ==================================================================
       환경 점검
       ================================================================== */
    PROCEDURE SP_CHECK_ENV( PI_HQ    IN VARCHAR2 DEFAULT NULL
                          , PI_STORE IN VARCHAR2 DEFAULT NULL )
    IS
        V_CNT  PLS_INTEGER;
        V_OK   BOOLEAN := TRUE;
        V_LIST  SYS.ODCIVARCHAR2LIST;
        V_PK    SYS.ODCIVARCHAR2LIST;
        V_SRC   VARCHAR2(300);
        V_CANDS PLS_INTEGER;
        V_NOPK  PLS_INTEGER := 0;
    BEGIN
        P_HEAD('환경 점검');

        P('-- 접속 계정      : ' || USER);
        P('-- 대상 스키마    : ' || G_OWNER
          || CASE WHEN USER = G_OWNER THEN '   (소유자. 권한 문제 없음)'
                  ELSE '   << 롤이 아닌 직접 권한이 필요합니다' END);

        SELECT COUNT(*) INTO V_CNT
          FROM ALL_TABLES
         WHERE OWNER = G_OWNER
           AND (TABLE_NAME LIKE 'TB_HQ%' OR TABLE_NAME LIKE 'TB_MS%');
        P('-- 보이는 테이블  : ' || V_CNT || ' 개'
          || CASE WHEN V_CNT = 0 THEN '   << 딕셔너리가 안 보입니다. 전부 건너뜁니다'
                  ELSE '' END);
        IF V_CNT = 0 THEN V_OK := FALSE; END IF;

        P(' ');
        P('-- 감사컬럼 타입 분포');
        FOR C IN ( SELECT DATA_TYPE, COUNT(DISTINCT TABLE_NAME) AS CNT
                     FROM ALL_TAB_COLUMNS
                    WHERE OWNER = G_OWNER
                      AND COLUMN_NAME IN ('REG_DT','MOD_DT')
                    GROUP BY DATA_TYPE
                    ORDER BY 2 DESC )
        LOOP
            P('--   ' || RPAD(C.DATA_TYPE, 16) || C.CNT || ' 개 테이블'
              || CASE WHEN C.DATA_TYPE LIKE 'VARCHAR%'
                      THEN '   -> TO_CHAR(SYSDATE,''' || G_DT_FMT || ''')'
                      ELSE '   -> SYSDATE' END);
        END LOOP;

        P(' ');
        BEGIN
            EXECUTE IMMEDIATE 'BEGIN DBMS_LOCK.SLEEP(0); END;';
            P('-- DBMS_LOCK      : 사용 가능');
        EXCEPTION
            WHEN OTHERS THEN
                P('-- DBMS_LOCK      : 권한 없음 (대기 없이 진행합니다. 문제 아님)');
        END;

        IF PI_HQ IS NOT NULL THEN
            V_CNT := FN_CNT('TB_HQ_OFFICE', 'HQ_OFFICE_CD = ' || FN_Q(PI_HQ));
            P('-- 본사행 ' || RPAD(PI_HQ, 10) || ': ' || V_CNT
              || CASE WHEN V_CNT <= 0 THEN '   << 먼저 만들어야 합니다' ELSE '' END);
            IF V_CNT <= 0 THEN V_OK := FALSE; END IF;
        END IF;

        IF PI_STORE IS NOT NULL THEN
            V_CNT := FN_CNT('TB_MS_STORE', 'STORE_CD = ' || FN_Q(PI_STORE));
            P('-- 매장행 ' || RPAD(PI_STORE, 10) || ': ' || V_CNT
              || CASE WHEN V_CNT <= 0 THEN '   << 먼저 만들어야 합니다' ELSE '' END);
            IF V_CNT <= 0 THEN V_OK := FALSE; END IF;
        END IF;

        P(' ');
        P('-- 키 상태 (PK 없이 UNIQUE 만 있는 것 / 아예 없는 것)');

        FOR K IN 1 .. 2 LOOP
            IF K = 1 THEN V_LIST := FN_LIST_H2H; ELSE V_LIST := FN_LIST_M2M; END IF;

            FOR I IN 1 .. V_LIST.COUNT LOOP
                IF FN_TAB_EXISTS(V_LIST(I)) THEN
                    SP_KEY_COLS(V_LIST(I),
                                CASE WHEN K = 1 THEN 'HQ_OFFICE_CD' ELSE 'STORE_CD' END,
                                V_PK, V_SRC, V_CANDS);

                    IF V_PK IS NULL OR V_PK.COUNT = 0 THEN
                        P('--   ' || RPAD(V_LIST(I), 36) || '<< 키 없음. 건너뜁니다');
                        V_NOPK := V_NOPK + 1;
                    ELSIF V_SRC NOT LIKE 'PK %' THEN
                        P('--   ' || RPAD(V_LIST(I), 36) || V_SRC
                          || CASE WHEN V_CANDS > 1 THEN '   (후보 ' || V_CANDS || ' 개)' ELSE '' END);
                        V_NOPK := V_NOPK + 1;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;

        IF V_NOPK = 0 THEN
            P('--   전부 PK 가 있습니다.');
        ELSE
            P('--   위 테이블은 SP_KEY_REPORT 로 후보를 확인하십시오.');
        END IF;

        P(' ');
        IF V_OK THEN
            P('-- 판정 : 진행 가능');
        ELSE
            P('-- 판정 : << 위 표시된 항목을 먼저 해결하세요');
        END IF;
        P(' ');
    END SP_CHECK_ENV;


    /* ==================================================================
       기본 복사 순서
       ================================================================== */
    FUNCTION FN_LIST_H2H RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'TB_HQ_ENVST', 'TB_HQ_NMCODE'
          , 'TB_HQ_PRODUCT', 'TB_HQ_PRODUCT_INFO', 'TB_HQ_PRODUCT_SPEC'
          , 'TB_HQ_PRODUCT_IMAGE', 'TB_HQ_PRODUCT_WEIGHT', 'TB_HQ_PRODUCT_SALE_PRICE'
          , 'TB_HQ_PRODUCT_OPTION_GROUP', 'TB_HQ_PRODUCT_OPTION_VAL'
          , 'TB_HQ_PRODUCT_SDSEL_CLASS', 'TB_HQ_PRODUCT_SDSEL_CLASS_CD'
          , 'TB_HQ_PRODUCT_SDSEL_GROUP', 'TB_HQ_PRODUCT_SDSEL_PROD'
          , 'TB_HQ_TOUCH_KEY_GROUP'
          , 'TB_HQ_KIOSK_GROUP', 'TB_HQ_KIOSK_M_CLS', 'TB_HQ_KIOSK_CLS'
          , 'TB_HQ_PROMO_H', 'TB_HQ_PROMO_CONDI'
          , 'TB_HQ_NEOE_PROMO', 'TB_HQ_NEOE_PROMO_BENE_PROD'
          , 'TB_HQ_STORE_TYPE_APP', 'TB_HQ_STORE_TYPE_PROD_GROUP'
          , 'TB_HQ_STORE_TYPE_APP_PROD1', 'TB_HQ_STORE_TYPE_APP_PROD2'
          , 'TB_HQ_STORE_PROD_GROUP_DTL'
          , 'TB_HQ_POS_ADVER_FILE', 'TB_HQ_ERP_PROD_MAPPING' );
    END FN_LIST_H2H;


    FUNCTION FN_LIST_H2M RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'TB_HQ_ENVST'
          , 'TB_HQ_PRODUCT', 'TB_HQ_PRODUCT_INFO'
          , 'TB_HQ_PRODUCT_WEIGHT', 'TB_HQ_PRODUCT_SALE_PRICE'
          , 'TB_HQ_PRODUCT_SDSEL_CLASS', 'TB_HQ_PRODUCT_SDSEL_GROUP'
          , 'TB_HQ_PRODUCT_SDSEL_PROD'
          , 'TB_HQ_TOUCH_KEY_GROUP'
          , 'TB_HQ_KIOSK_GROUP', 'TB_HQ_KIOSK_M_CLS', 'TB_HQ_KIOSK_CLS'
          , 'TB_HQ_PROMO_H', 'TB_HQ_PROMO_CONDI'
          , 'TB_HQ_NEOE_PROMO', 'TB_HQ_NEOE_PROMO_BENE_PROD'
          , 'TB_HQ_POS_ADVER_FILE' );
    END FN_LIST_H2M;


    FUNCTION FN_LIST_M2M RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'TB_MS_STORE_INFO', 'TB_MS_STORE_ENVST', 'TB_MS_STORE_NMCODE', 'TB_MS_BRAND'
          , 'TB_MS_CORNER', 'TB_MS_CORNER_TERMNL'
          , 'TB_MS_POS', 'TB_MS_POS_ENVST', 'TB_MS_POS_TERMNL'
          , 'TB_MS_STORE_FNKEY', 'TB_MS_POS_FNKEY'
          , 'TB_MS_PRINTER', 'TB_MS_PRINT', 'TB_MS_PRINT_TEMPL', 'TB_MS_STORAGE'
          , 'TB_MS_PRODUCT_CLASS', 'TB_MS_PRODUCT', 'TB_MS_PRODUCT_INFO'
          , 'TB_MS_PRODUCT_SALE_PRICE', 'TB_MS_PRODUCT_SALE_TIME'
          , 'TB_MS_PRODUCT_BARCD', 'TB_MS_PRODUCT_WEIGHT'
          , 'TB_MS_PRODUCT_UNITST_PROD', 'TB_MS_VENDOR_PROD'
          , 'TB_MS_PRODUCT_SDATTR_CLASS', 'TB_MS_PRODUCT_SDATTR'
          , 'TB_MS_PRODUCT_SDSEL_CLASS', 'TB_MS_PRODUCT_SDSEL_GROUP'
          , 'TB_MS_PRODUCT_SDSEL_PROD'
          , 'TB_MS_PRODUCT_RECP_ORIGIN', 'TB_MS_PRODUCT_RECP_PROD'
          , 'TB_MS_PRODUCT_ALGI_INFO', 'TB_MS_PRODUCT_ALGI_PROD'
          , 'TB_MS_PRODUCT_DLVR_PROD_NM', 'TB_MS_PRODUCT_DLVR_PROD_NM_MULTI'
          , 'TB_MS_TOUCH_KEY_GROUP', 'TB_MS_TOUCH_KEY_CLASS', 'TB_MS_TOUCH_KEY'
          , 'TB_MS_KIOSK_GROUP', 'TB_MS_KIOSK_M_CLS', 'TB_MS_KIOSK_CLS', 'TB_MS_KIOSK_KEY'
          , 'TB_MS_TABLE_GROUP', 'TB_MS_TABLE', 'TB_MS_TABLE_ATTR'
          , 'TB_MS_PAY_METHOD_CLASS', 'TB_MS_COUPON', 'TB_MS_COUPON_PROD'
          , 'TB_MS_GIFT', 'TB_MS_ACCOUNT', 'TB_MS_CAPTION_MESSAGE'
          , 'TB_MS_PROMO_H', 'TB_MS_PROMO_CONDI', 'TB_MS_PROMO_CONDI_PROD'
          , 'TB_MS_PROMO_BENE'
          , 'TB_MS_NEOE_PROMO', 'TB_MS_NEOE_PROMO_BENE_PROD'
          , 'TB_MS_POS_ADVER_FILE'
          , 'TB_WB_STORE_CONFG_XML', 'TB_WB_POS_CONFG_XML' );
    END FN_LIST_M2M;


    FUNCTION FN_MS_OF( PI_HQ_TABLE IN VARCHAR2 ) RETURN VARCHAR2 IS
    BEGIN
        IF G_PAIR.EXISTS(PI_HQ_TABLE) THEN
            RETURN G_PAIR(PI_HQ_TABLE);
        END IF;
        RETURN NULL;
    END FN_MS_OF;


    /* ==================================================================
       마무리 : 확정 여부
       ================================================================== */
    PROCEDURE SP_FINISH IS
    BEGIN
        SP_SUMMARY;

        IF G_PREVIEW_YN = 'Y' THEN
            P('-- 건수만 세었습니다. 실제로 하려면 G_PREVIEW_YN := ''N'' 으로 두세요.');
        ELSIF G_EXEC_YN = 'N' THEN
            P('-- 미실행 모드였습니다. 반영하려면 G_EXEC_YN := ''Y'' 로 두고 다시 부르세요.');
        ELSIF G_TOT_ERR > 0 THEN
            ROLLBACK;
            P('-- 오류가 있어 ROLLBACK 했습니다.');
        ELSIF G_COMMIT_YN = 'Y' THEN
            COMMIT;
            P('-- COMMIT 되었습니다.');
        ELSE
            ROLLBACK;
            P('-- ROLLBACK 했습니다. 확정하려면 G_COMMIT_YN := ''Y'' 로 두고 다시 부르세요.');
        END IF;
        P(' ');
    END SP_FINISH;


    /* ==================================================================
       본사 -> 본사
       ================================================================== */
    PROCEDURE SP_HQ2HQ( PI_SRC_HQ IN VARCHAR2
                      , PI_TGT_HQ IN VARCHAR2
                      , PI_TABLES IN SYS.ODCIVARCHAR2LIST DEFAULT NULL )
    IS
        V_LIST SYS.ODCIVARCHAR2LIST;
    BEGIN
        IF PI_TABLES IS NULL THEN
            V_LIST := FN_LIST_H2H;
        ELSE
            V_LIST := PI_TABLES;
        END IF;

        SP_RESET;
        P_HEAD('본사 -> 본사   ' || PI_SRC_HQ || '  ->  ' || PI_TGT_HQ
               || '   [' || G_MODE || '/' || G_EXEC_YN || ']');

        IF PI_SRC_HQ = PI_TGT_HQ THEN
            RAISE_APPLICATION_ERROR(-20001, '원본과 대상 본사코드가 같습니다.');
        END IF;

        IF FN_CNT('TB_HQ_OFFICE', 'HQ_OFFICE_CD = ' || FN_Q(PI_SRC_HQ)) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20011, '원본 본사 ' || PI_SRC_HQ || ' 가 없습니다.');
        END IF;

        IF FN_CNT('TB_HQ_OFFICE', 'HQ_OFFICE_CD = ' || FN_Q(PI_TGT_HQ)) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20012,
                '대상 본사 ' || PI_TGT_HQ || ' 가 없습니다. TB_HQ_OFFICE 부터 만드세요.');
        END IF;

        FOR I IN 1 .. V_LIST.COUNT LOOP
            SP_COPY_SAME(V_LIST(I), 'HQ_OFFICE_CD', PI_SRC_HQ, PI_TGT_HQ);
        END LOOP;

        SP_FINISH;
    END SP_HQ2HQ;


    /* ==================================================================
       본사 -> 매장
       ================================================================== */
    PROCEDURE SP_HQ2MS( PI_SRC_HQ    IN VARCHAR2
                      , PI_TGT_STORE IN VARCHAR2
                      , PI_TABLES    IN SYS.ODCIVARCHAR2LIST DEFAULT NULL )
    IS
        V_LIST SYS.ODCIVARCHAR2LIST;
        V_TGT  VARCHAR2(128);
        V_WH   VARCHAR2(1000);
    BEGIN
        IF PI_TABLES IS NULL THEN
            V_LIST := FN_LIST_H2M;
        ELSE
            V_LIST := PI_TABLES;
        END IF;

        SP_RESET;
        P_HEAD('본사 -> 매장   ' || PI_SRC_HQ || '  ->  ' || PI_TGT_STORE
               || '   [' || G_MODE || '/' || G_EXEC_YN || ']');

        IF FN_CNT('TB_MS_STORE', 'STORE_CD = ' || FN_Q(PI_TGT_STORE)
                  || ' AND HQ_OFFICE_CD = ' || FN_Q(PI_SRC_HQ)) <= 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                '매장 ' || PI_TGT_STORE || ' 이(가) 본사 ' || PI_SRC_HQ
                || ' 소속이 아니거나 없습니다.');
        END IF;

        IF G_PROD_FILTER = 'Y' THEN
            V_WH := 'EXISTS ( SELECT 1 FROM ' || G_OWNER || '.TB_HQ_PRODUCT_STORE m'
                 || '          WHERE m."HQ_OFFICE_CD" = s."HQ_OFFICE_CD"'
                 || '            AND m."PROD_CD"      = s."PROD_CD"'
                 || '            AND m."STORE_CD"     = ' || FN_Q(PI_TGT_STORE) || ' )';
            P('-- 상품 필터 : TB_HQ_PRODUCT_STORE 에 이 매장으로 지정된 상품만 내립니다.');
            P('--             전체를 내리려면 G_PROD_FILTER := ''N'' 으로 두세요.');
            P(' ');
        END IF;

        FOR I IN 1 .. V_LIST.COUNT LOOP
            V_TGT := FN_MS_OF(V_LIST(I));

            IF V_TGT IS NULL THEN
                P('-- >> SKIP : ' || V_LIST(I) || ' 의 매장쪽 짝을 모릅니다.');
                P(' ');
                G_TOT_SKIP := G_TOT_SKIP + 1;
            ELSE
                IF V_TGT = 'TB_MS_PRODUCT' AND FN_HAS_COL('TB_MS_PRODUCT','REG_FG') THEN
                    SP_MAP_ADD('REG_FG', '''H''');
                END IF;

                IF V_LIST(I) IN ( 'TB_HQ_PRODUCT', 'TB_HQ_PRODUCT_INFO'
                                , 'TB_HQ_PRODUCT_WEIGHT', 'TB_HQ_PRODUCT_SALE_PRICE' )
                THEN
                    SP_COPY(V_LIST(I), V_TGT, 'HQ_OFFICE_CD', 'STORE_CD',
                            PI_SRC_HQ, PI_TGT_STORE, V_WH);
                ELSE
                    SP_COPY(V_LIST(I), V_TGT, 'HQ_OFFICE_CD', 'STORE_CD',
                            PI_SRC_HQ, PI_TGT_STORE);
                END IF;
            END IF;
        END LOOP;

        P('-- 안내 : 매장 공통코드는 규칙이 달라 여기서 내리지 않습니다.');
        P('--        EXEC PKG_CM_COPY_V2.SP_NMCODE_STORE(' || FN_Q(PI_TGT_STORE) || ')');
        P('-- 안내 : 터치키 화면 구성은 XML(TB_WB_*)에 있어 별도 이관이 필요합니다.');
        P(' ');

        SP_FINISH;
    END SP_HQ2MS;


    /* ==================================================================
       매장 -> 매장
       ================================================================== */
    PROCEDURE SP_MS2MS( PI_SRC_STORE IN VARCHAR2
                      , PI_TGT_STORE IN VARCHAR2
                      , PI_TABLES    IN SYS.ODCIVARCHAR2LIST DEFAULT NULL )
    IS
        V_LIST   SYS.ODCIVARCHAR2LIST;
        V_SRC_HQ VARCHAR2(30);
        V_TGT_HQ VARCHAR2(30);
    BEGIN
        IF PI_TABLES IS NULL THEN
            V_LIST := FN_LIST_M2M;
        ELSE
            V_LIST := PI_TABLES;
        END IF;

        SP_RESET;
        P_HEAD('매장 -> 매장   ' || PI_SRC_STORE || '  ->  ' || PI_TGT_STORE
               || '   [' || G_MODE || '/' || G_EXEC_YN || ']');

        IF PI_SRC_STORE = PI_TGT_STORE THEN
            RAISE_APPLICATION_ERROR(-20003, '원본과 대상 매장코드가 같습니다.');
        END IF;

        BEGIN
            EXECUTE IMMEDIATE
                'SELECT HQ_OFFICE_CD FROM ' || G_OWNER || '.TB_MS_STORE WHERE STORE_CD = :1'
                INTO V_SRC_HQ USING PI_SRC_STORE;
            EXECUTE IMMEDIATE
                'SELECT HQ_OFFICE_CD FROM ' || G_OWNER || '.TB_MS_STORE WHERE STORE_CD = :1'
                INTO V_TGT_HQ USING PI_TGT_STORE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20004, '원본 또는 대상 매장이 없습니다.');
        END;

        IF V_SRC_HQ <> V_TGT_HQ THEN
            RAISE_APPLICATION_ERROR(-20005,
                '본사가 다릅니다. ' || PI_SRC_STORE || '=' || V_SRC_HQ ||
                ' / ' || PI_TGT_STORE || '=' || V_TGT_HQ || ' -> 복사 금지.');
        END IF;

        FOR I IN 1 .. V_LIST.COUNT LOOP
            IF G_POSTAB.EXISTS(V_LIST(I)) THEN
                SP_COPY_POS(V_LIST(I), PI_SRC_STORE, PI_TGT_STORE);
            ELSE
                SP_COPY_SAME(V_LIST(I), 'STORE_CD', PI_SRC_STORE, PI_TGT_STORE);
            END IF;
        END LOOP;

        SP_FINISH;
    END SP_MS2MS;


/* 세션 시작 시 기본값 등록 */
BEGIN
    /* 컬럼 별칭 */
    G_ALIAS('MS_BRAND_CD') := 'HQ_BRAND_CD';
    G_ALIAS('HQ_BRAND_CD') := 'MS_BRAND_CD';

    /* 본사 -> 매장 대응쌍 */
    G_PAIR('TB_HQ_ENVST')                := 'TB_MS_STORE_ENVST';
    G_PAIR('TB_HQ_NMCODE')               := 'TB_MS_STORE_NMCODE';
    G_PAIR('TB_HQ_PRODUCT')              := 'TB_MS_PRODUCT';
    G_PAIR('TB_HQ_PRODUCT_INFO')         := 'TB_MS_PRODUCT_INFO';
    G_PAIR('TB_HQ_PRODUCT_WEIGHT')       := 'TB_MS_PRODUCT_WEIGHT';
    G_PAIR('TB_HQ_PRODUCT_SALE_PRICE')   := 'TB_MS_PRODUCT_SALE_PRICE';
    G_PAIR('TB_HQ_PRODUCT_SDSEL_CLASS')  := 'TB_MS_PRODUCT_SDSEL_CLASS';
    G_PAIR('TB_HQ_PRODUCT_SDSEL_GROUP')  := 'TB_MS_PRODUCT_SDSEL_GROUP';
    G_PAIR('TB_HQ_PRODUCT_SDSEL_PROD')   := 'TB_MS_PRODUCT_SDSEL_PROD';
    G_PAIR('TB_HQ_TOUCH_KEY_GROUP')      := 'TB_MS_TOUCH_KEY_GROUP';
    G_PAIR('TB_HQ_KIOSK_GROUP')          := 'TB_MS_KIOSK_GROUP';
    G_PAIR('TB_HQ_KIOSK_M_CLS')          := 'TB_MS_KIOSK_M_CLS';
    G_PAIR('TB_HQ_KIOSK_CLS')            := 'TB_MS_KIOSK_CLS';
    G_PAIR('TB_HQ_PROMO_H')              := 'TB_MS_PROMO_H';
    G_PAIR('TB_HQ_PROMO_CONDI')          := 'TB_MS_PROMO_CONDI';
    G_PAIR('TB_HQ_NEOE_PROMO')           := 'TB_MS_NEOE_PROMO';
    G_PAIR('TB_HQ_NEOE_PROMO_BENE_PROD') := 'TB_MS_NEOE_PROMO_BENE_PROD';
    G_PAIR('TB_HQ_POS_ADVER_FILE')       := 'TB_MS_POS_ADVER_FILE';

    /* POS 번호 매핑이 필요한 표 */
    G_POSTAB('TB_MS_POS_ENVST')     := 'Y';
    G_POSTAB('TB_MS_POS_FNKEY')     := 'Y';
    G_POSTAB('TB_MS_POS_TERMNL')    := 'Y';
    G_POSTAB('TB_WB_POS_CONFG_XML') := 'Y';
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
