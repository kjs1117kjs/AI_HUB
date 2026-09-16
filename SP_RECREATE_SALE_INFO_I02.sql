CREATE OR REPLACE PROCEDURE SBPORA.SP_RECREATE_SALE_INFO_I02
(
    PI_SQL_INDEX      IN  VARCHAR2                  /* CREATE_RETURN(반품) / CREATE_SALE(재매출) */
   ,PI_SQL_PARAM      IN  VARCHAR2                  /* 행: 매장⊥원영업일⊥원POS⊥원영수⊥신영업일[⊥신POS][⊥사유코드]  행끝: ⊥♪ */
   ,PO_RESULT_CODE    OUT VARCHAR2                  /* '0000' 정상 / '9998·9999/...' 오류      */
   ,PO_RESULT_MSG     OUT VARCHAR2                  /* 건별 채번 결과 요약                      */
   ,PI_USER_ID        IN  VARCHAR2 DEFAULT NULL     /* REG_ID/MOD_ID. NULL 이면 USER            */
   ,PI_POS_SEND       IN  VARCHAR2 DEFAULT 'N'      /* 'Y' 면 TB_PS_CR_SVR_DATA(포스전송) 생성  */
   ,PI_BILLDT_FG      IN  VARCHAR2 DEFAULT 'NOW'    /* NOW=반품시각(POS표준) / ORG=원거래 시각  */
   ,PI_FORCE_RESALE   IN  VARCHAR2 DEFAULT 'N'      /* 'Y' 면 재매출 중복차단(-20005) 우회       */
)
IS
  /* ***********************************************************************************************
  1. Function Id      :   SP_RECREATE_SALE_INFO_I02
  2. Coder            :   임근주 / 반품쿼리 생성기 v5 로직 이식 (자동 생성)
  3. Coding Date      :   2026-09-16
  4. Remark           :
     원본 영수증 기준 반품(부호반전) 또는 재매출(동일 복사) 전표 생성.
     "반품쿼리 생성기 v5"(HTML) 의 검증된 스크립트를 그대로 이식한 것으로,
     구버전 SP_RECREATE_SALE_INFO_I01 을 대체한다.

     [I01 대비 주요 변경] ─ 상세는 함께 제공된 변경점 문서 참조
       · 테이블 커버리지 25 → 40 (HDR_DLVR/HDR_MEMBR/HDR_RTN_PAY/HDR_VMEM/DTL_DISCOUNT/
         SALE_PAY/SALE_PAY_DTL/CASH_RCP/PAY_PARTNER/PAY_POINT/PAY_REFUND/GIFT_DTL/GIFT_RTN/
         FSTMP_DTL/CASH_FNCHG 추가)
       · 회원후불(POSTPAID) 직접 INSERT → PKG_SL_SALE.SP_SL_SALE_PAY_POSTPAID_I01 호출
         (회원 후불원장·잔액 동시 갱신 — 직접 INSERT 시 잔액 틀어짐)
       · 중복 반품 2중 차단(back-fill + 최근 2주 역조회) / 재매출 재실행 차단(-20005)
       · 원거래 행 FOR UPDATE 잠금(동시 반품 직렬화) + 채번충돌 DUP_VAL_ON_INDEX(-20004) 안내
       · 모든 복사/갱신 WHERE 에 HQ_OFFICE_CD·HQ_BRAND_CD 한정
       · MERGE 4종(DTL_DISCOUNT/SALE_PAY/SALE_PAY_DTL/CASH_RCP), PAY_DTL 키에 PAY_SEQ 포함
       · 오류 시 즉시 중단(fail-fast) + RAISE — 행별 오류를 삼키고 계속 진행하던 버그 제거
       · REG_ID 하드코딩 제거(PI_USER_ID), 디버그성 DBMS_OUTPUT 정리, V_STEP 오류위치 추적
       · 전량반품 전용 — 부분반품(일부 상품/수량) 미지원

     [주의]
       · COMMIT 없음. 호출측이 사후 검증(생성기 [5] 탭 / SP_SALE_BILL_DATA_CHECK_S01) 후
         COMMIT 또는 ROLLBACK 한다. 오류 발생 시 예외가 전파되므로 호출측 ROLLBACK 필수.
       · 채번(MAX+1) 특성상 해당 POS 영업 중 실행 시 -20004 충돌 가능 → 영업 마감 후 실행 권장.
       · 반품·재매출을 묶어 내용 수정할 때는 두 호출 모두 같은 PI_BILLDT_FG 를 쓸 것.
  *********************************************************************************************** */

    /* ── 파라미터 파싱 ── */
    PS_ROW             VARCHAR2(4000)  := '';
    PS_ROW_CHR         VARCHAR2(   6)  := '⊥♪';
    PS_COL_CHR         VARCHAR2(   3)  := '⊥';
    PS_I               BINARY_INTEGER  := 0 ;
    V_ROW_CNT          BINARY_INTEGER  := 0 ;

    /* ── 오류 추적 ── */
    V_STEP             VARCHAR2( 100);              /* 현재 수행 단계(테이블/작업)      */
    V_ROW_INFO         VARCHAR2( 200);              /* 현재 처리 중 행의 원거래 키      */

    /* ── 공통 ── */
    P_USER_ID          VARCHAR2(  20)  := NVL(PI_USER_ID, USER);
    P_NOW              VARCHAR2(  14)  := TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS');

    /* ── 입력(행 단위) ── */
    P_STORE_CD         TB_SL_SALE_HDR.STORE_CD      %TYPE;
    P_ORG_SALE_DATE    TB_SL_SALE_HDR.SALE_DATE     %TYPE;
    P_ORG_POS_NO       TB_SL_SALE_HDR.POS_NO        %TYPE;
    P_BILL_NO          TB_SL_SALE_HDR.BILL_NO       %TYPE;
    P_RTN_SALE_DATE    TB_SL_SALE_HDR.SALE_DATE     %TYPE;   /* 반품 전표 영업일          */
    P_RTN_POS_NO       TB_SL_SALE_HDR.POS_NO        %TYPE;   /* 반품 전표 POS             */
    P_NEW_SALE_DATE    TB_SL_SALE_HDR.SALE_DATE     %TYPE;   /* 재매출 전표 영업일        */
    P_NEW_POS_NO       TB_SL_SALE_HDR.POS_NO        %TYPE;   /* 재매출 전표 POS           */
    P_POS_IN           VARCHAR2(   2);                       /* 6번째 컬럼(신규POS, 선택) */
    P_RTN_REASON_CD    TB_SL_SALE_HDR.RTN_REASON_CD %TYPE;

    /* ── 파생 ── */
    P_HQ_OFFICE_CD     TB_SL_SALE_HDR.HQ_OFFICE_CD  %TYPE;
    P_HQ_BRAND_CD      TB_SL_SALE_HDR.HQ_BRAND_CD   %TYPE;
    P_RTN_BILL_NO      TB_SL_SALE_HDR.BILL_NO       %TYPE;
    P_NEW_BILL_NO      TB_SL_SALE_HDR.BILL_NO       %TYPE;
    P_ORG_KEY          VARCHAR2(  30);
    P_RESVE_YN         TB_SL_SALE_HDR.RESVE_YN      %TYPE;
    P_RTN_REASON_NM    TB_SL_SALE_HDR.RTN_REASON_NM %TYPE;
    P_ORG_BILL_DT      TB_SL_SALE_HDR.BILL_DT       %TYPE;
    P_ORG_LINK         TB_SL_SALE_HDR.ORG_BILL_NO   %TYPE;   /* 원거래 back-fill 여부     */
    P_BILL_DT          TB_SL_SALE_HDR.BILL_DT       %TYPE;
    P_RESULT_CD        VARCHAR2(  10);
    N_CHK              NUMBER;
    P_ORG_ORDER_NO     TB_SL_SALE_HDR.ORDER_NO      %TYPE;   /* 재매출 중복차단용         */
    P_ORG_REAL_AMT     TB_SL_SALE_HDR.REAL_SALE_AMT %TYPE;

--------------------------------------------------------------------------------------------------------
-- PR_CREATE_RETURN : 반품 전표 생성 (SALE_YN='N', SALE_FG·금액·수량·단가 부호반전)
--   생성기 v5 [3] 반품 등록 스크립트 이식. 오류는 그대로 전파(fail-fast).
--------------------------------------------------------------------------------------------------------
    PROCEDURE PR_CREATE_RETURN
    IS
    BEGIN
    /* -- 0) 원거래 검증 : 존재 + 정상매출 -- */
    V_STEP := '원거래 검증(FOR UPDATE)';
    SELECT HQ_OFFICE_CD, HQ_BRAND_CD, RESVE_YN, RTN_REASON_NM, BILL_DT, ORG_BILL_NO
      INTO P_HQ_OFFICE_CD, P_HQ_BRAND_CD, P_RESVE_YN, P_RTN_REASON_NM, P_ORG_BILL_DT, P_ORG_LINK
      FROM TB_SL_SALE_HDR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND BILL_NO   = P_BILL_NO
       AND SALE_YN   = 'Y'
       FOR UPDATE;   /* [v5-3] 원거래 행 잠금.
                        같은 전표를 동시에 반품하는 다른 세션은 여기서 대기하고,
                        먼저 실행된 세션이 COMMIT 하면 아래 0-1) back-fill 검사에 걸려
                        중복 반품이 차단된다. (락은 COMMIT/ROLLBACK 시 해제) */

    P_ORG_KEY := P_STORE_CD || P_ORG_SALE_DATE || P_ORG_POS_NO || P_BILL_NO;

    /* -- BILL_DT 결정 --
       POS 표준 = 반품시각(현재시각). 실측 5525/5535.
       [반품 + 재매출] 을 묶어 내용을 고치는 작업이면 양쪽 모두 원거래 시각으로 두어야
       시간대 집계가 어긋나지 않는다. (한쪽만 바꾸면 안 됨) */
    /* BILL_DT 결정 : PI_BILLDT_FG = 'ORG' 이면 원거래 시각 유지(반품+재매출 묶음 수정용),
       그 외('NOW')는 POS 표준인 현재시각. ※ 반품·재매출은 반드시 같은 모드로 호출할 것 */
    IF UPPER(NVL(PI_BILLDT_FG,'NOW')) = 'ORG' THEN
        P_BILL_DT := P_ORG_BILL_DT;
    ELSE
        P_BILL_DT := P_NOW;
    END IF;

    /* -- 0-1) 중복 반품 차단 (1차, 비용 0) --
       정상 반품이면 원거래 ORG_BILL_NO 에 반품 전표키가 back-fill 되어 있다 (5535/5535). */
    IF P_ORG_LINK IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20001,'이미 반품 처리된 전표입니다(back-fill 존재): '||P_ORG_KEY||' -> '||P_ORG_LINK);
    END IF;

    /* -- 0-2) 중복 반품 차단 (2차, ORG_BILL_NO 역조회) --
       반품은 원거래와 다른 영업일에 등록될 수 있으므로 SALE_DATE '=' 조건은 걸지 않는다.
       (20260821 반품 1,935건 중 64건이 다른 날 매출의 반품)
       대신 최근 2주 범위로 제한한다 (v4) — STORE_CD 단독 조건은 매장 전체 스캔이라 너무 느림. */
    SELECT COUNT(*) INTO N_CHK
      FROM TB_SL_SALE_HDR
     WHERE STORE_CD    = P_STORE_CD
       AND SALE_DATE  >= TO_CHAR(TRUNC(SYSDATE) - 14, 'YYYYMMDD')
       AND SALE_YN     = 'N'
       AND ORG_BILL_NO = P_ORG_KEY
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD;
    IF N_CHK > 0 THEN
        RAISE_APPLICATION_ERROR(-20001,'이미 반품 처리된 전표입니다: '||P_ORG_KEY);
    END IF;

    /* -- 1) 반품 영수증번호 채번 -- */
    V_STEP := 'BILL_NO 채번(MAX+1)';
    SELECT LPAD(NVL(MAX(TO_NUMBER(BILL_NO)),0)+1, 4, '0')
      INTO P_RTN_BILL_NO
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_RTN_SALE_DATE
       AND POS_NO    = P_RTN_POS_NO;

    DBMS_OUTPUT.PUT_LINE('반품 전표번호 : '||P_STORE_CD||' / '||P_RTN_SALE_DATE||' / '||P_RTN_POS_NO||' / '||P_RTN_BILL_NO
                         ||'   BILL_DT='||P_BILL_DT);
    PO_RESULT_MSG := PO_RESULT_MSG
                  || '반품   : '||P_STORE_CD||'-'||P_RTN_SALE_DATE||'-'||P_RTN_POS_NO||'-'||P_RTN_BILL_NO
                  || '  <- 원거래 '||P_ORG_KEY || CHR(10);

    /* ------------------------------------------------------------------------
       2) TB_SL_SALE_HDR   [매출] 헤더
          8/21 실측 : 반품 1935행 / 원거래 1935행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR';
    INSERT INTO TB_SL_SALE_HDR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, BILL_DT, TOT_SALE_AMT, TOT_DC_AMT,
        TOT_TIP_AMT, TOT_ETC_AMT, REAL_SALE_AMT, TAX_SALE_AMT,
        VAT_AMT, NO_TAX_SALE_AMT, NET_SALE_AMT, EXPECT_PAY_AMT,
        RECV_PAY_AMT, RTN_PAY_AMT, DUTCH_PAY_CNT, TOT_GUEST_CNT,
        TBL_CD, EMP_NO, ORDER_NO, PAGER_NO,
        DLVR_YN, MEMBR_YN, RESVE_YN, REFUND_YN,
        ORG_BILL_NO, RTN_REASON_CD, RTN_REASON_NM, PAY_CHG_YN,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        PICKUP_YN, SALE_CHG_FG, DLVR_ORDER_FG, ERP_BILL_NO,
        DLVR_IN_FG, ORDER_START_DT, ORDER_END_DT, DLVR_IN_SVC_NM,
        TOT_OFFADD_AMT, BILL_SEQ_NO, KITCHEN_MEMO, ORDER_DT,
        CUP_AMT, DLVR_AMT, AI_TRAN_NO, CANCELED_AMT,
        DISPOSABLE_YN, MULTI_LANG_FG, POINT_AMT, TABLE_ID,
        STAY_RCV_CH, PRE_REVIEW_YN, DLVR_VAT_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        P_BILL_DT                  /* BILL_DT */,
        -1 * TOT_SALE_AMT          /* TOT_SALE_AMT */,
        -1 * TOT_DC_AMT            /* TOT_DC_AMT */,
        -1 * TOT_TIP_AMT           /* TOT_TIP_AMT */,
        -1 * TOT_ETC_AMT           /* TOT_ETC_AMT */,
        -1 * REAL_SALE_AMT         /* REAL_SALE_AMT */,
        -1 * TAX_SALE_AMT          /* TAX_SALE_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * NO_TAX_SALE_AMT       /* NO_TAX_SALE_AMT */,
        -1 * NET_SALE_AMT          /* NET_SALE_AMT */,
        -1 * EXPECT_PAY_AMT        /* EXPECT_PAY_AMT */,
        -1 * RECV_PAY_AMT          /* RECV_PAY_AMT */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        -1 * DUTCH_PAY_CNT         /* DUTCH_PAY_CNT */,
        -1 * TOT_GUEST_CNT         /* TOT_GUEST_CNT */,
        TBL_CD,
        EMP_NO,
        ORDER_NO,
        PAGER_NO,
        DLVR_YN,
        MEMBR_YN,
        RESVE_YN,
        REFUND_YN,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        RTN_REASON_CD,
        RTN_REASON_NM,
        PAY_CHG_YN,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        PICKUP_YN,
        SALE_CHG_FG,
        DLVR_ORDER_FG,
        ERP_BILL_NO,
        DLVR_IN_FG,
        ORDER_START_DT,
        ORDER_END_DT,
        DLVR_IN_SVC_NM,
        -1 * TOT_OFFADD_AMT        /* TOT_OFFADD_AMT */,
        BILL_SEQ_NO,
        KITCHEN_MEMO,
        ORDER_DT,
        -1 * CUP_AMT               /* CUP_AMT */,
        -1 * DLVR_AMT              /* DLVR_AMT */,
        AI_TRAN_NO,
        -1 * CANCELED_AMT          /* CANCELED_AMT */,
        DISPOSABLE_YN,
        MULTI_LANG_FG,
        -1 * POINT_AMT             /* POINT_AMT */,
        TABLE_ID,
        STAY_RCV_CH,
        PRE_REVIEW_YN,
        -1 * DLVR_VAT_AMT          /* DLVR_VAT_AMT */
      FROM TB_SL_SALE_HDR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       3) TB_SL_SALE_HDR_PAY   [매출] 헤더_결제
          8/21 실측 : 반품 1955행 / 원거래 1955행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_PAY';
    INSERT INTO TB_SL_SALE_HDR_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_CD, REG_SEQ,
        SALE_YN, SALE_FG, PAY_AMT, BILL_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        PAY_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * PAY_AMT               /* PAY_AMT */,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        -1 * CUP_AMT               /* CUP_AMT */
      FROM TB_SL_SALE_HDR_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       4) TB_SL_SALE_HDR_GUEST   [매출] 헤더_손님
          8/21 실측 : 반품 1928행 / 원거래 1928행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_GUEST';
    INSERT INTO TB_SL_SALE_HDR_GUEST (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, TBL_CD, GUEST_CNT_1, GUEST_CNT_2,
        GUEST_CNT_3, GUEST_CNT_4, GUEST_CLASS_FG_1, GUEST_CLASS_FG_2,
        BILL_DT, ORDER_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, EMP_NO, DLVR_ORDER_FG,
        GUEST_CNT_5, GUEST_CNT_6, DLVR_IN_FG, DLVR_IN_SVC_NM
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        TBL_CD,
        -1 * GUEST_CNT_1           /* GUEST_CNT_1 */,
        -1 * GUEST_CNT_2           /* GUEST_CNT_2 */,
        -1 * GUEST_CNT_3           /* GUEST_CNT_3 */,
        -1 * GUEST_CNT_4           /* GUEST_CNT_4 */,
        GUEST_CLASS_FG_1,
        GUEST_CLASS_FG_2,
        P_BILL_DT                  /* BILL_DT */,
        ORDER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        EMP_NO,
        DLVR_ORDER_FG,
        -1 * GUEST_CNT_5           /* GUEST_CNT_5 */,
        -1 * GUEST_CNT_6           /* GUEST_CNT_6 */,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM
      FROM TB_SL_SALE_HDR_GUEST
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       5) TB_SL_SALE_HDR_DC   [매출] 헤더_할인
          8/21 실측 : 반품 124행 / 원거래 124행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_DC';
    INSERT INTO TB_SL_SALE_HDR_DC (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, DC_CD, REG_SEQ,
        SALE_YN, SALE_FG, DC_AMT, BILL_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD,
        APP_DC_DESC
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        DC_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * DC_AMT                /* DC_AMT */,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        DC_REASON_CD,
        APP_DC_DESC
      FROM TB_SL_SALE_HDR_DC
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       6) TB_SL_SALE_HDR_DLVR   [매출] 헤더_배달
          8/21 실측 : 반품 485행 / 원거래 485행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_DLVR';
    INSERT INTO TB_SL_SALE_HDR_DLVR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, DLVR_NO, DLVR_ADDR_SEQ, DLVR_ADDR,
        DLVR_ADDR_DTL, DLVR_TEL_NO, DLVR_EMP_NO, DLVR_START_DT,
        DLVR_PAY_EMP_NO, DLVR_PAY_DT, DLVR_BOWL_RTN_EMP_NO, DLVR_BOWL_RTN_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_BOWL_EMP_NO, DLVR_BOWL_DT, DLVR_CALL_DT, DLVR_IN_FG,
        MEMBR_NO, DLVR_LZONE_CD, DLVR_MZONE_CD, BK_DLVR_ADDR,
        BK_DLVR_ADDR_DTL, BK_DLVR_TEL_NO, CHANNEL_ORDER_NO, DLVR_IN_SVC_NM,
        PAY_TIME_NM, AGENCY_MEMO, PAY_FG, VORDER_NO,
        VORDER_YN, RIDER_STATUS, RIDER_NM, COOK_TIME,
        EXPECT_TIME, ADD_COOK_TIME, INCLUDE_ALCOHOL, AGENT_YN
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        DLVR_NO,
        DLVR_ADDR_SEQ,
        DLVR_ADDR,
        DLVR_ADDR_DTL,
        DLVR_TEL_NO,
        DLVR_EMP_NO,
        DLVR_START_DT,
        DLVR_PAY_EMP_NO,
        DLVR_PAY_DT,
        DLVR_BOWL_RTN_EMP_NO,
        DLVR_BOWL_RTN_DT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_BOWL_EMP_NO,
        DLVR_BOWL_DT,
        DLVR_CALL_DT,
        DLVR_IN_FG,
        MEMBR_NO,
        DLVR_LZONE_CD,
        DLVR_MZONE_CD,
        BK_DLVR_ADDR,
        BK_DLVR_ADDR_DTL,
        BK_DLVR_TEL_NO,
        CHANNEL_ORDER_NO,
        DLVR_IN_SVC_NM,
        PAY_TIME_NM,
        AGENCY_MEMO,
        PAY_FG,
        VORDER_NO,
        VORDER_YN,
        RIDER_STATUS,
        RIDER_NM,
        COOK_TIME,
        EXPECT_TIME,
        ADD_COOK_TIME,
        INCLUDE_ALCOHOL,
        AGENT_YN
      FROM TB_SL_SALE_HDR_DLVR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       7) TB_SL_SALE_HDR_MEMBR   [매출] 헤더_회원
          8/21 실측 : 반품 41행 / 원거래 41행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_MEMBR';
    INSERT INTO TB_SL_SALE_HDR_MEMBR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, MEMBR_NO, MEMBR_NM, MEMBR_CARD_NO,
        SALE_SAVE_POINT, ANVSR_SAVE_POINT, FIRST_SALE_SAVE_POINT, REMAIN_POINT,
        PREPAID_BAL_AMT, POSTPAID_BAL_AMT, REG_DT, REG_ID,
        MOD_DT, MOD_ID, POSTPAID_FG, POST_ACC_YN,
        BK_MEMBR_NM, MEMBR_CLASS_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        MEMBR_NO,
        MEMBR_NM,
        MEMBR_CARD_NO,
        -1 * SALE_SAVE_POINT       /* SALE_SAVE_POINT */,
        -1 * ANVSR_SAVE_POINT      /* ANVSR_SAVE_POINT */,
        -1 * FIRST_SALE_SAVE_POINT /* FIRST_SALE_SAVE_POINT */,
        REMAIN_POINT,
        PREPAID_BAL_AMT,
        POSTPAID_BAL_AMT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        POSTPAID_FG,
        POST_ACC_YN,
        BK_MEMBR_NM,
        MEMBR_CLASS_CD
      FROM TB_SL_SALE_HDR_MEMBR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       8) TB_SL_SALE_HDR_RESVE   [매출] 헤더_예약
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_RESVE';
    INSERT INTO TB_SL_SALE_HDR_RESVE (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, RESVE_NO, RESVE_DATE, RESVE_TIME,
        RESVE_GUEST_NM, RESVE_GUEST_TEL_NO, RESVE_GUEST_CNT, REG_DT,
        REG_ID, MOD_DT, MOD_ID, RESVE_MEMO,
        RESVE_BIRTHDAY, SMS_FG, RESVE_IN_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        RESVE_NO,
        RESVE_DATE,
        RESVE_TIME,
        RESVE_GUEST_NM,
        RESVE_GUEST_TEL_NO,
        -1 * RESVE_GUEST_CNT       /* RESVE_GUEST_CNT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        RESVE_MEMO,
        RESVE_BIRTHDAY,
        SMS_FG,
        RESVE_IN_FG
      FROM TB_SL_SALE_HDR_RESVE
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       9) TB_SL_SALE_HDR_RTN_PAY   [매출] 헤더_거스름돈
          8/21 실측 : 반품 253행 / 원거래 253행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_RTN_PAY';
    INSERT INTO TB_SL_SALE_HDR_RTN_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, RTN_PAY_CD, REG_SEQ,
        SALE_YN, SALE_FG, RTN_PAY_AMT, CRNCY_CD,
        BILL_DT, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        RTN_PAY_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        CRNCY_CD,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_HDR_RTN_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       10) TB_SL_SALE_HDR_VMEM   [매출] 헤더_VMEM
          8/21 실측 : 반품 105행 / 원거래 84행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_VMEM';
    INSERT INTO TB_SL_SALE_HDR_VMEM (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        MEMBR_ORDER_NO, MEDIA_TYPE, MEDIA_NO, MEMBR_NO,
        MEMBR_NM, MEMBR_CARD_NO, SAVE_POINT, REMAIN_POINT,
        SAVE_COUNT, SAVE_STAMP, SAVE_FG, REG_DT,
        REG_ID, MOD_DT, MOD_ID, STAMP_GEN_COUNT,
        STAMP_ACC_COUNT, STAMP_FINISH_COUNT, STAMP_COUPN_ISSUE_YN, MEMBR_PHONE_NO,
        BK_MEMBR_NM, BK_MEMBR_PHONE_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        MEMBR_ORDER_NO,
        MEDIA_TYPE,
        MEDIA_NO,
        MEMBR_NO,
        MEMBR_NM,
        MEMBR_CARD_NO,
        -1 * SAVE_POINT            /* SAVE_POINT */,
        REMAIN_POINT,
        -1 * SAVE_COUNT            /* SAVE_COUNT */,
        SAVE_STAMP,
        SAVE_FG,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * STAMP_GEN_COUNT       /* STAMP_GEN_COUNT */,
        -1 * STAMP_ACC_COUNT       /* STAMP_ACC_COUNT */,
        -1 * STAMP_FINISH_COUNT    /* STAMP_FINISH_COUNT */,
        STAMP_COUPN_ISSUE_YN,
        MEMBR_PHONE_NO,
        BK_MEMBR_NM,
        BK_MEMBR_PHONE_NO
      FROM TB_SL_SALE_HDR_VMEM
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       11) TB_SL_SALE_DTL   [매출] 상세
          8/21 실측 : 반품 6951행 / 원거래 6951행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL';
    INSERT INTO TB_SL_SALE_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, REG_SEQ,
        SALE_YN, SALE_FG, DLVR_PACK_FG, CORNR_CD,
        PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN,
        SALE_UPRC, SALE_QTY, SALE_AMT, DC_AMT,
        TIP_AMT, ETC_AMT, REAL_SALE_AMT, VAT_AMT,
        MEMBR_SAVE_POINT, MEMBR_USE_POINT, REFUND_YN, SDATTR_CD,
        SDSEL_CLASS_CD, SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD,
        DOUBLE_AMT, DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO,
        ZONE_EMP_NO, CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG,
        PARTIAL_RTN_YN, REG_DT, REG_ID, MOD_DT,
        MOD_ID, COOK_MEMO, BILL_DT, MEMBR_NO,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG,
        REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT,
        OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD,
        SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO, PROD_ORDER_ID,
        CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT, ERP_SEND_PROD_CD,
        ERP_SEND_AMT, ERP_SEND_YN, VAT_INCLD_YN, QR_VORDER_NO,
        QR_PAY_TYPE
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        PROD_TYPE_FG,
        VAT_FG,
        PROD_TIP_YN,
        -1 * SALE_UPRC             /* SALE_UPRC */,
        -1 * SALE_QTY              /* SALE_QTY */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * DC_AMT                /* DC_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * ETC_AMT               /* ETC_AMT */,
        -1 * REAL_SALE_AMT         /* REAL_SALE_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * MEMBR_SAVE_POINT      /* MEMBR_SAVE_POINT */,
        -1 * MEMBR_USE_POINT       /* MEMBR_USE_POINT */,
        REFUND_YN,
        SDATTR_CD,
        SDSEL_CLASS_CD,
        SIDE_P_PROD_CD,
        SIDE_P_DTL_NO,
        DOUBLE_CD,
        -1 * DOUBLE_AMT            /* DOUBLE_AMT */,
        DUTCH_PAY_FG,
        -1 * SALE_SCALE_WT         /* SALE_SCALE_WT */,
        ORDER_EMP_NO,
        ZONE_EMP_NO,
        CHG_TICKET_NO,
        PROMTN_NO,
        PROMTN_PROD_FG,
        PARTIAL_RTN_YN,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        COOK_MEMO,
        P_BILL_DT                  /* BILL_DT */,
        MEMBR_NO,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        ORDER_ADD_FG,
        REMARK,
        ORG_BARCD_CD,
        -1 * WT_UPRC               /* WT_UPRC */,
        -1 * CUP_AMT               /* CUP_AMT */,
        OPTION_GRP_CD,
        OPTION_VAL_CD,
        SDSEL_TYPE_FG,
        SINGLE_CLASS_CD,
        SINGLE_PROD_CD,
        SINGLE_DTL_NO,
        DEPOSIT_DTL_NO,
        PROD_ORDER_ID,
        CANCEL_REASON_CD,
        CANCEL_REASON_NM,
        -1 * POINT_AMT             /* POINT_AMT */,
        ERP_SEND_PROD_CD,
        -1 * ERP_SEND_AMT          /* ERP_SEND_AMT */,
        ERP_SEND_YN,
        VAT_INCLD_YN,
        QR_VORDER_NO,
        QR_PAY_TYPE
      FROM TB_SL_SALE_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       12) TB_SL_SALE_DTL_PAY   [매출] 상세_결제
          8/21 실측 : 반품 7034행 / 원거래 7034행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL_PAY';
    INSERT INTO TB_SL_SALE_DTL_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, PAY_CD,
        REG_SEQ, SALE_YN, SALE_FG, PAY_AMT,
        DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT,
        REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG,
        DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT, SIDE_P_PROD_CD,
        SIDE_P_DTL_NO, SDSEL_CLASS_CD, BILL_DT, SINGLE_PROD_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        PAY_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * PAY_AMT               /* PAY_AMT */,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        -1 * CUP_AMT               /* CUP_AMT */,
        SIDE_P_PROD_CD,
        SIDE_P_DTL_NO,
        SDSEL_CLASS_CD,
        P_BILL_DT                  /* BILL_DT */,
        SINGLE_PROD_CD
      FROM TB_SL_SALE_DTL_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       13) TB_SL_SALE_DTL_DC   [매출] 상세_할인
          8/21 실측 : 반품 227행 / 원거래 227행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL_DC';
    INSERT INTO TB_SL_SALE_DTL_DC (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, DC_CD,
        REG_SEQ, SALE_YN, SALE_FG, DC_AMT,
        DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD,
        PROD_CD, REG_DT, REG_ID, MOD_DT,
        MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM,
        APP_DC_DESC
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        DC_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * DC_AMT                /* DC_AMT */,
        DC_REASON_CD,
        DC_REASON_NM,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        APP_DC_DESC
      FROM TB_SL_SALE_DTL_DC
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       14) TB_SL_SALE_DTL_DISCOUNT   [매출] 할인수단/프로모션 상세 정보
          8/21 실측 : 반품 29행 / 원거래 29행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, DC_SEQ
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_DTL_DISCOUNT';
    MERGE INTO TB_SL_SALE_DTL_DISCOUNT T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_RTN_SALE_DATE            AS SALE_DATE,
               P_RTN_POS_NO               AS POS_NO,
               P_RTN_BILL_NO              AS BILL_NO,
               BILL_DTL_NO,
               DC_SEQ,
               DC_CD,
               REG_SEQ,
               'N'                        AS SALE_YN,
               -1 * SALE_FG               AS SALE_FG,
               -1 * DC_AMT                AS DC_AMT,
               DC_REASON_CD,
               DC_REASON_NM,
               ADD_DATA1,
               ADD_DATA2,
               ADD_DATA3,
               CORNR_CD,
               PROD_CD,
               DLVR_PACK_FG,
               DLVR_ORDER_FG,
               DLVR_IN_FG,
               DLVR_IN_SVC_NM,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               ADD_DATA4,
               ADD_DATA5,
               -1 * SALE_QTY              AS SALE_QTY,
               MC_ORDER_NO,
               ORG_MC_ORDER_NO,
               APPR_NO,
               APPR_DT
             FROM TB_SL_SALE_DTL_DISCOUNT
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.BILL_DTL_NO = S.BILL_DTL_NO AND T.DC_SEQ = S.DC_SEQ)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.DC_CD                    = S.DC_CD,
        T.REG_SEQ                  = S.REG_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.SALE_FG                  = S.SALE_FG,
        T.DC_AMT                   = S.DC_AMT,
        T.DC_REASON_CD             = S.DC_REASON_CD,
        T.DC_REASON_NM             = S.DC_REASON_NM,
        T.ADD_DATA1                = S.ADD_DATA1,
        T.ADD_DATA2                = S.ADD_DATA2,
        T.ADD_DATA3                = S.ADD_DATA3,
        T.CORNR_CD                 = S.CORNR_CD,
        T.PROD_CD                  = S.PROD_CD,
        T.DLVR_PACK_FG             = S.DLVR_PACK_FG,
        T.DLVR_ORDER_FG            = S.DLVR_ORDER_FG,
        T.DLVR_IN_FG               = S.DLVR_IN_FG,
        T.DLVR_IN_SVC_NM           = S.DLVR_IN_SVC_NM,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.ADD_DATA4                = S.ADD_DATA4,
        T.ADD_DATA5                = S.ADD_DATA5,
        T.SALE_QTY                 = S.SALE_QTY,
        T.MC_ORDER_NO              = S.MC_ORDER_NO,
        T.ORG_MC_ORDER_NO          = S.ORG_MC_ORDER_NO,
        T.APPR_NO                  = S.APPR_NO,
        T.APPR_DT                  = S.APPR_DT
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, DC_SEQ,
        DC_CD, REG_SEQ, SALE_YN, SALE_FG,
        DC_AMT, DC_REASON_CD, DC_REASON_NM, ADD_DATA1,
        ADD_DATA2, ADD_DATA3, CORNR_CD, PROD_CD,
        DLVR_PACK_FG, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        ADD_DATA4, ADD_DATA5, SALE_QTY, MC_ORDER_NO,
        ORG_MC_ORDER_NO, APPR_NO, APPR_DT
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.BILL_DTL_NO, S.DC_SEQ,
        S.DC_CD, S.REG_SEQ, S.SALE_YN, S.SALE_FG,
        S.DC_AMT, S.DC_REASON_CD, S.DC_REASON_NM, S.ADD_DATA1,
        S.ADD_DATA2, S.ADD_DATA3, S.CORNR_CD, S.PROD_CD,
        S.DLVR_PACK_FG, S.DLVR_ORDER_FG, S.DLVR_IN_FG, S.DLVR_IN_SVC_NM,
        S.REG_DT, S.REG_ID, S.MOD_DT, S.MOD_ID,
        S.ADD_DATA4, S.ADD_DATA5, S.SALE_QTY, S.MC_ORDER_NO,
        S.ORG_MC_ORDER_NO, S.APPR_NO, S.APPR_DT
    );

    /* ------------------------------------------------------------------------
       15) TB_SL_SALE_PAY   [매출] 결제_정보_헤더(통합)
          8/21 실측 : 반품 1022행 / 원거래 1022행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_CD
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_PAY';
    MERGE INTO TB_SL_SALE_PAY T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_RTN_SALE_DATE            AS SALE_DATE,
               P_RTN_POS_NO               AS POS_NO,
               P_RTN_BILL_NO              AS BILL_NO,
               PAY_CD,
               -1 * PAY_AMT               AS PAY_AMT,
               -1 * TAX_AMT               AS TAX_AMT,
               -1 * VAT_AMT               AS VAT_AMT,
               -1 * TIP_AMT               AS TIP_AMT,
               -1 * NO_TAX_AMT            AS NO_TAX_AMT,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               REG_SEQ,
               'N'                        AS SALE_YN,
               -1 * RECV_AMT              AS RECV_AMT,
               -1 * RTN_AMT               AS RTN_AMT,
               -1 * CUP_AMT               AS CUP_AMT
             FROM TB_SL_SALE_PAY
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_CD = S.PAY_CD)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.REG_SEQ                  = S.REG_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.RECV_AMT                 = S.RECV_AMT,
        T.RTN_AMT                  = S.RTN_AMT,
        T.CUP_AMT                  = S.CUP_AMT
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_CD, PAY_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        REG_SEQ, SALE_YN, RECV_AMT, RTN_AMT,
        CUP_AMT
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_CD, S.PAY_AMT,
        S.TAX_AMT, S.VAT_AMT, S.TIP_AMT, S.NO_TAX_AMT,
        S.REG_DT, S.REG_ID, S.MOD_DT, S.MOD_ID,
        S.REG_SEQ, S.SALE_YN, S.RECV_AMT, S.RTN_AMT,
        S.CUP_AMT
    );

    /* ------------------------------------------------------------------------
       16) TB_SL_SALE_PAY_DTL   [매출] 결제_정보_상세(통합)
          8/21 실측 : 반품 1007행 / 원거래 1007행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ

          [v5-1 수정] MERGE ON 절에 PAY_SEQ 추가.
            기존에는 전표키 4개만으로 매칭했기 때문에 한 전표에 결제 행이 2건 이상
            (분할결제·결제수단 변경)이면 소스 여러 행이 타깃 1행에 매칭되어
            ORA-30926(안정적이지 않은 행 집합) 이 나거나 마지막 행만 남는 문제가 있었다.
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_PAY_DTL';
    MERGE INTO TB_SL_SALE_PAY_DTL T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_RTN_SALE_DATE            AS SALE_DATE,
               P_RTN_POS_NO               AS POS_NO,
               P_RTN_BILL_NO              AS BILL_NO,
               PAY_SEQ,
               'N'                        AS SALE_YN,
               PAY_CD,
               CHANGE_YN,
               NO_SALE_YN,
               CANCEL_PAY_SEQ,
               ORG_PAY_SEQ,
               -1 * PAY_AMT               AS PAY_AMT,
               -1 * TAX_AMT               AS TAX_AMT,
               -1 * VAT_AMT               AS VAT_AMT,
               -1 * TIP_AMT               AS TIP_AMT,
               -1 * NO_TAX_AMT            AS NO_TAX_AMT,
               -1 * DC_AMT                AS DC_AMT,
               APPR_CD,
               APPR_TERMNL_NO,
               APPR_PROC_FG,
               APPR_TYPE_FG,
               CARD_TYPE_FG,
               CARD_NO,
               INST_CNT,
               APPR_UNIQUE_NO,
               APPR_DT,
               APPR_NO,
               DDC_FG,
               ISSUE_CD,
               ISSUE_NM,
               ACQUIRE_CD,
               ACQUIRE_NM,
               CMN_CARD_CORP_CD,
               MEMBR_JOIN_NO,
               APPR_MSG,
               CORNR_CD,
               CORNR_FG,
               APPR_LOG_NO,
               P_ORG_KEY                  AS ORG_BILL_NO,
               -1 * COUPN_AMT             AS COUPN_AMT,
               -1 * POINT_AMT             AS POINT_AMT,
               -1 * FSTMP_AMT             AS FSTMP_AMT,
               -1 * BEFORE_AMT            AS BEFORE_AMT,
               -1 * AFTER_AMT             AS AFTER_AMT,
               COUPN_CD,
               COUPN_NM,
               POINT_NM,
               OFFICE_CD,
               OFFICE_NM,
               DEPT_NM,
               CARD_DATA,
               ADD_DATA1,
               ADD_DATA2,
               ADD_DATA3,
               ADD_DATA4,
               ADD_DATA5,
               ADD_DATA6,
               ADD_DATA7,
               ADD_DATA8,
               ADD_DATA9,
               ADD_DATA10,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               REG_SEQ,
               QR_VORDER_NO,
               QR_PAY_TYPE
             FROM TB_SL_SALE_PAY_DTL
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_SEQ = S.PAY_SEQ)   /* [v5-1] PAY_SEQ 추가 */
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_SEQ                  = S.PAY_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.PAY_CD                   = S.PAY_CD,
        T.CHANGE_YN                = S.CHANGE_YN,
        T.NO_SALE_YN               = S.NO_SALE_YN,
        T.CANCEL_PAY_SEQ           = S.CANCEL_PAY_SEQ,
        T.ORG_PAY_SEQ              = S.ORG_PAY_SEQ,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.DC_AMT                   = S.DC_AMT,
        T.APPR_CD                  = S.APPR_CD,
        T.APPR_TERMNL_NO           = S.APPR_TERMNL_NO,
        T.APPR_PROC_FG             = S.APPR_PROC_FG,
        T.APPR_TYPE_FG             = S.APPR_TYPE_FG,
        T.CARD_TYPE_FG             = S.CARD_TYPE_FG,
        T.CARD_NO                  = S.CARD_NO,
        T.INST_CNT                 = S.INST_CNT,
        T.APPR_UNIQUE_NO           = S.APPR_UNIQUE_NO,
        T.APPR_DT                  = S.APPR_DT,
        T.APPR_NO                  = S.APPR_NO,
        T.DDC_FG                   = S.DDC_FG,
        T.ISSUE_CD                 = S.ISSUE_CD,
        T.ISSUE_NM                 = S.ISSUE_NM,
        T.ACQUIRE_CD               = S.ACQUIRE_CD,
        T.ACQUIRE_NM               = S.ACQUIRE_NM,
        T.CMN_CARD_CORP_CD         = S.CMN_CARD_CORP_CD,
        T.MEMBR_JOIN_NO            = S.MEMBR_JOIN_NO,
        T.APPR_MSG                 = S.APPR_MSG,
        T.CORNR_CD                 = S.CORNR_CD,
        T.CORNR_FG                 = S.CORNR_FG,
        T.APPR_LOG_NO              = S.APPR_LOG_NO,
        T.ORG_BILL_NO              = S.ORG_BILL_NO,
        T.COUPN_AMT                = S.COUPN_AMT,
        T.POINT_AMT                = S.POINT_AMT,
        T.FSTMP_AMT                = S.FSTMP_AMT,
        T.BEFORE_AMT               = S.BEFORE_AMT,
        T.AFTER_AMT                = S.AFTER_AMT,
        T.COUPN_CD                 = S.COUPN_CD,
        T.COUPN_NM                 = S.COUPN_NM,
        T.POINT_NM                 = S.POINT_NM,
        T.OFFICE_CD                = S.OFFICE_CD,
        T.OFFICE_NM                = S.OFFICE_NM,
        T.DEPT_NM                  = S.DEPT_NM,
        T.CARD_DATA                = S.CARD_DATA,
        T.ADD_DATA1                = S.ADD_DATA1,
        T.ADD_DATA2                = S.ADD_DATA2,
        T.ADD_DATA3                = S.ADD_DATA3,
        T.ADD_DATA4                = S.ADD_DATA4,
        T.ADD_DATA5                = S.ADD_DATA5,
        T.ADD_DATA6                = S.ADD_DATA6,
        T.ADD_DATA7                = S.ADD_DATA7,
        T.ADD_DATA8                = S.ADD_DATA8,
        T.ADD_DATA9                = S.ADD_DATA9,
        T.ADD_DATA10               = S.ADD_DATA10,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.REG_SEQ                  = S.REG_SEQ,
        T.QR_VORDER_NO             = S.QR_VORDER_NO,
        T.QR_PAY_TYPE              = S.QR_PAY_TYPE
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, SALE_YN,
        PAY_CD, CHANGE_YN, NO_SALE_YN, CANCEL_PAY_SEQ,
        ORG_PAY_SEQ, PAY_AMT, TAX_AMT, VAT_AMT,
        TIP_AMT, NO_TAX_AMT, DC_AMT, APPR_CD,
        APPR_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG, CARD_TYPE_FG,
        CARD_NO, INST_CNT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, DDC_FG, ISSUE_CD, ISSUE_NM,
        ACQUIRE_CD, ACQUIRE_NM, CMN_CARD_CORP_CD, MEMBR_JOIN_NO,
        APPR_MSG, CORNR_CD, CORNR_FG, APPR_LOG_NO,
        ORG_BILL_NO, COUPN_AMT, POINT_AMT, FSTMP_AMT,
        BEFORE_AMT, AFTER_AMT, COUPN_CD, COUPN_NM,
        POINT_NM, OFFICE_CD, OFFICE_NM, DEPT_NM,
        CARD_DATA, ADD_DATA1, ADD_DATA2, ADD_DATA3,
        ADD_DATA4, ADD_DATA5, ADD_DATA6, ADD_DATA7,
        ADD_DATA8, ADD_DATA9, ADD_DATA10, REG_DT,
        REG_ID, MOD_DT, MOD_ID, REG_SEQ,
        QR_VORDER_NO, QR_PAY_TYPE
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_SEQ, S.SALE_YN,
        S.PAY_CD, S.CHANGE_YN, S.NO_SALE_YN, S.CANCEL_PAY_SEQ,
        S.ORG_PAY_SEQ, S.PAY_AMT, S.TAX_AMT, S.VAT_AMT,
        S.TIP_AMT, S.NO_TAX_AMT, S.DC_AMT, S.APPR_CD,
        S.APPR_TERMNL_NO, S.APPR_PROC_FG, S.APPR_TYPE_FG, S.CARD_TYPE_FG,
        S.CARD_NO, S.INST_CNT, S.APPR_UNIQUE_NO, S.APPR_DT,
        S.APPR_NO, S.DDC_FG, S.ISSUE_CD, S.ISSUE_NM,
        S.ACQUIRE_CD, S.ACQUIRE_NM, S.CMN_CARD_CORP_CD, S.MEMBR_JOIN_NO,
        S.APPR_MSG, S.CORNR_CD, S.CORNR_FG, S.APPR_LOG_NO,
        S.ORG_BILL_NO, S.COUPN_AMT, S.POINT_AMT, S.FSTMP_AMT,
        S.BEFORE_AMT, S.AFTER_AMT, S.COUPN_CD, S.COUPN_NM,
        S.POINT_NM, S.OFFICE_CD, S.OFFICE_NM, S.DEPT_NM,
        S.CARD_DATA, S.ADD_DATA1, S.ADD_DATA2, S.ADD_DATA3,
        S.ADD_DATA4, S.ADD_DATA5, S.ADD_DATA6, S.ADD_DATA7,
        S.ADD_DATA8, S.ADD_DATA9, S.ADD_DATA10, S.REG_DT,
        S.REG_ID, S.MOD_DT, S.MOD_ID, S.REG_SEQ,
        S.QR_VORDER_NO, S.QR_PAY_TYPE
    );

    /* ------------------------------------------------------------------------
       17) TB_SL_SALE_PAY_SEQ   [매출] 결제_순서
          8/21 실측 : 반품 2077행 / 원거래 2077행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_SEQ';
    INSERT INTO TB_SL_SALE_PAY_SEQ (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, REG_SEQ,
        SALE_YN, SALE_FG, PAY_CD, PAY_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, CUP_AMT, BILL_DT,
        DLVR_ORDER_FG, DLVR_IN_FG, PAYMENT_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        PAY_SEQ,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        PAY_CD,
        -1 * PAY_AMT               /* PAY_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        LINE_NO,
        APPR_PROC_FG,
        APPR_CARD_NO,
        APPR_SEQ_NO,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * CUP_AMT               /* CUP_AMT */,
        P_BILL_DT                  /* BILL_DT */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        PAYMENT_ID
      FROM TB_SL_SALE_PAY_SEQ
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       18) TB_SL_SALE_PAY_CARD   [매출] 결제_신용카드
          8/21 실측 : 반품 1125행 / 원거래 1126행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CARD';
    INSERT INTO TB_SL_SALE_PAY_CARD (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG,
        CARD_NO, INST_CNT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, APPR_AMT, DC_AMT, DDC_FG,
        ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM,
        CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD,
        APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, CUP_AMT, MPAY_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        CARD_TYPE_FG,
        CARD_NO,
        INST_CNT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * APPR_AMT              /* APPR_AMT */,
        -1 * DC_AMT                /* DC_AMT */,
        DDC_FG,
        ISSUE_CD,
        ISSUE_NM,
        ACQUIRE_CD,
        ACQUIRE_NM,
        CMN_CARD_CORP_CD,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * CUP_AMT               /* CUP_AMT */,
        MPAY_CD
      FROM TB_SL_SALE_PAY_CARD
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       19) TB_SL_SALE_PAY_CASH   [매출] 결제_현금영수증
          8/21 실측 : 반품 533행 / 원거래 533행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CASH';
    INSERT INTO TB_SL_SALE_PAY_CASH (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        RECV_AMT, RTN_AMT, VAN_CD, VAN_TERMNL_NO,
        APPR_PROC_FG, APPR_TYPE_FG, CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO,
        APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, CUP_AMT,
        DLVR_ORDER_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        -1 * RECV_AMT              /* RECV_AMT */,
        -1 * RTN_AMT               /* RTN_AMT */,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        APPR_TYPE_FG,
        CASH_BILL_CARD_TYPE_FG,
        CASH_BILL_CARD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * CUP_AMT               /* CUP_AMT */,
        DLVR_ORDER_FG
      FROM TB_SL_SALE_PAY_CASH
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       20) TB_SL_SALE_CASH_RCP   [매출] 현금 영수증
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_CASH_RCP';
    MERGE INTO TB_SL_SALE_CASH_RCP T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_RTN_SALE_DATE            AS SALE_DATE,
               P_RTN_POS_NO               AS POS_NO,
               P_RTN_BILL_NO              AS BILL_NO,
               PAY_SEQ,
               PAY_CD,
               'N'                        AS SALE_YN,
               CHANGE_YN,
               NO_SALE_YN,
               CANCEL_PAY_SEQ,
               ORG_PAY_SEQ,
               REG_SEQ,
               -1 * PAY_AMT               AS PAY_AMT,
               -1 * TAX_AMT               AS TAX_AMT,
               -1 * VAT_AMT               AS VAT_AMT,
               -1 * TIP_AMT               AS TIP_AMT,
               -1 * NO_TAX_AMT            AS NO_TAX_AMT,
               -1 * DC_AMT                AS DC_AMT,
               APPR_CD,
               APPR_TERMNL_NO,
               APPR_PROC_FG,
               APPR_TYPE_FG,
               CARD_TYPE_FG,
               CARD_NO,
               INST_CNT,
               APPR_UNIQUE_NO,
               APPR_DT,
               APPR_NO,
               DDC_FG,
               ISSUE_CD,
               ISSUE_NM,
               ACQUIRE_CD,
               ACQUIRE_NM,
               CMN_CARD_CORP_CD,
               MEMBR_JOIN_NO,
               APPR_MSG,
               -1 * CUP_AMT               AS CUP_AMT,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID
             FROM TB_SL_SALE_CASH_RCP
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_SEQ = S.PAY_SEQ)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_CD                   = S.PAY_CD,
        T.SALE_YN                  = S.SALE_YN,
        T.CHANGE_YN                = S.CHANGE_YN,
        T.NO_SALE_YN               = S.NO_SALE_YN,
        T.CANCEL_PAY_SEQ           = S.CANCEL_PAY_SEQ,
        T.ORG_PAY_SEQ              = S.ORG_PAY_SEQ,
        T.REG_SEQ                  = S.REG_SEQ,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.DC_AMT                   = S.DC_AMT,
        T.APPR_CD                  = S.APPR_CD,
        T.APPR_TERMNL_NO           = S.APPR_TERMNL_NO,
        T.APPR_PROC_FG             = S.APPR_PROC_FG,
        T.APPR_TYPE_FG             = S.APPR_TYPE_FG,
        T.CARD_TYPE_FG             = S.CARD_TYPE_FG,
        T.CARD_NO                  = S.CARD_NO,
        T.INST_CNT                 = S.INST_CNT,
        T.APPR_UNIQUE_NO           = S.APPR_UNIQUE_NO,
        T.APPR_DT                  = S.APPR_DT,
        T.APPR_NO                  = S.APPR_NO,
        T.DDC_FG                   = S.DDC_FG,
        T.ISSUE_CD                 = S.ISSUE_CD,
        T.ISSUE_NM                 = S.ISSUE_NM,
        T.ACQUIRE_CD               = S.ACQUIRE_CD,
        T.ACQUIRE_NM               = S.ACQUIRE_NM,
        T.CMN_CARD_CORP_CD         = S.CMN_CARD_CORP_CD,
        T.MEMBR_JOIN_NO            = S.MEMBR_JOIN_NO,
        T.APPR_MSG                 = S.APPR_MSG,
        T.CUP_AMT                  = S.CUP_AMT,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, PAY_CD,
        SALE_YN, CHANGE_YN, NO_SALE_YN, CANCEL_PAY_SEQ,
        ORG_PAY_SEQ, REG_SEQ, PAY_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, DC_AMT,
        APPR_CD, APPR_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG,
        CARD_TYPE_FG, CARD_NO, INST_CNT, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, DDC_FG, ISSUE_CD,
        ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM, CMN_CARD_CORP_CD,
        MEMBR_JOIN_NO, APPR_MSG, CUP_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_SEQ, S.PAY_CD,
        S.SALE_YN, S.CHANGE_YN, S.NO_SALE_YN, S.CANCEL_PAY_SEQ,
        S.ORG_PAY_SEQ, S.REG_SEQ, S.PAY_AMT, S.TAX_AMT,
        S.VAT_AMT, S.TIP_AMT, S.NO_TAX_AMT, S.DC_AMT,
        S.APPR_CD, S.APPR_TERMNL_NO, S.APPR_PROC_FG, S.APPR_TYPE_FG,
        S.CARD_TYPE_FG, S.CARD_NO, S.INST_CNT, S.APPR_UNIQUE_NO,
        S.APPR_DT, S.APPR_NO, S.DDC_FG, S.ISSUE_CD,
        S.ISSUE_NM, S.ACQUIRE_CD, S.ACQUIRE_NM, S.CMN_CARD_CORP_CD,
        S.MEMBR_JOIN_NO, S.APPR_MSG, S.CUP_AMT, S.REG_DT,
        S.REG_ID, S.MOD_DT, S.MOD_ID
    );

    /* ------------------------------------------------------------------------
       21) TB_SL_SALE_PAY_CASH_FNCHG   [매출] 결제_현금외환
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CASH_FNCHG';
    INSERT INTO TB_SL_SALE_PAY_CASH_FNCHG (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, CRNCY_SEQ,
        REG_SEQ, SALE_YN, SALE_FG, CRNCY_CD,
        CRNCY_AMT, CRNCY_RATE, KRW_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        CRNCY_SEQ,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        CRNCY_CD,
        -1 * CRNCY_AMT             /* CRNCY_AMT */,
        CRNCY_RATE,
        -1 * KRW_AMT               /* KRW_AMT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_CASH_FNCHG
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       22) TB_SL_SALE_PAY_COUPN   [매출] 결제 쿠폰
          8/21 실측 : 반품 65행 / 원거래 65행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_COUPN';
    INSERT INTO TB_SL_SALE_PAY_COUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, DC_AMT,
        COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG,
        COUPN_DC_RATE, COUPN_DC_AMT, COUPN_APPLY_FG, COUPN_SER_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO,
        APPR_AMT, APPR_DT, APPR_NO, APPR_MSG,
        PARTN_CD, DC_CD, OK_ACC_POINT, CARD_TYPE_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * DC_AMT                /* DC_AMT */,
        COUPN_REG_FG,
        PAY_CLASS_CD,
        COUPN_CD,
        COUPN_TYPE_FG,
        COUPN_DC_RATE,
        -1 * COUPN_DC_AMT          /* COUPN_DC_AMT */,
        COUPN_APPLY_FG,
        COUPN_SER_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        COUPN_APPR_NO,
        APPR_PROC_FG,
        APPR_BARCD_NO,
        -1 * APPR_AMT              /* APPR_AMT */,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        PARTN_CD,
        DC_CD,
        -1 * OK_ACC_POINT          /* OK_ACC_POINT */,
        CARD_TYPE_FG
      FROM TB_SL_SALE_PAY_COUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       23) TB_SL_SALE_PAY_MCOUPN   [매출] 결제_모바일쿠폰
          8/21 실측 : 반품 46행 / 원거래 46행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_MCOUPN';
    INSERT INTO TB_SL_SALE_PAY_MCOUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO,
        MCOUPN_UPRC, MCOUPN_REMAIN_AMT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, APPR_PROC_FG, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MCOUPN_CD,
        MCOUPN_TERMNL_NO,
        MCOUPN_TYPE_FG,
        MCOUPN_BARCD_NO,
        -1 * MCOUPN_UPRC           /* MCOUPN_UPRC */,
        MCOUPN_REMAIN_AMT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        APPR_PROC_FG,
        -1 * CUP_AMT               /* CUP_AMT */
      FROM TB_SL_SALE_PAY_MCOUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       24) TB_SL_SALE_PAY_MPAY   [매출] 결제_모바일페이
          8/21 실측 : 반품 23행 / 원거래 23행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_MPAY';
    INSERT INTO TB_SL_SALE_PAY_MPAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MPAY_CD,
        MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO,
        APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT,
        COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM,
        ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM,
        APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        APPR_TYPE_FG, INST_CNT, CUP_AMT, BILL_DT,
        DLVR_ORDER_FG, DLVR_IN_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MPAY_CD,
        MPAY_TERMNL_NO,
        APPR_PROC_FG,
        MPAY_BARCD_TYPE_FG,
        MPAY_BARCD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * APPR_AMT              /* APPR_AMT */,
        -1 * COUPN_AMT             /* COUPN_AMT */,
        COUPN_NM,
        -1 * POINT_AMT             /* POINT_AMT */,
        POINT_NM,
        ISSUE_CD,
        ISSUE_NM,
        ACQUIRE_CD,
        ACQUIRE_NM,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        APPR_TYPE_FG,
        INST_CNT,
        -1 * CUP_AMT               /* CUP_AMT */,
        P_BILL_DT                  /* BILL_DT */,
        DLVR_ORDER_FG,
        DLVR_IN_FG
      FROM TB_SL_SALE_PAY_MPAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       25) TB_SL_SALE_PAY_PAYCO   [매출] 결제_페이코
          8/21 실측 : 반품 18행 / 원거래 18행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PAYCO';
    INSERT INTO TB_SL_SALE_PAY_PAYCO (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, PAYCO_TERMNL_NO,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, PAYCO_BARCD_TYPE_FG,
        PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, APPR_AMT, COUPN_AMT,
        COUPN_NM, POINT_AMT, POINT_NM, MEMBR_CARD_NO,
        DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, FSTMP_AMT,
        TMONEY_AFTER_AMT, TMONEY_BEFORE_AMT, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        PAYCO_TERMNL_NO,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        PAYCO_BARCD_TYPE_FG,
        PAYCO_BARCD_NO,
        INST_CNT,
        APPR_COMPANY_NM,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * APPR_AMT              /* APPR_AMT */,
        -1 * COUPN_AMT             /* COUPN_AMT */,
        COUPN_NM,
        -1 * POINT_AMT             /* POINT_AMT */,
        POINT_NM,
        MEMBR_CARD_NO,
        DDC_FG,
        ACQUIRE_NM,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * FSTMP_AMT             /* FSTMP_AMT */,
        -1 * TMONEY_AFTER_AMT      /* TMONEY_AFTER_AMT */,
        -1 * TMONEY_BEFORE_AMT     /* TMONEY_BEFORE_AMT */,
        -1 * CUP_AMT               /* CUP_AMT */
      FROM TB_SL_SALE_PAY_PAYCO
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       26) TB_SL_SALE_PAY_PARTNER   [매출] 결제_제휴카드
          8/21 실측 : 반품 2행 / 원거래 2행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PARTNER';
    INSERT INTO TB_SL_SALE_PAY_PARTNER (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG,
        PARTN_CD, PARTN_CARD_NO, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, DC_AMT, SAVE_POINT, USE_POINT,
        AVABL_POINT, ACC_POINT, MEMBR_JOIN_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        APPR_TYPE_FG,
        PARTN_CD,
        PARTN_CARD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * DC_AMT                /* DC_AMT */,
        -1 * SAVE_POINT            /* SAVE_POINT */,
        -1 * USE_POINT             /* USE_POINT */,
        -1 * AVABL_POINT           /* AVABL_POINT */,
        -1 * ACC_POINT             /* ACC_POINT */,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_PARTNER
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       27) TB_SL_SALE_PAY_POINT   [매출] 결제_회원포인트
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_POINT';
    INSERT INTO TB_SL_SALE_PAY_POINT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, CORNR_CD,
        SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT,
        NO_TAX_AMT, MEMBR_NO, APPR_DT, APPR_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        ORG_BILL_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        CORNR_CD,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MEMBR_NO,
        APPR_DT,
        APPR_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        P_ORG_KEY                  /* ORG_BILL_NO */
      FROM TB_SL_SALE_PAY_POINT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       28) TB_SL_SALE_PAY_POSTPAID   [매출] 결제_회원후불
          8/21 실측 : 반품 32행 / 원거래 32행

          ★★ 직접 INSERT 금지 ★★
          SP_SL_SALE_PAY_POSTPAID_I01 은 이 테이블 외에
            - TB_MB_MEMBER_POSTPAID      (회원 후불원장, POSTPAID_FG='4')
            - TB_MB_MEMBER_PAID_BALANCE  (회원 후불잔액 차감)
          까지 함께 갱신한다. 직접 INSERT 하면 회원 잔액이 틀어진다.
          => 원거래의 후불 결제행을 읽어 패키지 프로시저를 호출한다.
       ------------------------------------------------------------------------ */
    V_STEP := 'PKG 호출 TB_SL_SALE_PAY_POSTPAID';
    FOR C IN (SELECT * FROM TB_SL_SALE_PAY_POSTPAID
               WHERE STORE_CD  = P_STORE_CD
                 AND SALE_DATE = P_ORG_SALE_DATE
                 AND POS_NO    = P_ORG_POS_NO
                 AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
                 AND HQ_BRAND_CD  = P_HQ_BRAND_CD
                 AND BILL_NO   = P_BILL_NO)
    LOOP
        PKG_SL_SALE.SP_SL_SALE_PAY_POSTPAID_I01(
            PI_HQ_OFFICE_CD => C.HQ_OFFICE_CD,
            PI_HQ_BRAND_CD  => C.HQ_BRAND_CD,
            PI_STORE_CD     => C.STORE_CD,
            PI_SALE_DATE    => P_RTN_SALE_DATE,   /* 반품 영업일 */
            PI_POS_NO       => P_RTN_POS_NO,   /* 반품 POS */
            PI_BILL_NO      => P_RTN_BILL_NO,   /* 신규 반품 전표 */
            PI_LINE_NO      => C.LINE_NO,
            PI_LINE_SEQ_NO  => C.LINE_SEQ_NO,
            PI_REG_SEQ      => C.REG_SEQ,
            PI_SALE_YN      => 'N',             /* -> POSTPAID_FG '4' */
            PI_SALE_FG      => -1,
            PI_SALE_AMT     => -1 * C.SALE_AMT,
            PI_TAX_AMT      => -1 * C.TAX_AMT,
            PI_VAT_AMT      => -1 * C.VAT_AMT,
            PI_TIP_AMT      => -1 * C.TIP_AMT,
            PI_NO_TAX_AMT   => -1 * C.NO_TAX_AMT,
            PI_MEMBR_NO     => C.MEMBR_NO,
            PI_REMARK       => C.REMARK,
            PI_CORNR_CD     => C.CORNR_CD,
            PI_ORG_BILL_NO  => P_ORG_KEY,
            PI_USER_ID      => P_USER_ID,
            PO_RESULT_CD    => P_RESULT_CD);

        IF P_RESULT_CD <> '0000' THEN
            RAISE_APPLICATION_ERROR(-20003,'후불 반품 처리 실패: '||P_RESULT_CD);
        END IF;
    END LOOP;

    /* ------------------------------------------------------------------------
       29) TB_SL_SALE_PAY_PREPAID   [매출] 결제_회원선불
          8/21 실측 : 반품 3행 / 원거래 3행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PREPAID';
    INSERT INTO TB_SL_SALE_PAY_PREPAID (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT,
        REMARK, CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MEMBR_NO,
        APPR_DT,
        APPR_NO,
        PREPAID_BAL_AMT,
        REMARK,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_PREPAID
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       30) TB_SL_SALE_PAY_REFUND   [매출] 결제_환급
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_REFUND';
    INSERT INTO TB_SL_SALE_PAY_REFUND (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, REFUND_CD,
        REFUND_TERMNL_NO, REFUND_TYPE_FG, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, REFUND_PREARNGE_AMT, REFUND_FEE_AMT,
        APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        REFUND_CD,
        REFUND_TERMNL_NO,
        REFUND_TYPE_FG,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * REFUND_PREARNGE_AMT   /* REFUND_PREARNGE_AMT */,
        -1 * REFUND_FEE_AMT        /* REFUND_FEE_AMT */,
        APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_REFUND
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       31) TB_SL_SALE_PAY_GIFT   [매출] 결제_상품권
          8/21 실측 : 반품 5행 / 원거래 5행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT';
    INSERT INTO TB_SL_SALE_PAY_GIFT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        GIFT_UPRC, RTN_PAY_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        -1 * GIFT_UPRC             /* GIFT_UPRC */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_GIFT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       32) TB_SL_SALE_PAY_GIFT_DTL   [매출] 결제_상품권_상세
          8/21 실측 : 반품 6행 / 원거래 6행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT_DTL';
    INSERT INTO TB_SL_SALE_PAY_GIFT_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, REG_SEQ,
        SALE_YN, SALE_FG, GIFT_SEQ, GIFT_CD,
        GIFT_UPRC, GIFT_QTY, GIFT_PROC_FG, GIFT_SER_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        MC_ORDER_NO, ORG_MC_ORDER_NO, APPR_NO, APPR_DT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        GIFT_SEQ,
        GIFT_CD,
        -1 * GIFT_UPRC             /* GIFT_UPRC */,
        -1 * GIFT_QTY              /* GIFT_QTY */,
        GIFT_PROC_FG,
        GIFT_SER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        MC_ORDER_NO,
        ORG_MC_ORDER_NO,
        APPR_NO,
        APPR_DT
      FROM TB_SL_SALE_PAY_GIFT_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       33) TB_SL_SALE_PAY_GIFT_RTN   [매출] 결제_상품권거스름
          8/21 실측 : 반품 3행 / 원거래 3행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT_RTN';
    INSERT INTO TB_SL_SALE_PAY_GIFT_RTN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, RTN_PAY_CD,
        REG_SEQ, SALE_YN, RTN_PAY_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        RTN_PAY_CD,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_GIFT_RTN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       34) TB_SL_SALE_PAY_FSTMP   [매출] 결제_식권
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_FSTMP';
    INSERT INTO TB_SL_SALE_PAY_FSTMP (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        RTN_PAY_AMT, ETC_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID, FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO,
        APPR_NO, APPR_DT, APPR_UNIQUE_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        -1 * ETC_AMT               /* ETC_AMT */,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * FSTMP_UPRC            /* FSTMP_UPRC */,
        FSTMP_CD,
        FSTMP_SER_NO,
        APPR_NO,
        APPR_DT,
        APPR_UNIQUE_NO
      FROM TB_SL_SALE_PAY_FSTMP
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       35) TB_SL_SALE_PAY_FSTMP_DTL   [매출] 결제_식권_상세
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_FSTMP_DTL';
    INSERT INTO TB_SL_SALE_PAY_FSTMP_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, REG_SEQ,
        SALE_YN, SALE_FG, FSTMP_SEQ, FSTMP_CD,
        FSTMP_UPRC, FSTMP_QTY, RTN_PAY_AMT, ETC_AMT,
        FSTMP_SER_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        FSTMP_SEQ,
        FSTMP_CD,
        -1 * FSTMP_UPRC            /* FSTMP_UPRC */,
        -1 * FSTMP_QTY             /* FSTMP_QTY */,
        -1 * RTN_PAY_AMT           /* RTN_PAY_AMT */,
        -1 * ETC_AMT               /* ETC_AMT */,
        FSTMP_SER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_FSTMP_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       36) TB_SL_SALE_PAY_EMP_CARD   [매출] 결제_사원카드
          8/21 실측 : 반품 4행 / 원거래 4행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_EMP_CARD';
    INSERT INTO TB_SL_SALE_PAY_EMP_CARD (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        REMAIN_AMT, ACCOUNT_FG, OFFICE_CD, OFFICE_NM,
        OFFICE_DEPT_NM, OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM,
        CARD_DATA, APPR_DT, APPR_NO, CORNR_CD,
        ORG_BILL_NO, APPR_PROC_FG, APPR_LOG_NO, APPR_MSG,
        REG_DT, REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_FG               /* SALE_FG */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        REMAIN_AMT,
        ACCOUNT_FG,
        OFFICE_CD,
        OFFICE_NM,
        OFFICE_DEPT_NM,
        OFFICE_EMP_NO,
        OFFICE_EMP_CARD_NO,
        OFFICE_EMP_NM,
        CARD_DATA,
        APPR_DT,
        APPR_NO,
        CORNR_CD,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        APPR_PROC_FG,
        APPR_LOG_NO,
        APPR_MSG,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_EMP_CARD
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       37) TB_SL_SALE_PAY_TEMPORARY   [매출] 결제가승인
          8/21 실측 : 반품 173행 / 원거래 173행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_TEMPORARY';
    INSERT INTO TB_SL_SALE_PAY_TEMPORARY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, TEMPORARY_PAY_CD,
        CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, TEMPORARY_PAY_FG, CUP_AMT,
        TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO,
        PROMOTION_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        TEMPORARY_PAY_CD,
        CORNR_CD,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        TEMPORARY_PAY_FG,
        -1 * CUP_AMT               /* CUP_AMT */,
        TEMPORARY_PAY_DTL_CD,
        DLVR_IN_FG,
        BARCD_NO,
        APPR_NO,
        PROMOTION_CD
      FROM TB_SL_SALE_PAY_TEMPORARY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       38) TB_SL_SALE_PAY_VORDER   [매출] 결제오더픽
          8/21 실측 : 반품 13행 / 원거래 13행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VORDER';
    INSERT INTO TB_SL_SALE_PAY_VORDER (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD,
        VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO,
        INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO,
        APPR_AMT, DC_AMT, ACQUIRE_CD, MEMBR_JOIN_NO,
        PICKUP_NO, PICKUP_FG, PICKUP_TIME, PICKUP_TEL_NO,
        PICKUP_NICK_NM, CORNR_CD, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, CUP_AMT,
        MEMBR_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        CARD_TYPE_FG,
        CARD_NO,
        INST_CNT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        -1 * APPR_AMT              /* APPR_AMT */,
        -1 * DC_AMT                /* DC_AMT */,
        ACQUIRE_CD,
        MEMBR_JOIN_NO,
        PICKUP_NO,
        PICKUP_FG,
        PICKUP_TIME,
        PICKUP_TEL_NO,
        PICKUP_NICK_NM,
        CORNR_CD,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        -1 * CUP_AMT               /* CUP_AMT */,
        MEMBR_NO
      FROM TB_SL_SALE_PAY_VORDER
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       39) TB_SL_SALE_PAY_VCHARGE   [매출] 결제_VMEM충전포인트사용
          8/21 실측 : 반품 13행 / 원거래 13행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VCHARGE';
    INSERT INTO TB_SL_SALE_PAY_VCHARGE (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO,
        VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT, CORNR_CD,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, TRANSACTION_ID, REQUEST_ID,
        ATTEMPT_NO, MERCHANT_ORDER_DT, BARCODE, ACCOUNT_ID,
        SECURITY_CODE, EXPIRE_DATE, BALANCE_AFTER
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MEMBR_ORDER_NO,
        VCHARGE_CARD_NO,
        VCHARGE_APPR_NO,
        VCHARGE_REMAIN_AMT,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        TRANSACTION_ID,
        REQUEST_ID,
        ATTEMPT_NO,
        MERCHANT_ORDER_DT,
        BARCODE,
        ACCOUNT_ID,
        SECURITY_CODE,
        EXPIRE_DATE,
        BALANCE_AFTER
      FROM TB_SL_SALE_PAY_VCHARGE
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       40) TB_SL_SALE_PAY_VCOUPN   [매출] 결제_VMEM쿠폰사용
          8/21 실측 : 반품 19행 / 원거래 19행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VCOUPN';
    INSERT INTO TB_SL_SALE_PAY_VCOUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, MEMBR_ORDER_NO, VCOUPN_NO,
        VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT,
        VCOUPN_SAVE_POINT, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, VCOUPN_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        MEMBR_ORDER_NO,
        VCOUPN_NO,
        VCOUPN_NM,
        VCOUPN_TYPE,
        VCOUPN_APPR_NO,
        -1 * VCOUPN_DC_AMT         /* VCOUPN_DC_AMT */,
        -1 * VCOUPN_SAVE_POINT     /* VCOUPN_SAVE_POINT */,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        VCOUPN_ID
      FROM TB_SL_SALE_PAY_VCOUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       41) TB_SL_SALE_PAY_VPOINT   [매출] 결제_VMEM적립포인트사용
          8/21 실측 : 반품 4행 / 원거래 4행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VPOINT';
    INSERT INTO TB_SL_SALE_PAY_VPOINT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO,
        VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_RTN_SALE_DATE            /* SALE_DATE */,
        P_RTN_POS_NO               /* POS_NO */,
        P_RTN_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        'N'                        /* SALE_YN */,
        -1 * SALE_AMT              /* SALE_AMT */,
        -1 * TAX_AMT               /* TAX_AMT */,
        -1 * VAT_AMT               /* VAT_AMT */,
        -1 * TIP_AMT               /* TIP_AMT */,
        -1 * NO_TAX_AMT            /* NO_TAX_AMT */,
        MEMBR_ORDER_NO,
        VPOINT_CARD_NO,
        VPOINT_APPR_NO,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        P_ORG_KEY                  /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_VPOINT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       42) 반품사유 세팅
       ------------------------------------------------------------------------ */
    V_STEP := 'UPDATE TB_SL_SALE_HDR';
    UPDATE TB_SL_SALE_HDR
       SET RTN_REASON_CD = P_RTN_REASON_CD
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_RTN_SALE_DATE
       AND POS_NO    = P_RTN_POS_NO
       AND BILL_NO   = P_RTN_BILL_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD;

    /* ------------------------------------------------------------------------
       43) 원거래 역방향 링크 back-fill
          PKG_SL_SALE.SP_SL_SALE_HDR_I01 과 동일 동작.
          [v2 수정] 패키지는 ORG_BILL_NO 만 세팅한다. MOD_DT/MOD_ID 는 건드리지 않음.
       ------------------------------------------------------------------------ */
    V_STEP := 'UPDATE TB_SL_SALE_HDR';
    UPDATE TB_SL_SALE_HDR
       SET ORG_BILL_NO = P_STORE_CD || P_RTN_SALE_DATE || P_RTN_POS_NO || P_RTN_BILL_NO
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       44) [v2 추가] 예약건이면 예약원장 링크
          PKG_SL_SALE.SP_SL_SALE_HDR_I01 의 픽업 예약 영수증번호 SET 로직.
          RTN_REASON_NM 은 반품사유명이 아니라 예약원장 연결키.
       ------------------------------------------------------------------------ */
    IF (P_RESVE_YN = 'Y' AND P_RTN_REASON_NM IS NOT NULL) THEN
        UPDATE TB_RV_SALE_HDR
           SET RTN_REASON_NM = P_STORE_CD || P_RTN_SALE_DATE || P_RTN_POS_NO || P_RTN_BILL_NO,
               MOD_DT        = P_NOW,
               MOD_ID        = 'PKG_SL_SALE'
         WHERE STORE_CD  = SUBSTR(P_RTN_REASON_NM, 1, LENGTH(P_STORE_CD))
           AND SALE_DATE = SUBSTR(P_RTN_REASON_NM, -14, 8)
           AND POS_NO    = SUBSTR(P_RTN_REASON_NM,  -6, 2)
           AND BILL_NO   = SUBSTR(P_RTN_REASON_NM,  -4, 4);
    END IF;

    /* ------------------------------------------------------------------------
       포스 전송 데이터 생성 (PI_POS_SEND = 'Y' 일 때만)   TB_PS_CR_SVR_DATA
          포스가 이 행(DATA_TYPE_FG='S', POS_PROC_YN='N')을 읽어 전표를 내려받는다.
          이미 행이 있으면 POS_PROC_YN='N' 으로 리셋하여 재전송 대상으로 만든다.
       ------------------------------------------------------------------------ */
    IF UPPER(NVL(PI_POS_SEND,'N')) = 'Y' THEN
        V_STEP := 'MERGE TB_PS_CR_SVR_DATA';
        MERGE INTO TB_PS_CR_SVR_DATA T
        USING DUAL
           ON (    T.STORE_CD  = P_STORE_CD
               AND T.SALE_DATE = P_RTN_SALE_DATE
               AND T.POS_NO    = P_RTN_POS_NO
               AND T.BILL_NO   = P_RTN_BILL_NO
               AND T.DATA_TYPE_FG = 'S')
        WHEN MATCHED THEN UPDATE
           SET T.POS_PROC_YN  = 'N'    /* 재전송 대상으로 리셋 */
              ,T.POS_PROC_DT  = ''
              ,T.POS_PROC_MSG = ''
        WHEN NOT MATCHED THEN INSERT
              (STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN, DATA_TYPE_FG
              ,POS_REQ_DT, POS_PROC_YN, POS_PROC_DT, POS_PROC_MSG
              ,ORG_STORE_CD, ORG_SALE_DATE, ORG_POS_NO, ORG_BILL_NO
              ,CR_COMMENT, REG_DT, REG_ID, MOD_DT, MOD_ID)
        VALUES(P_STORE_CD, P_RTN_SALE_DATE, P_RTN_POS_NO, P_RTN_BILL_NO
              ,'N'   /* SALE_YN : 반품 */
              ,'S', '', 'N', '', ''
              ,P_STORE_CD, P_ORG_SALE_DATE, P_ORG_POS_NO, P_BILL_NO
              ,'반품 생성(SP_RECREATE_SALE_INFO_I02)'
              ,P_NOW, P_USER_ID, P_NOW, P_USER_ID);
    END IF;

    /* COMMIT 없음 — 호출측에서 결과 확인(사후 검증) 후 COMMIT / ROLLBACK 할 것 */

    END PR_CREATE_RETURN;

--------------------------------------------------------------------------------------------------------
-- PR_CREATE_SALE : 재매출 전표 생성 (원거래를 부호반전 없이 그대로 복사, BILL_NO 만 신규 채번)
--   생성기 v5 [4] 재매출 등록 스크립트 이식. 오류는 그대로 전파(fail-fast).
--------------------------------------------------------------------------------------------------------
    PROCEDURE PR_CREATE_SALE
    IS
    BEGIN
    /* -- 0) 복사 원본 검증 : 존재 + 정상매출 -- */
    V_STEP := '원거래 검증(FOR UPDATE)';
    SELECT HQ_OFFICE_CD, HQ_BRAND_CD, BILL_DT, ORDER_NO, REAL_SALE_AMT   /* [v5-2] ORDER_NO·금액은 아래 중복 재매출 검사에 사용 */
      INTO P_HQ_OFFICE_CD, P_HQ_BRAND_CD, P_ORG_BILL_DT, P_ORG_ORDER_NO, P_ORG_REAL_AMT
      FROM TB_SL_SALE_HDR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND BILL_NO   = P_BILL_NO
       AND SALE_YN   = 'Y'
       FOR UPDATE;   /* [v5-3] 원거래 행 잠금 — 반품 스크립트와 동일한 동시성 보호 */

    /* -- BILL_DT 결정 --
       ★ [A] 반품 전표와 반드시 같은 기준으로 갈 것. 한쪽만 바꾸면 시간대 집계가 왜곡된다. */
    /* BILL_DT 결정 : PI_BILLDT_FG = 'ORG' 이면 원거래 시각 유지(반품+재매출 묶음 수정용),
       그 외('NOW')는 POS 표준인 현재시각. ※ 반품·재매출은 반드시 같은 모드로 호출할 것 */
    IF UPPER(NVL(PI_BILLDT_FG,'NOW')) = 'ORG' THEN
        P_BILL_DT := P_ORG_BILL_DT;
    ELSE
        P_BILL_DT := P_NOW;
    END IF;

    /* -- 0-1) [v5-2] 중복 재매출(스크립트 재실행) 차단 --
       재매출 전표는 POS 표준에 맞춰 ORG_BILL_NO 를 남기지 않으므로 원거래와의 직접 링크가 없다.
       → 같은 스크립트를 두 번 돌리면 매출이 두 번 잡혀도 알아챌 방법이 없었다 (v4 까지).
       대신 아래 휴리스틱으로 재실행을 감지한다 :
         "재매출 영업일·POS 에, 수기 실행 계정(REG_ID = P_USER_ID)으로 등록된
          동일 주문번호 + 동일 실판매금액의 정상매출" 이 이미 있으면 재실행으로 간주.
       POS 가 만든 전표는 REG_ID 가 다르므로 정상 영업 전표와는 충돌하지 않는다.
       ※ 의도적으로 같은 전표를 한 번 더 등록해야 하는 예외 상황이면
          이 0-1) 블록만 주석 처리하고 실행할 것. */
    IF UPPER(NVL(PI_FORCE_RESALE,'N')) <> 'Y' THEN
    SELECT COUNT(*)
      INTO N_CHK
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = P_HQ_OFFICE_CD
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND STORE_CD     = P_STORE_CD
       AND SALE_DATE    = P_NEW_SALE_DATE
       AND POS_NO       = P_NEW_POS_NO
       AND SALE_YN      = 'Y'
       AND REG_ID       = P_USER_ID
       AND NVL(ORDER_NO,'-')       = NVL(P_ORG_ORDER_NO,'-')
       AND NVL(REAL_SALE_AMT, 0)   = NVL(P_ORG_REAL_AMT, 0);

    IF N_CHK > 0 THEN
        RAISE_APPLICATION_ERROR(-20005,'[v5-2] 동일 조건의 재매출 전표가 이미 존재합니다 ('||N_CHK||'건). '
            ||'스크립트 재실행(중복 매출) 여부를 먼저 확인하십시오. '
            ||'의도된 재등록이면 PI_FORCE_RESALE => ''Y'' 로 호출.');
    END IF;
    END IF;   /* PI_FORCE_RESALE */

    /* -- 1) 재매출 영수증번호 채번 -- */
    V_STEP := 'BILL_NO 채번(MAX+1)';
    SELECT LPAD(NVL(MAX(TO_NUMBER(BILL_NO)),0)+1, 4, '0')
      INTO P_NEW_BILL_NO
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_NEW_SALE_DATE
       AND POS_NO    = P_NEW_POS_NO;

    DBMS_OUTPUT.PUT_LINE('재매출 전표번호 : '||P_STORE_CD||' / '||P_NEW_SALE_DATE||' / '||P_NEW_POS_NO||' / '||P_NEW_BILL_NO
                         ||'   BILL_DT='||P_BILL_DT);
    PO_RESULT_MSG := PO_RESULT_MSG
                  || '재매출 : '||P_STORE_CD||'-'||P_NEW_SALE_DATE||'-'||P_NEW_POS_NO||'-'||P_NEW_BILL_NO
                  || '  <- 원거래 복사 '||P_STORE_CD||P_ORG_SALE_DATE||P_ORG_POS_NO||P_BILL_NO || CHR(10);

    /* ------------------------------------------------------------------------
       2) TB_SL_SALE_HDR   [매출] 헤더
          8/21 실측 : 반품 1935행 / 원거래 1935행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR';
    INSERT INTO TB_SL_SALE_HDR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, BILL_DT, TOT_SALE_AMT, TOT_DC_AMT,
        TOT_TIP_AMT, TOT_ETC_AMT, REAL_SALE_AMT, TAX_SALE_AMT,
        VAT_AMT, NO_TAX_SALE_AMT, NET_SALE_AMT, EXPECT_PAY_AMT,
        RECV_PAY_AMT, RTN_PAY_AMT, DUTCH_PAY_CNT, TOT_GUEST_CNT,
        TBL_CD, EMP_NO, ORDER_NO, PAGER_NO,
        DLVR_YN, MEMBR_YN, RESVE_YN, REFUND_YN,
        ORG_BILL_NO, RTN_REASON_CD, RTN_REASON_NM, PAY_CHG_YN,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        PICKUP_YN, SALE_CHG_FG, DLVR_ORDER_FG, ERP_BILL_NO,
        DLVR_IN_FG, ORDER_START_DT, ORDER_END_DT, DLVR_IN_SVC_NM,
        TOT_OFFADD_AMT, BILL_SEQ_NO, KITCHEN_MEMO, ORDER_DT,
        CUP_AMT, DLVR_AMT, AI_TRAN_NO, CANCELED_AMT,
        DISPOSABLE_YN, MULTI_LANG_FG, POINT_AMT, TABLE_ID,
        STAY_RCV_CH, PRE_REVIEW_YN, DLVR_VAT_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        P_BILL_DT                  /* BILL_DT */,
        TOT_SALE_AMT,
        TOT_DC_AMT,
        TOT_TIP_AMT,
        TOT_ETC_AMT,
        REAL_SALE_AMT,
        TAX_SALE_AMT,
        VAT_AMT,
        NO_TAX_SALE_AMT,
        NET_SALE_AMT,
        EXPECT_PAY_AMT,
        RECV_PAY_AMT,
        RTN_PAY_AMT,
        DUTCH_PAY_CNT,
        TOT_GUEST_CNT,
        TBL_CD,
        EMP_NO,
        ORDER_NO,
        PAGER_NO,
        DLVR_YN,
        MEMBR_YN,
        RESVE_YN,
        REFUND_YN,
        NULL                       /* ORG_BILL_NO */,
        NULL                       /* RTN_REASON_CD */,
        NULL                       /* RTN_REASON_NM */,
        PAY_CHG_YN,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        PICKUP_YN,
        SALE_CHG_FG,
        DLVR_ORDER_FG,
        ERP_BILL_NO,
        DLVR_IN_FG,
        ORDER_START_DT,
        ORDER_END_DT,
        DLVR_IN_SVC_NM,
        TOT_OFFADD_AMT,
        BILL_SEQ_NO,
        KITCHEN_MEMO,
        ORDER_DT,
        CUP_AMT,
        DLVR_AMT,
        AI_TRAN_NO,
        CANCELED_AMT,
        DISPOSABLE_YN,
        MULTI_LANG_FG,
        POINT_AMT,
        TABLE_ID,
        STAY_RCV_CH,
        PRE_REVIEW_YN,
        DLVR_VAT_AMT
      FROM TB_SL_SALE_HDR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       3) TB_SL_SALE_HDR_PAY   [매출] 헤더_결제
          8/21 실측 : 반품 1955행 / 원거래 1955행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_PAY';
    INSERT INTO TB_SL_SALE_HDR_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_CD, REG_SEQ,
        SALE_YN, SALE_FG, PAY_AMT, BILL_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        PAY_CD,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        PAY_AMT,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        CUP_AMT
      FROM TB_SL_SALE_HDR_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       4) TB_SL_SALE_HDR_GUEST   [매출] 헤더_손님
          8/21 실측 : 반품 1928행 / 원거래 1928행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_GUEST';
    INSERT INTO TB_SL_SALE_HDR_GUEST (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, TBL_CD, GUEST_CNT_1, GUEST_CNT_2,
        GUEST_CNT_3, GUEST_CNT_4, GUEST_CLASS_FG_1, GUEST_CLASS_FG_2,
        BILL_DT, ORDER_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, EMP_NO, DLVR_ORDER_FG,
        GUEST_CNT_5, GUEST_CNT_6, DLVR_IN_FG, DLVR_IN_SVC_NM
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        TBL_CD,
        GUEST_CNT_1,
        GUEST_CNT_2,
        GUEST_CNT_3,
        GUEST_CNT_4,
        GUEST_CLASS_FG_1,
        GUEST_CLASS_FG_2,
        P_BILL_DT                  /* BILL_DT */,
        ORDER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        EMP_NO,
        DLVR_ORDER_FG,
        GUEST_CNT_5,
        GUEST_CNT_6,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM
      FROM TB_SL_SALE_HDR_GUEST
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       5) TB_SL_SALE_HDR_DC   [매출] 헤더_할인
          8/21 실측 : 반품 124행 / 원거래 124행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_DC';
    INSERT INTO TB_SL_SALE_HDR_DC (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, DC_CD, REG_SEQ,
        SALE_YN, SALE_FG, DC_AMT, BILL_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD,
        APP_DC_DESC
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        DC_CD,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        DC_AMT,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        DC_REASON_CD,
        APP_DC_DESC
      FROM TB_SL_SALE_HDR_DC
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       6) TB_SL_SALE_HDR_DLVR   [매출] 헤더_배달
          8/21 실측 : 반품 485행 / 원거래 485행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_DLVR';
    INSERT INTO TB_SL_SALE_HDR_DLVR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, DLVR_NO, DLVR_ADDR_SEQ, DLVR_ADDR,
        DLVR_ADDR_DTL, DLVR_TEL_NO, DLVR_EMP_NO, DLVR_START_DT,
        DLVR_PAY_EMP_NO, DLVR_PAY_DT, DLVR_BOWL_RTN_EMP_NO, DLVR_BOWL_RTN_DT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        DLVR_BOWL_EMP_NO, DLVR_BOWL_DT, DLVR_CALL_DT, DLVR_IN_FG,
        MEMBR_NO, DLVR_LZONE_CD, DLVR_MZONE_CD, BK_DLVR_ADDR,
        BK_DLVR_ADDR_DTL, BK_DLVR_TEL_NO, CHANNEL_ORDER_NO, DLVR_IN_SVC_NM,
        PAY_TIME_NM, AGENCY_MEMO, PAY_FG, VORDER_NO,
        VORDER_YN, RIDER_STATUS, RIDER_NM, COOK_TIME,
        EXPECT_TIME, ADD_COOK_TIME, INCLUDE_ALCOHOL, AGENT_YN
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        DLVR_NO,
        DLVR_ADDR_SEQ,
        DLVR_ADDR,
        DLVR_ADDR_DTL,
        DLVR_TEL_NO,
        DLVR_EMP_NO,
        DLVR_START_DT,
        DLVR_PAY_EMP_NO,
        DLVR_PAY_DT,
        DLVR_BOWL_RTN_EMP_NO,
        DLVR_BOWL_RTN_DT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_BOWL_EMP_NO,
        DLVR_BOWL_DT,
        DLVR_CALL_DT,
        DLVR_IN_FG,
        MEMBR_NO,
        DLVR_LZONE_CD,
        DLVR_MZONE_CD,
        BK_DLVR_ADDR,
        BK_DLVR_ADDR_DTL,
        BK_DLVR_TEL_NO,
        CHANNEL_ORDER_NO,
        DLVR_IN_SVC_NM,
        PAY_TIME_NM,
        AGENCY_MEMO,
        PAY_FG,
        VORDER_NO,
        VORDER_YN,
        RIDER_STATUS,
        RIDER_NM,
        COOK_TIME,
        EXPECT_TIME,
        ADD_COOK_TIME,
        INCLUDE_ALCOHOL,
        AGENT_YN
      FROM TB_SL_SALE_HDR_DLVR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       7) TB_SL_SALE_HDR_MEMBR   [매출] 헤더_회원
          8/21 실측 : 반품 41행 / 원거래 41행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_MEMBR';
    INSERT INTO TB_SL_SALE_HDR_MEMBR (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, MEMBR_NO, MEMBR_NM, MEMBR_CARD_NO,
        SALE_SAVE_POINT, ANVSR_SAVE_POINT, FIRST_SALE_SAVE_POINT, REMAIN_POINT,
        PREPAID_BAL_AMT, POSTPAID_BAL_AMT, REG_DT, REG_ID,
        MOD_DT, MOD_ID, POSTPAID_FG, POST_ACC_YN,
        BK_MEMBR_NM, MEMBR_CLASS_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        MEMBR_NO,
        MEMBR_NM,
        MEMBR_CARD_NO,
        SALE_SAVE_POINT,
        ANVSR_SAVE_POINT,
        FIRST_SALE_SAVE_POINT,
        REMAIN_POINT,
        PREPAID_BAL_AMT,
        POSTPAID_BAL_AMT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        POSTPAID_FG,
        POST_ACC_YN,
        BK_MEMBR_NM,
        MEMBR_CLASS_CD
      FROM TB_SL_SALE_HDR_MEMBR
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       8) TB_SL_SALE_HDR_RESVE   [매출] 헤더_예약
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_RESVE';
    INSERT INTO TB_SL_SALE_HDR_RESVE (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        SALE_FG, RESVE_NO, RESVE_DATE, RESVE_TIME,
        RESVE_GUEST_NM, RESVE_GUEST_TEL_NO, RESVE_GUEST_CNT, REG_DT,
        REG_ID, MOD_DT, MOD_ID, RESVE_MEMO,
        RESVE_BIRTHDAY, SMS_FG, RESVE_IN_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        RESVE_NO,
        RESVE_DATE,
        RESVE_TIME,
        RESVE_GUEST_NM,
        RESVE_GUEST_TEL_NO,
        RESVE_GUEST_CNT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        RESVE_MEMO,
        RESVE_BIRTHDAY,
        SMS_FG,
        RESVE_IN_FG
      FROM TB_SL_SALE_HDR_RESVE
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       9) TB_SL_SALE_HDR_RTN_PAY   [매출] 헤더_거스름돈
          8/21 실측 : 반품 253행 / 원거래 253행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_RTN_PAY';
    INSERT INTO TB_SL_SALE_HDR_RTN_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, RTN_PAY_CD, REG_SEQ,
        SALE_YN, SALE_FG, RTN_PAY_AMT, CRNCY_CD,
        BILL_DT, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        RTN_PAY_CD,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        RTN_PAY_AMT,
        CRNCY_CD,
        P_BILL_DT                  /* BILL_DT */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_HDR_RTN_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       10) TB_SL_SALE_HDR_VMEM   [매출] 헤더_VMEM
          8/21 실측 : 반품 105행 / 원거래 84행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_HDR_VMEM';
    INSERT INTO TB_SL_SALE_HDR_VMEM (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, REG_SEQ, SALE_YN,
        MEMBR_ORDER_NO, MEDIA_TYPE, MEDIA_NO, MEMBR_NO,
        MEMBR_NM, MEMBR_CARD_NO, SAVE_POINT, REMAIN_POINT,
        SAVE_COUNT, SAVE_STAMP, SAVE_FG, REG_DT,
        REG_ID, MOD_DT, MOD_ID, STAMP_GEN_COUNT,
        STAMP_ACC_COUNT, STAMP_FINISH_COUNT, STAMP_COUPN_ISSUE_YN, MEMBR_PHONE_NO,
        BK_MEMBR_NM, BK_MEMBR_PHONE_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        REG_SEQ,
        SALE_YN,
        MEMBR_ORDER_NO,
        MEDIA_TYPE,
        MEDIA_NO,
        MEMBR_NO,
        MEMBR_NM,
        MEMBR_CARD_NO,
        SAVE_POINT,
        REMAIN_POINT,
        SAVE_COUNT,
        SAVE_STAMP,
        SAVE_FG,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        STAMP_GEN_COUNT,
        STAMP_ACC_COUNT,
        STAMP_FINISH_COUNT,
        STAMP_COUPN_ISSUE_YN,
        MEMBR_PHONE_NO,
        BK_MEMBR_NM,
        BK_MEMBR_PHONE_NO
      FROM TB_SL_SALE_HDR_VMEM
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       11) TB_SL_SALE_DTL   [매출] 상세
          8/21 실측 : 반품 6951행 / 원거래 6951행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL';
    INSERT INTO TB_SL_SALE_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, REG_SEQ,
        SALE_YN, SALE_FG, DLVR_PACK_FG, CORNR_CD,
        PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN,
        SALE_UPRC, SALE_QTY, SALE_AMT, DC_AMT,
        TIP_AMT, ETC_AMT, REAL_SALE_AMT, VAT_AMT,
        MEMBR_SAVE_POINT, MEMBR_USE_POINT, REFUND_YN, SDATTR_CD,
        SDSEL_CLASS_CD, SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD,
        DOUBLE_AMT, DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO,
        ZONE_EMP_NO, CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG,
        PARTIAL_RTN_YN, REG_DT, REG_ID, MOD_DT,
        MOD_ID, COOK_MEMO, BILL_DT, MEMBR_NO,
        DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG,
        REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT,
        OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD,
        SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO, PROD_ORDER_ID,
        CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT, ERP_SEND_PROD_CD,
        ERP_SEND_AMT, ERP_SEND_YN, VAT_INCLD_YN, QR_VORDER_NO,
        QR_PAY_TYPE
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        PROD_TYPE_FG,
        VAT_FG,
        PROD_TIP_YN,
        SALE_UPRC,
        SALE_QTY,
        SALE_AMT,
        DC_AMT,
        TIP_AMT,
        ETC_AMT,
        REAL_SALE_AMT,
        VAT_AMT,
        MEMBR_SAVE_POINT,
        MEMBR_USE_POINT,
        REFUND_YN,
        SDATTR_CD,
        SDSEL_CLASS_CD,
        SIDE_P_PROD_CD,
        SIDE_P_DTL_NO,
        DOUBLE_CD,
        DOUBLE_AMT,
        DUTCH_PAY_FG,
        SALE_SCALE_WT,
        ORDER_EMP_NO,
        ZONE_EMP_NO,
        CHG_TICKET_NO,
        PROMTN_NO,
        PROMTN_PROD_FG,
        PARTIAL_RTN_YN,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        COOK_MEMO,
        P_BILL_DT                  /* BILL_DT */,
        MEMBR_NO,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        ORDER_ADD_FG,
        REMARK,
        ORG_BARCD_CD,
        WT_UPRC,
        CUP_AMT,
        OPTION_GRP_CD,
        OPTION_VAL_CD,
        SDSEL_TYPE_FG,
        SINGLE_CLASS_CD,
        SINGLE_PROD_CD,
        SINGLE_DTL_NO,
        DEPOSIT_DTL_NO,
        PROD_ORDER_ID,
        CANCEL_REASON_CD,
        CANCEL_REASON_NM,
        POINT_AMT,
        ERP_SEND_PROD_CD,
        ERP_SEND_AMT,
        ERP_SEND_YN,
        VAT_INCLD_YN,
        QR_VORDER_NO,
        QR_PAY_TYPE
      FROM TB_SL_SALE_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       12) TB_SL_SALE_DTL_PAY   [매출] 상세_결제
          8/21 실측 : 반품 7034행 / 원거래 7034행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL_PAY';
    INSERT INTO TB_SL_SALE_DTL_PAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, PAY_CD,
        REG_SEQ, SALE_YN, SALE_FG, PAY_AMT,
        DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT,
        REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG,
        DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT, SIDE_P_PROD_CD,
        SIDE_P_DTL_NO, SDSEL_CLASS_CD, BILL_DT, SINGLE_PROD_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        PAY_CD,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        PAY_AMT,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        CUP_AMT,
        SIDE_P_PROD_CD,
        SIDE_P_DTL_NO,
        SDSEL_CLASS_CD,
        P_BILL_DT                  /* BILL_DT */,
        SINGLE_PROD_CD
      FROM TB_SL_SALE_DTL_PAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       13) TB_SL_SALE_DTL_DC   [매출] 상세_할인
          8/21 실측 : 반품 227행 / 원거래 227행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_DTL_DC';
    INSERT INTO TB_SL_SALE_DTL_DC (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, DC_CD,
        REG_SEQ, SALE_YN, SALE_FG, DC_AMT,
        DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD,
        PROD_CD, REG_DT, REG_ID, MOD_DT,
        MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM,
        APP_DC_DESC
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        BILL_DTL_NO,
        DC_CD,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        DC_AMT,
        DC_REASON_CD,
        DC_REASON_NM,
        DLVR_PACK_FG,
        CORNR_CD,
        PROD_CD,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        DLVR_IN_SVC_NM,
        APP_DC_DESC
      FROM TB_SL_SALE_DTL_DC
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       14) TB_SL_SALE_DTL_DISCOUNT   [매출] 할인수단/프로모션 상세 정보
          8/21 실측 : 반품 29행 / 원거래 29행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, DC_SEQ
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_DTL_DISCOUNT';
    MERGE INTO TB_SL_SALE_DTL_DISCOUNT T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_NEW_SALE_DATE            AS SALE_DATE,
               P_NEW_POS_NO               AS POS_NO,
               P_NEW_BILL_NO              AS BILL_NO,
               BILL_DTL_NO,
               DC_SEQ,
               DC_CD,
               REG_SEQ,
               SALE_YN,
               SALE_FG,
               DC_AMT,
               DC_REASON_CD,
               DC_REASON_NM,
               ADD_DATA1,
               ADD_DATA2,
               ADD_DATA3,
               CORNR_CD,
               PROD_CD,
               DLVR_PACK_FG,
               DLVR_ORDER_FG,
               DLVR_IN_FG,
               DLVR_IN_SVC_NM,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               ADD_DATA4,
               ADD_DATA5,
               SALE_QTY,
               MC_ORDER_NO,
               ORG_MC_ORDER_NO,
               APPR_NO,
               APPR_DT
             FROM TB_SL_SALE_DTL_DISCOUNT
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.BILL_DTL_NO = S.BILL_DTL_NO AND T.DC_SEQ = S.DC_SEQ)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.DC_CD                    = S.DC_CD,
        T.REG_SEQ                  = S.REG_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.SALE_FG                  = S.SALE_FG,
        T.DC_AMT                   = S.DC_AMT,
        T.DC_REASON_CD             = S.DC_REASON_CD,
        T.DC_REASON_NM             = S.DC_REASON_NM,
        T.ADD_DATA1                = S.ADD_DATA1,
        T.ADD_DATA2                = S.ADD_DATA2,
        T.ADD_DATA3                = S.ADD_DATA3,
        T.CORNR_CD                 = S.CORNR_CD,
        T.PROD_CD                  = S.PROD_CD,
        T.DLVR_PACK_FG             = S.DLVR_PACK_FG,
        T.DLVR_ORDER_FG            = S.DLVR_ORDER_FG,
        T.DLVR_IN_FG               = S.DLVR_IN_FG,
        T.DLVR_IN_SVC_NM           = S.DLVR_IN_SVC_NM,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.ADD_DATA4                = S.ADD_DATA4,
        T.ADD_DATA5                = S.ADD_DATA5,
        T.SALE_QTY                 = S.SALE_QTY,
        T.MC_ORDER_NO              = S.MC_ORDER_NO,
        T.ORG_MC_ORDER_NO          = S.ORG_MC_ORDER_NO,
        T.APPR_NO                  = S.APPR_NO,
        T.APPR_DT                  = S.APPR_DT
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, BILL_DTL_NO, DC_SEQ,
        DC_CD, REG_SEQ, SALE_YN, SALE_FG,
        DC_AMT, DC_REASON_CD, DC_REASON_NM, ADD_DATA1,
        ADD_DATA2, ADD_DATA3, CORNR_CD, PROD_CD,
        DLVR_PACK_FG, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        ADD_DATA4, ADD_DATA5, SALE_QTY, MC_ORDER_NO,
        ORG_MC_ORDER_NO, APPR_NO, APPR_DT
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.BILL_DTL_NO, S.DC_SEQ,
        S.DC_CD, S.REG_SEQ, S.SALE_YN, S.SALE_FG,
        S.DC_AMT, S.DC_REASON_CD, S.DC_REASON_NM, S.ADD_DATA1,
        S.ADD_DATA2, S.ADD_DATA3, S.CORNR_CD, S.PROD_CD,
        S.DLVR_PACK_FG, S.DLVR_ORDER_FG, S.DLVR_IN_FG, S.DLVR_IN_SVC_NM,
        S.REG_DT, S.REG_ID, S.MOD_DT, S.MOD_ID,
        S.ADD_DATA4, S.ADD_DATA5, S.SALE_QTY, S.MC_ORDER_NO,
        S.ORG_MC_ORDER_NO, S.APPR_NO, S.APPR_DT
    );

    /* ------------------------------------------------------------------------
       15) TB_SL_SALE_PAY   [매출] 결제_정보_헤더(통합)
          8/21 실측 : 반품 1022행 / 원거래 1022행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_CD
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_PAY';
    MERGE INTO TB_SL_SALE_PAY T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_NEW_SALE_DATE            AS SALE_DATE,
               P_NEW_POS_NO               AS POS_NO,
               P_NEW_BILL_NO              AS BILL_NO,
               PAY_CD,
               PAY_AMT,
               TAX_AMT,
               VAT_AMT,
               TIP_AMT,
               NO_TAX_AMT,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               REG_SEQ,
               SALE_YN,
               RECV_AMT,
               RTN_AMT,
               CUP_AMT
             FROM TB_SL_SALE_PAY
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_CD = S.PAY_CD)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.REG_SEQ                  = S.REG_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.RECV_AMT                 = S.RECV_AMT,
        T.RTN_AMT                  = S.RTN_AMT,
        T.CUP_AMT                  = S.CUP_AMT
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_CD, PAY_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        REG_SEQ, SALE_YN, RECV_AMT, RTN_AMT,
        CUP_AMT
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_CD, S.PAY_AMT,
        S.TAX_AMT, S.VAT_AMT, S.TIP_AMT, S.NO_TAX_AMT,
        S.REG_DT, S.REG_ID, S.MOD_DT, S.MOD_ID,
        S.REG_SEQ, S.SALE_YN, S.RECV_AMT, S.RTN_AMT,
        S.CUP_AMT
    );

    /* ------------------------------------------------------------------------
       16) TB_SL_SALE_PAY_DTL   [매출] 결제_정보_상세(통합)
          8/21 실측 : 반품 1007행 / 원거래 1007행

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ

          [v5-1 수정] MERGE ON 절에 PAY_SEQ 추가.
            기존에는 전표키 4개만으로 매칭했기 때문에 한 전표에 결제 행이 2건 이상
            (분할결제·결제수단 변경)이면 소스 여러 행이 타깃 1행에 매칭되어
            ORA-30926(안정적이지 않은 행 집합) 이 나거나 마지막 행만 남는 문제가 있었다.
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_PAY_DTL';
    MERGE INTO TB_SL_SALE_PAY_DTL T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_NEW_SALE_DATE            AS SALE_DATE,
               P_NEW_POS_NO               AS POS_NO,
               P_NEW_BILL_NO              AS BILL_NO,
               PAY_SEQ,
               SALE_YN,
               PAY_CD,
               CHANGE_YN,
               NO_SALE_YN,
               CANCEL_PAY_SEQ,
               ORG_PAY_SEQ,
               PAY_AMT,
               TAX_AMT,
               VAT_AMT,
               TIP_AMT,
               NO_TAX_AMT,
               DC_AMT,
               APPR_CD,
               APPR_TERMNL_NO,
               APPR_PROC_FG,
               APPR_TYPE_FG,
               CARD_TYPE_FG,
               CARD_NO,
               INST_CNT,
               APPR_UNIQUE_NO,
               APPR_DT,
               APPR_NO,
               DDC_FG,
               ISSUE_CD,
               ISSUE_NM,
               ACQUIRE_CD,
               ACQUIRE_NM,
               CMN_CARD_CORP_CD,
               MEMBR_JOIN_NO,
               APPR_MSG,
               CORNR_CD,
               CORNR_FG,
               APPR_LOG_NO,
               NULL                       AS ORG_BILL_NO,
               COUPN_AMT,
               POINT_AMT,
               FSTMP_AMT,
               BEFORE_AMT,
               AFTER_AMT,
               COUPN_CD,
               COUPN_NM,
               POINT_NM,
               OFFICE_CD,
               OFFICE_NM,
               DEPT_NM,
               CARD_DATA,
               ADD_DATA1,
               ADD_DATA2,
               ADD_DATA3,
               ADD_DATA4,
               ADD_DATA5,
               ADD_DATA6,
               ADD_DATA7,
               ADD_DATA8,
               ADD_DATA9,
               ADD_DATA10,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID,
               REG_SEQ,
               QR_VORDER_NO,
               QR_PAY_TYPE
             FROM TB_SL_SALE_PAY_DTL
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_SEQ = S.PAY_SEQ)   /* [v5-1] PAY_SEQ 추가 */
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_SEQ                  = S.PAY_SEQ,
        T.SALE_YN                  = S.SALE_YN,
        T.PAY_CD                   = S.PAY_CD,
        T.CHANGE_YN                = S.CHANGE_YN,
        T.NO_SALE_YN               = S.NO_SALE_YN,
        T.CANCEL_PAY_SEQ           = S.CANCEL_PAY_SEQ,
        T.ORG_PAY_SEQ              = S.ORG_PAY_SEQ,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.DC_AMT                   = S.DC_AMT,
        T.APPR_CD                  = S.APPR_CD,
        T.APPR_TERMNL_NO           = S.APPR_TERMNL_NO,
        T.APPR_PROC_FG             = S.APPR_PROC_FG,
        T.APPR_TYPE_FG             = S.APPR_TYPE_FG,
        T.CARD_TYPE_FG             = S.CARD_TYPE_FG,
        T.CARD_NO                  = S.CARD_NO,
        T.INST_CNT                 = S.INST_CNT,
        T.APPR_UNIQUE_NO           = S.APPR_UNIQUE_NO,
        T.APPR_DT                  = S.APPR_DT,
        T.APPR_NO                  = S.APPR_NO,
        T.DDC_FG                   = S.DDC_FG,
        T.ISSUE_CD                 = S.ISSUE_CD,
        T.ISSUE_NM                 = S.ISSUE_NM,
        T.ACQUIRE_CD               = S.ACQUIRE_CD,
        T.ACQUIRE_NM               = S.ACQUIRE_NM,
        T.CMN_CARD_CORP_CD         = S.CMN_CARD_CORP_CD,
        T.MEMBR_JOIN_NO            = S.MEMBR_JOIN_NO,
        T.APPR_MSG                 = S.APPR_MSG,
        T.CORNR_CD                 = S.CORNR_CD,
        T.CORNR_FG                 = S.CORNR_FG,
        T.APPR_LOG_NO              = S.APPR_LOG_NO,
        T.ORG_BILL_NO              = S.ORG_BILL_NO,
        T.COUPN_AMT                = S.COUPN_AMT,
        T.POINT_AMT                = S.POINT_AMT,
        T.FSTMP_AMT                = S.FSTMP_AMT,
        T.BEFORE_AMT               = S.BEFORE_AMT,
        T.AFTER_AMT                = S.AFTER_AMT,
        T.COUPN_CD                 = S.COUPN_CD,
        T.COUPN_NM                 = S.COUPN_NM,
        T.POINT_NM                 = S.POINT_NM,
        T.OFFICE_CD                = S.OFFICE_CD,
        T.OFFICE_NM                = S.OFFICE_NM,
        T.DEPT_NM                  = S.DEPT_NM,
        T.CARD_DATA                = S.CARD_DATA,
        T.ADD_DATA1                = S.ADD_DATA1,
        T.ADD_DATA2                = S.ADD_DATA2,
        T.ADD_DATA3                = S.ADD_DATA3,
        T.ADD_DATA4                = S.ADD_DATA4,
        T.ADD_DATA5                = S.ADD_DATA5,
        T.ADD_DATA6                = S.ADD_DATA6,
        T.ADD_DATA7                = S.ADD_DATA7,
        T.ADD_DATA8                = S.ADD_DATA8,
        T.ADD_DATA9                = S.ADD_DATA9,
        T.ADD_DATA10               = S.ADD_DATA10,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID,
        T.REG_SEQ                  = S.REG_SEQ,
        T.QR_VORDER_NO             = S.QR_VORDER_NO,
        T.QR_PAY_TYPE              = S.QR_PAY_TYPE
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, SALE_YN,
        PAY_CD, CHANGE_YN, NO_SALE_YN, CANCEL_PAY_SEQ,
        ORG_PAY_SEQ, PAY_AMT, TAX_AMT, VAT_AMT,
        TIP_AMT, NO_TAX_AMT, DC_AMT, APPR_CD,
        APPR_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG, CARD_TYPE_FG,
        CARD_NO, INST_CNT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, DDC_FG, ISSUE_CD, ISSUE_NM,
        ACQUIRE_CD, ACQUIRE_NM, CMN_CARD_CORP_CD, MEMBR_JOIN_NO,
        APPR_MSG, CORNR_CD, CORNR_FG, APPR_LOG_NO,
        ORG_BILL_NO, COUPN_AMT, POINT_AMT, FSTMP_AMT,
        BEFORE_AMT, AFTER_AMT, COUPN_CD, COUPN_NM,
        POINT_NM, OFFICE_CD, OFFICE_NM, DEPT_NM,
        CARD_DATA, ADD_DATA1, ADD_DATA2, ADD_DATA3,
        ADD_DATA4, ADD_DATA5, ADD_DATA6, ADD_DATA7,
        ADD_DATA8, ADD_DATA9, ADD_DATA10, REG_DT,
        REG_ID, MOD_DT, MOD_ID, REG_SEQ,
        QR_VORDER_NO, QR_PAY_TYPE
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_SEQ, S.SALE_YN,
        S.PAY_CD, S.CHANGE_YN, S.NO_SALE_YN, S.CANCEL_PAY_SEQ,
        S.ORG_PAY_SEQ, S.PAY_AMT, S.TAX_AMT, S.VAT_AMT,
        S.TIP_AMT, S.NO_TAX_AMT, S.DC_AMT, S.APPR_CD,
        S.APPR_TERMNL_NO, S.APPR_PROC_FG, S.APPR_TYPE_FG, S.CARD_TYPE_FG,
        S.CARD_NO, S.INST_CNT, S.APPR_UNIQUE_NO, S.APPR_DT,
        S.APPR_NO, S.DDC_FG, S.ISSUE_CD, S.ISSUE_NM,
        S.ACQUIRE_CD, S.ACQUIRE_NM, S.CMN_CARD_CORP_CD, S.MEMBR_JOIN_NO,
        S.APPR_MSG, S.CORNR_CD, S.CORNR_FG, S.APPR_LOG_NO,
        S.ORG_BILL_NO, S.COUPN_AMT, S.POINT_AMT, S.FSTMP_AMT,
        S.BEFORE_AMT, S.AFTER_AMT, S.COUPN_CD, S.COUPN_NM,
        S.POINT_NM, S.OFFICE_CD, S.OFFICE_NM, S.DEPT_NM,
        S.CARD_DATA, S.ADD_DATA1, S.ADD_DATA2, S.ADD_DATA3,
        S.ADD_DATA4, S.ADD_DATA5, S.ADD_DATA6, S.ADD_DATA7,
        S.ADD_DATA8, S.ADD_DATA9, S.ADD_DATA10, S.REG_DT,
        S.REG_ID, S.MOD_DT, S.MOD_ID, S.REG_SEQ,
        S.QR_VORDER_NO, S.QR_PAY_TYPE
    );

    /* ------------------------------------------------------------------------
       17) TB_SL_SALE_PAY_SEQ   [매출] 결제_순서
          8/21 실측 : 반품 2077행 / 원거래 2077행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_SEQ';
    INSERT INTO TB_SL_SALE_PAY_SEQ (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, REG_SEQ,
        SALE_YN, SALE_FG, PAY_CD, PAY_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, CUP_AMT, BILL_DT,
        DLVR_ORDER_FG, DLVR_IN_FG, PAYMENT_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        PAY_SEQ,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        PAY_CD,
        PAY_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        LINE_NO,
        APPR_PROC_FG,
        APPR_CARD_NO,
        APPR_SEQ_NO,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        CUP_AMT,
        P_BILL_DT                  /* BILL_DT */,
        DLVR_ORDER_FG,
        DLVR_IN_FG,
        PAYMENT_ID
      FROM TB_SL_SALE_PAY_SEQ
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       18) TB_SL_SALE_PAY_CARD   [매출] 결제_신용카드
          8/21 실측 : 반품 1125행 / 원거래 1126행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CARD';
    INSERT INTO TB_SL_SALE_PAY_CARD (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG,
        CARD_NO, INST_CNT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, APPR_AMT, DC_AMT, DDC_FG,
        ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM,
        CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD,
        APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, CUP_AMT, MPAY_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        CARD_TYPE_FG,
        CARD_NO,
        INST_CNT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_AMT,
        DC_AMT,
        DDC_FG,
        ISSUE_CD,
        ISSUE_NM,
        ACQUIRE_CD,
        ACQUIRE_NM,
        CMN_CARD_CORP_CD,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        CUP_AMT,
        MPAY_CD
      FROM TB_SL_SALE_PAY_CARD
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       19) TB_SL_SALE_PAY_CASH   [매출] 결제_현금영수증
          8/21 실측 : 반품 533행 / 원거래 533행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CASH';
    INSERT INTO TB_SL_SALE_PAY_CASH (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        RECV_AMT, RTN_AMT, VAN_CD, VAN_TERMNL_NO,
        APPR_PROC_FG, APPR_TYPE_FG, CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO,
        APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, CUP_AMT,
        DLVR_ORDER_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        RECV_AMT,
        RTN_AMT,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        APPR_TYPE_FG,
        CASH_BILL_CARD_TYPE_FG,
        CASH_BILL_CARD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        CUP_AMT,
        DLVR_ORDER_FG
      FROM TB_SL_SALE_PAY_CASH
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       20) TB_SL_SALE_CASH_RCP   [매출] 현금 영수증
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)

          ※ 패키지가 MERGE(UPSERT) 로 처리하는 테이블이므로 INSERT 가 아닌 MERGE 사용.
            MERGE 키 : STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ
       ------------------------------------------------------------------------ */
    V_STEP := 'MERGE INTO TB_SL_SALE_CASH_RCP';
    MERGE INTO TB_SL_SALE_CASH_RCP T
    USING (SELECT
               HQ_OFFICE_CD,
               HQ_BRAND_CD,
               STORE_CD,
               P_NEW_SALE_DATE            AS SALE_DATE,
               P_NEW_POS_NO               AS POS_NO,
               P_NEW_BILL_NO              AS BILL_NO,
               PAY_SEQ,
               PAY_CD,
               SALE_YN,
               CHANGE_YN,
               NO_SALE_YN,
               CANCEL_PAY_SEQ,
               ORG_PAY_SEQ,
               REG_SEQ,
               PAY_AMT,
               TAX_AMT,
               VAT_AMT,
               TIP_AMT,
               NO_TAX_AMT,
               DC_AMT,
               APPR_CD,
               APPR_TERMNL_NO,
               APPR_PROC_FG,
               APPR_TYPE_FG,
               CARD_TYPE_FG,
               CARD_NO,
               INST_CNT,
               APPR_UNIQUE_NO,
               APPR_DT,
               APPR_NO,
               DDC_FG,
               ISSUE_CD,
               ISSUE_NM,
               ACQUIRE_CD,
               ACQUIRE_NM,
               CMN_CARD_CORP_CD,
               MEMBR_JOIN_NO,
               APPR_MSG,
               CUP_AMT,
               P_NOW                      AS REG_DT,
               P_USER_ID                  AS REG_ID,
               P_NOW                      AS MOD_DT,
               P_USER_ID                  AS MOD_ID
             FROM TB_SL_SALE_CASH_RCP
            WHERE STORE_CD  = P_STORE_CD
              AND SALE_DATE = P_ORG_SALE_DATE
              AND POS_NO    = P_ORG_POS_NO
              AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
              AND HQ_BRAND_CD  = P_HQ_BRAND_CD
              AND BILL_NO   = P_BILL_NO) S
       ON (T.STORE_CD = S.STORE_CD AND T.SALE_DATE = S.SALE_DATE AND T.POS_NO = S.POS_NO AND T.BILL_NO = S.BILL_NO AND T.PAY_SEQ = S.PAY_SEQ)
    WHEN MATCHED THEN UPDATE SET
        T.HQ_OFFICE_CD             = S.HQ_OFFICE_CD,
        T.HQ_BRAND_CD              = S.HQ_BRAND_CD,
        T.PAY_CD                   = S.PAY_CD,
        T.SALE_YN                  = S.SALE_YN,
        T.CHANGE_YN                = S.CHANGE_YN,
        T.NO_SALE_YN               = S.NO_SALE_YN,
        T.CANCEL_PAY_SEQ           = S.CANCEL_PAY_SEQ,
        T.ORG_PAY_SEQ              = S.ORG_PAY_SEQ,
        T.REG_SEQ                  = S.REG_SEQ,
        T.PAY_AMT                  = S.PAY_AMT,
        T.TAX_AMT                  = S.TAX_AMT,
        T.VAT_AMT                  = S.VAT_AMT,
        T.TIP_AMT                  = S.TIP_AMT,
        T.NO_TAX_AMT               = S.NO_TAX_AMT,
        T.DC_AMT                   = S.DC_AMT,
        T.APPR_CD                  = S.APPR_CD,
        T.APPR_TERMNL_NO           = S.APPR_TERMNL_NO,
        T.APPR_PROC_FG             = S.APPR_PROC_FG,
        T.APPR_TYPE_FG             = S.APPR_TYPE_FG,
        T.CARD_TYPE_FG             = S.CARD_TYPE_FG,
        T.CARD_NO                  = S.CARD_NO,
        T.INST_CNT                 = S.INST_CNT,
        T.APPR_UNIQUE_NO           = S.APPR_UNIQUE_NO,
        T.APPR_DT                  = S.APPR_DT,
        T.APPR_NO                  = S.APPR_NO,
        T.DDC_FG                   = S.DDC_FG,
        T.ISSUE_CD                 = S.ISSUE_CD,
        T.ISSUE_NM                 = S.ISSUE_NM,
        T.ACQUIRE_CD               = S.ACQUIRE_CD,
        T.ACQUIRE_NM               = S.ACQUIRE_NM,
        T.CMN_CARD_CORP_CD         = S.CMN_CARD_CORP_CD,
        T.MEMBR_JOIN_NO            = S.MEMBR_JOIN_NO,
        T.APPR_MSG                 = S.APPR_MSG,
        T.CUP_AMT                  = S.CUP_AMT,
        T.REG_DT                   = S.REG_DT,
        T.REG_ID                   = S.REG_ID,
        T.MOD_DT                   = S.MOD_DT,
        T.MOD_ID                   = S.MOD_ID
    WHEN NOT MATCHED THEN INSERT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, PAY_SEQ, PAY_CD,
        SALE_YN, CHANGE_YN, NO_SALE_YN, CANCEL_PAY_SEQ,
        ORG_PAY_SEQ, REG_SEQ, PAY_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, DC_AMT,
        APPR_CD, APPR_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG,
        CARD_TYPE_FG, CARD_NO, INST_CNT, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, DDC_FG, ISSUE_CD,
        ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM, CMN_CARD_CORP_CD,
        MEMBR_JOIN_NO, APPR_MSG, CUP_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    ) VALUES (
        S.HQ_OFFICE_CD, S.HQ_BRAND_CD, S.STORE_CD, S.SALE_DATE,
        S.POS_NO, S.BILL_NO, S.PAY_SEQ, S.PAY_CD,
        S.SALE_YN, S.CHANGE_YN, S.NO_SALE_YN, S.CANCEL_PAY_SEQ,
        S.ORG_PAY_SEQ, S.REG_SEQ, S.PAY_AMT, S.TAX_AMT,
        S.VAT_AMT, S.TIP_AMT, S.NO_TAX_AMT, S.DC_AMT,
        S.APPR_CD, S.APPR_TERMNL_NO, S.APPR_PROC_FG, S.APPR_TYPE_FG,
        S.CARD_TYPE_FG, S.CARD_NO, S.INST_CNT, S.APPR_UNIQUE_NO,
        S.APPR_DT, S.APPR_NO, S.DDC_FG, S.ISSUE_CD,
        S.ISSUE_NM, S.ACQUIRE_CD, S.ACQUIRE_NM, S.CMN_CARD_CORP_CD,
        S.MEMBR_JOIN_NO, S.APPR_MSG, S.CUP_AMT, S.REG_DT,
        S.REG_ID, S.MOD_DT, S.MOD_ID
    );

    /* ------------------------------------------------------------------------
       21) TB_SL_SALE_PAY_CASH_FNCHG   [매출] 결제_현금외환
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_CASH_FNCHG';
    INSERT INTO TB_SL_SALE_PAY_CASH_FNCHG (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, CRNCY_SEQ,
        REG_SEQ, SALE_YN, SALE_FG, CRNCY_CD,
        CRNCY_AMT, CRNCY_RATE, KRW_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        CRNCY_SEQ,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        CRNCY_CD,
        CRNCY_AMT,
        CRNCY_RATE,
        KRW_AMT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_CASH_FNCHG
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       22) TB_SL_SALE_PAY_COUPN   [매출] 결제 쿠폰
          8/21 실측 : 반품 65행 / 원거래 65행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_COUPN';
    INSERT INTO TB_SL_SALE_PAY_COUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, DC_AMT,
        COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG,
        COUPN_DC_RATE, COUPN_DC_AMT, COUPN_APPLY_FG, COUPN_SER_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO,
        APPR_AMT, APPR_DT, APPR_NO, APPR_MSG,
        PARTN_CD, DC_CD, OK_ACC_POINT, CARD_TYPE_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        DC_AMT,
        COUPN_REG_FG,
        PAY_CLASS_CD,
        COUPN_CD,
        COUPN_TYPE_FG,
        COUPN_DC_RATE,
        COUPN_DC_AMT,
        COUPN_APPLY_FG,
        COUPN_SER_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        COUPN_APPR_NO,
        APPR_PROC_FG,
        APPR_BARCD_NO,
        APPR_AMT,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        PARTN_CD,
        DC_CD,
        OK_ACC_POINT,
        CARD_TYPE_FG
      FROM TB_SL_SALE_PAY_COUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       23) TB_SL_SALE_PAY_MCOUPN   [매출] 결제_모바일쿠폰
          8/21 실측 : 반품 46행 / 원거래 46행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_MCOUPN';
    INSERT INTO TB_SL_SALE_PAY_MCOUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO,
        MCOUPN_UPRC, MCOUPN_REMAIN_AMT, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, APPR_PROC_FG, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MCOUPN_CD,
        MCOUPN_TERMNL_NO,
        MCOUPN_TYPE_FG,
        MCOUPN_BARCD_NO,
        MCOUPN_UPRC,
        MCOUPN_REMAIN_AMT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        APPR_PROC_FG,
        CUP_AMT
      FROM TB_SL_SALE_PAY_MCOUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       24) TB_SL_SALE_PAY_MPAY   [매출] 결제_모바일페이
          8/21 실측 : 반품 23행 / 원거래 23행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_MPAY';
    INSERT INTO TB_SL_SALE_PAY_MPAY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MPAY_CD,
        MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO,
        APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT,
        COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM,
        ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM,
        APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        APPR_TYPE_FG, INST_CNT, CUP_AMT, BILL_DT,
        DLVR_ORDER_FG, DLVR_IN_FG
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MPAY_CD,
        MPAY_TERMNL_NO,
        APPR_PROC_FG,
        MPAY_BARCD_TYPE_FG,
        MPAY_BARCD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_AMT,
        COUPN_AMT,
        COUPN_NM,
        POINT_AMT,
        POINT_NM,
        ISSUE_CD,
        ISSUE_NM,
        ACQUIRE_CD,
        ACQUIRE_NM,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        APPR_TYPE_FG,
        INST_CNT,
        CUP_AMT,
        P_BILL_DT                  /* BILL_DT */,
        DLVR_ORDER_FG,
        DLVR_IN_FG
      FROM TB_SL_SALE_PAY_MPAY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       25) TB_SL_SALE_PAY_PAYCO   [매출] 결제_페이코
          8/21 실측 : 반품 18행 / 원거래 18행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PAYCO';
    INSERT INTO TB_SL_SALE_PAY_PAYCO (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, PAYCO_TERMNL_NO,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, PAYCO_BARCD_TYPE_FG,
        PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, APPR_AMT, COUPN_AMT,
        COUPN_NM, POINT_AMT, POINT_NM, MEMBR_CARD_NO,
        DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, FSTMP_AMT,
        TMONEY_AFTER_AMT, TMONEY_BEFORE_AMT, CUP_AMT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        PAYCO_TERMNL_NO,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        PAYCO_BARCD_TYPE_FG,
        PAYCO_BARCD_NO,
        INST_CNT,
        APPR_COMPANY_NM,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_AMT,
        COUPN_AMT,
        COUPN_NM,
        POINT_AMT,
        POINT_NM,
        MEMBR_CARD_NO,
        DDC_FG,
        ACQUIRE_NM,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        FSTMP_AMT,
        TMONEY_AFTER_AMT,
        TMONEY_BEFORE_AMT,
        CUP_AMT
      FROM TB_SL_SALE_PAY_PAYCO
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       26) TB_SL_SALE_PAY_PARTNER   [매출] 결제_제휴카드
          8/21 실측 : 반품 2행 / 원거래 2행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PARTNER';
    INSERT INTO TB_SL_SALE_PAY_PARTNER (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG,
        PARTN_CD, PARTN_CARD_NO, APPR_UNIQUE_NO, APPR_DT,
        APPR_NO, DC_AMT, SAVE_POINT, USE_POINT,
        AVABL_POINT, ACC_POINT, MEMBR_JOIN_NO, APPR_MSG,
        CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        APPR_TYPE_FG,
        PARTN_CD,
        PARTN_CARD_NO,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        DC_AMT,
        SAVE_POINT,
        USE_POINT,
        AVABL_POINT,
        ACC_POINT,
        MEMBR_JOIN_NO,
        APPR_MSG,
        CORNR_CD,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_PARTNER
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       27) TB_SL_SALE_PAY_POINT   [매출] 결제_회원포인트
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_POINT';
    INSERT INTO TB_SL_SALE_PAY_POINT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, CORNR_CD,
        SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT,
        NO_TAX_AMT, MEMBR_NO, APPR_DT, APPR_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        ORG_BILL_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        CORNR_CD,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MEMBR_NO,
        APPR_DT,
        APPR_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        NULL                       /* ORG_BILL_NO */
      FROM TB_SL_SALE_PAY_POINT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       28) TB_SL_SALE_PAY_POSTPAID   [매출] 결제_회원후불
          8/21 실측 : 반품 32행 / 원거래 32행

          ★★ 직접 INSERT 금지 ★★
          SP_SL_SALE_PAY_POSTPAID_I01 은 이 테이블 외에
            - TB_MB_MEMBER_POSTPAID      (회원 후불원장)
            - TB_MB_MEMBER_PAID_BALANCE  (회원 후불잔액)
          까지 함께 갱신한다. 재매출은 정상매출과 같은 값으로 호출하여 잔액을 다시 차감한다.
          ([A] 반품이 잔액을 복구했으므로 [A]+[B] 순증감은 0)
       ------------------------------------------------------------------------ */
    V_STEP := 'PKG 호출 TB_SL_SALE_PAY_POSTPAID';
    FOR C IN (SELECT * FROM TB_SL_SALE_PAY_POSTPAID
               WHERE STORE_CD  = P_STORE_CD
                 AND SALE_DATE = P_ORG_SALE_DATE
                 AND POS_NO    = P_ORG_POS_NO
                 AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
                 AND HQ_BRAND_CD  = P_HQ_BRAND_CD
                 AND BILL_NO   = P_BILL_NO)
    LOOP
        PKG_SL_SALE.SP_SL_SALE_PAY_POSTPAID_I01(
            PI_HQ_OFFICE_CD => C.HQ_OFFICE_CD,
            PI_HQ_BRAND_CD  => C.HQ_BRAND_CD,
            PI_STORE_CD     => C.STORE_CD,
            PI_SALE_DATE    => P_NEW_SALE_DATE,   /* 재매출 영업일 */
            PI_POS_NO       => P_NEW_POS_NO,   /* 재매출 POS */
            PI_BILL_NO      => P_NEW_BILL_NO,   /* 신규 재매출 전표 */
            PI_LINE_NO      => C.LINE_NO,
            PI_LINE_SEQ_NO  => C.LINE_SEQ_NO,
            PI_REG_SEQ      => C.REG_SEQ,
            PI_SALE_YN      => C.SALE_YN,       /* 정상매출 그대로 */
            PI_SALE_FG      => C.SALE_FG,
            PI_SALE_AMT     => C.SALE_AMT,
            PI_TAX_AMT      => C.TAX_AMT,
            PI_VAT_AMT      => C.VAT_AMT,
            PI_TIP_AMT      => C.TIP_AMT,
            PI_NO_TAX_AMT   => C.NO_TAX_AMT,
            PI_MEMBR_NO     => C.MEMBR_NO,
            PI_REMARK       => C.REMARK,
            PI_CORNR_CD     => C.CORNR_CD,
            PI_ORG_BILL_NO  => NULL,
            PI_USER_ID      => P_USER_ID,
            PO_RESULT_CD    => P_RESULT_CD);

        IF P_RESULT_CD <> '0000' THEN
            RAISE_APPLICATION_ERROR(-20003,'후불 재매출 처리 실패: '||P_RESULT_CD);
        END IF;
    END LOOP;

    /* ------------------------------------------------------------------------
       29) TB_SL_SALE_PAY_PREPAID   [매출] 결제_회원선불
          8/21 실측 : 반품 3행 / 원거래 3행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_PREPAID';
    INSERT INTO TB_SL_SALE_PAY_PREPAID (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT,
        REMARK, CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MEMBR_NO,
        APPR_DT,
        APPR_NO,
        PREPAID_BAL_AMT,
        REMARK,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_PREPAID
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       30) TB_SL_SALE_PAY_REFUND   [매출] 결제_환급
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_REFUND';
    INSERT INTO TB_SL_SALE_PAY_REFUND (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, REFUND_CD,
        REFUND_TERMNL_NO, REFUND_TYPE_FG, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, APPR_UNIQUE_NO,
        APPR_DT, APPR_NO, REFUND_PREARNGE_AMT, REFUND_FEE_AMT,
        APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        REFUND_CD,
        REFUND_TERMNL_NO,
        REFUND_TYPE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        REFUND_PREARNGE_AMT,
        REFUND_FEE_AMT,
        APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_REFUND
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       31) TB_SL_SALE_PAY_GIFT   [매출] 결제_상품권
          8/21 실측 : 반품 5행 / 원거래 5행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT';
    INSERT INTO TB_SL_SALE_PAY_GIFT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        GIFT_UPRC, RTN_PAY_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        GIFT_UPRC,
        RTN_PAY_AMT,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_GIFT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       32) TB_SL_SALE_PAY_GIFT_DTL   [매출] 결제_상품권_상세
          8/21 실측 : 반품 6행 / 원거래 6행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT_DTL';
    INSERT INTO TB_SL_SALE_PAY_GIFT_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, REG_SEQ,
        SALE_YN, SALE_FG, GIFT_SEQ, GIFT_CD,
        GIFT_UPRC, GIFT_QTY, GIFT_PROC_FG, GIFT_SER_NO,
        REG_DT, REG_ID, MOD_DT, MOD_ID,
        MC_ORDER_NO, ORG_MC_ORDER_NO, APPR_NO, APPR_DT
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        GIFT_SEQ,
        GIFT_CD,
        GIFT_UPRC,
        GIFT_QTY,
        GIFT_PROC_FG,
        GIFT_SER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        MC_ORDER_NO,
        ORG_MC_ORDER_NO,
        APPR_NO,
        APPR_DT
      FROM TB_SL_SALE_PAY_GIFT_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       33) TB_SL_SALE_PAY_GIFT_RTN   [매출] 결제_상품권거스름
          8/21 실측 : 반품 3행 / 원거래 3행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_GIFT_RTN';
    INSERT INTO TB_SL_SALE_PAY_GIFT_RTN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, RTN_PAY_CD,
        REG_SEQ, SALE_YN, RTN_PAY_AMT, REG_DT,
        REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        RTN_PAY_CD,
        REG_SEQ,
        SALE_YN,
        RTN_PAY_AMT,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_GIFT_RTN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       34) TB_SL_SALE_PAY_FSTMP   [매출] 결제_식권
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_FSTMP';
    INSERT INTO TB_SL_SALE_PAY_FSTMP (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        RTN_PAY_AMT, ETC_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID, FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO,
        APPR_NO, APPR_DT, APPR_UNIQUE_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        RTN_PAY_AMT,
        ETC_AMT,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        FSTMP_UPRC,
        FSTMP_CD,
        FSTMP_SER_NO,
        APPR_NO,
        APPR_DT,
        APPR_UNIQUE_NO
      FROM TB_SL_SALE_PAY_FSTMP
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       35) TB_SL_SALE_PAY_FSTMP_DTL   [매출] 결제_식권_상세
          8/21 데이터 없음 (구조상 필요하므로 쿼리만 유지)
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_FSTMP_DTL';
    INSERT INTO TB_SL_SALE_PAY_FSTMP_DTL (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, REG_SEQ,
        SALE_YN, SALE_FG, FSTMP_SEQ, FSTMP_CD,
        FSTMP_UPRC, FSTMP_QTY, RTN_PAY_AMT, ETC_AMT,
        FSTMP_SER_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        FSTMP_SEQ,
        FSTMP_CD,
        FSTMP_UPRC,
        FSTMP_QTY,
        RTN_PAY_AMT,
        ETC_AMT,
        FSTMP_SER_NO,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_FSTMP_DTL
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       36) TB_SL_SALE_PAY_EMP_CARD   [매출] 결제_사원카드
          8/21 실측 : 반품 4행 / 원거래 4행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_EMP_CARD';
    INSERT INTO TB_SL_SALE_PAY_EMP_CARD (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_FG, SALE_AMT,
        TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT,
        REMAIN_AMT, ACCOUNT_FG, OFFICE_CD, OFFICE_NM,
        OFFICE_DEPT_NM, OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM,
        CARD_DATA, APPR_DT, APPR_NO, CORNR_CD,
        ORG_BILL_NO, APPR_PROC_FG, APPR_LOG_NO, APPR_MSG,
        REG_DT, REG_ID, MOD_DT, MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_FG,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        REMAIN_AMT,
        ACCOUNT_FG,
        OFFICE_CD,
        OFFICE_NM,
        OFFICE_DEPT_NM,
        OFFICE_EMP_NO,
        OFFICE_EMP_CARD_NO,
        OFFICE_EMP_NM,
        CARD_DATA,
        APPR_DT,
        APPR_NO,
        CORNR_CD,
        NULL                       /* ORG_BILL_NO */,
        APPR_PROC_FG,
        APPR_LOG_NO,
        APPR_MSG,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_EMP_CARD
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       37) TB_SL_SALE_PAY_TEMPORARY   [매출] 결제가승인
          8/21 실측 : 반품 173행 / 원거래 173행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_TEMPORARY';
    INSERT INTO TB_SL_SALE_PAY_TEMPORARY (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, TEMPORARY_PAY_CD,
        CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, TEMPORARY_PAY_FG, CUP_AMT,
        TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO,
        PROMOTION_CD
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        TEMPORARY_PAY_CD,
        CORNR_CD,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        TEMPORARY_PAY_FG,
        CUP_AMT,
        TEMPORARY_PAY_DTL_CD,
        DLVR_IN_FG,
        BARCD_NO,
        APPR_NO,
        PROMOTION_CD
      FROM TB_SL_SALE_PAY_TEMPORARY
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       38) TB_SL_SALE_PAY_VORDER   [매출] 결제오더픽
          8/21 실측 : 반품 13행 / 원거래 13행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VORDER';
    INSERT INTO TB_SL_SALE_PAY_VORDER (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD,
        VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO,
        INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO,
        APPR_AMT, DC_AMT, ACQUIRE_CD, MEMBR_JOIN_NO,
        PICKUP_NO, PICKUP_FG, PICKUP_TIME, PICKUP_TEL_NO,
        PICKUP_NICK_NM, CORNR_CD, ORG_BILL_NO, REG_DT,
        REG_ID, MOD_DT, MOD_ID, CUP_AMT,
        MEMBR_NO
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        VAN_CD,
        VAN_TERMNL_NO,
        APPR_PROC_FG,
        CARD_TYPE_FG,
        CARD_NO,
        INST_CNT,
        APPR_UNIQUE_NO,
        APPR_DT,
        APPR_NO,
        APPR_AMT,
        DC_AMT,
        ACQUIRE_CD,
        MEMBR_JOIN_NO,
        PICKUP_NO,
        PICKUP_FG,
        PICKUP_TIME,
        PICKUP_TEL_NO,
        PICKUP_NICK_NM,
        CORNR_CD,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        CUP_AMT,
        MEMBR_NO
      FROM TB_SL_SALE_PAY_VORDER
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       39) TB_SL_SALE_PAY_VCHARGE   [매출] 결제_VMEM충전포인트사용
          8/21 실측 : 반품 13행 / 원거래 13행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VCHARGE';
    INSERT INTO TB_SL_SALE_PAY_VCHARGE (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO,
        VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT, CORNR_CD,
        CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, TRANSACTION_ID, REQUEST_ID,
        ATTEMPT_NO, MERCHANT_ORDER_DT, BARCODE, ACCOUNT_ID,
        SECURITY_CODE, EXPIRE_DATE, BALANCE_AFTER
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MEMBR_ORDER_NO,
        VCHARGE_CARD_NO,
        VCHARGE_APPR_NO,
        VCHARGE_REMAIN_AMT,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        TRANSACTION_ID,
        REQUEST_ID,
        ATTEMPT_NO,
        MERCHANT_ORDER_DT,
        BARCODE,
        ACCOUNT_ID,
        SECURITY_CODE,
        EXPIRE_DATE,
        BALANCE_AFTER
      FROM TB_SL_SALE_PAY_VCHARGE
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       40) TB_SL_SALE_PAY_VCOUPN   [매출] 결제_VMEM쿠폰사용
          8/21 실측 : 반품 19행 / 원거래 19행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VCOUPN';
    INSERT INTO TB_SL_SALE_PAY_VCOUPN (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, MEMBR_ORDER_NO, VCOUPN_NO,
        VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT,
        VCOUPN_SAVE_POINT, ORG_BILL_NO, REG_DT, REG_ID,
        MOD_DT, MOD_ID, VCOUPN_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        MEMBR_ORDER_NO,
        VCOUPN_NO,
        VCOUPN_NM,
        VCOUPN_TYPE,
        VCOUPN_APPR_NO,
        VCOUPN_DC_AMT,
        VCOUPN_SAVE_POINT,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */,
        VCOUPN_ID
      FROM TB_SL_SALE_PAY_VCOUPN
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       41) TB_SL_SALE_PAY_VPOINT   [매출] 결제_VMEM적립포인트사용
          8/21 실측 : 반품 4행 / 원거래 4행
       ------------------------------------------------------------------------ */
    V_STEP := 'INSERT INTO TB_SL_SALE_PAY_VPOINT';
    INSERT INTO TB_SL_SALE_PAY_VPOINT (
        HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE,
        POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO,
        REG_SEQ, SALE_YN, SALE_AMT, TAX_AMT,
        VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO,
        VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD, CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO,
        ORG_BILL_NO, REG_DT, REG_ID, MOD_DT,
        MOD_ID
    )
    SELECT
        HQ_OFFICE_CD,
        HQ_BRAND_CD,
        STORE_CD,
        P_NEW_SALE_DATE            /* SALE_DATE */,
        P_NEW_POS_NO               /* POS_NO */,
        P_NEW_BILL_NO              /* BILL_NO */,
        LINE_NO,
        LINE_SEQ_NO,
        REG_SEQ,
        SALE_YN,
        SALE_AMT,
        TAX_AMT,
        VAT_AMT,
        TIP_AMT,
        NO_TAX_AMT,
        MEMBR_ORDER_NO,
        VPOINT_CARD_NO,
        VPOINT_APPR_NO,
        CORNR_CD,
        CASH_BILL_APPR_PROC_FG,
        CASH_BILL_CARD_NO,
        CASH_BILL_APPR_DT,
        CASH_BILL_APPR_NO,
        CASH_BILL_APPR_LOG_NO,
        NULL                       /* ORG_BILL_NO */,
        P_NOW                      /* REG_DT */,
        P_USER_ID                  /* REG_ID */,
        P_NOW                      /* MOD_DT */,
        P_USER_ID                  /* MOD_ID */
      FROM TB_SL_SALE_PAY_VPOINT
     WHERE STORE_CD  = P_STORE_CD
       AND SALE_DATE = P_ORG_SALE_DATE
       AND POS_NO    = P_ORG_POS_NO
       AND HQ_OFFICE_CD = P_HQ_OFFICE_CD   /* [v5-4] 본사/브랜드 한정 */
       AND HQ_BRAND_CD  = P_HQ_BRAND_CD
       AND BILL_NO   = P_BILL_NO;

    /* ------------------------------------------------------------------------
       포스 전송 데이터 생성 (PI_POS_SEND = 'Y' 일 때만)   TB_PS_CR_SVR_DATA
          포스가 이 행(DATA_TYPE_FG='S', POS_PROC_YN='N')을 읽어 전표를 내려받는다.
          이미 행이 있으면 POS_PROC_YN='N' 으로 리셋하여 재전송 대상으로 만든다.
       ------------------------------------------------------------------------ */
    IF UPPER(NVL(PI_POS_SEND,'N')) = 'Y' THEN
        V_STEP := 'MERGE TB_PS_CR_SVR_DATA';
        MERGE INTO TB_PS_CR_SVR_DATA T
        USING DUAL
           ON (    T.STORE_CD  = P_STORE_CD
               AND T.SALE_DATE = P_NEW_SALE_DATE
               AND T.POS_NO    = P_NEW_POS_NO
               AND T.BILL_NO   = P_NEW_BILL_NO
               AND T.DATA_TYPE_FG = 'S')
        WHEN MATCHED THEN UPDATE
           SET T.POS_PROC_YN  = 'N'    /* 재전송 대상으로 리셋 */
              ,T.POS_PROC_DT  = ''
              ,T.POS_PROC_MSG = ''
        WHEN NOT MATCHED THEN INSERT
              (STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN, DATA_TYPE_FG
              ,POS_REQ_DT, POS_PROC_YN, POS_PROC_DT, POS_PROC_MSG
              ,ORG_STORE_CD, ORG_SALE_DATE, ORG_POS_NO, ORG_BILL_NO
              ,CR_COMMENT, REG_DT, REG_ID, MOD_DT, MOD_ID)
        VALUES(P_STORE_CD, P_NEW_SALE_DATE, P_NEW_POS_NO, P_NEW_BILL_NO
              ,'Y'   /* SALE_YN : 재매출(정상매출) */
              ,'S', '', 'N', '', ''
              ,P_STORE_CD, P_ORG_SALE_DATE, P_ORG_POS_NO, P_BILL_NO
              ,'재매출 생성(SP_RECREATE_SALE_INFO_I02)'
              ,P_NOW, P_USER_ID, P_NOW, P_USER_ID);
    END IF;

    /* COMMIT 없음 — 호출측에서 결과 확인(사후 검증) 후 COMMIT / ROLLBACK 할 것 */

    END PR_CREATE_SALE;

--------------------------------------------------------------------------------------------------------
-- MAIN : 파라미터 행 단위 루프. 오류 발생 시 즉시 중단·전파 (호출측 ROLLBACK 필수)
--------------------------------------------------------------------------------------------------------
BEGIN
    PO_RESULT_CODE := '0000';
    PO_RESULT_MSG  := '';

    IF PI_SQL_INDEX NOT IN ('CREATE_RETURN','CREATE_SALE') THEN
        RAISE_APPLICATION_ERROR(-20000, '[SP_RECREATE_SALE_INFO_I02] 잘못된 PI_SQL_INDEX: '
            || NVL(PI_SQL_INDEX,'(NULL)') || '  (CREATE_RETURN / CREATE_SALE)');
    END IF;

    LOOP
        PS_I   := PS_I + 1;
        PS_ROW := FN_GET_MULTI_DATA(PI_SQL_PARAM, PS_ROW_CHR, PS_I);
        EXIT WHEN PS_ROW IS NULL;
        V_ROW_CNT := V_ROW_CNT + 1;

        /* ── 행 파싱 : 1~5 필수, 6(신규POS)·7(사유코드) 선택 ── */
        V_STEP := '행 파싱';
        P_STORE_CD      := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 1);
        P_ORG_SALE_DATE := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 2);
        P_ORG_POS_NO    := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 3);
        P_BILL_NO       := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 4);
        P_POS_IN        := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 6);

        V_ROW_INFO := '행 '||PS_I||' ['||P_STORE_CD||'-'||P_ORG_SALE_DATE||'-'||P_ORG_POS_NO||'-'||P_BILL_NO||']';

        IF P_STORE_CD IS NULL OR P_ORG_SALE_DATE IS NULL OR P_ORG_POS_NO IS NULL OR P_BILL_NO IS NULL
           OR FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 5) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20000, '[SP_RECREATE_SALE_INFO_I02] '||V_ROW_INFO
                || ' 필수 컬럼 누락 (매장⊥원영업일⊥원POS⊥원영수⊥신영업일)');
        END IF;

        CASE PI_SQL_INDEX
            WHEN 'CREATE_RETURN' THEN
                P_RTN_SALE_DATE := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 5);
                P_RTN_POS_NO    := NVL(P_POS_IN, P_ORG_POS_NO);
                P_RTN_REASON_CD := NVL(FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 7), 'MB');
                PR_CREATE_RETURN();

            WHEN 'CREATE_SALE' THEN
                P_NEW_SALE_DATE := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 5);
                P_NEW_POS_NO    := NVL(P_POS_IN, P_ORG_POS_NO);
                PR_CREATE_SALE();
        END CASE;
    END LOOP;

    IF V_ROW_CNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20000, '[SP_RECREATE_SALE_INFO_I02] 처리할 행이 없습니다. PI_SQL_PARAM 확인.');
    END IF;

    PO_RESULT_MSG := CHR(10)
        || '-------------------------------------------------------------------------' || CHR(10)
        || ' '||DECODE(PI_SQL_INDEX,'CREATE_RETURN','반품','재매출')||' 데이터 생성 완료 — 총 '||V_ROW_CNT||'건' || CHR(10)
        || PO_RESULT_MSG
        || '-------------------------------------------------------------------------' || CHR(10)
        || ' COMMIT 없음 : 사후 검증(생성기 [5] / SP_SALE_BILL_DATA_CHECK_S01) 후 별도 COMMIT !!!' || CHR(10)
        || '-------------------------------------------------------------------------' || CHR(10);

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        PO_RESULT_CODE := '9998/'||V_ROW_INFO||' 원거래 매출 없음 또는 정상매출(SALE_YN=Y) 아님';
        RAISE_APPLICATION_ERROR(-20002, '[SP_RECREATE_SALE_INFO_I02] '||PO_RESULT_CODE
            ||CHR(10)||'STEP='||V_STEP);
    WHEN DUP_VAL_ON_INDEX THEN
        PO_RESULT_CODE := '9998/'||V_ROW_INFO||' BILL_NO 채번 충돌(PK 중복)';
        RAISE_APPLICATION_ERROR(-20004, '[SP_RECREATE_SALE_INFO_I02] '||PO_RESULT_CODE
            ||CHR(10)||'채번(MAX+1) 후 INSERT 사이에 다른 세션(영업 중인 POS 등)이 같은 번호를 선점했습니다.'
            ||CHR(10)||'해당 POS 영업 종료 후, 또는 영업에 사용하지 않는 POS 번호로 재실행하십시오.'
            ||CHR(10)||'STEP='||V_STEP);
    WHEN OTHERS THEN
        PO_RESULT_CODE := '9999/'||V_ROW_INFO||' '||SQLERRM;
        RAISE_APPLICATION_ERROR(-20009, '[SP_RECREATE_SALE_INFO_I02] '||V_ROW_INFO
            ||CHR(10)||'STEP='||NVL(V_STEP,'-')
            ||CHR(10)||SQLERRM
            ||CHR(10)||'※ 이미 처리된 앞 행 포함 전체 미커밋 상태 — 호출측에서 ROLLBACK 하십시오.');
END SP_RECREATE_SALE_INFO_I02;
/
