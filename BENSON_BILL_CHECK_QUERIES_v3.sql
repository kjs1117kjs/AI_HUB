/* ==================================================================================================
   벤슨 매출 정합성 점검 쿼리집 v3  (SP_SALE_BILL_DATA_CHECK_S01 대체용 / 직접 실행)
   --------------------------------------------------------------------------------------------------
   기준 소스 : 2026/09/03 재업로드 버전 (SP_SALE_BILL_DATA_CHECK_S01 / SP_BENSON_DATA_DAILY_CHECK_IUD01)
   목적      : 프로시저를 컴파일·호출하지 않고, 프로시저가 수행하는 검증을 SQL 로 직접 실행한다.
               프로시저 소스에서 발견된 결함(오류를 정상으로 통과시키는 버그)은 모두 제거하여
               "원래 잡으려던 것"이 실제로 잡히도록 만들었다.

   v2 → v3 변경 (재업로드 소스 반영)
     [D]  8001 이 벤슨(H0665)에서는 8801 로 분기. HDR_DC.DC_CD 가 02/12/05 가 아닌 할인을 더해 재비교.
          → SUM 이 NULL 이면 통과하는 신규 결함 있음. 여기서는 NVL 로 잡음.
     [F]  6303(실매출 음수) / 6305(할인 음수) 신설. SALE_YN='Y' 일 때만. 순서 6103→6102→6303→6305→6405→6505.
     [L]  NE01 은 본부 A0001 에서만 실행. 벤슨은 이제 이 체크를 타지 않음 (참고용으로만 유지).
     [Z]  위 세 가지를 ORIG_CD / FIXED_CD 양쪽 CASE 에 반영.

   --------------------------------------------------------------------------------------------------
   사용법
   --------------------------------------------------------------------------------------------------
   1) 맨 아래 DEFINE 3줄을 원하는 값으로 바꾸고 먼저 실행한다.
   2) [A]~[L] 는 항목별 상세, [Z] 는 영수증당 대표 오류 1건(프로시저와 동일한 형태) 이다.
   3) 처음이면 [Z] → [Z-2] 로 규모를 먼저 보고, 많이 걸리는 코드의 블록으로 들어간다.
   4) 특정 영수증 1건만 보려면 BILLS 절 안의 주석 처리된 줄을 살린다.

   실행 환경 : SQL Developer / Toad / SQL*Plus. 치환변수(&) 를 쓰므로 SET DEFINE ON 상태여야 한다.

   --------------------------------------------------------------------------------------------------
   프로시저와 다른 점 (결과 비교 시 참고)
   --------------------------------------------------------------------------------------------------
   프로시저는 (1) 영수증 1건씩 (2) 첫 오류에서 RETURN (3) 앞 단계 통과 시에만 뒷 단계 실행,
   이라는 구조라서 한 영수증당 코드 1개만 나오고, 앞 단계에서 걸리면 뒤 단계 오류는 안 보인다.
   항목별 쿼리는 그 제약이 없어 같은 영수증이 여러 블록에 나올 수 있고 프로시저보다 더 많이 잡힌다.
   [Z] 는 프로시저 순서대로 CASE 를 쌓아 "대표 1건" 형태를 재현했고, 원본 프로시저가 판정했을
   코드(ORIG_CD)와 결함 제거 후 코드(FIXED_CD)를 나란히 보여준다.

   --------------------------------------------------------------------------------------------------
   테이블 / 조인 키
   --------------------------------------------------------------------------------------------------
   모든 테이블은 (STORE_CD, SALE_DATE, POS_NO, BILL_NO) 4개 키로 조인한다.
   본부 필터(HQ_OFFICE_CD)는 TB_SL_SALE_HDR 에만 걸고 나머지는 키 조인으로 따라간다.

     TB_SL_SALE_HDR         영수증 헤더        TOT_SALE_AMT TOT_DC_AMT REAL_SALE_AMT VAT_AMT NET_SALE_AMT SALE_YN
     TB_SL_SALE_DTL         상품별 상세        BILL_DTL_NO PROD_CD SALE_AMT DC_AMT REAL_SALE_AMT VAT_AMT ERP_SEND_AMT
                                               SIDE_P_DTL_NO SDSEL_CLASS_CD SALE_YN
     TB_SL_SALE_PAY_SEQ     결제 시퀀스        PAY_SEQ LINE_NO PAY_CD PAY_AMT VAT_AMT
     TB_SL_SALE_HDR_PAY     헤더 결제수단별    PAY_CD PAY_AMT
     TB_SL_SALE_DTL_PAY     상품별 결제        BILL_DTL_NO PAY_CD PAY_AMT
     TB_SL_SALE_HDR_DC      헤더 할인          DC_CD DC_AMT            ← v3: DC_CD 사용 (8801)
     TB_SL_SALE_DTL_DC      상품별 할인        BILL_DTL_NO DC_AMT SALE_YN
     TB_SL_SALE_PAY_*       결제수단별 상세    LINE_NO SALE_AMT VAT_AMT (+ CARD:DC_AMT / VCOUPN:VCOUPN_DC_AMT / COUPN:DC_AMT,SALE_FG)
     TB_MS_PRODUCT          상품 마스터        STORE_CD PROD_CD SDSEL_GRP_CD
   ================================================================================================== */

SET DEFINE ON
DEFINE HQ_OFFICE_CD = H0665
DEFINE FROM_DATE    = 20260901
DEFINE TO_DATE      = 20260903


/* ==================================================================================================
   [A] 데이터 존재 여부
   --------------------------------------------------------------------------------------------------
   프로시저 : GET_SALE_DATA
     1404  헤더 없음 (TOT_SALE_AMT NULL)
     4404  TB_SL_SALE_DTL     없음
     3404  TB_SL_SALE_PAY_SEQ 없음
     4414  TB_SL_SALE_HDR_PAY 없음   ← 프로시저는 '4404' 로 코딩되어 있으나 DTL 과 겹쳐 구분용 신규코드
     5404  TB_SL_SALE_DTL_PAY 없음
     6404  TB_SL_SALE_HDR_DC  없음 (헤더 할인 <> 0 일 때만)
     7404  TB_SL_SALE_DTL_DC  없음 (헤더 할인 <> 0 일 때만)

   원본 결함 → 이 쿼리의 처리
     HDR_PAY / DTL_PAY 는 SUM() 으로 조회해서 행이 없어도 NULL 만 오고 NO_DATA_FOUND 가 안 난다.
     그래서 4404(HDR_PAY)/5404 는 한 번도 발동한 적이 없고, 이어지는 7001 도 NULL 비교로 통과한다.
     여기서는 COUNT 로 직접 세어 잡는다.  ORIG_DETECT = 원본 프로시저 검출 가능 여부.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN, TOT_SALE_AMT, TOT_DC_AMT, REAL_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    -- AND STORE_CD = 'A000123' AND POS_NO = '01' AND BILL_NO = '0045'
),
CNT AS (
    SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO
          ,(SELECT COUNT(*) FROM TB_SL_SALE_DTL     X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) DTL_CNT
          ,(SELECT COUNT(*) FROM TB_SL_SALE_PAY_SEQ X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) SEQ_CNT
          ,(SELECT COUNT(*) FROM TB_SL_SALE_HDR_PAY X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) HPAY_CNT
          ,(SELECT COUNT(*) FROM TB_SL_SALE_DTL_PAY X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) DPAY_CNT
          ,(SELECT COUNT(*) FROM TB_SL_SALE_HDR_DC  X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) HDC_CNT
          ,(SELECT COUNT(*) FROM TB_SL_SALE_DTL_DC  X WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO) DDC_CNT
      FROM BILLS B
)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO, B.SALE_YN
      ,B.TOT_SALE_AMT, B.TOT_DC_AMT, B.REAL_SALE_AMT
      ,C.DTL_CNT, C.SEQ_CNT, C.HPAY_CNT, C.DPAY_CNT, C.HDC_CNT, C.DDC_CNT
      ,CASE WHEN B.TOT_SALE_AMT IS NULL                  THEN '1404'
            WHEN C.DTL_CNT  = 0                          THEN '4404'
            WHEN C.SEQ_CNT  = 0                          THEN '3404'
            WHEN C.HPAY_CNT = 0                          THEN '4414'
            WHEN C.DPAY_CNT = 0                          THEN '5404'
            WHEN B.TOT_DC_AMT <> 0 AND C.HDC_CNT = 0     THEN '6404'
            WHEN B.TOT_DC_AMT <> 0 AND C.DDC_CNT = 0     THEN '7404'
       END AS RESULT_CD
      ,CASE WHEN B.TOT_SALE_AMT IS NULL OR C.DTL_CNT=0 OR C.SEQ_CNT=0
              OR (B.TOT_DC_AMT<>0 AND (C.HDC_CNT=0 OR C.DDC_CNT=0)) THEN 'Y'
            ELSE 'N (원본 미검출)' END AS ORIG_DETECT
  FROM BILLS B, CNT C
 WHERE C.STORE_CD=B.STORE_CD AND C.SALE_DATE=B.SALE_DATE AND C.POS_NO=B.POS_NO AND C.BILL_NO=B.BILL_NO
   AND (  B.TOT_SALE_AMT IS NULL
       OR C.DTL_CNT=0 OR C.SEQ_CNT=0 OR C.HPAY_CNT=0 OR C.DPAY_CNT=0
       OR (B.TOT_DC_AMT<>0 AND (C.HDC_CNT=0 OR C.DDC_CNT=0)) )
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [B] 헤더 자체 항등식
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_SUM_DATA 앞부분
     9211  SALE_YN='Y' 인데 REAL_SALE_AMT < 0
     9212  SALE_YN='N' 인데 REAL_SALE_AMT > 0
     9023  NET_SALE_AMT + VAT_AMT <> REAL_SALE_AMT   (공급가 + 부가세 = 실매출)
   조인이 없어 가장 가볍다. 대량 기간 점검은 이것부터.
   ================================================================================================== */
SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN
      ,TOT_SALE_AMT, TOT_DC_AMT, NET_SALE_AMT, VAT_AMT, REAL_SALE_AMT
      ,NET_SALE_AMT + VAT_AMT AS NET_PLUS_VAT
      ,(NET_SALE_AMT + VAT_AMT) - REAL_SALE_AMT AS DIFF
      ,CASE WHEN SALE_YN='Y' AND REAL_SALE_AMT < 0 THEN '9211'
            WHEN SALE_YN='N' AND REAL_SALE_AMT > 0 THEN '9212'
            ELSE '9023' END AS RESULT_CD
  FROM TB_SL_SALE_HDR
 WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
   AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
   AND (  (SALE_YN='Y' AND REAL_SALE_AMT < 0)
       OR (SALE_YN='N' AND REAL_SALE_AMT > 0)
       OR (NET_SALE_AMT + VAT_AMT <> REAL_SALE_AMT) )
 ORDER BY SALE_DATE, STORE_CD, POS_NO, BILL_NO;


/* ==================================================================================================
   [C] 헤더 vs 상품상세(DTL) 합계
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_SUM_DATA
     9001  TOT_SALE_AMT  <> SUM(DTL.SALE_AMT)
     9002  TOT_DC_AMT    <> SUM(DTL.DC_AMT)
     9003  VAT_AMT       <> SUM(DTL.VAT_AMT)   (SALE_DATE <= 20210206 은 ABS 비교)
     9004  REAL_SALE_AMT <> SUM(DTL.REAL_SALE_AMT)
   DIFF 가 1~2원이면 반올림, 크면 상세 누락/중복이다.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, TOT_SALE_AMT, TOT_DC_AMT, VAT_AMT, REAL_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
D AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO
          ,SUM(SALE_AMT) SALE_AMT, SUM(DC_AMT) DC_AMT, SUM(REAL_SALE_AMT) REAL_AMT, SUM(VAT_AMT) VAT_AMT
      FROM TB_SL_SALE_DTL
     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
     GROUP BY STORE_CD, SALE_DATE, POS_NO, BILL_NO
)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO
      ,B.TOT_SALE_AMT , D.SALE_AMT, B.TOT_SALE_AMT  - D.SALE_AMT AS DIFF_9001
      ,B.TOT_DC_AMT   , D.DC_AMT  , B.TOT_DC_AMT    - D.DC_AMT   AS DIFF_9002
      ,B.VAT_AMT      , D.VAT_AMT , B.VAT_AMT       - D.VAT_AMT  AS DIFF_9003
      ,B.REAL_SALE_AMT, D.REAL_AMT, B.REAL_SALE_AMT - D.REAL_AMT AS DIFF_9004
      ,CASE WHEN B.TOT_SALE_AMT  <> D.SALE_AMT THEN '9001'
            WHEN B.TOT_DC_AMT    <> D.DC_AMT   THEN '9002'
            WHEN (B.SALE_DATE >  '20210206' AND B.VAT_AMT <> D.VAT_AMT)
              OR (B.SALE_DATE <= '20210206' AND ABS(B.VAT_AMT) <> ABS(D.VAT_AMT)) THEN '9003'
            WHEN B.REAL_SALE_AMT <> D.REAL_AMT THEN '9004'
       END AS RESULT_CD
  FROM BILLS B, D
 WHERE D.STORE_CD=B.STORE_CD AND D.SALE_DATE=B.SALE_DATE AND D.POS_NO=B.POS_NO AND D.BILL_NO=B.BILL_NO
   AND (  B.TOT_SALE_AMT  <> D.SALE_AMT
       OR B.TOT_DC_AMT    <> D.DC_AMT
       OR B.REAL_SALE_AMT <> D.REAL_AMT
       OR (B.SALE_DATE >  '20210206' AND B.VAT_AMT <> D.VAT_AMT)
       OR (B.SALE_DATE <= '20210206' AND ABS(B.VAT_AMT) <> ABS(D.VAT_AMT)) )
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [D] 헤더 vs 결제시퀀스(PAY_SEQ) 합계          ★ v3 변경
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_SUM_DATA
   PAY_SEQ 집계 규칙 (프로시저와 동일)
     SEQ_REAL = SUM( PAY_CD 가 05/12 가 아닌 PAY_AMT )       ← 실제 결제
     SEQ_DC   = SUM( PAY_CD 05(VMEM쿠폰)/12(쿠폰할인) PAY_AMT )  ← 할인으로 취급
     SEQ_VAT  = SUM( VAT_AMT )

   총할인 판정 — 본부별로 다르다
     H0393 (맘스터치) : 비교 자체를 건너뜀 (V_SEQ_DC_AMT := V_HDR_TOT_DC_AMT)
     H0665 (벤슨)     : TOT_DC <> SEQ_DC 이면 HDR_DC 에서 DC_CD 가 02/12/05 가 아닌 할인(ETC)을 더해 재비교
                          TOT_DC <> SEQ_DC + ETC  →  8801
                        (02/12/05 는 PAY_SEQ 에 잡히는 쿠폰류이고, 그 외 할인은 PAY_SEQ 에 없으므로 보정)
     그 외 본부       : TOT_DC <> SEQ_DC  →  8001
     8002  VAT_AMT       <> SEQ_VAT
     8003  REAL_SALE_AMT <> SEQ_REAL

   원본 결함 → 이 쿼리의 처리 (v3 신규)
     V_ETC_DC_AMT 를 SUM() 으로 구해서 HDR_DC 에 02/12/05 외 행이 하나도 없으면 NULL 이 된다.
     SEQ_DC + NULL = NULL 이라 8801 비교가 UNKNOWN → 통과. NVL(ETC,0) 으로 잡는다.
     또한 8801 메시지에 ETC 값이 안 찍히므로 여기서는 ETC 를 컬럼으로 같이 보여준다.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, HQ_OFFICE_CD, TOT_DC_AMT, VAT_AMT, REAL_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
S AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO
          ,SUM(DECODE(PAY_CD,'05',0,'12',0,PAY_AMT))       SEQ_REAL
          ,SUM(DECODE(PAY_CD,'05',PAY_AMT,'12',PAY_AMT,0)) SEQ_DC
          ,SUM(VAT_AMT)                                    SEQ_VAT
      FROM TB_SL_SALE_PAY_SEQ
     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
     GROUP BY STORE_CD, SALE_DATE, POS_NO, BILL_NO
),
E AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SUM(DC_AMT) ETC_DC
      FROM TB_SL_SALE_HDR_DC
     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
       AND DC_CD NOT IN ('02','12','05')
     GROUP BY STORE_CD, SALE_DATE, POS_NO, BILL_NO
)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO
      ,B.TOT_DC_AMT, S.SEQ_DC, NVL(E.ETC_DC,0) AS ETC_DC
      ,B.TOT_DC_AMT - S.SEQ_DC                  AS DIFF_8001
      ,B.TOT_DC_AMT - (S.SEQ_DC + NVL(E.ETC_DC,0)) AS DIFF_8801
      ,B.VAT_AMT      , S.SEQ_VAT , B.VAT_AMT       - S.SEQ_VAT  AS DIFF_8002
      ,B.REAL_SALE_AMT, S.SEQ_REAL, B.REAL_SALE_AMT - S.SEQ_REAL AS DIFF_8003
      ,CASE WHEN B.HQ_OFFICE_CD NOT IN ('H0393','H0665') AND B.TOT_DC_AMT <> S.SEQ_DC           THEN '8001'
            WHEN B.HQ_OFFICE_CD = 'H0665' AND B.TOT_DC_AMT <> S.SEQ_DC
             AND B.TOT_DC_AMT <> S.SEQ_DC + NVL(E.ETC_DC,0)                                     THEN '8801'
            WHEN B.VAT_AMT       <> S.SEQ_VAT  THEN '8002'
            WHEN B.REAL_SALE_AMT <> S.SEQ_REAL THEN '8003'
       END AS RESULT_CD
      ,CASE WHEN B.HQ_OFFICE_CD = 'H0665' AND B.TOT_DC_AMT <> S.SEQ_DC AND E.ETC_DC IS NULL
            THEN 'N (ETC SUM NULL → 통과)' ELSE 'Y' END AS ORIG_DETECT
  FROM BILLS B
  JOIN S ON S.STORE_CD=B.STORE_CD AND S.SALE_DATE=B.SALE_DATE AND S.POS_NO=B.POS_NO AND S.BILL_NO=B.BILL_NO
  LEFT JOIN E ON E.STORE_CD=B.STORE_CD AND E.SALE_DATE=B.SALE_DATE AND E.POS_NO=B.POS_NO AND E.BILL_NO=B.BILL_NO
 WHERE (B.HQ_OFFICE_CD NOT IN ('H0393','H0665') AND B.TOT_DC_AMT <> S.SEQ_DC)
    OR (B.HQ_OFFICE_CD = 'H0665' AND B.TOT_DC_AMT <> S.SEQ_DC AND B.TOT_DC_AMT <> S.SEQ_DC + NVL(E.ETC_DC,0))
    OR B.VAT_AMT       <> S.SEQ_VAT
    OR B.REAL_SALE_AMT <> S.SEQ_REAL
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [E] 헤더 vs HDR_PAY / HDR_DC / DTL_DC 합계
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_SUM_DATA
     7001  REAL_SALE_AMT <> SUM(HDR_PAY.PAY_AMT)
     6001  TOT_DC_AMT    <> SUM(HDR_DC.DC_AMT)
     6002  TOT_DC_AMT    <> SUM(DTL_DC.DC_AMT)
   원본 결함 → 이 쿼리의 처리
     (1) 7001 : HDR_PAY 가 없으면 SUM 이 NULL 이라 <> 비교가 UNKNOWN → 통과. NVL 로 잡는다.
     (2) 6001/6002 : 프로시저는 TOT_DC_AMT <> 0 일 때만 할인테이블을 읽고, 0 이면 초기값 0 끼리 비교해
         통과시킨다. "헤더 할인 0 / 상세에는 금액 있음" 역방향을 못 잡는다. 여기서는 항상 비교.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, TOT_DC_AMT, REAL_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
HP AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(PAY_AMT) AMT FROM TB_SL_SALE_HDR_PAY
        WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
HD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(DC_AMT)  AMT FROM TB_SL_SALE_HDR_DC
        WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
DD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(DC_AMT)  AMT FROM TB_SL_SALE_DTL_DC
        WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO
      ,B.REAL_SALE_AMT, NVL(HP.AMT,0) AS HDR_PAY_AMT, B.REAL_SALE_AMT - NVL(HP.AMT,0) AS DIFF_7001
      ,B.TOT_DC_AMT   , NVL(HD.AMT,0) AS HDR_DC_AMT , B.TOT_DC_AMT    - NVL(HD.AMT,0) AS DIFF_6001
      ,                 NVL(DD.AMT,0) AS DTL_DC_AMT , B.TOT_DC_AMT    - NVL(DD.AMT,0) AS DIFF_6002
      ,CASE WHEN B.REAL_SALE_AMT <> NVL(HP.AMT,0) THEN '7001'
            WHEN B.TOT_DC_AMT    <> NVL(HD.AMT,0) THEN '6001'
            WHEN B.TOT_DC_AMT    <> NVL(DD.AMT,0) THEN '6002'
       END AS RESULT_CD
      ,CASE WHEN HP.AMT IS NULL AND B.REAL_SALE_AMT <> 0     THEN 'N (HDR_PAY 없음 → NULL 통과)'
            WHEN B.TOT_DC_AMT = 0
             AND (NVL(HD.AMT,0)<>0 OR NVL(DD.AMT,0)<>0)      THEN 'N (헤더할인 0 → 미조회)'
            ELSE 'Y' END AS ORIG_DETECT
  FROM BILLS B
  LEFT JOIN HP ON HP.STORE_CD=B.STORE_CD AND HP.SALE_DATE=B.SALE_DATE AND HP.POS_NO=B.POS_NO AND HP.BILL_NO=B.BILL_NO
  LEFT JOIN HD ON HD.STORE_CD=B.STORE_CD AND HD.SALE_DATE=B.SALE_DATE AND HD.POS_NO=B.POS_NO AND HD.BILL_NO=B.BILL_NO
  LEFT JOIN DD ON DD.STORE_CD=B.STORE_CD AND DD.SALE_DATE=B.SALE_DATE AND DD.POS_NO=B.POS_NO AND DD.BILL_NO=B.BILL_NO
 WHERE B.REAL_SALE_AMT <> NVL(HP.AMT,0)
    OR B.TOT_DC_AMT    <> NVL(HD.AMT,0)
    OR B.TOT_DC_AMT    <> NVL(DD.AMT,0)
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [F] 개별 금액 규칙          ★ v3 변경 (6303 / 6305 추가)
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_SUM_DATA 말미. 판정 순서 그대로:
     6103  포인트(PAY_CD 04) 결제의 VAT_AMT 합 <> 0   (SALE_DATE > 20250207 부터)
     6102  SALE_YN='Y' 인데 DTL 에 VAT_AMT < 0 행 존재
     6303  SALE_YN='Y' 인데 DTL 에 REAL_SALE_AMT < 0 행 존재      (v3 신규)
     6305  SALE_YN='Y' 인데 DTL 에 DC_AMT < 0 행 존재             (v3 신규)
     6405  DTL 에 ABS(SALE_AMT) < ABS(DC_AMT) 행 존재
     6505  TOT_SALE_AMT <> ERP 전송금액 합계
           ERP 전송금액 = SUM( PROD_CD 앞 4자리 'LYNK' 면 ERP_SEND_AMT, 아니면 SALE_AMT )
           (프로시저 메시지는 REAL_SALE_AMT 를 찍지만 실제 비교는 TOT_SALE_AMT 다)

   참고 : 6303/6305 는 [J] 의 2404 와 조건이 겹친다. CHECK_SUM_DATA 가 먼저 돌므로
          프로시저에서는 6303/6305 가 먼저 잡히고 2404 는 사실상 도달하지 않는다.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN, TOT_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
S AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO, SUM(DECODE(PAY_CD,'04',VAT_AMT,0)) POINT_VAT
        FROM TB_SL_SALE_PAY_SEQ WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
       GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
D AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO
            ,SUM(CASE WHEN VAT_AMT       < 0 THEN 1 ELSE 0 END)             MINUS_VAT_CNT
            ,SUM(CASE WHEN REAL_SALE_AMT < 0 THEN 1 ELSE 0 END)             MINUS_REAL_CNT
            ,SUM(CASE WHEN DC_AMT        < 0 THEN 1 ELSE 0 END)             MINUS_DC_CNT
            ,SUM(CASE WHEN ABS(SALE_AMT) < ABS(DC_AMT) THEN 1 ELSE 0 END)   OVER_DC_CNT
            ,SUM(DECODE(SUBSTRB(PROD_CD,1,4),'LYNK',ERP_SEND_AMT,SALE_AMT)) ERP_SEND_AMT
        FROM TB_SL_SALE_DTL WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
       GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO, B.SALE_YN
      ,NVL(S.POINT_VAT,0) AS POINT_VAT
      ,D.MINUS_VAT_CNT, D.MINUS_REAL_CNT, D.MINUS_DC_CNT, D.OVER_DC_CNT
      ,B.TOT_SALE_AMT, D.ERP_SEND_AMT, NVL(B.TOT_SALE_AMT,0) - NVL(D.ERP_SEND_AMT,0) AS DIFF_6505
      ,CASE WHEN NVL(S.POINT_VAT,0) <> 0 AND B.SALE_DATE > '20250207' THEN '6103'
            WHEN B.SALE_YN='Y' AND D.MINUS_VAT_CNT  > 0              THEN '6102'
            WHEN B.SALE_YN='Y' AND D.MINUS_REAL_CNT > 0              THEN '6303'
            WHEN B.SALE_YN='Y' AND D.MINUS_DC_CNT   > 0              THEN '6305'
            WHEN D.OVER_DC_CNT > 0                                   THEN '6405'
            WHEN NVL(B.TOT_SALE_AMT,0) <> NVL(D.ERP_SEND_AMT,0)      THEN '6505'
       END AS RESULT_CD
  FROM BILLS B
  LEFT JOIN S ON S.STORE_CD=B.STORE_CD AND S.SALE_DATE=B.SALE_DATE AND S.POS_NO=B.POS_NO AND S.BILL_NO=B.BILL_NO
  LEFT JOIN D ON D.STORE_CD=B.STORE_CD AND D.SALE_DATE=B.SALE_DATE AND D.POS_NO=B.POS_NO AND D.BILL_NO=B.BILL_NO
 WHERE (NVL(S.POINT_VAT,0) <> 0 AND B.SALE_DATE > '20250207')
    OR (B.SALE_YN='Y' AND (D.MINUS_VAT_CNT > 0 OR D.MINUS_REAL_CNT > 0 OR D.MINUS_DC_CNT > 0))
    OR D.OVER_DC_CNT > 0
    OR NVL(B.TOT_SALE_AMT,0) <> NVL(D.ERP_SEND_AMT,0)
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [G] 상품상세(DTL) 행 단위
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_DTL_DATA
     5001  DTL 행에서 SALE_AMT - DC_AMT <> REAL_SALE_AMT
     5003  DTL.DC_AMT <> BILL_DTL_NO 별 SUM(DTL_DC.DC_AMT)
   원본 결함 → 이 쿼리의 처리
     5003 은 LEFT JOIN 인데 WHERE 에서 A.DC_AMT <> B.SUM_DC_AMT 로 비교해, DTL_DC 행이 없으면 NULL 비교로
     제외된다. NVL(…,0) 으로 잡고 DTL_DC_CNT=0 으로 구분한다. 프로시저는 첫 1건만 보지만 여기는 전부.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
DD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,BILL_DTL_NO, SUM(DC_AMT) SUM_DC_AMT, COUNT(*) CNT
         FROM TB_SL_SALE_DTL_DC WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
        GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO,BILL_DTL_NO)
SELECT A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO, A.PROD_CD
      ,A.SALE_AMT, A.DC_AMT, A.REAL_SALE_AMT
      ,A.SALE_AMT - A.DC_AMT AS EXPECT_REAL
      ,NVL(DD.SUM_DC_AMT,0)  AS DTL_DC_SUM
      ,NVL(DD.CNT,0)         AS DTL_DC_CNT
      ,CASE WHEN A.SALE_AMT - A.DC_AMT <> A.REAL_SALE_AMT THEN '5001'
            WHEN A.DC_AMT <> NVL(DD.SUM_DC_AMT,0)         THEN '5003' END AS RESULT_CD
      ,CASE WHEN A.SALE_AMT - A.DC_AMT = A.REAL_SALE_AMT AND NVL(DD.CNT,0)=0
            THEN 'N (DTL_DC 없음 → NULL 통과)' ELSE 'Y' END AS ORIG_DETECT
  FROM TB_SL_SALE_DTL A, BILLS B
  LEFT JOIN DD ON DD.STORE_CD=B.STORE_CD AND DD.SALE_DATE=B.SALE_DATE AND DD.POS_NO=B.POS_NO AND DD.BILL_NO=B.BILL_NO
              AND DD.BILL_DTL_NO = A.BILL_DTL_NO
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND (  A.SALE_AMT - A.DC_AMT <> A.REAL_SALE_AMT
       OR A.DC_AMT <> NVL(DD.SUM_DC_AMT,0) )
 ORDER BY A.SALE_DATE, A.STORE_CD, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO;


/* ==================================================================================================
   [H] 결제수단별 상세 대사  (가장 중요한 블록)
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_PAY_DATA — PAY_SEQ 한 행마다 PAY_CD 에 맞는 상세 테이블을 SELECT 해 비교.
   16개 테이블을 UNION ALL 로 펼친 것이 PAYDTL 이다.
   비교 규칙
     PAY_CD 05/12  → 3001  PAY_SEQ.PAY_AMT <> 상세.할인금액
     그 외         → 3002  PAY_SEQ.PAY_AMT <> 상세.SALE_AMT
                     3003  PAY_SEQ.VAT_AMT <> 상세.VAT_AMT
     PAY_AMT = 0 인 PAY_SEQ 행은 프로시저가 CONTINUE 로 건너뛴다 (여기도 제외).
   원본 결함 → 이 쿼리의 처리
     (1) 3009 : CASE 에 ELSE 가 없어 미지원 PAY_CD(09,15,16 등)가 오면 CASE_NOT_FOUND 로 프로시저가 죽는다.
     (2) 3004 : 상세 테이블에 LINE_NO 행이 없으면 NO_DATA_FOUND 로 죽는다.
     둘 다 ORA-20001 이 되고, 벤슨 배치에서는 WHEN OTHERS THEN NULL 에 삼켜져 로그 없이 사라진다.
     → 3009 / 3004 가 나오면 그 영수증은 프로시저로는 점검 자체가 불가능했던 건이다.
   PAY_CD ↔ 상세 테이블
     01 CARD  02 CASH  03 PAYCO  04 VPOINT  05 VCOUPN  06 VCHARGE  07 MPAY  08 MCOUPN
     10 PREPAID  11 POSTPAID  12 COUPN  13 GIFT  14 FSTMP  17 EMP_CARD  18 TEMPORARY  19 VORDER
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
PAYDTL AS (
    SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'01' PAY_CD, SALE_AMT AM_PAY, DC_AMT AM_DC, VAT_AMT AM_VAT
      FROM TB_SL_SALE_PAY_CARD      WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'02',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_CASH      WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'03',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_PAYCO     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'04',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_VPOINT    WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'05',0,NVL(VCOUPN_DC_AMT,0),0
      FROM TB_SL_SALE_PAY_VCOUPN    WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'06',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_VCHARGE   WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'07',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_MPAY      WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'08',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_MCOUPN    WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'10',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_PREPAID   WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'11',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_POSTPAID  WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'12',0,NVL(DC_AMT,0)*SALE_FG,0
      FROM TB_SL_SALE_PAY_COUPN     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'13',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_GIFT      WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'14',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_FSTMP     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'17',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_EMP_CARD  WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'18',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_TEMPORARY WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
    UNION ALL SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,LINE_NO,'19',SALE_AMT,0,VAT_AMT
      FROM TB_SL_SALE_PAY_VORDER    WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
SEQ AS (
    SELECT S.STORE_CD, S.SALE_DATE, S.POS_NO, S.BILL_NO, S.PAY_SEQ, S.LINE_NO, S.PAY_CD
          ,S.PAY_AMT SEQ_PAY_AMT, S.VAT_AMT SEQ_VAT_AMT
      FROM TB_SL_SALE_PAY_SEQ S, BILLS B
     WHERE S.STORE_CD=B.STORE_CD AND S.SALE_DATE=B.SALE_DATE AND S.POS_NO=B.POS_NO AND S.BILL_NO=B.BILL_NO
       AND S.PAY_AMT <> 0
)
SELECT Q.STORE_CD, Q.SALE_DATE, Q.POS_NO, Q.BILL_NO, Q.PAY_SEQ, Q.LINE_NO, Q.PAY_CD
      ,Q.SEQ_PAY_AMT, P.AM_PAY, P.AM_DC
      ,Q.SEQ_VAT_AMT, P.AM_VAT
      ,CASE WHEN Q.PAY_CD NOT IN ('01','02','03','04','05','06','07','08','10','11','12','13','14','17','18','19')
                                                                            THEN '3009'
            WHEN P.PAY_CD IS NULL                                           THEN '3004'
            WHEN Q.PAY_CD IN ('05','12')     AND Q.SEQ_PAY_AMT <> P.AM_DC   THEN '3001'
            WHEN Q.PAY_CD NOT IN ('05','12') AND Q.SEQ_PAY_AMT <> P.AM_PAY  THEN '3002'
            WHEN Q.PAY_CD NOT IN ('05','12') AND Q.SEQ_VAT_AMT <> P.AM_VAT  THEN '3003'
       END AS RESULT_CD
      ,CASE WHEN Q.PAY_CD NOT IN ('01','02','03','04','05','06','07','08','10','11','12','13','14','17','18','19')
              OR P.PAY_CD IS NULL THEN 'N (프로시저 ORA-20001 로 사망)' ELSE 'Y' END AS ORIG_DETECT
  FROM SEQ Q
  LEFT JOIN PAYDTL P
    ON  P.STORE_CD=Q.STORE_CD AND P.SALE_DATE=Q.SALE_DATE AND P.POS_NO=Q.POS_NO
    AND P.BILL_NO =Q.BILL_NO  AND P.LINE_NO  =Q.LINE_NO   AND P.PAY_CD=Q.PAY_CD
 WHERE Q.PAY_CD NOT IN ('01','02','03','04','05','06','07','08','10','11','12','13','14','17','18','19')
    OR P.PAY_CD IS NULL
    OR (Q.PAY_CD IN ('05','12')     AND Q.SEQ_PAY_AMT <> P.AM_DC)
    OR (Q.PAY_CD NOT IN ('05','12') AND (Q.SEQ_PAY_AMT <> P.AM_PAY OR Q.SEQ_VAT_AMT <> P.AM_VAT))
 ORDER BY Q.SALE_DATE, Q.STORE_CD, Q.POS_NO, Q.BILL_NO, Q.PAY_SEQ;


/* ==================================================================================================
   [I] PAY_SEQ vs HDR_PAY vs DTL_PAY  (PAY_CD 별 합계)
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_PAY_DATA 후반
     3101  해당 PAY_CD 가 HDR_PAY 에 없음
     3102  PAY_CD별 SUM(PAY_SEQ) <> HDR_PAY.PAY_AMT
     3201  해당 PAY_CD 가 DTL_PAY 에 없음
     3202  PAY_CD별 SUM(PAY_SEQ) <> SUM(DTL_PAY)
   원본 결함 → 이 쿼리의 처리
     3202 판정용 V_SEQ_SUM_AMT 가 3102 분기 안에서만 채워진다. HDR_PAY 는 맞고 DTL_PAY 만 틀리면
     NULL(또는 직전 반복의 값)과 비교되어 통과한다. 여기서는 PAY_CD 별 합계를 항상 계산해 비교한다.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
S AS (SELECT X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD, SUM(X.PAY_AMT) AMT
        FROM TB_SL_SALE_PAY_SEQ X, BILLS B
       WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO
         AND X.PAY_AMT <> 0
       GROUP BY X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD),
HP AS (SELECT X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD, SUM(X.PAY_AMT) AMT
        FROM TB_SL_SALE_HDR_PAY X, BILLS B
       WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO
       GROUP BY X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD),
DP AS (SELECT X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD, SUM(X.PAY_AMT) AMT
        FROM TB_SL_SALE_DTL_PAY X, BILLS B
       WHERE X.STORE_CD=B.STORE_CD AND X.SALE_DATE=B.SALE_DATE AND X.POS_NO=B.POS_NO AND X.BILL_NO=B.BILL_NO
       GROUP BY X.STORE_CD,X.SALE_DATE,X.POS_NO,X.BILL_NO,X.PAY_CD)
SELECT S.STORE_CD, S.SALE_DATE, S.POS_NO, S.BILL_NO, S.PAY_CD
      ,S.AMT AS SEQ_AMT, HP.AMT AS HDR_PAY_AMT, DP.AMT AS DTL_PAY_AMT
      ,CASE WHEN HP.PAY_CD IS NULL   THEN '3101'
            WHEN S.AMT <> HP.AMT     THEN '3102'
            WHEN DP.PAY_CD IS NULL   THEN '3201'
            WHEN S.AMT <> DP.AMT     THEN '3202' END AS RESULT_CD
      ,CASE WHEN HP.PAY_CD IS NOT NULL AND S.AMT = HP.AMT AND DP.PAY_CD IS NOT NULL AND S.AMT <> DP.AMT
            THEN 'N (V_SEQ_SUM_AMT 미계산)' ELSE 'Y' END AS ORIG_DETECT
  FROM S
  LEFT JOIN HP ON HP.STORE_CD=S.STORE_CD AND HP.SALE_DATE=S.SALE_DATE AND HP.POS_NO=S.POS_NO AND HP.BILL_NO=S.BILL_NO AND HP.PAY_CD=S.PAY_CD
  LEFT JOIN DP ON DP.STORE_CD=S.STORE_CD AND DP.SALE_DATE=S.SALE_DATE AND DP.POS_NO=S.POS_NO AND DP.BILL_NO=S.BILL_NO AND DP.PAY_CD=S.PAY_CD
 WHERE HP.PAY_CD IS NULL OR DP.PAY_CD IS NULL
    OR S.AMT <> HP.AMT   OR S.AMT <> DP.AMT
 ORDER BY S.SALE_DATE, S.STORE_CD, S.POS_NO, S.BILL_NO, S.PAY_CD;


/* ==================================================================================================
   [J] 할인 상세 정합성
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_DC_DTL_DATA
     2404  DTL 에 SALE_YN='Y' 이면서 DC_AMT < 0 또는 REAL_SALE_AMT < 0   (v3: 6303/6305 가 먼저 선점)
     2504  DTL_DC.DC_AMT > DTL.SALE_AMT
     2405  DTL_DC 에는 있는데 DTL 에 같은 BILL_DTL_NO 없음 (고아 할인행)
     2406  BILL_DTL_NO 별 SUM(DTL_DC.DC_AMT) <> DTL.DC_AMT
   원본 결함 → 이 쿼리의 처리
     (1) 이 블록은 V_DC_AMT_HDR <> 0 일 때만 실행됐다 → 헤더 할인 0 영수증은 전부 스킵. 여기는 조건 없음.
     (2) 2405 검출 후 RETURN 이 없어 직전 반복의 값과 비교해 2406 으로 덮이거나 정상 처리됐다.
     (3) 2406 메시지의 BILL_DTL_NO 가 치환되지 않아 어느 품목인지 알 수 없었다. 여기는 행 단위로 나온다.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, TOT_DC_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
)
-- 2404 : DTL 마이너스  (프로시저에서는 6303/6305 가 먼저 잡음)
SELECT '2404' RESULT_CD, A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO
      ,A.PROD_CD, A.SALE_AMT, A.DC_AMT AS DC_AMT_DTL, NULL AS DC_AMT_DTLDC, A.REAL_SALE_AMT
      ,'6303/6305 선점 → 2404 도달 불가' AS ORIG_DETECT
  FROM TB_SL_SALE_DTL A, BILLS B
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND A.SALE_YN='Y' AND (A.DC_AMT < 0 OR A.REAL_SALE_AMT < 0)
UNION ALL
-- 2504 : 할인 > 상품금액
SELECT '2504', A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO
      ,D.PROD_CD, D.SALE_AMT, D.DC_AMT, A.DC_AMT, D.REAL_SALE_AMT
      ,CASE WHEN B.TOT_DC_AMT = 0 THEN 'N (헤더할인 0 → 블록 미실행)' ELSE 'Y' END
  FROM TB_SL_SALE_DTL_DC A, TB_SL_SALE_DTL D, BILLS B
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND D.STORE_CD=A.STORE_CD AND D.SALE_DATE=A.SALE_DATE AND D.POS_NO=A.POS_NO AND D.BILL_NO=A.BILL_NO
   AND D.BILL_DTL_NO=A.BILL_DTL_NO
   AND A.SALE_YN='Y' AND A.DC_AMT > D.SALE_AMT
UNION ALL
-- 2405 / 2406 : 고아 할인행 / BILL_DTL_NO 별 합계 불일치
SELECT CASE WHEN D.BILL_DTL_NO IS NULL THEN '2405' ELSE '2406' END
      ,X.STORE_CD, X.SALE_DATE, X.POS_NO, X.BILL_NO, X.BILL_DTL_NO
      ,D.PROD_CD, D.SALE_AMT, D.DC_AMT, X.SUM_DC_AMT, D.REAL_SALE_AMT
      ,CASE WHEN B.TOT_DC_AMT = 0        THEN 'N (헤더할인 0 → 블록 미실행)'
            WHEN D.BILL_DTL_NO IS NULL   THEN 'N (2405 후 RETURN 누락으로 오판정)'
            ELSE 'Y' END
  FROM (SELECT A.STORE_CD,A.SALE_DATE,A.POS_NO,A.BILL_NO,A.BILL_DTL_NO, SUM(A.DC_AMT) SUM_DC_AMT
          FROM TB_SL_SALE_DTL_DC A, BILLS B
         WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
         GROUP BY A.STORE_CD,A.SALE_DATE,A.POS_NO,A.BILL_NO,A.BILL_DTL_NO) X
  JOIN BILLS B ON B.STORE_CD=X.STORE_CD AND B.SALE_DATE=X.SALE_DATE AND B.POS_NO=X.POS_NO AND B.BILL_NO=X.BILL_NO
  LEFT JOIN TB_SL_SALE_DTL D
    ON D.STORE_CD=X.STORE_CD AND D.SALE_DATE=X.SALE_DATE AND D.POS_NO=X.POS_NO AND D.BILL_NO=X.BILL_NO
   AND D.BILL_DTL_NO=X.BILL_DTL_NO
 WHERE D.BILL_DTL_NO IS NULL OR X.SUM_DC_AMT <> D.DC_AMT
 ORDER BY 3,2,4,5,6;


/* ==================================================================================================
   [K] 상품 마스터 / 세트(선택메뉴) 구성
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_PROD_INFO
     5P04  SALE_YN='Y' 인데 PROD_CD 가 해당 매장 TB_MS_PRODUCT 에 없음 (반품은 검사 안 함)
     5P12  세트 구성상품인데 SDSEL_CLASS_CD 가 NULL
     5P33  세트 모상품은 있는데 하위 구성상품이 하나도 없음
   원본 결함 → 이 쿼리의 처리
     (1) 5P12 : 조회 조건에 값이 한 번도 대입되지 않은 V_STORE_CD 등을 써서 항상 0건 → 한 번도 발동한 적 없음.
     (2) 5P33 : 구성상품 카운터가 루프마다 초기화되지 않아 두 번째 이후 세트 모상품은 검사되지 않았다.
     (3) 5P11 은 절대 NULL 이 될 수 없는 변수를 검사하는 죽은 코드라 제외. 5P40 은 주석 처리 상태라 제외.
   세트 구조 : TB_MS_PRODUCT.SDSEL_GRP_CD 가 있는 상품 = 모상품. 하위 구성상품은 SIDE_P_DTL_NO 에 모상품의 BILL_DTL_NO.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
)
SELECT '5P04' RESULT_CD, A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO
      ,A.PROD_CD, A.SIDE_P_DTL_NO, A.SDSEL_CLASS_CD, 'Y' AS ORIG_DETECT
  FROM TB_SL_SALE_DTL A, BILLS B
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND A.SALE_YN='Y'
   AND NOT EXISTS (SELECT 1 FROM TB_MS_PRODUCT P WHERE P.STORE_CD=A.STORE_CD AND P.PROD_CD=A.PROD_CD)
UNION ALL
SELECT '5P12', A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO
      ,A.PROD_CD, A.SIDE_P_DTL_NO, A.SDSEL_CLASS_CD, 'N (변수 미대입 → 항상 0건)'
  FROM TB_SL_SALE_DTL A, BILLS B
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND A.SIDE_P_DTL_NO IS NOT NULL
   AND A.SIDE_P_DTL_NO <> A.BILL_DTL_NO
   AND A.SDSEL_CLASS_CD IS NULL
UNION ALL
SELECT '5P33', A.STORE_CD, A.SALE_DATE, A.POS_NO, A.BILL_NO, A.BILL_DTL_NO
      ,A.PROD_CD, A.SIDE_P_DTL_NO, A.SDSEL_CLASS_CD
      ,CASE WHEN ROW_NUMBER() OVER (PARTITION BY A.STORE_CD,A.SALE_DATE,A.POS_NO,A.BILL_NO ORDER BY A.BILL_DTL_NO) = 1
            THEN 'Y' ELSE 'N (카운터 미초기화 → 2번째 이후 미검사)' END
  FROM TB_SL_SALE_DTL A, TB_MS_PRODUCT P, BILLS B
 WHERE A.STORE_CD=B.STORE_CD AND A.SALE_DATE=B.SALE_DATE AND A.POS_NO=B.POS_NO AND A.BILL_NO=B.BILL_NO
   AND P.STORE_CD=A.STORE_CD AND P.PROD_CD=A.PROD_CD
   AND P.SDSEL_GRP_CD IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM TB_SL_SALE_DTL C
                    WHERE C.STORE_CD=A.STORE_CD AND C.SALE_DATE=A.SALE_DATE AND C.POS_NO=A.POS_NO AND C.BILL_NO=A.BILL_NO
                      AND C.SIDE_P_DTL_NO=A.BILL_DTL_NO AND C.BILL_DTL_NO<>A.BILL_DTL_NO)
 ORDER BY 3,2,4,5,6;


/* ==================================================================================================
   [L] 최종 4자 대사 (NE01)          ★ v3: 벤슨은 미실행
   --------------------------------------------------------------------------------------------------
   프로시저 : CHECK_PKG_NEOE. 재업로드 소스에서 V_HQ_OFFICE_CD = 'A0001' 일 때만 호출되도록 바뀜.
   벤슨(H0665)은 이 체크를 타지 않으므로 프로시저 결과와 비교할 때는 이 블록을 제외한다.
   참고용으로만 남긴다. 관계식 : TOT_SALE_AMT = SUM(HDR_PAY)+SUM(HDR_DC) = SUM(PAY_SEQ) = SUM(DTL.SALE_AMT)
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, TOT_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
HP AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(PAY_AMT)  AMT FROM TB_SL_SALE_HDR_PAY WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
HD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(DC_AMT)   AMT FROM TB_SL_SALE_HDR_DC  WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
S  AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(PAY_AMT)  AMT FROM TB_SL_SALE_PAY_SEQ WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
D  AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,SUM(SALE_AMT) AMT FROM TB_SL_SALE_DTL     WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO)
SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO
      ,B.TOT_SALE_AMT
      ,NVL(HP.AMT,0) + NVL(HD.AMT,0) AS PAY_PLUS_DC
      ,NVL(S.AMT,0)  AS PAY_SEQ_AMT
      ,NVL(D.AMT,0)  AS DTL_AMT
      ,'NE01' AS RESULT_CD
  FROM BILLS B
  LEFT JOIN HP ON HP.STORE_CD=B.STORE_CD AND HP.SALE_DATE=B.SALE_DATE AND HP.POS_NO=B.POS_NO AND HP.BILL_NO=B.BILL_NO
  LEFT JOIN HD ON HD.STORE_CD=B.STORE_CD AND HD.SALE_DATE=B.SALE_DATE AND HD.POS_NO=B.POS_NO AND HD.BILL_NO=B.BILL_NO
  LEFT JOIN S  ON S.STORE_CD =B.STORE_CD AND S.SALE_DATE =B.SALE_DATE AND S.POS_NO =B.POS_NO AND S.BILL_NO =B.BILL_NO
  LEFT JOIN D  ON D.STORE_CD =B.STORE_CD AND D.SALE_DATE =B.SALE_DATE AND D.POS_NO =B.POS_NO AND D.BILL_NO =B.BILL_NO
 WHERE B.TOT_SALE_AMT <> NVL(HP.AMT,0) + NVL(HD.AMT,0)
    OR B.TOT_SALE_AMT <> NVL(S.AMT,0)
    OR B.TOT_SALE_AMT <> NVL(D.AMT,0)
 ORDER BY B.SALE_DATE, B.STORE_CD, B.POS_NO, B.BILL_NO;


/* ==================================================================================================
   [Z] 통합 판정 — 영수증당 대표 오류 1건  (원본 프로시저 판정 vs 결함 제거 판정)   ★ v3 반영
   --------------------------------------------------------------------------------------------------
   집계를 한 번만 만들고 CASE 를 프로시저 실행 순서대로 쌓아 "첫 오류에서 RETURN" 을 재현했다.
     ORIG_CD  : 지금 프로시저가 반환했을 코드 (결함 포함 그대로 흉내냄)
     FIXED_CD : 결함을 제거했을 때의 코드
     DIFF     : 두 판정이 다르면 'Y' — 프로시저가 놓치고 있던 건

   판정 순서 (재업로드 소스 기준)
     1404 → 4404 → 3404 → [4414 → 5404] → 6404 → 7404
     → 9211 → 9212 → 9023 → 9001 → 9002 → 9003 → 9004
     → 8001 / 8801(벤슨) → 8002 → 8003 → 7001 → 6001 → 6002
     → 6103 → 6102 → 6303 → 6305 → 6405 → 6505 → 5001 → 5003 → NE01(A0001 만)
   결제수단별(3xxx) / 세트구성(5Pxx) 은 행 단위라 [H][I][K] 로 따로 본다. ORIG_CD 에서 이들은 '0000' 취급.
   ================================================================================================== */
WITH BILLS AS (
    SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, HQ_OFFICE_CD, SALE_YN
          ,TOT_SALE_AMT, TOT_DC_AMT, VAT_AMT, NET_SALE_AMT, REAL_SALE_AMT
      FROM TB_SL_SALE_HDR
     WHERE HQ_OFFICE_CD = '&HQ_OFFICE_CD'
       AND SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
),
D AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO, COUNT(*) CNT
            ,SUM(SALE_AMT) SALE_AMT, SUM(DC_AMT) DC_AMT, SUM(REAL_SALE_AMT) REAL_AMT, SUM(VAT_AMT) VAT_AMT
            ,SUM(CASE WHEN VAT_AMT       < 0 THEN 1 ELSE 0 END)                 MINUS_VAT_CNT
            ,SUM(CASE WHEN REAL_SALE_AMT < 0 THEN 1 ELSE 0 END)                 MINUS_REAL_CNT
            ,SUM(CASE WHEN DC_AMT        < 0 THEN 1 ELSE 0 END)                 MINUS_DC_CNT
            ,SUM(CASE WHEN ABS(SALE_AMT) < ABS(DC_AMT) THEN 1 ELSE 0 END)       OVER_DC_CNT
            ,SUM(CASE WHEN SALE_AMT - DC_AMT <> REAL_SALE_AMT THEN 1 ELSE 0 END) ERR_5001
            ,SUM(DECODE(SUBSTRB(PROD_CD,1,4),'LYNK',ERP_SEND_AMT,SALE_AMT))     ERP_SEND_AMT
        FROM TB_SL_SALE_DTL WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
       GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
DD5003 AS (
    SELECT A.STORE_CD,A.SALE_DATE,A.POS_NO,A.BILL_NO
          ,SUM(CASE WHEN X.SUM_DC IS NOT NULL AND A.DC_AMT <> X.SUM_DC THEN 1 ELSE 0 END) ERR_ORIG
          ,SUM(CASE WHEN A.DC_AMT <> NVL(X.SUM_DC,0) THEN 1 ELSE 0 END)                   ERR_FIXED
      FROM TB_SL_SALE_DTL A
      LEFT JOIN (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,BILL_DTL_NO,SUM(DC_AMT) SUM_DC
                   FROM TB_SL_SALE_DTL_DC WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
                  GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO,BILL_DTL_NO) X
        ON X.STORE_CD=A.STORE_CD AND X.SALE_DATE=A.SALE_DATE AND X.POS_NO=A.POS_NO AND X.BILL_NO=A.BILL_NO
       AND X.BILL_DTL_NO=A.BILL_DTL_NO
     WHERE A.SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
     GROUP BY A.STORE_CD,A.SALE_DATE,A.POS_NO,A.BILL_NO),
S AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO, COUNT(*) CNT
            ,SUM(DECODE(PAY_CD,'05',0,'12',0,PAY_AMT))       REAL_AMT
            ,SUM(DECODE(PAY_CD,'05',PAY_AMT,'12',PAY_AMT,0)) DC_AMT
            ,SUM(VAT_AMT)                                    VAT_AMT
            ,SUM(DECODE(PAY_CD,'04',VAT_AMT,0))              POINT_VAT
            ,SUM(PAY_AMT)                                    PAY_ALL
        FROM TB_SL_SALE_PAY_SEQ WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE'
       GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
E AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO, SUM(DC_AMT) ETC_DC
        FROM TB_SL_SALE_HDR_DC
       WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' AND DC_CD NOT IN ('02','12','05')
       GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
HP AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,COUNT(*) CNT,SUM(PAY_AMT) AMT FROM TB_SL_SALE_HDR_PAY WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
DP AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,COUNT(*) CNT,SUM(PAY_AMT) AMT FROM TB_SL_SALE_DTL_PAY WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
HD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,COUNT(*) CNT,SUM(DC_AMT)  AMT FROM TB_SL_SALE_HDR_DC  WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
DD AS (SELECT STORE_CD,SALE_DATE,POS_NO,BILL_NO,COUNT(*) CNT,SUM(DC_AMT)  AMT FROM TB_SL_SALE_DTL_DC  WHERE SALE_DATE BETWEEN '&FROM_DATE' AND '&TO_DATE' GROUP BY STORE_CD,SALE_DATE,POS_NO,BILL_NO),
JUDGE AS (
    SELECT B.STORE_CD, B.SALE_DATE, B.POS_NO, B.BILL_NO, B.SALE_YN
          ,B.TOT_SALE_AMT, B.TOT_DC_AMT, B.VAT_AMT, B.NET_SALE_AMT, B.REAL_SALE_AMT
          ,D.SALE_AMT DTL_SALE, D.DC_AMT DTL_DC, D.VAT_AMT DTL_VAT, D.REAL_AMT DTL_REAL
          ,S.REAL_AMT SEQ_REAL, S.DC_AMT SEQ_DC, S.VAT_AMT SEQ_VAT, E.ETC_DC
          ,HP.AMT HDRPAY_AMT, HD.AMT HDRDC_AMT, DD.AMT DTLDC_AMT
          -- ---------------- 원본 프로시저 판정 (결함 그대로) ----------------
          ,CASE
             WHEN B.TOT_SALE_AMT IS NULL                          THEN '1404'
             WHEN D.CNT IS NULL                                   THEN '4404'
             WHEN S.CNT IS NULL                                   THEN '3404'
             WHEN B.TOT_DC_AMT <> 0 AND HD.CNT IS NULL            THEN '6404'
             WHEN B.TOT_DC_AMT <> 0 AND DD.CNT IS NULL            THEN '7404'
             WHEN B.SALE_YN='Y' AND B.REAL_SALE_AMT < 0           THEN '9211'
             WHEN B.SALE_YN='N' AND B.REAL_SALE_AMT > 0           THEN '9212'
             WHEN B.NET_SALE_AMT + B.VAT_AMT <> B.REAL_SALE_AMT   THEN '9023'
             WHEN B.TOT_SALE_AMT  <> D.SALE_AMT                   THEN '9001'
             WHEN B.TOT_DC_AMT    <> D.DC_AMT                     THEN '9002'
             WHEN (B.SALE_DATE >  '20210206' AND B.VAT_AMT <> D.VAT_AMT)
               OR (B.SALE_DATE <= '20210206' AND ABS(B.VAT_AMT) <> ABS(D.VAT_AMT)) THEN '9003'
             WHEN B.REAL_SALE_AMT <> D.REAL_AMT                   THEN '9004'
             WHEN B.HQ_OFFICE_CD NOT IN ('H0393','H0665') AND B.TOT_DC_AMT <> S.DC_AMT THEN '8001'
             WHEN B.HQ_OFFICE_CD = 'H0665' AND B.TOT_DC_AMT <> S.DC_AMT
              AND E.ETC_DC IS NOT NULL                                              -- NULL 이면 통과(결함)
              AND B.TOT_DC_AMT <> S.DC_AMT + E.ETC_DC              THEN '8801'
             WHEN B.VAT_AMT       <> S.VAT_AMT                    THEN '8002'
             WHEN B.REAL_SALE_AMT <> S.REAL_AMT                   THEN '8003'
             WHEN HP.AMT IS NOT NULL AND B.REAL_SALE_AMT <> HP.AMT THEN '7001'      -- NULL 이면 통과(결함)
             WHEN B.TOT_DC_AMT <> 0 AND B.TOT_DC_AMT <> NVL(HD.AMT,0) THEN '6001'   -- 할인 0 이면 미조회(결함)
             WHEN B.TOT_DC_AMT <> 0 AND B.TOT_DC_AMT <> NVL(DD.AMT,0) THEN '6002'
             WHEN NVL(S.POINT_VAT,0) <> 0 AND B.SALE_DATE > '20250207' THEN '6103'
             WHEN B.SALE_YN='Y' AND D.MINUS_VAT_CNT  > 0          THEN '6102'
             WHEN B.SALE_YN='Y' AND D.MINUS_REAL_CNT > 0          THEN '6303'
             WHEN B.SALE_YN='Y' AND D.MINUS_DC_CNT   > 0          THEN '6305'
             WHEN D.OVER_DC_CNT > 0                               THEN '6405'
             WHEN NVL(B.TOT_SALE_AMT,0) <> NVL(D.ERP_SEND_AMT,0)  THEN '6505'
             WHEN D.ERR_5001 > 0                                  THEN '5001'
             WHEN Z.ERR_ORIG > 0                                  THEN '5003'
             WHEN B.HQ_OFFICE_CD = 'A0001'
              AND ( B.TOT_SALE_AMT <> NVL(HP.AMT,0) + NVL(HD.AMT,0)
                 OR B.TOT_SALE_AMT <> NVL(S.PAY_ALL,0)
                 OR B.TOT_SALE_AMT <> NVL(D.SALE_AMT,0) )         THEN 'NE01'
             ELSE '0000' END AS ORIG_CD
          -- ---------------- 결함 제거 판정 ----------------
          ,CASE
             WHEN B.TOT_SALE_AMT IS NULL                          THEN '1404'
             WHEN D.CNT IS NULL                                   THEN '4404'
             WHEN S.CNT IS NULL                                   THEN '3404'
             WHEN HP.CNT IS NULL                                  THEN '4414'
             WHEN DP.CNT IS NULL                                  THEN '5404'
             WHEN B.TOT_DC_AMT <> 0 AND HD.CNT IS NULL            THEN '6404'
             WHEN B.TOT_DC_AMT <> 0 AND DD.CNT IS NULL            THEN '7404'
             WHEN B.SALE_YN='Y' AND B.REAL_SALE_AMT < 0           THEN '9211'
             WHEN B.SALE_YN='N' AND B.REAL_SALE_AMT > 0           THEN '9212'
             WHEN B.NET_SALE_AMT + B.VAT_AMT <> B.REAL_SALE_AMT   THEN '9023'
             WHEN B.TOT_SALE_AMT  <> D.SALE_AMT                   THEN '9001'
             WHEN B.TOT_DC_AMT    <> D.DC_AMT                     THEN '9002'
             WHEN (B.SALE_DATE >  '20210206' AND B.VAT_AMT <> D.VAT_AMT)
               OR (B.SALE_DATE <= '20210206' AND ABS(B.VAT_AMT) <> ABS(D.VAT_AMT)) THEN '9003'
             WHEN B.REAL_SALE_AMT <> D.REAL_AMT                   THEN '9004'
             WHEN B.HQ_OFFICE_CD NOT IN ('H0393','H0665') AND B.TOT_DC_AMT <> S.DC_AMT THEN '8001'
             WHEN B.HQ_OFFICE_CD = 'H0665' AND B.TOT_DC_AMT <> S.DC_AMT
              AND B.TOT_DC_AMT <> S.DC_AMT + NVL(E.ETC_DC,0)      THEN '8801'
             WHEN B.VAT_AMT       <> S.VAT_AMT                    THEN '8002'
             WHEN B.REAL_SALE_AMT <> S.REAL_AMT                   THEN '8003'
             WHEN B.REAL_SALE_AMT <> NVL(HP.AMT,0)                THEN '7001'
             WHEN B.TOT_DC_AMT    <> NVL(HD.AMT,0)                THEN '6001'
             WHEN B.TOT_DC_AMT    <> NVL(DD.AMT,0)                THEN '6002'
             WHEN NVL(S.POINT_VAT,0) <> 0 AND B.SALE_DATE > '20250207' THEN '6103'
             WHEN B.SALE_YN='Y' AND D.MINUS_VAT_CNT  > 0          THEN '6102'
             WHEN B.SALE_YN='Y' AND D.MINUS_REAL_CNT > 0          THEN '6303'
             WHEN B.SALE_YN='Y' AND D.MINUS_DC_CNT   > 0          THEN '6305'
             WHEN D.OVER_DC_CNT > 0                               THEN '6405'
             WHEN NVL(B.TOT_SALE_AMT,0) <> NVL(D.ERP_SEND_AMT,0)  THEN '6505'
             WHEN D.ERR_5001 > 0                                  THEN '5001'
             WHEN Z.ERR_FIXED > 0                                 THEN '5003'
             WHEN B.HQ_OFFICE_CD = 'A0001'
              AND ( B.TOT_SALE_AMT <> NVL(HP.AMT,0) + NVL(HD.AMT,0)
                 OR B.TOT_SALE_AMT <> NVL(S.PAY_ALL,0)
                 OR B.TOT_SALE_AMT <> NVL(D.SALE_AMT,0) )         THEN 'NE01'
             ELSE '0000' END AS FIXED_CD
      FROM BILLS B
      LEFT JOIN D      ON D.STORE_CD=B.STORE_CD AND D.SALE_DATE=B.SALE_DATE AND D.POS_NO=B.POS_NO AND D.BILL_NO=B.BILL_NO
      LEFT JOIN DD5003 Z ON Z.STORE_CD=B.STORE_CD AND Z.SALE_DATE=B.SALE_DATE AND Z.POS_NO=B.POS_NO AND Z.BILL_NO=B.BILL_NO
      LEFT JOIN S      ON S.STORE_CD=B.STORE_CD AND S.SALE_DATE=B.SALE_DATE AND S.POS_NO=B.POS_NO AND S.BILL_NO=B.BILL_NO
      LEFT JOIN E      ON E.STORE_CD=B.STORE_CD AND E.SALE_DATE=B.SALE_DATE AND E.POS_NO=B.POS_NO AND E.BILL_NO=B.BILL_NO
      LEFT JOIN HP     ON HP.STORE_CD=B.STORE_CD AND HP.SALE_DATE=B.SALE_DATE AND HP.POS_NO=B.POS_NO AND HP.BILL_NO=B.BILL_NO
      LEFT JOIN DP     ON DP.STORE_CD=B.STORE_CD AND DP.SALE_DATE=B.SALE_DATE AND DP.POS_NO=B.POS_NO AND DP.BILL_NO=B.BILL_NO
      LEFT JOIN HD     ON HD.STORE_CD=B.STORE_CD AND HD.SALE_DATE=B.SALE_DATE AND HD.POS_NO=B.POS_NO AND HD.BILL_NO=B.BILL_NO
      LEFT JOIN DD     ON DD.STORE_CD=B.STORE_CD AND DD.SALE_DATE=B.SALE_DATE AND DD.POS_NO=B.POS_NO AND DD.BILL_NO=B.BILL_NO
)
SELECT STORE_CD, SALE_DATE, POS_NO, BILL_NO, SALE_YN
      ,ORIG_CD, FIXED_CD
      ,CASE WHEN ORIG_CD <> FIXED_CD THEN 'Y' ELSE ' ' END AS DIFF
      ,TOT_SALE_AMT, TOT_DC_AMT, VAT_AMT, NET_SALE_AMT, REAL_SALE_AMT
      ,DTL_SALE, DTL_DC, DTL_VAT, DTL_REAL
      ,SEQ_REAL, SEQ_DC, SEQ_VAT, ETC_DC
      ,HDRPAY_AMT, HDRDC_AMT, DTLDC_AMT
  FROM JUDGE
 WHERE FIXED_CD <> '0000'                 -- 정상까지 보려면 주석 처리
 ORDER BY SALE_DATE, FIXED_CD, STORE_CD, POS_NO, BILL_NO;


/* ==================================================================================================
   [Z-2] 일자별 요약 — 원본 판정 vs 수정 판정
   --------------------------------------------------------------------------------------------------
   [Z] 의 WITH 절 전체(BILLS ~ JUDGE)를 그대로 복사한 뒤, 마지막 SELECT 만 아래로 바꾼다.

   -- 코드별
   SELECT SALE_DATE, FIXED_CD, COUNT(*) CNT
         ,SUM(CASE WHEN ORIG_CD = FIXED_CD THEN 1 ELSE 0 END) AS SAME_AS_ORIG
         ,SUM(CASE WHEN ORIG_CD <> FIXED_CD THEN 1 ELSE 0 END) AS NEWLY_FOUND
     FROM JUDGE
    GROUP BY SALE_DATE, FIXED_CD
    ORDER BY SALE_DATE, FIXED_CD;

   -- 정상/오류 2분류 (SEND_DOORAY_TODAY_SUMMARY 가 만들던 요약과 동일 형태)
   SELECT SALE_DATE
         ,SUM(CASE WHEN FIXED_CD = '0000' THEN 1 ELSE 0 END) AS OK_CNT
         ,SUM(CASE WHEN FIXED_CD <> '0000' THEN 1 ELSE 0 END) AS ERR_CNT
         ,SUM(CASE WHEN ORIG_CD = '0000' AND FIXED_CD <> '0000' THEN 1 ELSE 0 END) AS ERR_MISSED_BY_PROC
         ,COUNT(*) AS TOT_CNT
     FROM JUDGE
    GROUP BY SALE_DATE
    ORDER BY SALE_DATE;
   ================================================================================================== */


/* ==================================================================================================
   부록. 결과코드 일람  (블록 / 원본 프로시저 검출 여부)   — 재업로드 소스 기준
   --------------------------------------------------------------------------------------------------
   1404  헤더 없음                              [A]    O
   4404  DTL 없음                               [A]    O
   3404  PAY_SEQ 없음                           [A]    O
   4414  HDR_PAY 없음  (신규코드)               [A]    X  SUM→NULL 로 미검출
   5404  DTL_PAY 없음                           [A]    X  SUM→NULL 로 미검출
   6404  HDR_DC 없음   (헤더할인<>0)            [A]    O
   7404  DTL_DC 없음   (헤더할인<>0)            [A]    O
   9211  SALE_YN=Y 실매출 음수                  [B]    O
   9212  SALE_YN=N 실매출 양수                  [B]    O
   9023  NET+VAT <> REAL                        [B]    O
   9001~9004  헤더 vs DTL 합계                  [C]    O
   8001  헤더 vs PAY_SEQ 할인 (벤슨 외)         [D]    O
   8801  헤더 vs PAY_SEQ+ETC 할인 (벤슨) v3     [D]    △  ETC SUM NULL 이면 통과
   8002/8003  헤더 vs PAY_SEQ 부가세/결제       [D]    O
   7001  헤더 vs HDR_PAY                        [E]    △  HDR_PAY 없으면 NULL 통과
   6001/6002  헤더 vs HDR_DC / DTL_DC           [E]    △  헤더할인 0 이면 미조회
   6103  포인트 부가세 <> 0                     [F]    O
   6102  DTL 음수 부가세                        [F]    O
   6303  DTL 음수 실매출  v3                    [F]    O
   6305  DTL 음수 할인    v3                    [F]    O
   6405  상품금액 < 할인                        [F]    O
   6505  ERP 전송금액 불일치                    [F]    O  (메시지만 오표기)
   5001  DTL SALE-DC <> REAL                    [G]    O
   5003  DTL.DC <> DTL_DC 합계                  [G]    △  DTL_DC 행 없으면 NULL 통과
   3001~3003  결제상세 금액/부가세              [H]    O
   3004  결제상세 행 없음 (신규코드)            [H]    X  NO_DATA_FOUND 로 사망
   3009  미지원 PAY_CD (신규코드)               [H]    X  CASE_NOT_FOUND 로 사망
   3101/3102  PAY_SEQ vs HDR_PAY                [I]    O
   3201  DTL_PAY 없음                           [I]    O
   3202  PAY_SEQ vs DTL_PAY                     [I]    △  HDR_PAY 일치 시 미검출
   2404  DTL 마이너스                           [J]    -  v3: 6303/6305 가 선점하여 도달 불가
   2504  DTL_DC 할인 > 상품금액                 [J]    △  헤더할인 0 이면 블록 미실행
   2405  DTL_DC 고아행                          [J]    △  RETURN 누락으로 오판정
   2406  BILL_DTL_NO 별 할인 불일치             [J]    △  상동 + 메시지 변수 미치환
   5P04  상품마스터 없음                        [K]    O
   5P12  구성상품 CLASS_CD NULL                 [K]    X  변수 미대입으로 항상 0건
   5P33  모상품 구성상품 없음                   [K]    △  2번째 이후 모상품 미검사
   NE01  최종 4자 대사                          [L]    -  v3: 본부 A0001 만 실행. 벤슨 미실행
   ================================================================================================== */
