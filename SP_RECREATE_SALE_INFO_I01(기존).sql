CREATE OR REPLACE PROCEDURE SBPORA.SP_RECREATE_SALE_INFO_I01
(
    PI_SQL_INDEX         IN  VARCHAR2
   ,PI_SQL_PARAM         IN  VARCHAR2
   ,PO_RESULT_CODE       OUT VARCHAR2
   ,PO_RESULT_MSG        OUT VARCHAR2
)
IS
  /* ***********************************************************************************************
  1. Function Id      :   SP_RECREATE_SALE_INFO_I01
  2. Input Parameter  :   PI_SQL_INDEX  = CREATE_SALE(신규 매출 생성) / CREATE_RETURN(반품 생성)
                          PI_SQL_PARAM  = 매장코드⊥영업일자⊥포스번호⊥영수번호⊥신규영업일자 (행구분자 ⊥♪)
  3. Output Parameter :   PO_RESULT_CODE = '0000' 정상 / '9998/...' 개별행 오류 / '9999/...' 시스템 오류
  4. Output  Table    :   TB_SL_SALE_HDR 외 14개 매출 관련 테이블
  5. Coder            :   임근주
  6. Coding Date      :   2026-09-04
  7. Remark           :   원본 영수증 기준으로 반품 또는 신규(동일) 매출 자료 생성
                          INSERT ~ SELECT 구조이므로 원본이 없으면 아무 것도 생성되지 않아 정합성 이슈 없음.
                          COMMIT 을 포함하지 않으므로 호출측에서 결과 확인 후 별도 COMMIT 필요.
  8. 수 정 내 용        :
  *********************************************************************************************** */

    V_USER_DEF_EXP     EXCEPTION;
    V_ERR_MSG          VARCHAR2(1000)  := '';

    PS_ROW             VARCHAR2(1000)  := '';
    PS_ROW_CHR         VARCHAR2(   6)  := '⊥♪';
    PS_COL_CHR         VARCHAR2(   3)  := '⊥';
    PS_I               BINARY_INTEGER  := 0 ;

    V_ERR_LINE_NO      VARCHAR2(   4)       ;
    V_SYSDATE          VARCHAR2(  14)  := TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS');
    V_REG_ID           VARCHAR2(  20)  := 'kjlim';

    V_STORE_NM         VARCHAR2( 100)       ;
    V_CNT              NUMBER               ;

    PI_STORE_CD             TB_SL_SALE_HDR.STORE_CD      %TYPE;
    PI_SALE_DATE            TB_SL_SALE_HDR.SALE_DATE     %TYPE;
    PI_POS_NO               TB_SL_SALE_HDR.POS_NO        %TYPE;
    PI_BILL_NO              TB_SL_SALE_HDR.BILL_NO       %TYPE;
    PI_NEW_SALE_DATE        TB_SL_SALE_HDR.SALE_DATE     %TYPE;

    V_ORG_BILL_DT           TB_SL_SALE_HDR.BILL_DT       %TYPE;
    V_NEW_BILL_NO           TB_SL_SALE_HDR.BILL_NO       %TYPE;
    V_NEW_BILL_DT           TB_SL_SALE_HDR.BILL_DT       %TYPE;
    V_NEW_ORDER_NO          TB_SL_SALE_HDR.ORDER_NO      %TYPE;
    V_NEW_ORG_BILL_NO       TB_SL_SALE_HDR.ORG_BILL_NO   %TYPE;

    PV_RESULT_CD    VARCHAR2(  10);
    PV_RESULT_MSG   VARCHAR2(1000);
    PV_SQL_PARAM    VARCHAR2( 200);

--------------------------------------------------------------------------------------------------------
-- SUB_PROCEDURE : SUB_INIT_TARGET (원본 존재 검증 + 매장명 조회 + 신규 BILL_NO/BILL_DT 채번 - 두 분기 공통)
--------------------------------------------------------------------------------------------------------
    PROCEDURE SUB_INIT_TARGET
    IS
    BEGIN
        V_ERR_LINE_NO := 'IN01';

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=1');
        BEGIN
            SELECT BILL_DT INTO V_ORG_BILL_DT
              FROM TB_SL_SALE_HDR
             WHERE STORE_CD  = PI_STORE_CD
               AND SALE_DATE = PI_SALE_DATE
               AND POS_NO    = PI_POS_NO
               AND BILL_NO   = PI_BILL_NO;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            V_ERR_MSG := '원본 영수증을 찾을 수 없습니다. ['||PI_STORE_CD||'-'||PI_SALE_DATE||'-'||PI_POS_NO||'-'||PI_BILL_NO||']';
            RAISE V_USER_DEF_EXP;
        END;

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=2');
        V_ERR_LINE_NO := 'IN02';
        BEGIN
            SELECT B.STORE_NM INTO V_STORE_NM
              FROM TB_MS_STORE B
             WHERE B.STORE_CD = PI_STORE_CD;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            V_STORE_NM := PI_STORE_CD;
            RAISE V_USER_DEF_EXP;
        END;

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=3');
        -- BILL_DT = 신규 영업일자 || 원본 시각(HH24MISS)
        V_ERR_LINE_NO := 'IN03';
        V_NEW_BILL_DT := PI_NEW_SALE_DATE || SUBSTR(V_ORG_BILL_DT, 9);

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=4');
        -- 신규 BILL_NO 채번 : 매장+신규영업일자+포스 기준 마지막 BILL_NO + 1
        --  (TB_SL_SALE_HDR 관련 트리거(TR_SL_SALE_HDR_01/80/90)는 일자별 집계/외부연동용이며 BILL_NO를 자동 채번하지 않음을 DB에서 확인함)
        V_ERR_LINE_NO := 'IN04';

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=5');
        SELECT TRIM(TO_CHAR(NVL(MAX(BILL_NO),0) + 1,'0000'))
          INTO V_NEW_BILL_NO
          FROM TB_SL_SALE_HDR
         WHERE STORE_CD  = PI_STORE_CD
           AND SALE_DATE = PI_NEW_SALE_DATE
           AND POS_NO    = PI_POS_NO;

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=6');
            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET V_NEW_BILL_NO='||V_NEW_BILL_NO);
           EXCEPTION
            WHEN V_USER_DEF_EXP THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||V_ERR_MSG;
                RAISE V_USER_DEF_EXP;
            WHEN OTHERS THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
                RAISE V_USER_DEF_EXP;
    END SUB_INIT_TARGET;

-----------------------------------------------------------------------------------
-- SUB_PROCEDURE CR_SVR_DATA : 포스 전송용 데이터 생성
--------------------------------------------------------------------------------------------------------

    PROCEDURE CR_SVR_DATA
    IS
    BEGIN
        BEGIN
        V_ERR_LINE_NO := '0041';

        MERGE INTO TB_PS_CR_SVR_DATA
            USING DUAL
            ON (    STORE_CD  = PI_STORE_CD
                AND SALE_DATE = PI_NEW_SALE_DATE
                AND POS_NO    = PI_POS_NO
                AND BILL_NO   = V_NEW_BILL_NO
                AND DATA_TYPE_FG = 'S'
               )
            WHEN MATCHED THEN
                UPDATE
                   SET POS_PROC_YN  = 'N'
                      ,POS_PROC_DT  = ''
                      ,POS_PROC_MSG = ''
            WHEN NOT MATCHED THEN
            INSERT (STORE_CD
                 ,SALE_DATE
                 ,POS_NO
                 ,BILL_NO
                 ,SALE_YN
                 ,DATA_TYPE_FG
                 ,POS_REQ_DT
                 ,POS_PROC_YN
                 ,POS_PROC_DT
                 ,POS_PROC_MSG
                 ,ORG_STORE_CD
                 ,ORG_SALE_DATE
                 ,ORG_POS_NO
                 ,ORG_BILL_NO
                 ,CR_COMMENT
                 ,REG_DT
                 ,REG_ID
                 ,MOD_DT
                 ,MOD_ID       )
          VALUES (PI_STORE_CD
                 ,PI_NEW_SALE_DATE
                 ,PI_POS_NO
                 ,V_NEW_BILL_NO
                 ,DECODE(PI_SQL_INDEX,'CREATE_SALE' , 'Y', 'N')
                 ,'S' --DATA_TYPE_FG
                 ,''  --POS_REQ_DT
                 ,'N' --POS_PROC_YN
                 ,''  --POS_PROC_DT
                 ,''  --POS_PROC_MSG
                 ,PI_STORE_CD
                 ,PI_SALE_DATE
                 ,PI_POS_NO
                 ,PI_BILL_NO
                 ,'매출 생성' --CR_COMMENT
                 ,TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS') --REG_DT
                 ,'SP_RECR' --REG_ID
                 ,TO_CHAR(SYSDATE,'YYYYMMDDHH24MISS') --MOD_DT
                 ,'SP_RECR' --MOD_ID
                 );


        EXCEPTION
            WHEN V_USER_DEF_EXP THEN
                V_ERR_MSG := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
                RAISE V_USER_DEF_EXP;
            WHEN OTHERS THEN
                V_ERR_MSG := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
                RAISE V_USER_DEF_EXP;
        END;
    END CR_SVR_DATA;

--------------------------------------------------------------------------------------------------------
-- SUB_PROCEDURE CR_SALE : 신규(동일) 매출 생성  (SALE_YN='Y', SALE_FG=1, 금액 부호 유지)
--------------------------------------------------------------------------------------------------------

    PROCEDURE CR_SALE
    IS
    BEGIN
        BEGIN


            DBMS_OUTPUT.PUT_LINE('CR_SALE=START');
            SUB_INIT_TARGET();

            DBMS_OUTPUT.PUT_LINE('SUB_INIT_TARGET=END');

            -- ORDER_NO = 신규 매출일자 기준 MAX(ORDER_NO) + 1000
            V_ERR_LINE_NO := 'CS01';
            BEGIN
            SELECT TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(0,10000)), 'FM0000')
             INTO V_NEW_ORDER_NO
            FROM DUAL;
                EXCEPTION WHEN V_USER_DEF_EXP THEN
                    PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||V_ERR_MSG;
                    RAISE V_USER_DEF_EXP;
                WHEN OTHERS THEN
                    PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
                    RAISE V_USER_DEF_EXP;
            END;
            DBMS_OUTPUT.PUT_LINE('V_NEW_ORDER_NO=V_NEW_ORDER_NO');
            -----------------------------------------------
            --TB_SL_SALE_HDR
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS10';
            INSERT INTO TB_SL_SALE_HDR
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG
            ,BILL_DT, TOT_SALE_AMT, TOT_DC_AMT, TOT_TIP_AMT, TOT_ETC_AMT, REAL_SALE_AMT, TAX_SALE_AMT, VAT_AMT
            ,NO_TAX_SALE_AMT, NET_SALE_AMT, EXPECT_PAY_AMT, RECV_PAY_AMT, RTN_PAY_AMT, DUTCH_PAY_CNT, TOT_GUEST_CNT
            ,TBL_CD, EMP_NO, ORDER_NO, PAGER_NO, DLVR_YN, MEMBR_YN, RESVE_YN, REFUND_YN, ORG_BILL_NO
            ,RTN_REASON_CD, RTN_REASON_NM, PAY_CHG_YN, REG_DT, REG_ID, MOD_DT, MOD_ID, PICKUP_YN, SALE_CHG_FG
            ,DLVR_ORDER_FG, ERP_BILL_NO, DLVR_IN_FG, ORDER_START_DT, ORDER_END_DT, DLVR_IN_SVC_NM, TOT_OFFADD_AMT
            ,BILL_SEQ_NO, KITCHEN_MEMO, ORDER_DT, CUP_AMT, DLVR_AMT, AI_TRAN_NO, CANCELED_AMT, DISPOSABLE_YN
            ,MULTI_LANG_FG, POINT_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, A.REG_SEQ, 'Y', 1
            ,V_NEW_BILL_DT, A.TOT_SALE_AMT, A.TOT_DC_AMT, A.TOT_TIP_AMT, A.TOT_ETC_AMT, A.REAL_SALE_AMT, A.TAX_SALE_AMT, A.VAT_AMT
            ,A.NO_TAX_SALE_AMT, A.NET_SALE_AMT, A.EXPECT_PAY_AMT, A.RECV_PAY_AMT, A.RTN_PAY_AMT, A.DUTCH_PAY_CNT, A.TOT_GUEST_CNT
            ,A.TBL_CD, A.EMP_NO, V_NEW_ORDER_NO, A.PAGER_NO, A.DLVR_YN, A.MEMBR_YN, A.RESVE_YN, A.REFUND_YN, A.ORG_BILL_NO
            ,A.RTN_REASON_CD, A.RTN_REASON_NM, A.PAY_CHG_YN, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, A.PICKUP_YN, A.SALE_CHG_FG
            ,A.DLVR_ORDER_FG, A.ERP_BILL_NO, A.DLVR_IN_FG, A.ORDER_START_DT, A.ORDER_END_DT, A.DLVR_IN_SVC_NM, A.TOT_OFFADD_AMT
            ,A.BILL_SEQ_NO, A.KITCHEN_MEMO, A.ORDER_DT, A.CUP_AMT, A.DLVR_AMT, A.AI_TRAN_NO, A.CANCELED_AMT, A.DISPOSABLE_YN
            ,A.MULTI_LANG_FG, A.POINT_AMT
            FROM TB_SL_SALE_HDR A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            DBMS_OUTPUT.PUT_LINE('COUNT='||SQL%ROWCOUNT);
            -----------------------------------------------
            --TB_SL_SALE_HDR_DC
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS11';
            INSERT INTO TB_SL_SALE_HDR_DC
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, DC_CD, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, BILL_DT, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, DC_CD, REG_SEQ, 'Y', 1
            ,A.DC_AMT, V_NEW_BILL_DT, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD
            FROM TB_SL_SALE_HDR_DC A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_GUEST
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS12';
            INSERT INTO TB_SL_SALE_HDR_GUEST
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG, TBL_CD
            ,GUEST_CNT_1, GUEST_CNT_2, GUEST_CNT_3, GUEST_CNT_4, GUEST_CLASS_FG_1, GUEST_CLASS_FG_2, BILL_DT, ORDER_NO
            ,REG_DT, REG_ID, MOD_DT, MOD_ID, EMP_NO, DLVR_ORDER_FG, GUEST_CNT_5, GUEST_CNT_6, DLVR_IN_FG, DLVR_IN_SVC_NM)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, REG_SEQ, 'Y', 1, TBL_CD
            ,GUEST_CNT_1, GUEST_CNT_2, GUEST_CNT_3, GUEST_CNT_4, GUEST_CLASS_FG_1, GUEST_CLASS_FG_2, V_NEW_BILL_DT, V_NEW_ORDER_NO
            ,V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, EMP_NO, DLVR_ORDER_FG, GUEST_CNT_5, GUEST_CNT_6, DLVR_IN_FG, DLVR_IN_SVC_NM
            FROM TB_SL_SALE_HDR_GUEST A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_PAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS13';
            INSERT INTO TB_SL_SALE_HDR_PAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_CD, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_AMT, BILL_DT, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, PAY_CD, REG_SEQ, 'Y', 1
            ,PAY_AMT, V_NEW_BILL_DT, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT
            FROM TB_SL_SALE_HDR_PAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_RESVE
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS14';
            INSERT INTO TB_SL_SALE_HDR_RESVE
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG, RESVE_NO
            ,RESVE_DATE, RESVE_TIME, RESVE_GUEST_NM, RESVE_GUEST_TEL_NO, RESVE_GUEST_CNT, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,RESVE_MEMO, RESVE_BIRTHDAY, SMS_FG, RESVE_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, REG_SEQ, 'Y', 1, RESVE_NO
            ,RESVE_DATE, RESVE_TIME, (RESVE_GUEST_NM), (RESVE_GUEST_TEL_NO), RESVE_GUEST_CNT, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,RESVE_MEMO, (RESVE_BIRTHDAY), SMS_FG, RESVE_IN_FG
            FROM TB_SL_SALE_HDR_RESVE A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS15';
            INSERT INTO TB_SL_SALE_DTL
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, REG_SEQ, SALE_YN, SALE_FG
            ,DLVR_PACK_FG, CORNR_CD, PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN, SALE_UPRC, SALE_QTY, SALE_AMT, DC_AMT
            ,TIP_AMT, ETC_AMT, REAL_SALE_AMT, VAT_AMT, MEMBR_SAVE_POINT, MEMBR_USE_POINT, REFUND_YN, SDATTR_CD, SDSEL_CLASS_CD
            ,SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD, DOUBLE_AMT, DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO, ZONE_EMP_NO
            ,CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG, PARTIAL_RTN_YN, REG_DT, REG_ID, MOD_DT, MOD_ID, COOK_MEMO, BILL_DT
            ,MEMBR_NO, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG, REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT
            ,OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD, SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO
            ,PROD_ORDER_ID, CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT, ERP_SEND_PROD_CD, ERP_SEND_AMT, ERP_SEND_YN, VAT_INCLD_YN)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, A.BILL_DTL_NO, REG_SEQ, 'Y', 1
            ,DLVR_PACK_FG, CORNR_CD, PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN, SALE_UPRC, SALE_QTY, SALE_AMT, DC_AMT
            ,TIP_AMT, A.ETC_AMT, REAL_SALE_AMT, VAT_AMT, MEMBR_SAVE_POINT, MEMBR_USE_POINT, REFUND_YN, SDATTR_CD, SDSEL_CLASS_CD
            ,SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD, DOUBLE_AMT, DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO, ZONE_EMP_NO
            ,CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG, PARTIAL_RTN_YN, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, COOK_MEMO, V_NEW_BILL_DT
            ,(MEMBR_NO), DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG, REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT
            ,OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD, SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO
            ,PROD_ORDER_ID, CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT, ERP_SEND_PROD_CD, ERP_SEND_AMT, ERP_SEND_YN, VAT_INCLD_YN
            FROM TB_SL_SALE_DTL A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL_DC
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS16';
            INSERT INTO TB_SL_SALE_DTL_DC
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, DC_CD, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, BILL_DTL_NO, DC_CD, REG_SEQ, 'Y', 1
            ,DC_AMT, DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD, PROD_CD, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            FROM TB_SL_SALE_DTL_DC A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL_PAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS17';
            INSERT INTO TB_SL_SALE_DTL_PAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, PAY_CD, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_AMT, DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            ,CUP_AMT, SIDE_P_PROD_CD, SIDE_P_DTL_NO, SDSEL_CLASS_CD, BILL_DT, SINGLE_PROD_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, BILL_DTL_NO, PAY_CD, REG_SEQ, 'Y', 1
            ,PAY_AMT, DLVR_PACK_FG, CORNR_CD, PROD_CD, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            ,CUP_AMT, SIDE_P_PROD_CD, SIDE_P_DTL_NO, SDSEL_CLASS_CD, V_NEW_BILL_DT, SINGLE_PROD_CD
            FROM TB_SL_SALE_DTL_PAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_SEQ
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS18';
            INSERT INTO TB_SL_SALE_PAY_SEQ
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_CD, PAY_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, PAY_SEQ, REG_SEQ, 'Y', 1
            ,PAY_CD, PAY_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT, V_NEW_BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG
            FROM TB_SL_SALE_PAY_SEQ A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VPOINT
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS19';
            INSERT INTO TB_SL_SALE_PAY_VPOINT
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_VPOINT A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VCOUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS20';
            INSERT INTO TB_SL_SALE_PAY_VCOUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,MEMBR_ORDER_NO, VCOUPN_NO, VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT, VCOUPN_SAVE_POINT
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, VCOUPN_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,MEMBR_ORDER_NO, VCOUPN_NO, VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT, VCOUPN_SAVE_POINT
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, VCOUPN_ID
            FROM TB_SL_SALE_PAY_VCOUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VCHARGE
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS21';
            INSERT INTO TB_SL_SALE_PAY_VCHARGE
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT
            ,CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT
            ,CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_VCHARGE A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_MCOUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS22';
            INSERT INTO TB_SL_SALE_PAY_MCOUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO
            ,MCOUPN_UPRC, MCOUPN_REMAIN_AMT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, APPR_PROC_FG, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO
            ,MCOUPN_UPRC, MCOUPN_REMAIN_AMT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, APPR_PROC_FG, CUP_AMT
            FROM TB_SL_SALE_PAY_MCOUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_COUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS23';
            INSERT INTO TB_SL_SALE_PAY_COUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG, COUPN_DC_RATE, COUPN_DC_AMT, COUPN_APPLY_FG
            ,COUPN_SER_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO
            ,APPR_AMT, APPR_DT, APPR_NO, APPR_MSG, PARTN_CD, DC_CD, OK_ACC_POINT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,DC_AMT, COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG, COUPN_DC_RATE, COUPN_DC_AMT, COUPN_APPLY_FG
            ,COUPN_SER_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO
            ,APPR_AMT, APPR_DT, APPR_NO, APPR_MSG, PARTN_CD, DC_CD, OK_ACC_POINT
            FROM TB_SL_SALE_PAY_COUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VORDER
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS24';
            INSERT INTO TB_SL_SALE_PAY_VORDER
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, ACQUIRE_CD, MEMBR_JOIN_NO, PICKUP_NO, PICKUP_FG
            ,PICKUP_TIME, PICKUP_TEL_NO, PICKUP_NICK_NM, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, MEMBR_NO)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, ACQUIRE_CD, MEMBR_JOIN_NO, PICKUP_NO, PICKUP_FG
            ,PICKUP_TIME, (PICKUP_TEL_NO), (PICKUP_NICK_NM), CORNR_CD, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT, (MEMBR_NO)
            FROM TB_SL_SALE_PAY_VORDER A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_CARD
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS25';
            INSERT INTO TB_SL_SALE_PAY_CARD
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, DDC_FG, ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM
            ,CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,CUP_AMT, MPAY_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, DDC_FG, ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM
            ,CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,CUP_AMT, MPAY_CD
            FROM TB_SL_SALE_PAY_CARD A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_CASH
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS26';
            INSERT INTO TB_SL_SALE_PAY_CASH
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RECV_AMT, RTN_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG
            ,CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, DLVR_ORDER_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RECV_AMT, RTN_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG
            ,CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT, DLVR_ORDER_FG
            FROM TB_SL_SALE_PAY_CASH A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_PAYCO
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS27';
            INSERT INTO TB_SL_SALE_PAY_PAYCO
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, PAYCO_TERMNL_NO, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG
            ,PAYCO_BARCD_TYPE_FG, PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT
            ,COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, MEMBR_CARD_NO, DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD
            ,APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, FSTMP_AMT, TMONEY_AFTER_AMT, TMONEY_BEFORE_AMT, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, PAYCO_TERMNL_NO, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG
            ,PAYCO_BARCD_TYPE_FG, PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT
            ,COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, MEMBR_CARD_NO, DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD
            ,APPR_LOG_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, FSTMP_AMT, TMONEY_AFTER_AMT, TMONEY_BEFORE_AMT, CUP_AMT
            FROM TB_SL_SALE_PAY_PAYCO A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_MPAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS28';
            INSERT INTO TB_SL_SALE_PAY_MPAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MPAY_CD, MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO
            ,APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, ISSUE_CD, ISSUE_NM
            ,ACQUIRE_CD, ACQUIRE_NM, APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,APPR_TYPE_FG, INST_CNT, CUP_AMT, BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MPAY_CD, MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO
            ,APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, ISSUE_CD, ISSUE_NM
            ,ACQUIRE_CD, ACQUIRE_NM, APPR_MSG, CORNR_CD, APPR_LOG_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,APPR_TYPE_FG, INST_CNT, CUP_AMT, V_NEW_BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG
            FROM TB_SL_SALE_PAY_MPAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_PREPAID
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS29';
            INSERT INTO TB_SL_SALE_PAY_PREPAID
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT, REMARK, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT, REMARK, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_PREPAID A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_POSTPAID
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS30';
            INSERT INTO TB_SL_SALE_PAY_POSTPAID
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, REMARK, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, REMARK, CORNR_CD, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_POSTPAID A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_GIFT
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS31';
            INSERT INTO TB_SL_SALE_PAY_GIFT
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, GIFT_UPRC, RTN_PAY_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, GIFT_UPRC, RTN_PAY_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_GIFT A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_FSTMP
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS32';
            INSERT INTO TB_SL_SALE_PAY_FSTMP
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RTN_PAY_AMT, ETC_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO, APPR_NO, APPR_DT, APPR_UNIQUE_NO)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RTN_PAY_AMT, ETC_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO, APPR_NO, APPR_DT, APPR_UNIQUE_NO
            FROM TB_SL_SALE_PAY_FSTMP A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_EMP_CARD
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS33';
            INSERT INTO TB_SL_SALE_PAY_EMP_CARD
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, REMAIN_AMT, ACCOUNT_FG, OFFICE_CD, OFFICE_NM, OFFICE_DEPT_NM
            ,OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM, CARD_DATA, APPR_DT, APPR_NO, CORNR_CD, ORG_BILL_NO
            ,APPR_PROC_FG, APPR_LOG_NO, APPR_MSG, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y', 1
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, REMAIN_AMT, ACCOUNT_FG, OFFICE_CD, OFFICE_NM, OFFICE_DEPT_NM
            ,OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM, CARD_DATA, APPR_DT, APPR_NO, CORNR_CD, A.ORG_BILL_NO
            ,APPR_PROC_FG, APPR_LOG_NO, APPR_MSG, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_EMP_CARD A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_TEMPORARY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CS34';
            INSERT INTO TB_SL_SALE_PAY_TEMPORARY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, TEMPORARY_PAY_CD, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,TEMPORARY_PAY_FG, CUP_AMT, TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO, PROMOTION_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'Y'
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, TEMPORARY_PAY_CD, CORNR_CD, A.ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,TEMPORARY_PAY_FG, CUP_AMT, TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO, PROMOTION_CD
            FROM TB_SL_SALE_PAY_TEMPORARY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

 V_ERR_LINE_NO := 'CS35';
            PO_RESULT_MSG  := CHR(10)||'-------------------------------------------------------------------------' ||CHR(10)
                             ||' 신규 매출 데이터 생성 완료 . ('||V_STORE_NM||')' ||CHR(10)
                             ||':원본 영수증 정보 ['||PI_STORE_CD||'-' ||PI_SALE_DATE||'-'||PI_POS_NO||'-'||PI_BILL_NO||']'||CHR(10)
                             ||':신규 매출 영수증 정보 ['||PI_STORE_CD||'-' ||PI_NEW_SALE_DATE||'-'||PI_POS_NO||'-'||V_NEW_BILL_NO||']'||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ||' 별도 COMMIT 필요 !!! ' ||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ;

        EXCEPTION
            WHEN V_USER_DEF_EXP THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||V_ERR_MSG;
            WHEN OTHERS THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
        END;
    END CR_SALE;


--------------------------------------------------------------------------------------------------------
-- SUB_PROCEDURE CR_RETURN : 반품 자료 생성  (SALE_YN='N', SALE_FG=-1, 금액/횟수 부호 반전)
--------------------------------------------------------------------------------------------------------

    PROCEDURE CR_RETURN
    IS
    BEGIN
        BEGIN
            SUB_INIT_TARGET();

            -- 반품 전표는 실제 주문번호를 갖지 않으므로 예약 값(9998) 고정
            V_NEW_ORDER_NO    := '9998';
            -- 반품 전표가 가리키는 원본 영수증 KEY
            V_NEW_ORG_BILL_NO := PI_STORE_CD || PI_SALE_DATE || PI_POS_NO || PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR10';
            INSERT INTO TB_SL_SALE_HDR
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG
            ,BILL_DT, TOT_SALE_AMT, TOT_DC_AMT, TOT_TIP_AMT, TOT_ETC_AMT, REAL_SALE_AMT, TAX_SALE_AMT, VAT_AMT
            ,NO_TAX_SALE_AMT, NET_SALE_AMT, EXPECT_PAY_AMT, RECV_PAY_AMT, RTN_PAY_AMT, DUTCH_PAY_CNT, TOT_GUEST_CNT
            ,TBL_CD, EMP_NO, ORDER_NO, PAGER_NO, DLVR_YN, MEMBR_YN, RESVE_YN, REFUND_YN, ORG_BILL_NO
            ,RTN_REASON_CD, RTN_REASON_NM, PAY_CHG_YN, REG_DT, REG_ID, MOD_DT, MOD_ID, PICKUP_YN, SALE_CHG_FG
            ,DLVR_ORDER_FG, ERP_BILL_NO, DLVR_IN_FG, ORDER_START_DT, ORDER_END_DT, DLVR_IN_SVC_NM, TOT_OFFADD_AMT
            ,BILL_SEQ_NO, KITCHEN_MEMO, ORDER_DT, CUP_AMT, DLVR_AMT, AI_TRAN_NO, CANCELED_AMT, DISPOSABLE_YN
            ,MULTI_LANG_FG, POINT_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, A.REG_SEQ, 'N', -1
            ,V_NEW_BILL_DT, A.TOT_SALE_AMT*(-1), A.TOT_DC_AMT*(-1), A.TOT_TIP_AMT*(-1), A.TOT_ETC_AMT*(-1), A.REAL_SALE_AMT*(-1), A.TAX_SALE_AMT*(-1), A.VAT_AMT*(-1)
            ,A.NO_TAX_SALE_AMT*(-1), A.NET_SALE_AMT*(-1), A.EXPECT_PAY_AMT*(-1), A.RECV_PAY_AMT*(-1), A.RTN_PAY_AMT*(-1), A.DUTCH_PAY_CNT*(-1), A.TOT_GUEST_CNT*(-1)
            ,A.TBL_CD, A.EMP_NO, V_NEW_ORDER_NO, A.PAGER_NO, A.DLVR_YN, A.MEMBR_YN, A.RESVE_YN, A.REFUND_YN, V_NEW_ORG_BILL_NO
            ,A.RTN_REASON_CD, A.RTN_REASON_NM, A.PAY_CHG_YN, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, A.PICKUP_YN, A.SALE_CHG_FG
            ,A.DLVR_ORDER_FG, A.ERP_BILL_NO, A.DLVR_IN_FG, A.ORDER_START_DT, A.ORDER_END_DT, A.DLVR_IN_SVC_NM, A.TOT_OFFADD_AMT*(-1)
            ,A.BILL_SEQ_NO, A.KITCHEN_MEMO, A.ORDER_DT, A.CUP_AMT*(-1), A.DLVR_AMT*(-1), A.AI_TRAN_NO, A.CANCELED_AMT*(-1), A.DISPOSABLE_YN
            ,A.MULTI_LANG_FG, A.POINT_AMT*(-1)
            FROM TB_SL_SALE_HDR A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_DC
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR11';
            INSERT INTO TB_SL_SALE_HDR_DC
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, DC_CD, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, BILL_DT, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, DC_CD, REG_SEQ, 'N', -1
            ,A.DC_AMT*(-1), V_NEW_BILL_DT, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, DC_REASON_CD
            FROM TB_SL_SALE_HDR_DC A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_GUEST
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR12';
            INSERT INTO TB_SL_SALE_HDR_GUEST
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG, TBL_CD
            ,GUEST_CNT_1, GUEST_CNT_2, GUEST_CNT_3, GUEST_CNT_4, GUEST_CLASS_FG_1, GUEST_CLASS_FG_2, BILL_DT, ORDER_NO
            ,REG_DT, REG_ID, MOD_DT, MOD_ID, EMP_NO, DLVR_ORDER_FG, GUEST_CNT_5, GUEST_CNT_6, DLVR_IN_FG, DLVR_IN_SVC_NM)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, REG_SEQ, 'N', -1, TBL_CD
            ,GUEST_CNT_1*(-1), GUEST_CNT_2*(-1), GUEST_CNT_3*(-1), GUEST_CNT_4*(-1), GUEST_CLASS_FG_1, GUEST_CLASS_FG_2, V_NEW_BILL_DT, V_NEW_ORDER_NO
            ,V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, EMP_NO, DLVR_ORDER_FG, GUEST_CNT_5*(-1), GUEST_CNT_6*(-1), DLVR_IN_FG, DLVR_IN_SVC_NM
            FROM TB_SL_SALE_HDR_GUEST A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_PAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR13';
            INSERT INTO TB_SL_SALE_HDR_PAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_CD, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_AMT, BILL_DT, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, PAY_CD, REG_SEQ, 'N', -1
            ,PAY_AMT*(-1), V_NEW_BILL_DT, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, CUP_AMT*(-1)
            FROM TB_SL_SALE_HDR_PAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_HDR_RESVE
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR14';
            INSERT INTO TB_SL_SALE_HDR_RESVE
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, REG_SEQ, SALE_YN, SALE_FG, RESVE_NO
            ,RESVE_DATE, RESVE_TIME, RESVE_GUEST_NM, RESVE_GUEST_TEL_NO, RESVE_GUEST_CNT, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,RESVE_MEMO, RESVE_BIRTHDAY, SMS_FG, RESVE_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, REG_SEQ, 'N', -1, RESVE_NO
            ,RESVE_DATE, RESVE_TIME, (RESVE_GUEST_NM), (RESVE_GUEST_TEL_NO), RESVE_GUEST_CNT*(-1), V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,RESVE_MEMO, (RESVE_BIRTHDAY), SMS_FG, RESVE_IN_FG
            FROM TB_SL_SALE_HDR_RESVE A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR15';
            INSERT INTO TB_SL_SALE_DTL
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, REG_SEQ, SALE_YN, SALE_FG
            ,DLVR_PACK_FG, CORNR_CD, PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN, SALE_UPRC, SALE_QTY, SALE_AMT, DC_AMT
            ,TIP_AMT, ETC_AMT, REAL_SALE_AMT, VAT_AMT, MEMBR_SAVE_POINT, MEMBR_USE_POINT, REFUND_YN, SDATTR_CD, SDSEL_CLASS_CD
            ,SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD, DOUBLE_AMT, DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO, ZONE_EMP_NO
            ,CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG, PARTIAL_RTN_YN, REG_DT, REG_ID, MOD_DT, MOD_ID, COOK_MEMO, BILL_DT
            ,MEMBR_NO, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG, REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT
            ,OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD, SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO
            ,PROD_ORDER_ID, CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT, ERP_SEND_PROD_CD, ERP_SEND_AMT, ERP_SEND_YN, VAT_INCLD_YN)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, A.BILL_DTL_NO, REG_SEQ, 'N', -1
            ,DLVR_PACK_FG, CORNR_CD, PROD_CD, PROD_TYPE_FG, VAT_FG, PROD_TIP_YN, SALE_UPRC*(-1), SALE_QTY*(-1), SALE_AMT*(-1), DC_AMT*(-1)
            ,TIP_AMT*(-1), A.ETC_AMT*(-1), REAL_SALE_AMT*(-1), VAT_AMT*(-1), MEMBR_SAVE_POINT*(-1), MEMBR_USE_POINT*(-1), REFUND_YN, SDATTR_CD, SDSEL_CLASS_CD
            ,SIDE_P_PROD_CD, SIDE_P_DTL_NO, DOUBLE_CD, DOUBLE_AMT*(-1), DUTCH_PAY_FG, SALE_SCALE_WT, ORDER_EMP_NO, ZONE_EMP_NO
            ,CHG_TICKET_NO, PROMTN_NO, PROMTN_PROD_FG, PARTIAL_RTN_YN, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, COOK_MEMO, V_NEW_BILL_DT
            ,(MEMBR_NO), DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM, ORDER_ADD_FG, REMARK, ORG_BARCD_CD, WT_UPRC, CUP_AMT*(-1)
            ,OPTION_GRP_CD, OPTION_VAL_CD, SDSEL_TYPE_FG, SINGLE_CLASS_CD, SINGLE_PROD_CD, SINGLE_DTL_NO, DEPOSIT_DTL_NO
            ,PROD_ORDER_ID, CANCEL_REASON_CD, CANCEL_REASON_NM, POINT_AMT*(-1), ERP_SEND_PROD_CD, ERP_SEND_AMT*(-1), ERP_SEND_YN, VAT_INCLD_YN
            FROM TB_SL_SALE_DTL A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL_DC
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR16';
            INSERT INTO TB_SL_SALE_DTL_DC
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, DC_CD, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, BILL_DTL_NO, DC_CD, REG_SEQ, 'N', -1
            ,DC_AMT*(-1), DC_REASON_CD, DC_REASON_NM, DLVR_PACK_FG, CORNR_CD, PROD_CD, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            FROM TB_SL_SALE_DTL_DC A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_DTL_PAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR17';
            INSERT INTO TB_SL_SALE_DTL_PAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, BILL_DTL_NO, PAY_CD, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_AMT, DLVR_PACK_FG, CORNR_CD, PROD_CD, REG_DT, REG_ID, MOD_DT, MOD_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            ,CUP_AMT, SIDE_P_PROD_CD, SIDE_P_DTL_NO, SDSEL_CLASS_CD, BILL_DT, SINGLE_PROD_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, BILL_DTL_NO, PAY_CD, REG_SEQ, 'N', -1
            ,PAY_AMT*(-1), DLVR_PACK_FG, CORNR_CD, PROD_CD, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, DLVR_ORDER_FG, DLVR_IN_FG, DLVR_IN_SVC_NM
            ,CUP_AMT*(-1), SIDE_P_PROD_CD, SIDE_P_DTL_NO, SDSEL_CLASS_CD, V_NEW_BILL_DT, SINGLE_PROD_CD
            FROM TB_SL_SALE_DTL_PAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_SEQ
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR18';
            INSERT INTO TB_SL_SALE_PAY_SEQ
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, PAY_SEQ, REG_SEQ, SALE_YN, SALE_FG
            ,PAY_CD, PAY_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, PAY_SEQ, REG_SEQ, 'N', -1
            ,PAY_CD, PAY_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), LINE_NO, APPR_PROC_FG, APPR_CARD_NO, APPR_SEQ_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT*(-1), V_NEW_BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG
            FROM TB_SL_SALE_PAY_SEQ A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VPOINT
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR19';
            INSERT INTO TB_SL_SALE_PAY_VPOINT
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MEMBR_ORDER_NO, VPOINT_CARD_NO, VPOINT_APPR_NO, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_VPOINT A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VCOUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR20';
            INSERT INTO TB_SL_SALE_PAY_VCOUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,MEMBR_ORDER_NO, VCOUPN_NO, VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT, VCOUPN_SAVE_POINT
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, VCOUPN_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,MEMBR_ORDER_NO, VCOUPN_NO, VCOUPN_NM, VCOUPN_TYPE, VCOUPN_APPR_NO, VCOUPN_DC_AMT*(-1), VCOUPN_SAVE_POINT*(-1)
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, VCOUPN_ID
            FROM TB_SL_SALE_PAY_VCOUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VCHARGE
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR21';
            INSERT INTO TB_SL_SALE_PAY_VCHARGE
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_ORDER_NO, VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT
            ,CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MEMBR_ORDER_NO, VCHARGE_CARD_NO, VCHARGE_APPR_NO, VCHARGE_REMAIN_AMT*(-1)
            ,CORNR_CD, CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_VCHARGE A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_MCOUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR22';
            INSERT INTO TB_SL_SALE_PAY_MCOUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO
            ,MCOUPN_UPRC, MCOUPN_REMAIN_AMT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, APPR_PROC_FG, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MCOUPN_CD, MCOUPN_TERMNL_NO, MCOUPN_TYPE_FG, MCOUPN_BARCD_NO
            ,MCOUPN_UPRC, MCOUPN_REMAIN_AMT*(-1), APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, APPR_PROC_FG, CUP_AMT*(-1)
            FROM TB_SL_SALE_PAY_MCOUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_COUPN
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR23';
            INSERT INTO TB_SL_SALE_PAY_COUPN
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,DC_AMT, COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG, COUPN_DC_RATE, COUPN_DC_AMT, COUPN_APPLY_FG
            ,COUPN_SER_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO
            ,APPR_AMT, APPR_DT, APPR_NO, APPR_MSG, PARTN_CD, DC_CD, OK_ACC_POINT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,DC_AMT, COUPN_REG_FG, PAY_CLASS_CD, COUPN_CD, COUPN_TYPE_FG, COUPN_DC_RATE*(-1), COUPN_DC_AMT*(-1), COUPN_APPLY_FG
            ,COUPN_SER_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, COUPN_APPR_NO, APPR_PROC_FG, APPR_BARCD_NO
            ,APPR_AMT*(-1), APPR_DT, APPR_NO, APPR_MSG, PARTN_CD, DC_CD, OK_ACC_POINT*(-1)
            FROM TB_SL_SALE_PAY_COUPN A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_VORDER
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR24';
            INSERT INTO TB_SL_SALE_PAY_VORDER
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, ACQUIRE_CD, MEMBR_JOIN_NO, PICKUP_NO, PICKUP_FG
            ,PICKUP_TIME, PICKUP_TEL_NO, PICKUP_NICK_NM, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, MEMBR_NO)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT*(-1), ACQUIRE_CD, MEMBR_JOIN_NO, PICKUP_NO, PICKUP_FG
            ,PICKUP_TIME, (PICKUP_TEL_NO), (PICKUP_NICK_NM), CORNR_CD, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT*(-1), (MEMBR_NO)
            FROM TB_SL_SALE_PAY_VORDER A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_CARD
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR25';
            INSERT INTO TB_SL_SALE_PAY_CARD
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, DC_AMT, DDC_FG, ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM
            ,CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,CUP_AMT, MPAY_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, CARD_TYPE_FG, CARD_NO
            ,INST_CNT, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT*(-1), DC_AMT*(-1), DDC_FG, ISSUE_CD, ISSUE_NM, ACQUIRE_CD, ACQUIRE_NM
            ,CMN_CARD_CORP_CD, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,CUP_AMT*(-1), MPAY_CD
            FROM TB_SL_SALE_PAY_CARD A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_CASH
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR26';
            INSERT INTO TB_SL_SALE_PAY_CASH
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RECV_AMT, RTN_AMT, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG
            ,CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, CUP_AMT, DLVR_ORDER_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), RECV_AMT*(-1), RTN_AMT*(-1), VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG, APPR_TYPE_FG
            ,CASH_BILL_CARD_TYPE_FG, CASH_BILL_CARD_NO, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_MSG, CORNR_CD, APPR_LOG_NO
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, CUP_AMT*(-1), DLVR_ORDER_FG
            FROM TB_SL_SALE_PAY_CASH A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_PAYCO
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR27';
            INSERT INTO TB_SL_SALE_PAY_PAYCO
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, PAYCO_TERMNL_NO, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG
            ,PAYCO_BARCD_TYPE_FG, PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT
            ,COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, MEMBR_CARD_NO, DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD
            ,APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID, FSTMP_AMT, TMONEY_AFTER_AMT, TMONEY_BEFORE_AMT, CUP_AMT)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), PAYCO_TERMNL_NO, VAN_CD, VAN_TERMNL_NO, APPR_PROC_FG
            ,PAYCO_BARCD_TYPE_FG, PAYCO_BARCD_NO, INST_CNT, APPR_COMPANY_NM, APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT*(-1)
            ,COUPN_AMT*(-1), COUPN_NM, POINT_AMT*(-1), POINT_NM, MEMBR_CARD_NO, DDC_FG, ACQUIRE_NM, MEMBR_JOIN_NO, APPR_MSG, CORNR_CD
            ,APPR_LOG_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID, FSTMP_AMT*(-1), TMONEY_AFTER_AMT*(-1), TMONEY_BEFORE_AMT*(-1), CUP_AMT*(-1)
            FROM TB_SL_SALE_PAY_PAYCO A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_MPAY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR28';
            INSERT INTO TB_SL_SALE_PAY_MPAY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MPAY_CD, MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO
            ,APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT, COUPN_AMT, COUPN_NM, POINT_AMT, POINT_NM, ISSUE_CD, ISSUE_NM
            ,ACQUIRE_CD, ACQUIRE_NM, APPR_MSG, CORNR_CD, APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,APPR_TYPE_FG, INST_CNT, CUP_AMT, BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MPAY_CD, MPAY_TERMNL_NO, APPR_PROC_FG, MPAY_BARCD_TYPE_FG, MPAY_BARCD_NO
            ,APPR_UNIQUE_NO, APPR_DT, APPR_NO, APPR_AMT*(-1), COUPN_AMT*(-1), COUPN_NM, POINT_AMT*(-1), POINT_NM, ISSUE_CD, ISSUE_NM
            ,ACQUIRE_CD, ACQUIRE_NM, APPR_MSG, CORNR_CD, APPR_LOG_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,APPR_TYPE_FG, INST_CNT, CUP_AMT*(-1), V_NEW_BILL_DT, DLVR_ORDER_FG, DLVR_IN_FG
            FROM TB_SL_SALE_PAY_MPAY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_PREPAID
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR29';
            INSERT INTO TB_SL_SALE_PAY_PREPAID
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT, REMARK, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MEMBR_NO, APPR_DT, APPR_NO, PREPAID_BAL_AMT*(-1), REMARK, CORNR_CD
            ,CASH_BILL_APPR_PROC_FG, CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO
            ,V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_PREPAID A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_POSTPAID
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR30';
            INSERT INTO TB_SL_SALE_PAY_POSTPAID
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, MEMBR_NO, REMARK, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), MEMBR_NO, REMARK, CORNR_CD, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_POSTPAID A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_GIFT
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR31';
            INSERT INTO TB_SL_SALE_PAY_GIFT
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, GIFT_UPRC, RTN_PAY_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), GIFT_UPRC, RTN_PAY_AMT*(-1), CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_GIFT A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_FSTMP
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR32';
            INSERT INTO TB_SL_SALE_PAY_FSTMP
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, RTN_PAY_AMT, ETC_AMT, CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO, APPR_NO, APPR_DT, APPR_UNIQUE_NO)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), RTN_PAY_AMT*(-1), ETC_AMT*(-1), CORNR_CD, CASH_BILL_APPR_PROC_FG
            ,CASH_BILL_CARD_NO, CASH_BILL_APPR_DT, CASH_BILL_APPR_NO, CASH_BILL_APPR_LOG_NO, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,FSTMP_UPRC, FSTMP_CD, FSTMP_SER_NO, APPR_NO, APPR_DT, APPR_UNIQUE_NO
            FROM TB_SL_SALE_PAY_FSTMP A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_EMP_CARD
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR33';
            INSERT INTO TB_SL_SALE_PAY_EMP_CARD
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN, SALE_FG
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, REMAIN_AMT, ACCOUNT_FG, OFFICE_CD, OFFICE_NM, OFFICE_DEPT_NM
            ,OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM, CARD_DATA, APPR_DT, APPR_NO, CORNR_CD, ORG_BILL_NO
            ,APPR_PROC_FG, APPR_LOG_NO, APPR_MSG, REG_DT, REG_ID, MOD_DT, MOD_ID)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N', -1
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), REMAIN_AMT*(-1), ACCOUNT_FG, OFFICE_CD, OFFICE_NM, OFFICE_DEPT_NM
            ,OFFICE_EMP_NO, OFFICE_EMP_CARD_NO, OFFICE_EMP_NM, CARD_DATA, APPR_DT, APPR_NO, CORNR_CD, V_NEW_ORG_BILL_NO
            ,APPR_PROC_FG, APPR_LOG_NO, APPR_MSG, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            FROM TB_SL_SALE_PAY_EMP_CARD A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --TB_SL_SALE_PAY_TEMPORARY
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR34';
            INSERT INTO TB_SL_SALE_PAY_TEMPORARY
            (HQ_OFFICE_CD, HQ_BRAND_CD, STORE_CD, SALE_DATE, POS_NO, BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, SALE_YN
            ,SALE_AMT, TAX_AMT, VAT_AMT, TIP_AMT, NO_TAX_AMT, TEMPORARY_PAY_CD, CORNR_CD, ORG_BILL_NO, REG_DT, REG_ID, MOD_DT, MOD_ID
            ,TEMPORARY_PAY_FG, CUP_AMT, TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO, PROMOTION_CD)
            SELECT
             A.HQ_OFFICE_CD, A.HQ_BRAND_CD, A.STORE_CD, PI_NEW_SALE_DATE, A.POS_NO, V_NEW_BILL_NO, LINE_NO, LINE_SEQ_NO, REG_SEQ, 'N'
            ,SALE_AMT*(-1), TAX_AMT*(-1), VAT_AMT*(-1), TIP_AMT*(-1), NO_TAX_AMT*(-1), TEMPORARY_PAY_CD, CORNR_CD, V_NEW_ORG_BILL_NO, V_SYSDATE, V_REG_ID, V_SYSDATE, V_REG_ID
            ,TEMPORARY_PAY_FG, CUP_AMT*(-1), TEMPORARY_PAY_DTL_CD, DLVR_IN_FG, BARCD_NO, APPR_NO, PROMOTION_CD
            FROM TB_SL_SALE_PAY_TEMPORARY A
            WHERE A.STORE_CD = PI_STORE_CD AND A.SALE_DATE = PI_SALE_DATE AND A.POS_NO = PI_POS_NO AND A.BILL_NO = PI_BILL_NO;

            -----------------------------------------------
            --기존 원본 영수증의 ORG_BILL_NO 를 신규 반품전표 KEY로 갱신
            -----------------------------------------------
            V_ERR_LINE_NO := 'CR30';
            UPDATE TB_SL_SALE_HDR A
               SET A.ORG_BILL_NO = PI_STORE_CD || PI_NEW_SALE_DATE || PI_POS_NO || V_NEW_BILL_NO
                  ,A.MOD_DT      = V_SYSDATE
                  ,A.MOD_ID      = V_REG_ID
             WHERE A.STORE_CD  = PI_STORE_CD
               AND A.SALE_DATE = PI_SALE_DATE
               AND A.POS_NO    = PI_POS_NO
               AND A.BILL_NO   = PI_BILL_NO;

            PO_RESULT_MSG  := CHR(10)||'-------------------------------------------------------------------------' ||CHR(10)
                             ||' 반품 데이터 생성 완료 . ('||V_STORE_NM||')' ||CHR(10)
                             ||':원본 영수증 정보 ['||PI_STORE_CD||'-' ||PI_SALE_DATE||'-'||PI_POS_NO||'-'||PI_BILL_NO||']'||CHR(10)
                             ||':반품 영수증 정보 ['||PI_STORE_CD||'-' ||PI_NEW_SALE_DATE||'-'||PI_POS_NO||'-'||V_NEW_BILL_NO||']'||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ||' 별도 COMMIT 필요 !!! ' ||CHR(10)
                             ||'-------------------------------------------------------------------------' ||CHR(10)
                             ;

        EXCEPTION
            WHEN V_USER_DEF_EXP THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||V_ERR_MSG;
            WHEN OTHERS THEN
                PO_RESULT_CODE := '9998/['||V_ERR_LINE_NO||']'||SQLERRM;
        END;
    END CR_RETURN;


--------------------------------------------------------------------------------------------------------
-- MAIN_PROCESS :
--------------------------------------------------------------------------------------------------------

BEGIN

    PO_RESULT_CODE := '0000';
    BEGIN

            DBMS_OUTPUT.PUT_LINE('START111=');
        LOOP
            PS_I   := PS_I + 1 ;
            PS_ROW := FN_GET_MULTI_DATA(PI_SQL_PARAM, PS_ROW_CHR, PS_I );
            V_ERR_LINE_NO := 'TR03';

            DBMS_OUTPUT.PUT_LINE('START222=');
            EXIT WHEN PS_ROW IS NULL;

            CASE PI_SQL_INDEX
                WHEN 'CREATE_SALE' THEN

            DBMS_OUTPUT.PUT_LINE('PI_STORE_CD=PI_STORE_CD');
                    -- 신규(동일) 매출 자료 생성
                    PI_STORE_CD      := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 1) ; V_ERR_LINE_NO := 'FN02';
                    PI_SALE_DATE     := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 2) ; V_ERR_LINE_NO := 'FN03';
                    PI_POS_NO        := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 3) ; V_ERR_LINE_NO := 'FN04';
                    PI_BILL_NO       := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 4) ; V_ERR_LINE_NO := 'FN05';
                    PI_NEW_SALE_DATE := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 5) ; V_ERR_LINE_NO := 'FN06';

            DBMS_OUTPUT.PUT_LINE('PI_STORE_CD='||PI_STORE_CD);
            DBMS_OUTPUT.PUT_LINE('PI_SALE_DATE='||PI_SALE_DATE);
            DBMS_OUTPUT.PUT_LINE('PI_POS_NO='||PI_POS_NO);
            DBMS_OUTPUT.PUT_LINE('PI_BILL_NO='||PI_BILL_NO);
            DBMS_OUTPUT.PUT_LINE('PI_NEW_SALE_DATE='||PI_NEW_SALE_DATE);

                    CR_SALE();
                    V_ERR_LINE_NO := 'CS40';
                    --포스 전송 데이터 생성
                    CR_SVR_DATA();
                    V_ERR_LINE_NO := 'C41';
                    PV_RESULT_CD  := '';
                    PV_RESULT_MSG := '';
                    PV_SQL_PARAM := PI_STORE_CD ||'⊥'|| PI_NEW_SALE_DATE ||'⊥'
                                || PI_POS_NO   ||'⊥'|| V_NEW_BILL_NO    ||'⊥♪';

                    /*SP_SALE_BILL_DATA_CHECK_S01(
                        PI_SQL_INDEX   => 'CR_NEOE',
                        PI_SQL_PARAM   => PV_SQL_PARAM,
                        PO_RESULT_CODE => PV_RESULT_CD,
                        PO_RESULT_MSG  => PV_RESULT_MSG
                    );*/
                    DBMS_OUTPUT.PUT_LINE('----------------------------------------------');
                    DBMS_OUTPUT.PUT_LINE('SP_SALE_BILL_DATA_CHECK_S01 별도 실행 필요');
                    DBMS_OUTPUT.PUT_LINE('PV_RESULT_CD = '||PV_RESULT_CD);
                    DBMS_OUTPUT.PUT_LINE('PV_RESULT_MSG = '||PV_RESULT_MSG);
                    DBMS_OUTPUT.PUT_LINE('NEW_BILL_INFO = '||PV_SQL_PARAM);
                    DBMS_OUTPUT.PUT_LINE('----------------------------------------------');

                WHEN 'CREATE_RETURN' THEN
                    -- 반품 자료 생성
                    PI_STORE_CD       := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 1) ; V_ERR_LINE_NO := 'FN02';
                    PI_SALE_DATE      := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 2) ; V_ERR_LINE_NO := 'FN03';
                    PI_POS_NO         := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 3) ; V_ERR_LINE_NO := 'FN04';
                    PI_BILL_NO        := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 4) ; V_ERR_LINE_NO := 'FN05';
                    PI_NEW_SALE_DATE  := FN_GET_MULTI_DATA(PS_ROW, PS_COL_CHR, 5) ; V_ERR_LINE_NO := 'FN06';

                    DBMS_OUTPUT.PUT_LINE('CR_RETURN');
                    CR_RETURN();

                    --포스 전송 데이터 생성

                    DBMS_OUTPUT.PUT_LINE('CR_SVR_DATA');
                    CR_SVR_DATA();

                    PV_RESULT_CD  := '';
                    PV_RESULT_MSG := '';
                    PV_SQL_PARAM := PI_STORE_CD ||'⊥'|| PI_NEW_SALE_DATE ||'⊥'
                                || PI_POS_NO   ||'⊥'|| V_NEW_BILL_NO    ||'⊥♪';

                    /*SP_SALE_BILL_DATA_CHECK_S01(
                        PI_SQL_INDEX   => 'CR_NEOE',
                        PI_SQL_PARAM   => PV_SQL_PARAM,
                        PO_RESULT_CODE => PV_RESULT_CD,
                        PO_RESULT_MSG  => PV_RESULT_MSG
                    );*/
                    DBMS_OUTPUT.PUT_LINE('----------------------------------------------');
                    DBMS_OUTPUT.PUT_LINE('SP_SALE_BILL_DATA_CHECK_S01 별도 실행 필요');
                    DBMS_OUTPUT.PUT_LINE('PV_RESULT_CD = '||PV_RESULT_CD);
                    DBMS_OUTPUT.PUT_LINE('PV_RESULT_MSG = '||PV_RESULT_MSG);
                    DBMS_OUTPUT.PUT_LINE('NEW_BILL_INFO = '||PV_SQL_PARAM);
                    DBMS_OUTPUT.PUT_LINE('----------------------------------------------');

                ELSE
                    V_ERR_MSG := '잘못된 INDEX값입니다.';
                    RAISE V_USER_DEF_EXP;
            END CASE;

        END LOOP;  -- END PS_DATA LOOP ;

    END ;
    V_ERR_LINE_NO := 'TR99';

-- -----------------------------------------------------------------------------------------------------------------------

EXCEPTION
    WHEN V_USER_DEF_EXP THEN
        V_ERR_MSG := V_ERR_LINE_NO||'-8888:'||CHR(10)||V_ERR_MSG;
        RAISE_APPLICATION_ERROR(-20001, '[ SP_RECREATE_SALE_INFO_I01 ] '||'-'||  V_ERR_MSG ||CHR(10)||'PARAM='||  PI_SQL_PARAM ) ;
    WHEN OTHERS THEN
        V_ERR_MSG := V_ERR_LINE_NO||'-9999:'||CHR(10)||V_ERR_MSG;
        RAISE_APPLICATION_ERROR(-20002, '['||V_ERR_LINE_NO||']'||'-'|| SQLERRM ||CHR(10)||'PARAM='|| PI_SQL_PARAM );

END;
