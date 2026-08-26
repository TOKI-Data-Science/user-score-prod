create table t_user_score_wallet_temp as 
with balance_raw as (
  select
    r.identifier,
    r.month,
    avg(r.balance)                      as avg_balance,
    min(r.balance)                      as min_balance,
    max(r.balance)                      as max_balance
  from (
    select
      identifier,
      to_char(to_date(p_date, 'YYYYMMDD'), 'YYYYMM') as month,
      balance
    from toki.dpr_maat_remains
    where to_number(p_date) between to_number(to_char(add_months(trunc(sysdate) - 1, -6), 'YYYYMMDD')) and to_number(to_char(trunc(sysdate) - 1, 'YYYYMMDD'))
  ) r
  group by r.identifier, r.month
),
balance_base as (
  select
    a.user_id,
    a.base_month,
    b.month,
    b.avg_balance,
    b.min_balance,
    b.max_balance,
    case when to_number(b.month) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -3), 'yyyymm'))
    then 1 else 0 end as is_w3m,
    case when to_number(b.month) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
    then 1 else 0 end as is_w1m
  from t_temp_union_pool a
  inner join balance_raw b on a.user_id = b.identifier
    and to_number(b.month) between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -6), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
)

select
  user_id,
  base_month,

  max(avg_balance)                                                         as max_balance_w_6m,
  avg(min_balance)                                                         as avg_min_balance_w_6m,
  min(min_balance)                                                         as min_min_balance_w_6m,
  max(case when is_w3m = 1 then max_balance end)                           as max_max_balance_w_3m,
  avg(case when is_w1m = 1 then avg_balance end)                           as avg_balance_w_1m

from balance_base
group by user_id, base_month
order by user_id;

create table t_user_score_transaction_temp as
WITH raw_transaction AS (
    SELECT 
        MAX(T.CUSTOMER_ACCOUNT_IDENTIFIER) AS userid,
        T.IDENTIFIER AS transaction_id,
        MAX(T.TRANSACTION_DATE) AS transaction_date,
        TO_CHAR(MAX(T.TRANSACTION_DATE), 'YYYYMM') AS transaction_month,
        MAX(T.AMOUNT) AS amount,
        MAX(T.TARGET_ACCOUNT_IDENTIFIER) AS target_id,
        MAX(REQUEST_TYPE) AS request_type,
        MAX(BANK_NAME) AS bank_name,
        MIN(
            CASE
                WHEN T1.CUSTOMER_ACCOUNT_IDENTIFIER IS NULL THEN 'Debit'
                WHEN T1.TRANSACTION_TYPE LIKE '%M2P%' THEN 'Credit'
                WHEN REQUEST_TYPE LIKE '%CARD%' THEN 'Saved card'
                WHEN BANK_NAME LIKE 'Golomt%' THEN 'SocialPay'
                WHEN BANK_NAME LIKE 'Khan%' THEN 'QPay'
            END
        ) AS ptype
    FROM (
        SELECT *
        FROM TOKI.DPR_TAJET_TELLER_TRANSACTIONS
        WHERE TRANSACTION_TYPE LIKE '%P2M%'
          AND TRANSACTION_DATE BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1
    ) T
    LEFT JOIN (
        SELECT 
            T.CUSTOMER_ACCOUNT_IDENTIFIER, 
            TRANSACTION_TYPE, 
            TRANSACTION_DATE, 
            T.AMOUNT, 
            T1.REQUEST_TYPE, 
            BANK_NAME
        FROM TOKI.DPR_TAJET_TELLER_TRANSACTIONS T
        LEFT JOIN TOKI.DPR_TAJET_TELLER_EXTERNAL_TRANSACTIONS T1 
            ON T.IDENTIFIER = T1.TRANSACTION_ID
        WHERE TRANSACTION_TYPE LIKE '%BDPT%'
          AND T.TRANSACTION_DATE BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1
        
        UNION
        
        SELECT 
            TARGET_ACCOUNT_IDENTIFIER,
            TRANSACTION_TYPE,
            TRANSACTION_DATE,
            AMOUNT,
            'Credit' AS REQUEST_TYPE,
            'Credit' AS BANK_NAME
        FROM TOKI.DPR_TAJET_TELLER_TRANSACTIONS
        WHERE TRANSACTION_TYPE LIKE '%M2P%'
          AND TRANSACTION_DATE BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1
    ) T1 
    ON T.CUSTOMER_ACCOUNT_IDENTIFIER = T1.CUSTOMER_ACCOUNT_IDENTIFIER 
    AND T.AMOUNT = T1.AMOUNT 
    AND T.TRANSACTION_DATE > T1.TRANSACTION_DATE
    AND T.TRANSACTION_DATE < T1.TRANSACTION_DATE + INTERVAL '60' SECOND
    GROUP BY T.IDENTIFIER
),
transaction_with_lag AS (
    SELECT 
        userid,
        transaction_id,
        target_id,
        transaction_date,
        transaction_month,
        amount,
        ptype
    FROM raw_transaction
),
transaction_features AS (
    SELECT 
        userid,
        transaction_month,
        COUNT(*) AS trans_count,
        SUM(amount) AS trans_amount,
        SUM(CASE WHEN ptype = 'Credit' THEN 1 ELSE 0 END) AS trans_count_credit,
        SUM(CASE WHEN ptype = 'Credit' THEN amount ELSE 0 END) AS trans_amount_credit,
        SUM(CASE WHEN ptype = 'Saved card' THEN amount ELSE 0 END) AS trans_amount_card
    FROM transaction_with_lag
    GROUP BY userid, transaction_month
),
time_of_day_activity AS (
    SELECT 
        userid,
        transaction_month,
        CASE 
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '00' AND '05' THEN 'night'
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '06' AND '11' THEN 'morning'
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '12' AND '17' THEN 'afternoon'
            ELSE 'evening'
        END AS time_of_day,
        COUNT(*) AS time_of_day_count
    FROM transaction_with_lag
    GROUP BY userid, transaction_month, 
        CASE 
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '00' AND '05' THEN 'night'
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '06' AND '11' THEN 'morning'
            WHEN TO_CHAR(transaction_date, 'HH24') BETWEEN '12' AND '17' THEN 'afternoon'
            ELSE 'evening'
        END
),
time_of_day_percentages AS (
    SELECT 
        userid,
        transaction_month,
        SUM(CASE WHEN time_of_day = 'night' THEN time_of_day_count ELSE 0 END) AS night_count,
        SUM(CASE WHEN time_of_day = 'morning' THEN time_of_day_count ELSE 0 END) AS morning_count
    FROM time_of_day_activity
    GROUP BY userid, transaction_month
),
transaction_monthly as (
    SELECT 
        tf.userid,
        tf.transaction_month,
        tf.trans_count,
        tf.trans_amount,
        tf.trans_count_credit,
        tf.trans_amount_credit,
        tf.trans_amount_card,
        tdp.night_count,
        tdp.morning_count
    FROM transaction_features tf
    LEFT JOIN time_of_day_percentages tdp 
    ON tf.userid = tdp.userid AND tf.transaction_month = tdp.transaction_month
    ORDER BY tf.userid, tf.transaction_month
),
transaction_raw as (
    select
        a.user_id,
        a.base_month,
        b.transaction_month,
        b.trans_count,
        b.trans_amount,
        b.trans_count_credit,
        b.trans_amount_credit,
        b.trans_amount_card,
        b.night_count,
        b.morning_count,
        case when to_number(b.transaction_month) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -3), 'yyyymm'))
        then 1 else 0 end as is_w3m,
        case when to_number(b.transaction_month) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
        then 1 else 0 end as is_w1m
    from t_temp_union_pool a
    inner join transaction_monthly b on a.user_id = b.userid
        and to_number(b.transaction_month) between
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -6), 'yyyymm'))
            and to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
)

select
    user_id,
    base_month,

    max(trans_count)                                                             as max_trans_cnt_w_6m,
    round(stddev(trans_amount), 2)                                               as std_trans_amt_w_6m,
    sum(case when is_w1m = 1 then trans_amount else 0 end)                       as sum_trans_amt_w_1m,

    max(trans_amount_credit)                                                     as max_trans_amt_credit_w_6m,
    round(stddev(trans_amount_credit), 2)                                        as std_trans_amt_credit_w_6m,
    sum(case when is_w1m = 1 then trans_amount_card else 0 end)                  as sum_trans_amt_card_w_1m,

    round(stddev(night_count), 2)                                                as std_trans_cnt_night_w_6m,
    sum(morning_count)                                                           as sum_trans_cnt_morning_w_6m,
    sum(case when is_w1m = 1 then trans_count - trans_count_credit else 0 end)   as sum_trans_cnt_non_credit_w_1m,

    sum(trans_amount - trans_amount_credit)                                      as sum_trans_amt_non_credit_w_6m,
    round(stddev(case when is_w3m = 1 then trans_amount - trans_amount_credit end), 2) as std_trans_amt_non_credit_w_3m,

    count(distinct transaction_month)                                            as distinct_transaction_months_w_6m

from transaction_raw
group by user_id, base_month
order by user_id;

create table t_user_score_tenure_temp as 
select distinct
  a.user_id,
  a.base_month,
  case when trunc(to_date(to_char(a.base_month), 'yyyymm')) - trunc(b.contract_date) >= 0 then trunc(to_date(to_char(a.base_month), 'yyyymm')) - trunc(b.contract_date) - 1
  else null end as sign_tenure,
  case when trunc(to_date(to_char(a.base_month), 'yyyymm')) - trunc(c.created_on) >= 0 then trunc(to_date(to_char(a.base_month), 'yyyymm')) - trunc(c.created_on)
  else null end as toki_tenure
from t_temp_union_pool a
left join (
    SELECT
    id_,
    CASE
        WHEN REGEXP_LIKE(ts, '^[0-9]{13}$')
        THEN DATE '1970-01-01' + TO_NUMBER(ts) / 1000 / 86400
        ELSE NULL
    END AS contract_date
    FROM (
    SELECT
        id_,
        COALESCE(
            REGEXP_SUBSTR(
                imsaccount,
                'signedAt[^0-9]*([0-9]{13})',
                1, 1, NULL, 1
            ),
            REGEXP_SUBSTR(
                imsaccount,
                'FILE_([0-9]{13})',
                1, 1, NULL, 1
            ),
            REGEXP_SUBSTR(
                imsaccount,
                'IDENTIFIER_([0-9]{13})',
                1, 1, NULL, 1
            )
        ) AS ts
    FROM toki.mongo_users
)
) b on a.user_id = b.id_
left join toki.dpr_maat_customers c on a.user_id = c.identifier;

create table t_user_score_service_more_temp as
with service_raw as (
    select distinct
        d.user_id,
        d.base_month,
        b.service_name as merchant_name,
        c.category as merchant_group,
        case when to_number(to_char(to_date(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) >=
            to_number(to_char(add_months(to_date(d.base_month, 'yyyymm'), -3), 'yyyymm'))
        then 1 else 0 end as is_w3m,
        case when to_number(to_char(to_date(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) >=
            to_number(to_char(add_months(to_date(d.base_month, 'yyyymm'), -1), 'yyyymm'))
        then 1 else 0 end as is_w1m
    from t_toki_transaction a
    inner join t_merchant_lookup b on b.merchant_id = a.target_id 
    left join toki_data_proc_user.lookup_merchant_category c on lower(b.merchant_group) = c.merchant_group
    inner join t_temp_union_pool d on a.userid = d.user_id
        and to_number(to_char(to_date(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) between
            to_number(to_char(add_months(to_date(d.base_month, 'yyyymm'), -6), 'yyyymm'))
            and to_number(to_char(add_months(to_date(d.base_month, 'yyyymm'), -1), 'yyyymm'))
)
    select 
        user_id,
        base_month,
        count(distinct merchant_name) as merchant_count_w_6m,
        count(distinct case when is_w1m = 1 then merchant_group end) as merchant_group_count_w_1m
    from service_raw
    group by user_id, base_month;

CREATE TABLE t_user_score_service_more_temp AS
WITH 
refund_transaction AS (
    SELECT 
        REFUND_TRANSACTION_ID,
        SUM(t.amount) AS ref_amount
    FROM toki.DPR_TAJET_REFUND_TRANSACTIONS t
    GROUP BY REFUND_TRANSACTION_ID
),
dispute_transaction AS (
    SELECT
        DISPUTED_TRANSACTION_ID,
        MAX(AMOUNT) AS disp_amnt,
        MAX(fee) AS disp_fee
    FROM toki.DPR_TAJET_DISPUTE_TRANSACTION t
    GROUP BY DISPUTED_TRANSACTION_ID
),
postpay_transaction AS (
    SELECT 
        user_id, 
        TRANSACTIONID AS transaction_id
    FROM toki.mobility_project_parking_invoices t
    WHERE t.refund_amount = 'None'
        AND PAYMENT_TYPE = 'post-pay'
        AND PAY = 'True'
),
toki_transaction AS (
    -- P2M and SUB transactions
    SELECT
        b.IDENTIFIER AS USERID,
        TO_CHAR(a.TRANSACTION_DATE, 'yyyy-mm-dd') AS Transaction_date,
        a.TRANSACTION_ID,
        a.amount - NVL(d.ref_amount, 0) - NVL(e.disp_amnt, 0) AS AMOUNT,
        CASE 
            WHEN TARGET_ACCOUNT_ID IN ('64a678aca00ecef93584b4b7', '651e5fc2a00ecef9355b1e5a') THEN
                CASE 
                    WHEN DISPUTED_TRANSACTION_ID IS NOT NULL THEN 0
                    WHEN ref_amount = amount THEN 0
                    ELSE CAST(
                        REGEXP_REPLACE(
                            SUBSTR(
                                TRANSACTION_NOTE, 
                                INSTR(LOWER(TRANSACTION_NOTE), '???????') + 8,
                                LENGTH(TRANSACTION_NOTE) - INSTR(LOWER(TRANSACTION_NOTE), '???????') - 8
                            ), 
                            '[^0-9\.]+', 
                            ''
                        ) AS NUMBER DEFAULT NULL ON CONVERSION ERROR
                    )
                END
            ELSE a.fee - NVL(ref_amount, 0) / AMOUNT * FEE - NVL(disp_fee, 0) 
        END AS FEE_AUTO,
        CASE 
            WHEN a.TARGET_ACCOUNT_Id = '60d3f6d03ab5a2e6538b90d6' AND MESSAGE <> 'P2M' 
            THEN '6448c9fd39c15f8d9bb639a6'
            ELSE a.TARGET_ACCOUNT_ID 
        END AS TARGET_ID,
        a.MESSAGE,
        a.TRANSACTION_NOTE
    FROM TOKI.DPR_THOTH_ACCOUNT_ENTRIES a
    LEFT JOIN toki.DPR_THOTH_ACCOUNTS b ON a.ACCOUNT_ID = b.ID_
    LEFT JOIN refund_transaction d ON a.TRANSACTION_ID = d.REFUND_TRANSACTION_ID
    LEFT JOIN dispute_transaction e ON a.TRANSACTION_ID = e.DISPUTED_TRANSACTION_ID
    WHERE (MESSAGE LIKE '%P2M%' OR MESSAGE LIKE '%SUB%')
        AND MESSAGE NOT IN ('SUBCHARGE', 'SUB2MAIN', 'SUB2SUB')
        AND a.a_type = 'DEBIT'
        AND TARGET_ACCOUNT_ID <> '1101'
        AND a.amount - NVL(d.ref_amount, 0) - NVL(e.disp_amnt, 0) > 0
        AND a.TRANSACTION_DATE BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- Postpay transactions
    SELECT
        t.user_id AS USERID,
        TO_CHAR(a.TRANSACTION_DATE, 'yyyy-mm-dd') AS Transaction_date,
        a.TRANSACTION_ID,
        a.amount - NVL(d.ref_amount, 0) - NVL(e.disp_amnt, 0) AS AMOUNT,
        a.fee - NVL(ref_amount, 0) / AMOUNT * FEE - NVL(disp_fee, 0) AS FEE_AUTO,
        a.TARGET_ACCOUNT_ID AS TARGET_ID,
        'P2M' AS MESSAGE,
        a.TRANSACTION_NOTE
    FROM postpay_transaction t
    LEFT JOIN TOKI.DPR_THOTH_ACCOUNT_ENTRIES a ON t.transaction_id = a.transaction_id
    LEFT JOIN toki.DPR_THOTH_ACCOUNTS b ON a.ACCOUNT_ID = b.ID_
    LEFT JOIN refund_transaction d ON a.TRANSACTION_ID = d.REFUND_TRANSACTION_ID
    LEFT JOIN dispute_transaction e ON a.TRANSACTION_ID = e.DISPUTED_TRANSACTION_ID
    WHERE a.a_type = 'DEBIT'
        AND TARGET_ACCOUNT_ID <> '1101'
        AND a.amount - NVL(d.ref_amount, 0) - NVL(e.disp_amnt, 0) > 0
        AND a.TRANSACTION_DATE BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- Univision Payment (upoint)
    SELECT
        AA.ACCOUNTID AS USERID,
        TO_CHAR(TO_TIMESTAMP(AA.CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6'), 'yyyy-mm-dd') AS transaction_date,
        NULL AS TRANSACTION_ID,
        CASE
            WHEN AA.PAYMENTTYPE IN ('upoint', 'both') THEN ROUND(BB.UPOINT, 0)
            ELSE NULL
        END AS AMOUNT,
        NULL AS fee_auto,
        '5ecb29ea60bb3559ac25e115' AS TARGET_ID,
        'P2M' AS message,
        CASE
            WHEN AA.PAYMENTTYPE = 'both' THEN 'upoint'
            ELSE AA.PAYMENTTYPE
        END AS Transaction_note
    FROM toki.univision_orders AA
    LEFT JOIN toki.univision_invoices BB ON AA.id_ = BB.orderid
    WHERE LOWER(AA.status) = 'success'
        AND PAYMENTTYPE IN ('upoint', 'both')
        AND TO_TIMESTAMP(AA.CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6') 
            BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- Unitel Payment (upoint)
    SELECT
        ID_ AS USERID,
        TO_CHAR(TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6'), 'yyyy-mm-dd') AS transaction_date,
        NULL AS TRANSACTION_ID,
        CASE
            WHEN PAYMENTTYPE IN ('upoint') OR STATUS = 'UPOINT' THEN AMOUNT
            ELSE NULL
        END AS AMOUNT,
        NULL AS fee_auto,
        '60d3f6d03ab5a2e6538b90d6' AS TARGET_ID,
        'P2M' AS message,
        CASE
            WHEN PAYMENTTYPE = 'upoint' OR STATUS = 'UPOINT' THEN 'upoint'
            ELSE NULL
        END AS Transaction_note
    FROM toki.mongo_orders
    WHERE LOWER(status) IN ('success', 'upoint')
        AND (TYPE = 'PAYMENT' OR TYPE IS NULL)
        AND (PAYMENTTYPE IN ('upoint') OR STATUS = 'UPOINT')
        AND TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6') 
            BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- Data & Unit purchases
    SELECT
        TOKIID AS USERID,
        TO_CHAR(TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6'), 'yyyy-mm-dd') AS transaction_date,
        NULL AS TRANSACTION_ID,
        CASE
            WHEN PAYMENTTYPE IN ('unit', 'addon', 'upoint', 'uloan') THEN ROUND(AMOUNT, 0)
            ELSE NULL
        END AS AMOUNT,
        NULL AS fee_auto,
        CASE
            WHEN TYPE = 'DATA' THEN '5f17d9eb27657eafab155266'
            WHEN TYPE = 'UNIT' THEN '5f16790f1010baac2066810f'
            ELSE NULL
        END AS TARGET_ID,
        'P2M' AS message,
        CASE
            WHEN PAYMENTTYPE = 'addon' THEN 'tulbur dr'
            WHEN PAYMENTTYPE = 'uloan' THEN 'zeeleer'
            WHEN PAYMENTTYPE = 'unit' THEN 'negjeer'
            ELSE PAYMENTTYPE
        END AS Transaction_note
    FROM TOKI.UNITDATA_ORDERS
    WHERE OPERATOR = 'unitel'
        AND status = 'SUCCESS'
        AND paymenttype <> 'cash'
        AND TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6') 
            BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- Movie rental payments
    SELECT
        USERID,
        TO_CHAR(TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6'), 'yyyy-mm-dd') AS transaction_date,
        NULL AS TRANSACTION_ID,
        ROUND(AMOUNT, 0) AS AMOUNT,
        NULL AS fee_auto,
        '64643a78c8961d69d81057eb' AS TARGET_ID, 
        'P2M' AS message,
        CASE
            WHEN PAYMENTTYPE = 'UNIVISION' THEN 'tulbur dr'
            WHEN PAYMENTTYPE = 'UPOINT' THEN 'upoint'
            ELSE NULL
        END AS Transaction_note
    FROM toki.mp_movie_orders
    WHERE LOWER(status) = 'success'
        AND paymenttype NOT IN ('VOD', 'TOKI')
        AND TO_TIMESTAMP(CREATEDAT, 'yyyy-mm-dd HH24:MI:SS.ff6') 
            BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1

    UNION ALL

    -- TOKI CALL transactions
    SELECT
        subscriber_id AS userid,
        TO_CHAR(TO_DATE(ddate, 'yyyy-mm-dd'), 'yyyy-mm-dd') AS transaction_date,
        NULL AS transaction_id,
        TO_NUMBER(amount) AS amount,
        NULL AS fee_auto, 
        '65c34ceeb595e38f6c1cd8b8' AS target_id, 
        NULL AS message, 
        NULL AS transaction_note
    FROM (
        SELECT 
            TO_CHAR(TO_DATE(used_date, 'yyyy-mm-dd'), 'yyyy-mm-dd') AS ddate, 
            subscriber_id, 
            SUM(avg_amt) AS amount, 
            'other-package' AS channel, 
            'package' AS type_1
        FROM Datawarehouse.t_arpu_ip77_value
        WHERE TO_DATE(used_date, 'yyyy-mm-dd') 
            BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1
        GROUP BY TO_CHAR(TO_DATE(used_date, 'yyyy-mm-dd'), 'yyyy-mm-dd'), subscriber_id

        UNION ALL

        SELECT 
            ddate, 
            subscriber_id, 
            amount, 
            'other-negj' AS channel, 
            'negj' AS type_1
        FROM (
            SELECT 
                TO_CHAR(bb.payment_date, 'yyyy-mm-dd') AS ddate, 
                aa.entr_no AS subscriber_id, 
                aa.phone_no, 
                aa.customer_node_id, 
                ROUND(amount, 0) AS amount
            FROM uni_info_res.t_ip77_cdr_complect aa
            LEFT JOIN sv_data.sv_payment_inc bb ON aa.customer_node_id = bb.customer_node_id
            WHERE SUBSTR(aa.complect_date, 1, 4) = TO_CHAR(SYSDATE, 'yyyy')
                AND bb.customer_node_id IS NOT NULL
                AND aa.cdr_count30 IS NOT NULL
                AND aa.phone_no IS NOT NULL
                AND bb.payment_date BETWEEN ADD_MONTHS(TRUNC(SYSDATE) - 1, -6) AND TRUNC(SYSDATE) - 1
            GROUP BY 
                TO_CHAR(bb.payment_date, 'yyyy-mm-dd'), 
                aa.entr_no, 
                aa.phone_no, 
                aa.customer_node_id, 
                ROUND(amount, 0)
        )
    )
),

service_raw AS (
    SELECT DISTINCT
        d.user_id,
        d.base_month,
        b.service_name AS merchant_name,
        c.category AS merchant_group,
        CASE WHEN TO_NUMBER(TO_CHAR(TO_DATE(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) >=
            TO_NUMBER(TO_CHAR(ADD_MONTHS(TO_DATE(d.base_month, 'yyyymm'), -3), 'yyyymm'))
        THEN 1 ELSE 0 END AS is_w3m,
        CASE WHEN TO_NUMBER(TO_CHAR(TO_DATE(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) >=
            TO_NUMBER(TO_CHAR(ADD_MONTHS(TO_DATE(d.base_month, 'yyyymm'), -1), 'yyyymm'))
        THEN 1 ELSE 0 END AS is_w1m
    FROM toki_transaction a
    INNER JOIN t_merchant_lookup b ON b.merchant_id = a.target_id
    LEFT JOIN toki_data_proc_user.lookup_merchant_category c ON LOWER(b.merchant_group) = c.merchant_group
    INNER JOIN t_temp_union_pool d ON a.userid = d.user_id
        AND TO_NUMBER(TO_CHAR(TO_DATE(a.transaction_date, 'yyyy-mm-dd'), 'yyyymm')) BETWEEN
            TO_NUMBER(TO_CHAR(ADD_MONTHS(TO_DATE(d.base_month, 'yyyymm'), -6), 'yyyymm'))
            AND TO_NUMBER(TO_CHAR(ADD_MONTHS(TO_DATE(d.base_month, 'yyyymm'), -1), 'yyyymm'))
)

SELECT 
    user_id,
    base_month,
    COUNT(DISTINCT merchant_name) AS merchant_count_w_6m,
    COUNT(DISTINCT CASE WHEN is_w1m = 1 THEN merchant_group END) AS merchant_group_count_w_1m
FROM service_raw
GROUP BY user_id, base_month;

create table t_user_score_parking_temp as
with parking_raw as (
  select distinct
    a.user_id,
    a.plate_number,
    a.transactionid,
    to_number(a.amount)  as amount,
    a.payment_type,
    a.parking_id,
    to_number(to_char(to_date(substr(a.created_date, 1, 10), 'yyyy-mm-dd'), 'yyyymmdd')) as created_date
  from (select * from toki.mobility_project_parking_invoices where pay = 'True') a
  inner join toki.mobility_project_parking_park_lists b
    on a.parking_id = b.parking_id and b.status = 'working'
),
parking_base as (
  select
    b.user_id,
    a.base_month,
    b.plate_number,
    b.transactionid,
    b.amount,
    b.payment_type,
    b.parking_id,
    b.created_date,
    case when trunc(b.created_date / 100) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -3), 'yyyymm'))
    then 1 else 0 end as is_w3m,
    case when trunc(b.created_date / 100) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
    then 1 else 0 end as is_w1m
  from t_temp_union_pool a
  inner join parking_raw b on a.user_id = b.user_id
    and trunc(b.created_date / 100) between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -6), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
)

select
  user_id,
  base_month,

  sum(amount)                                                                        as sum_parking_amt_w_6m

from parking_base
group by user_id, base_month
order by user_id;

create table t_user_score_number_value_temp as 
with number_change_log as (
    select
        b.identifier as user_id,
        b.device_no as last_state,
        a.old_state,
        a.new_state,
        a.p_date as change_date
    from toki.dpr_maat_commands a
    right join toki.dpr_maat_customers b on b.id_ = a.customer_id
    and a.a_type in ('CHANGEPHONENUMBER')
    and a.old_state is not null
    and a.new_state is not null

),
joined as (
  select
    a.*,
    case
      when b.change_date is null then b.last_state
      when to_number(a.base_month) <= to_number(substr(b.change_date, 1, 6)) then b.last_state
      when to_number(a.base_month) >  to_number(substr(b.change_date, 1, 6)) then b.old_state
    end as device_no,
    b.change_date as log_change_date
  from t_temp_union_pool a
  left join number_change_log b on a.user_id = b.user_id
),
ranked as (
  select
    a.*,
    row_number() over (
      partition by user_id, base_month
      order by
        case
          when to_number(base_month) > to_number(substr(log_change_date, 1, 6)) then 0
          when to_number(base_month) <= to_number(substr(log_change_date, 1, 6)) then 1
          else 2
        end asc,
        to_number(log_change_date) desc nulls last
    ) as rn
  from joined a
),
number_base as (
    select user_id, base_month, device_no
    from ranked
    where rn = 1
)
select
    user_id,
    base_month,
    device_no,

    case when substr(device_no, 1, 2) = substr(device_no, 3, 2)                                         then 1 else 0 end as same_double,
    case when substr(device_no, 1, 1) = substr(device_no, 2, 1)
          and substr(device_no, 3, 1) = substr(device_no, 4, 1)                                         then 1 else 0 end as double_double,
    case when substr(device_no, 1, 3) in ('000','111','222','333','444','555','666','777','888','999')    then 1 else 0 end as triple_start,
    case when substr(device_no, 2, 3) in ('000','111','222','333','444','555','666','777','888','999')    then 1 else 0 end as triple_end,
    case when substr(device_no, 1, 1) = substr(device_no, 4, 1)
          and substr(device_no, 2, 1) = substr(device_no, 3, 1)                                         then 1 else 0 end as valid_bronze,

    case when substr(device_no, 1, 4) in ('8888','8811','9999','9911')                                   then 1 else 0 end as premium_index,
    case when substr(device_no, 1, 4) in ('8800','8810','9910','9909','9908','9907','9906','9905','9904','9903','9902','9901','9900') then 1 else 0 end as gold_pre,
    case when substr(device_no, 1, 4) in ('8911','8611','8801','8802','8803','8804','8805','8806','8807','8808','8809')              then 1 else 0 end as silver_pre,
    case when substr(device_no, 5)    in ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999')                     then 1 else 0 end as gold_e,
    case when instr(device_no, '00000') > 0
          or instr(device_no, '11111') > 0
          or instr(device_no, '22222') > 0
          or instr(device_no, '33333') > 0
          or instr(device_no, '44444') > 0
          or instr(device_no, '55555') > 0
          or instr(device_no, '66666') > 0
          or instr(device_no, '77777') > 0
          or instr(device_no, '88888') > 0
          or instr(device_no, '99999') > 0                                                               then 1 else 0 end as cons_gold,
    case when substr(device_no, 4) in ('00000','11111','22222','33333','44444','55555','66666','77777','88888','99999')              then 1 else 0 end as sub_super_end,
    case when substr(device_no, 3) in ('000000','111111','222222','333333','444444','555555','666666','777777','888888','999999')    then 1 else 0 end as super_ended

from number_base;

create table t_user_score_mp_usage_temp as 
with mp_raw as (
    select * from tergel_mu.app_usage_miniprogramm_final
    union
    select * from tergel_mu.app_usage_miniprogramm_final_cont
    union
    select * from t_app_usage_miniprogramm
),
mp_base as (
    select
        a.user_id,
        a.base_month,
        b.createmon,
        b.night_usage_count,
        b.morning_usage_count,
        b.afternoon_usage_count,
        b.evening_usage_count,
        case when to_number(b.createmon) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -3), 'yyyymm'))
        then 1 else 0 end as is_w3m,
        case when to_number(b.createmon) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
        then 1 else 0 end as is_w1m
    from t_temp_union_pool a
    inner join mp_raw b on a.user_id = b.userid
        and to_number(b.createmon) between
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -6), 'yyyymm'))
            and to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
)
    select
        user_id,
        base_month,

        stddev(night_usage_count)                                               as night_usage_count_std_w_6m,

        sum(case when is_w1m = 1 then morning_usage_count end)                  as morning_usage_count_sum_w_1m,
        round(sum(morning_usage_count) / nullif(sum(night_usage_count + morning_usage_count + afternoon_usage_count + evening_usage_count), 0), 4)                                                                                                                        as morning_usage_per_w_6m,

        sum(case when night_usage_count > 0 then 1 else 0 end)                          as night_usage_month_w_6m,

        sum(night_usage_count + morning_usage_count + afternoon_usage_count + evening_usage_count) as mp_usage_count_sum_w_6m,

        min(night_usage_count + morning_usage_count + afternoon_usage_count + evening_usage_count) as mp_usage_count_min_w_6m,

        stddev(night_usage_count + morning_usage_count + afternoon_usage_count + evening_usage_count) as mp_usage_count_std_w_6m


    from mp_base
    group by user_id, base_month;

create table t_user_score_kyc_temp as
with user_kyc_raw as (
    select 
        userid,
        createdat,
        to_char(to_timestamp(createdat, 'YYYY-MM-DD HH24:MI:SS.FF'), 'yyyymm') as kyc_month,
        kyctype,
        rejectionreason,
        isvisibletoadmin,
        adminaction
    from toki.mongo_userkycs
)
    select
        a.user_id,
        a.base_month,
        max(case when b.isvisibletoadmin = 'True' and b.adminaction = 'ADMIN_APPROVED'
                 and b.kyctype is not null then b.kyctype end)                              as last_kyctype_true,
        trunc(to_date(to_char(a.base_month), 'yyyymm'))
            - trunc(max(case when b.isvisibletoadmin = 'True' and b.adminaction = 'ADMIN_APPROVED'
                              and b.kyctype is not null
                              then to_timestamp(b.createdat, 'YYYY-MM-DD HH24:MI:SS.FF') end))
                                                                                            as days_since_last_kyc_true
    from t_temp_union_pool a
    inner join user_kyc_raw b on a.user_id = b.userid
        and to_number(b.kyc_month) < to_number(to_char(a.base_month))
    group by a.user_id, a.base_month

create table t_user_score_gaming_temp as
with txn_raw as (
  select
    b.identifier                                                 as userid,
    to_char(a.transaction_date, 'yyyy-mm-dd')                   as transaction_date,
    a.amount - nvl(d.ref_amount, 0) - nvl(e.disp_amnt, 0)      as amount,
    case when a.target_account_id = '60d3f6d03ab5a2e6538b90d6' and a.message <> 'P2M'
         then '6448c9fd39c15f8d9bb639a6'
         else a.target_account_id
    end                                                          as target_id
  from toki.dpr_thoth_account_entries a
  left join toki.dpr_thoth_accounts b on a.account_id = b.id_
  left join (
    select refund_transaction_id, sum(amount) as ref_amount
    from toki.dpr_tajet_refund_transactions
    group by refund_transaction_id
  ) d on a.transaction_id = d.refund_transaction_id
  left join (
    select disputed_transaction_id, max(amount) as disp_amnt, max(fee) as disp_fee
    from toki.dpr_tajet_dispute_transaction
    group by disputed_transaction_id
  ) e on a.transaction_id = e.disputed_transaction_id
  where a.message like '%P2M%'
    and a.a_type = 'DEBIT'
    and a.target_account_id <> '1101'
    and a.amount - nvl(d.ref_amount, 0) - nvl(e.disp_amnt, 0) > 0
    and a.target_account_id not in (
      '631720b4d4c261b1123f8004', '6308917b854feb1da7d0c39a',
      '63e1d043bc8e17a4de09d605', '64cf4e6ba00ecef93597bdfd'
    )

  union all

  select
    case when c.device_no is not null then c.userid else a1.userid end as userid,
    a1.transaction_date,
    a1.amount,
    'gameon' as target_id
  from (
    select substr(a.msisdn, 4, 8) as userid,
           to_char(a.create_date, 'yyyy-mm-dd') as transaction_date,
           a.total_price as amount
    from datawarehouse.game_on_cdr a
    where a.item_description = 'GAMEON'

    union

    select substr(a.phone_no, 4, 8) as userid,
           substr(a.create_date, 1, 10) as transaction_date,
           to_number(a.total_price) as amount
    from dev_ai.t_sla_merchant_log a
    where a.item_name = 'GAMEON'
      and a.status_code = 'SUCCESS'
  ) a1
  left join (
    select identifier as userid, device_no
    from toki.dpr_maat_customers
    where not (lower(given_name) like '%stress%' or lower(given_name) like '%test%')
      and current_state = 'ACTIVE'
  ) c on a1.userid = c.device_no
),
gaming_raw as (
  select
    t.userid,
    to_char(to_date(t.transaction_date, 'yyyy-mm-dd'), 'yyyymm') as month_id,
    to_date(t.transaction_date, 'yyyy-mm-dd')                    as txn_date,
    count(*)                                                       as total_purchase_count,
    nullif(sum(t.amount), 0)                                       as total_purchase_amount
  from txn_raw t
  inner join t_merchant_lookup lkp on t.target_id = lkp.merchant_id
  where lkp.service_name in ('Codashop', 'Seller panda', 'GameOn', 'Seagm')
  group by t.userid, to_char(to_date(t.transaction_date, 'yyyy-mm-dd'), 'yyyymm'),
           to_date(t.transaction_date, 'yyyy-mm-dd')
),
gaming_base as (
  select
    a.user_id,
    a.base_month,
    b.month_id,
    b.txn_date,
    b.total_purchase_count,
    b.total_purchase_amount,
    case when to_number(b.month_id) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -3), 'yyyymm'))
    then 1 else 0 end as is_w3m,
    case when to_number(b.month_id) >=
      to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
    then 1 else 0 end as is_w1m
  from t_temp_union_pool a
  inner join gaming_raw b on a.user_id = b.userid
    and to_number(b.month_id) between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -6), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
)

select
  user_id,
  base_month,

  sum(total_purchase_amount)                                         as sum_gaming_amt_w_6m

from gaming_base
group by user_id, base_month
order by user_id;

create table t_user_score_fire_temp as
with fire_raw as (
    select * from t_app_usage_firebase_old
    union
    select * from t_app_usage_firebase
),
fire_base as (
    select
        a.user_id,
        a.base_month,
        b.event_month,
        b.device_div,
        b.is_device_changed,
        b.mobile_div,
        b.is_model_changed,
        b.engage_days,
        b.avg_session_cnt_d,
        b.max_session_cnt_d,
        b.total_session_cnt,
        b.std_session_cnt_d,
        b.avg_session_sec_d,
        b.max_session_sec_d,
        b.total_session_sec,
        b.std_session_sec_d,
        b.total_app_removal,
        case when to_number(b.event_month) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -3), 'yyyymm'))
        then 1 else 0 end as is_w3m,
        case when to_number(b.event_month) >=
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
        then 1 else 0 end as is_w1m
    from t_temp_union_pool a
    inner join fire_raw b on a.user_id = b.userid
        and to_number(b.event_month) between
            to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -6), 'yyyymm'))
            and to_number(to_char(add_months(to_date(a.base_month, 'yyyymm'), -1), 'yyyymm'))
)

select
    user_id,
    base_month,

    round(avg(mobile_div), 2)                                                   as avg_fire_model_cnt_w_6m,
    count(distinct event_month)                                                 as distinct_fire_event_months_w_6m,
    avg(case when is_w1m = 1 then avg_session_cnt_d end) as avg_fire_session_cnt_w_1m,

    sum(case when is_w1m = 1 then total_session_cnt else 0 end) as sum_fire_session_cnt_w_1m

from fire_base
group by user_id, base_month
order by user_id;

create table t_user_score_card_temp as
with card_raw as (
    select
        a.account_id                                                               as user_id,
        to_date(to_char(b.base_month, 'FM000000'), 'YYYYMM') as base_month,
        lower(a.bank_name)                                                         as bank_name,
        lower(a.card_holder_name)                                                  as holder_name,
        trunc(a.created_on)                                                        as add_date,
        trunc(a.removed_date)                                                      as removed_date
    from toki.dpr_tajet_tokens a
    inner join t_temp_union_pool b on a.account_id = b.user_id
),
card_base as (
    select
        user_id,
        base_month,
        bank_name,
        holder_name,
        add_date,
        removed_date,
        case when add_date < base_month
             and (removed_date is null or removed_date >= base_month)
        then 1 else 0 end                                                          as is_active,
        case when add_date >= base_month - 180
             and add_date <  base_month
        then 1 else 0 end                                                          as is_add_w6m,
        case when add_date >= base_month - 90
             and add_date <  base_month
        then 1 else 0 end                                                          as is_add_w3m,
        case when add_date >= base_month - 30
             and add_date <  base_month
        then 1 else 0 end                                                          as is_add_w1m,
        case when removed_date is not null
             and removed_date >= base_month - 180
             and removed_date <  base_month
        then 1 else 0 end                                                          as is_remove_w6m,
        case when removed_date is not null
             and removed_date >= base_month - 90
             and removed_date <  base_month
        then 1 else 0 end                                                          as is_remove_w3m,
        case when removed_date is not null
             and removed_date >= base_month - 30
             and removed_date <  base_month
        then 1 else 0 end                                                          as is_remove_w1m
    from card_raw
)

select
    user_id,
    base_month,

    base_month - max(case when add_date < base_month then add_date end)            as days_since_last_add

from card_base
group by user_id, base_month
order by user_id;

create table t_user_score_car_ownership_temp as
with saved_cars as (
  select
    user_id,
    plate_number,
    save_type,
    user_car,
    delflg,
    createdat,
    updatedat
  from (
    select
      user_id,
      plate_number,
      save_type,
      user_car,
      delflg,
      substr(createdat, 1, 10) as createdat,
      substr(updatedat, 1, 10) as updatedat
    from toki.mobility_saved_cars

    union all

    select
      user_id,
      car_number || car_string as plate_number,
      save_type,
      car_save               as user_car,
      delflg,
      substr(createdat, 1, 10) as createdat,
      substr(createdat, 1, 10) as updatedat
    from toki.parking_cars_new
  )
  group by user_id, plate_number, save_type, user_car, delflg, createdat, updatedat
),
mobility_cars as (
  select
    case when lt.mongo_reg = lt.car_owner then 'Y' else 'N' end as owner_tag,
    lt.*
  from (
    select
      sc.user_id,
      sc.save_type,
      sc.user_car,
      sc.delflg,
      sc.createdat                                             as saved_createdat,
      lower(json_value(u.wallet, '$[0].nationalId'))           as mongo_reg,
      lower(jt.ownerRegnum)                                    as car_owner,
      c.plate_number,
      jt.countryName,
      jt.manCount,
      c.build_year,
      c.cabin_number,
      c.capacity,
      c.certificate_number,
      c.class_name,
      c.color_name,
      c.fuel_type,
      c.length,
      c.width,
      c.height,
      c.import_date,
      c.mark_name,
      c.model_name,
      c.owner_country,
      c.owner_handphone,
      c.owner_type,
      c.owner_workphone,
      c.transmission,
      c.wheel_position,
      c.type,
      c.indata,
      c.delflg                                                 as car_delflg,
      c.createdat,
      c.updatedat
    from toki.mobility_car_infos c
    left join json_table(
      replace(replace(replace(c.indata, '"', ''''), 'False', 'false'), 'None', 'null'),
      '$'
      columns (
        ownerRegnum  varchar2(50)  path '$.ownerRegnum',
        countryName  varchar2(100) path '$.countryName',
        manCount     number        path '$.manCount'
      )
    ) jt on 1 = 1
    left join saved_cars sc
      on c.plate_number = sc.plate_number
      and substr(c.createdat, 1, 10) = sc.createdat
    left join toki.mongo_users u
      on sc.user_id = u.id_
  ) lt
),
penalty_raw as (
  select
    t.user_id,
    t.plate_number,
    jt.amount,
    to_number(to_char(to_date(substr(t.paid_date, 1, 10), 'yyyy-mm-dd'), 'yyyymmdd')) as txn_date
  from (
    select *
    from toki.mobility_project_penaltys_invoices
    where to_number(to_char(to_date(substr(createdat, 1, 10), 'yyyy-mm-dd'), 'yyyymmdd')) > 20240531
  ) t
  left join json_table(
    replace(replace(replace(t.inv_data, '''', '"'), 'False', 'false'), 'None', 'null'),
    '$[*]'
    columns (
      amount  number  path '$.amount'
    )
  ) jt on 1 = 1
  where t.paid_date is not null
    and jt.amount > 0
),
parking_raw as (
  select
    a.user_id,
    a.plate_number,
    to_number(a.amount) as amount,
    to_number(to_char(to_date(substr(a.created_date, 1, 10), 'yyyy-mm-dd'), 'yyyymmdd')) as txn_date
  from toki.mobility_project_parking_invoices a
  inner join toki.mobility_project_parking_park_lists b
    on a.parking_id = b.parking_id and b.status = 'working'
  where a.pay = 'True'
),
car_raw as (
  select user_id, plate_number, amount, txn_date from penalty_raw
  union all
  select user_id, plate_number, amount, txn_date from parking_raw
),
car_base as (
  select
    a.user_id,
    a.base_month,
    b.plate_number,
    b.owner_tag,
    sum(cr.amount) as plate_total_amt,
    case
      when b.owner_tag = 'Y' then 'Y'
      when sum(cr.amount) > 50000 then 'Y'
      else 'N'
    end as effective_owner_tag
  from t_temp_union_pool a
  inner join mobility_cars b
    on a.user_id = b.user_id
    and to_number(to_char(to_date(b.saved_createdat, 'yyyy-mm-dd'), 'yyyymm')) <= a.base_month
  left join car_raw cr
    on cr.user_id = b.user_id
    and cr.plate_number = b.plate_number
    and trunc(cr.txn_date / 100) <= a.base_month
  group by a.user_id, a.base_month, b.plate_number, b.owner_tag
)

select
  user_id,
  base_month,
  max(case when effective_owner_tag = 'Y' then 1 else 0 end)  as is_own_car

from car_base
group by user_id, base_month
order by user_id;

create table t_user_score_all_request_temp as
with request_raw as (
  select distinct
    p.user_id,
    p.base_month,
    trunc(r.decision_engine_is_successful_date) as request_date
  from toki.credit_zms_request r
  inner join toki.credit_credit c on r.borrower_id = c.borrower_id
  inner join t_temp_union_pool p on c.user_id = p.user_id
  where r.decision_engine_is_successful_date is not null
    and to_number(to_char(r.decision_engine_is_successful_date, 'yyyymm')) between
        to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -1), 'yyyymm'))

  union all

  select distinct
    p.user_id,
    p.base_month,
    trunc(r.decision_engine_successful_date) as request_date
  from toki.handset_tmp_limit_request r
  inner join t_temp_union_pool p on r.user_id = p.user_id
  where r.decision_engine_successful_date is not null
    and to_number(to_char(r.decision_engine_successful_date, 'yyyymm')) between
        to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -1), 'yyyymm'))

  union all

  select distinct
    p.user_id,
    p.base_month,
    trunc(r.decision_engine_success_date) as request_date
  from toki.bnpl_limit_request r
  inner join toki.bnpl_account b on r.bnpl_account_id = b.id_
  inner join t_temp_union_pool p on b.user_id = p.user_id
  where r.decision_engine_success_date is not null
    and to_number(to_char(r.decision_engine_success_date, 'yyyymm')) between
        to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -1), 'yyyymm'))
)

select
  user_id,
  base_month,
  count(*) as req_cnt_w_2y,
  count(case when request_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -12)
    then 1 end)                                                                  as req_cnt_w_1y,
  count(case when request_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -6)
    then 1 end)                                                                  as req_cnt_w_6m,
  trunc(to_date(to_char(base_month), 'yyyymm'))
    - max(request_date)                                                          as day_since_last_req
from request_raw
group by user_id, base_month
order by user_id;

create table t_user_score_all_limit_usage_temp as
with credit_monthly as (
  select
    p.user_id,
    p.base_month,
    c.credit_id,
    to_char(cch.created_date, 'yyyymm')                                                     as year_month,
    max(cch.credit_limit) keep (dense_rank last order by cch.created_date)                  as credit_limit,
    coalesce(max(cch.balance) keep (dense_rank last order by cch.created_date), 0)          as balance
  from toki.credit_credit_history cch
  inner join toki.credit_credit c on cch.credit_id = c.credit_id
  inner join t_temp_union_pool p on c.user_id = p.user_id
  where cch.created_date is not null
    and to_number(to_char(cch.created_date, 'yyyymm')) between
        to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -1), 'yyyymm'))
  group by p.user_id, p.base_month, c.credit_id, to_char(cch.created_date, 'yyyymm')
),
credit_latest_month as (
  select user_id, base_month, credit_id, max(year_month) as latest_month
  from credit_monthly
  group by user_id, base_month, credit_id
),
latest_credit as (
  select user_id, base_month, credit_id,
    row_number() over (
      partition by user_id, base_month
      order by latest_month desc, credit_id desc
    ) as rn
  from credit_latest_month
),
credit_util as (
  select
    ms.user_id,
    ms.base_month,
    ms.year_month,
    ms.balance,
    ms.credit_limit as total_limit
  from latest_credit lc
  inner join credit_monthly ms
    on ms.user_id = lc.user_id and ms.base_month = lc.base_month and ms.credit_id = lc.credit_id
  where lc.rn = 1
),

bnpl_loan_data as (
  select distinct
    a.account_id                                                              as user_id,
    a.transaction_id                                                          as loan_transaction_id,
    a.amount                                                                  as loan_amt,
    to_number(to_char(trunc(a.created_at), 'yyyymmdd'))                      as loan_date,
    a.status                                                                  as loan_status,
    to_number(to_char(trunc(c.transaction_date), 'yyyymmdd'))                as repayment_date
  from toki.dpr_tajet_bnpl_request a
  inner join toki.dpr_tajet_bnpl_invoice b
    on a.transaction_id = b.transaction_id and a.status not in ('CANCELLED')
  inner join toki.dpr_tajet_bnpl_repayment c
    on b.id_ = c.invoice_id and c.status = 'SUCCESS' and c.payment_type = 'REPAYMENT'
),
bnpl_loan_summary as (
  select distinct
    user_id, loan_transaction_id, loan_date, loan_amt, loan_status,
    max(repayment_date) as loan_closed_date
  from bnpl_loan_data
  group by user_id, loan_transaction_id, loan_date, loan_amt, loan_status
),
bnpl_account_summary as (
  select distinct
    a.bnpl_account_id,
    a.user_id,
    a.bnpl_limit,
    to_number(to_char(trunc(a.created_date), 'yyyymmdd'))                    as created_date,
    to_number(substr(to_char(to_number(to_char(trunc(a.created_date), 'yyyymmdd'))), 1, 6)) as month,
    coalesce(sum(distinct case
      when ls.loan_date <= to_number(to_char(trunc(a.created_date), 'yyyymmdd'))
       and (ls.loan_closed_date is null
            or ls.loan_closed_date > to_number(to_char(trunc(a.created_date), 'yyyymmdd')))
      then ls.loan_amt else 0
    end), 0) as balance
  from toki.bnpl_account_history a
  left join bnpl_loan_summary b
    on a.user_id = b.user_id
    and to_number(to_char(trunc(a.created_date), 'yyyymmdd')) = b.loan_date
    and a.created_by_action = 'loan'
  left join bnpl_loan_summary ls on a.user_id = ls.user_id
  where a.product = 'DEFAULT'
  group by a.bnpl_account_id, a.user_id, a.bnpl_limit, a.created_by_action,
           to_number(to_char(trunc(a.created_date), 'yyyymmdd')),
           b.loan_amt, b.loan_status, b.loan_closed_date
),
bnpl_monthly_values as (
  select
    bnpl_account_id, user_id, month, bnpl_limit as latest_bnpl_limit, balance as latest_balance,
    row_number() over (partition by bnpl_account_id, user_id, month order by created_date desc) as rn
  from bnpl_account_summary
),
bnpl_monthly_filtered as (
  select bnpl_account_id, user_id, month, latest_bnpl_limit, latest_balance
  from bnpl_monthly_values where rn = 1
),
bnpl_user_month_range as (
  select bnpl_account_id, user_id, min(month) as min_month, max(month) as max_month
  from bnpl_monthly_filtered
  group by bnpl_account_id, user_id
),
bnpl_all_months as (
  select
    umr.bnpl_account_id,
    umr.user_id,
    to_number(to_char(add_months(to_date(to_char(umr.min_month), 'yyyymm'), level - 1), 'yyyymm')) as month
  from bnpl_user_month_range umr
  connect by level <= months_between(
               to_date(to_char(umr.max_month), 'yyyymm'),
               to_date(to_char(umr.min_month), 'yyyymm')) + 1
    and prior bnpl_account_id = bnpl_account_id
    and prior user_id         = user_id
    and prior sys_guid()      is not null
),
bnpl_account_result as (
  select
    am.bnpl_account_id,
    am.user_id,
    am.month,
    coalesce(mf.latest_bnpl_limit,
      last_value(mf.latest_bnpl_limit ignore nulls) over (
        partition by am.bnpl_account_id, am.user_id
        order by am.month
        rows between unbounded preceding and current row)) as latest_bnpl_limit,
    coalesce(mf.latest_balance,
      last_value(mf.latest_balance ignore nulls) over (
        partition by am.bnpl_account_id, am.user_id
        order by am.month
        rows between unbounded preceding and current row)) as latest_balance
  from bnpl_all_months am
  left join bnpl_monthly_filtered mf
    on am.bnpl_account_id = mf.bnpl_account_id
    and am.user_id        = mf.user_id
    and am.month          = mf.month
),
bnpl_util as (
  select
    a.user_id,
    a.base_month,
    to_char(b.month, 'FM000000') as year_month,
    sum(b.latest_balance)        as balance,
    sum(b.latest_bnpl_limit)     as total_limit
  from t_temp_union_pool a
  inner join bnpl_account_result b on a.user_id = b.user_id
    and b.month between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
  group by a.user_id, a.base_month, b.month
),

all_raw as (
  -- select user_id, base_month, year_month, balance, total_limit from lease_util
  -- union all
  select user_id, base_month, year_month, balance, total_limit from credit_util
  union all
  select user_id, base_month, year_month, balance, total_limit from bnpl_util
),
monthly_combined as (
  select
    user_id,
    base_month,
    year_month,
    case when sum(total_limit) > 0 then sum(balance) / sum(total_limit) else 0 end as util_ratio
  from all_raw
  group by user_id, base_month, year_month
)

select
  user_id,
  base_month,

  round(max(util_ratio), 2)                                                        as max_util_pct_w_2y,
  round(min(util_ratio), 2)                                                        as min_util_pct_w_2y,
  
  round(min(case when to_number(year_month) >=
    to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm'))
    then util_ratio end), 2)                                                       as min_util_pct_w_6m,

  round(max(case when to_number(year_month) >=
    to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -3), 'yyyymm'))
    then util_ratio end), 2)                                                       as max_util_pct_w_3m,

  round(max(util_ratio) keep (dense_rank last order by year_month), 2)             as latest_util_pct

from monthly_combined
group by user_id, base_month
order by user_id;

create table t_user_score_bnpl_repayment_temp as 
with user_pool as (
    select distinct user_id, base_month from t_temp_union_pool
    where user_id is not null
),
invoice_raw as (
  select distinct
    a.id_ as loan_request_id,
    to_number(to_char(trunc(a.created_at), 'yyyymmdd')) as loan_request_date,
    to_number(substr(to_char(trunc(a.created_at), 'yyyymmdd'), 1, 6)) as loan_request_month,
    a.amount as loan_request_amt,
    a.transaction_id as loan_transaction_id,
    a.account_id as user_id,
    a.bnpl_type as loan_type,
    a.method as loan_method,
    a.status as loan_status,
    b.id_ as invoice_id,
    b.amount as invoice_amt,
    to_number(to_char(trunc(b.payment_date), 'yyyymmdd')) as invoice_date,
    b.status as invoice_status,
    c.amount as repayment_amt,
    to_number(to_char(trunc(c.transaction_date), 'yyyymmdd')) as repayment_date,
    c.payment_type as repayment_type,
    c.status as repayment_status,
    b.payment_date as invoice_payment_date,
    c.transaction_date as repayment_transaction_date
  from toki.dpr_tajet_bnpl_request a
  left join toki.dpr_tajet_bnpl_invoice b on a.transaction_id = b.transaction_id and a.status not in ('CANCELLED', 'PENDING')
  left join toki.dpr_tajet_bnpl_repayment c on b.id_ = c.invoice_id and c.status in ('SUCCESS') and c.payment_type not in ('REFUND')
),
repayment_aggregation as (
  select
    i.loan_request_id,
    i.invoice_id,
    i.loan_type,
    i.loan_request_amt,
    i.invoice_amt,
    m.base_month,
    sum(case when i.loan_type = 'UNSTRICTED_1' and i.repayment_date <= to_number(to_char(last_day(to_date(to_char(m.base_month), 'yyyymm')), 'yyyymmdd')) then i.repayment_amt else 0 end) as total_repayment_model_unrestricted,
    max(case when i.loan_type = 'STRICTED_4' and i.repayment_date <= to_number(to_char(last_day(to_date(to_char(m.base_month), 'yyyymm')), 'yyyymmdd')) then i.repayment_amt else 0 end) as repayment_amt_model_restricted,
    sum(case when i.loan_type = 'UNSTRICTED_1' and i.repayment_date < to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), -1), 'yyyymmdd')) then i.repayment_amt else 0 end) as total_repayment_before_base_unrestricted,
    max(case when i.loan_type = 'STRICTED_4' and i.repayment_date < to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), -1), 'yyyymmdd')) then i.repayment_amt else 0 end) as repayment_amt_restricted
  from invoice_raw i
  inner join user_pool m on i.user_id = m.user_id
  where to_number(substr(to_char(i.invoice_date), 1, 6))
    between to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), -1), 'yyyymm'))
  group by i.loan_request_id, i.invoice_id, i.loan_type, i.loan_request_amt, i.invoice_amt, m.base_month
),
calculated_od as (
  select
    i.user_id,
    i.loan_request_id,
    i.invoice_id,
    i.loan_type,
    i.invoice_amt,
    i.invoice_date,
    i.loan_request_amt,
    i.repayment_type,
    i.repayment_transaction_date,
    i.invoice_payment_date,
    m.base_month,
    r.total_repayment_before_base_unrestricted,
    r.repayment_amt_restricted,
    case
      when to_number(substr(to_char(i.invoice_date), 1, 6)) between
          to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -24), 'yyyymm'))
          and m.base_month
      then
        case
          when i.repayment_type in ('REPAYMENT')
            and (case
              when i.loan_type = 'UNSTRICTED_1' and r.total_repayment_model_unrestricted >= i.loan_request_amt then 1
              when i.loan_type = 'STRICTED_4' and r.repayment_amt_model_restricted >= i.invoice_amt then 1
              else 0
            end) = 1
            and i.repayment_transaction_date is not null
            and i.repayment_transaction_date <= last_day(to_date(to_char(m.base_month), 'yyyymm'))
            then trunc(i.repayment_transaction_date) - trunc(i.invoice_payment_date)
          when i.repayment_type in ('REPAYMENT')
            and (case
              when i.loan_type = 'UNSTRICTED_1' and r.total_repayment_model_unrestricted >= i.loan_request_amt then 1
              when i.loan_type = 'STRICTED_4' and r.repayment_amt_model_restricted >= i.invoice_amt then 1
              else 0
            end) = 0
            and i.repayment_transaction_date is not null
            then last_day(to_date(to_char(m.base_month), 'yyyymm')) - trunc(i.invoice_payment_date)
          when i.repayment_type is null
            then last_day(to_date(to_char(m.base_month), 'yyyymm')) - trunc(i.invoice_payment_date)
          else 0
        end
      else null
    end as od
  from invoice_raw i
  inner join user_pool m on i.user_id = m.user_id
  left join repayment_aggregation r on i.loan_request_id = r.loan_request_id and i.invoice_id = r.invoice_id and m.base_month = r.base_month
  where to_number(substr(to_char(i.invoice_date), 1, 6))
    between to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -24), 'yyyymm'))
        and to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), -1), 'yyyymm'))
)

select distinct
  user_id,
  base_month,

  sum(case when od > 0 and repayment_type = 'REPAYMENT' then invoice_amt else 0 end) as od_inv_amt_w_2y,
  sum(case when od between 16 and 30 and repayment_type = 'REPAYMENT' then invoice_amt else 0 end) as od_30_inv_amt_w_2y,
  sum(case when od between 31 and 60 and repayment_type = 'REPAYMENT' then invoice_amt else 0 end) as od_60_inv_amt_w_2y,
  sum(case when od between 91 and 180 and repayment_type = 'REPAYMENT' then invoice_amt else 0 end) as od_180_inv_amt_w_2y,
  max(od) as max_od_w_2y,
  sum(od) as sum_od_w_2y,

  sum(case when od > 0 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -12), 'yyyymm')) then invoice_amt else 0 end) as od_inv_amt_w_1y,
  sum(case when od between 16 and 30 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -12), 'yyyymm')) then invoice_amt else 0 end) as od_30_inv_amt_w_1y,

  sum(case when od > 0 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_inv_amt_w_6m,
  sum(case when od between 1 and 15 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_15_inv_amt_w_6m,
  count(distinct case when od between 16 and 30 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_id end) as od_30_inv_cnt_w_6m,
  sum(case when od between 16 and 30 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_30_inv_amt_w_6m,
  sum(case when od between 61 and 90 and repayment_type = 'REPAYMENT' and to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_90_inv_amt_w_6m,
  max(case when to_number(substr(to_char(invoice_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then od end) as max_od_w_6m

from calculated_od
group by user_id, base_month;

create table t_user_score_credit_repayment_temp as 
with tmp_credit_invoice as (
  select
    b.user_id,
    b.base_month,
    i.invoice_id,
    i.invoice_type,
    i.principal_amt     as invoice_amt,
    i.target_month_date as invoice_month,
    i.fully_paid_date,
    i.due_date,
    case
      when trunc(i.due_date, 'MM') between add_months(to_date(to_char(b.base_month), 'yyyymm'), -24)
        and add_months(to_date(to_char(b.base_month), 'yyyymm'), -1)
      then
        case
          when i.fully_paid_date is not null
            and trunc(i.fully_paid_date, 'MM') <= to_date(to_char(b.base_month), 'yyyymm')
            then case when trunc(i.fully_paid_date) - trunc(i.due_date) >= 0
                      then trunc(i.fully_paid_date) - trunc(i.due_date) else 0 end
          else case when to_date(to_char(b.base_month), 'yyyymm') - trunc(i.due_date) >= 0
                    then to_date(to_char(b.base_month), 'yyyymm') - trunc(i.due_date) else 0 end
        end
      else null
    end as od
  from toki.credit_invoice i
  inner join toki.credit_credit cc on i.credit_id = cc.credit_id   
  inner join (
    select * from t_temp_union_pool
    where user_id is not null
    ) b on cc.user_id = b.user_id
    and trunc(i.due_date, 'MM') between add_months(to_date(to_char(b.base_month), 'yyyymm'), -24)
      and add_months(to_date(to_char(b.base_month), 'yyyymm'), -1)
      and i.principal_amt > 0
    --and i.invoice_type = 'MONTHLY'
)

select distinct
  user_id,
  base_month,

  sum(case when od > 0 and invoice_type = 'MONTHLY' then invoice_amt else 0 end) as od_inv_amt_w_2y,
  sum(case when od between 16 and 30 and invoice_type = 'MONTHLY' then invoice_amt else 0 end) as od_30_inv_amt_w_2y,
  sum(case when od between 31 and 60 and invoice_type = 'MONTHLY' then invoice_amt else 0 end) as od_60_inv_amt_w_2y,
  sum(case when od between 91 and 180 and invoice_type = 'MONTHLY' then invoice_amt else 0 end) as od_180_inv_amt_w_2y,
  sum(case when trunc(fully_paid_date, 'MM') <= to_date(to_char(base_month), 'yyyymm') and invoice_type = 'INSTANT' then invoice_amt else 0 end) as instant_inv_amt_w_2y,
  max(od) as max_od_w_2y,
  sum(od) as sum_od_w_2y,

  sum(case when od > 0 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -12) then invoice_amt else 0 end) as od_inv_amt_w_1y,
  sum(case when od between 16 and 30 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -12) then invoice_amt else 0 end) as od_30_inv_amt_w_1y,
  sum(case when od > 0 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_amt else 0 end) as od_inv_amt_w_6m,
  sum(case when od between 1 and 15 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_amt else 0 end) as od_15_inv_amt_w_6m,
  count(distinct case when od between 16 and 30 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_id end) as od_30_inv_cnt_w_6m,
  sum(case when od between 16 and 30 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_amt else 0 end) as od_30_inv_amt_w_6m,
  sum(case when od between 61 and 90 and invoice_type = 'MONTHLY' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_amt else 0 end) as od_90_inv_amt_w_6m,
  count(distinct case when trunc(fully_paid_date, 'MM') <= to_date(to_char(base_month), 'yyyymm') and invoice_type = 'INSTANT' and trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then invoice_id end) as instant_inv_cnt_w_6m,
  max(case when trunc(due_date, 'MM') >= add_months(to_date(to_char(base_month), 'yyyymm'), -6) then od end) as max_od_w_6m

from tmp_credit_invoice
group by user_id, base_month;

create table t_user_score_lease_repayment_temp as
with tmp_handset_invoice as (
    select 
        b.loan_id,
        a.id as invoice_id,
        b.id as loan_invoice_id,
        a.invoice_type,
        a.principal_amt,
        to_date(a.due_date, 'dd-mon-yy') as due_date
    from toki.handset_invoice a
    left join toki.handset_loan_invoice b on a.id = b.invoice_id
),
tmp_handset_repayment as (
    select 
        loan_id,
        loan_invoice_id,
        max(createdat) as createdat
    from (
        select 
            loan_id,
            loan_invoice_id,
            to_date(created_date, 'dd-mon-yy') as createdat
        from toki.handset_loan_repayment
    )
    group by loan_id, loan_invoice_id
),
handset_combined as (
    select distinct
        d.user_id,
        d.base_month,
        a.loan_id,
        to_number(to_char(trunc(c.loan_activated_date), 'yyyymmdd')) as loan_activated_date,
        a.invoice_id,
        to_number(a.principal_amt) as invoice_amt,
        a.invoice_type,
        to_number(to_char(trunc(rep.createdat), 'yyyymmdd')) as paid_date,
        to_number(to_char(trunc(a.due_date), 'yyyymmdd')) as due_date,
        case
            when trunc(a.due_date, 'MM') between add_months(to_date(to_char(d.base_month), 'yyyymm'), -24)
        and add_months(to_date(to_char(d.base_month), 'yyyymm'), -1)
            then
                case
                    when rep.createdat is not null
                        and trunc(rep.createdat, 'MM') <= to_date(to_char(d.base_month), 'yyyymm')
                    then trunc(rep.createdat) - trunc(a.due_date)
                    else to_date(to_char(d.base_month), 'yyyymm') - trunc(a.due_date)
                end
            else null
        end as od
    from tmp_handset_invoice a
    left join tmp_handset_repayment rep on a.loan_id = rep.loan_id and a.loan_invoice_id = rep.loan_invoice_id
    inner join toki.handset_orders b on to_number(a.loan_id) = b.loanid  --sync n zogsson tul orluulah shaardlagtai
    inner join toki.handset_loan c on a.loan_id = c.id
    inner join (
        select * from t_temp_union_pool 
        where user_id is not null
        ) d on b.accountid = d.user_id
        and trunc(a.due_date, 'MM') between add_months(to_date(to_char(d.base_month), 'yyyymm'), -24)
        and add_months(to_date(to_char(d.base_month), 'yyyymm'), -1)
    --where a.invoice_type = 'SCHEDULED' 
    where c.is_staff_deal = 0
    and a.principal_amt > 0
)

select distinct
  user_id,
  base_month,


  sum(case when od > 0 and invoice_type = 'SCHEDULED' then invoice_amt else 0 end) as od_inv_amt_w_2y,
  sum(case when od between 16 and 30 and invoice_type = 'SCHEDULED' then invoice_amt else 0 end) as od_30_inv_amt_w_2y,
  sum(case when od between 31 and 60 and invoice_type = 'SCHEDULED' then invoice_amt else 0 end) as od_60_inv_amt_w_2y,
  sum(case when od between 91 and 180 and invoice_type = 'SCHEDULED' then invoice_amt else 0 end) as od_180_inv_amt_w_2y,
  sum(case when to_number(substr(to_char(paid_date), 1, 6)) <= base_month and invoice_type = 'INSTANT' then invoice_amt else 0 end) as instant_inv_amt_w_2y,
  max(od) as max_od_w_2y,
  sum(od) as sum_od_w_2y,

  sum(case when od > 0 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -12), 'yyyymm')) then invoice_amt else 0 end) as od_inv_amt_w_1y,
  sum(case when od between 16 and 30 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -12), 'yyyymm')) then invoice_amt else 0 end) as od_30_inv_amt_w_1y,

  sum(case when od > 0 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_inv_amt_w_6m,
  sum(case when od between 1 and 15 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_15_inv_amt_w_6m,
  count(distinct case when od between 16 and 30 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_id end) as od_30_inv_cnt_w_6m,
  sum(case when od between 16 and 30 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_30_inv_amt_w_6m,
  sum(case when od between 61 and 90 and invoice_type = 'SCHEDULED' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_amt else 0 end) as od_90_inv_amt_w_6m,
  count(distinct case when to_number(substr(to_char(paid_date), 1, 6)) <= base_month and invoice_type = 'INSTANT' and to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then invoice_id end) as instant_inv_cnt_w_6m,
  max(case when to_number(substr(to_char(due_date), 1, 6)) >= to_number(to_char(add_months(to_date(to_char(base_month), 'yyyymm'), -6), 'yyyymm')) then od end) as max_od_w_6m

from handset_combined
group by user_id, base_month;

create table t_user_score_credit_usage_temp as 
with base_data as (
  select
    t.user_id,
    t.base_month,
    lr.merchant_name,
    lr.product_name,
    lr.product_price,
    lr.created_date,
    trunc(lr.created_date) as usage_date

  from toki.credit_loan_request lr
  inner join toki.credit_credit cc on lr.credit_id = cc.credit_id
  inner join t_temp_union_pool t on cc.user_id = t.user_id
  and trunc(lr.created_date, 'MM') between add_months(to_date(to_char(t.base_month), 'yyyymm'), -24)
  and add_months(to_date(to_char(t.base_month), 'yyyymm'), -1)
  and lr.loan_type = 'PURCHASE' and lr.request_status = 'SUCCESS'
),
daily_usage as (
  select
    user_id,
    base_month,
    usage_date,
    usage_date - row_number() over (partition by user_id, base_month order by usage_date) as island_id
  from (
    select distinct user_id, base_month, usage_date
    from base_data
  )
)
  select
    user_id,
    base_month,

    count(*)                                                                                 as credit_usage_cnt_w_2y,
    sum(product_price)                                                                       as credit_usage_amt_w_2y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -12) then product_price end)                 as credit_usage_amt_w_1y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -3) then product_price end)                 as credit_usage_amt_w_3m,
    to_date(to_char(base_month), 'yyyymm') - max(trunc(created_date))                                                                 as max_usage_date

  from base_data
  group by user_id, base_month

create table t_user_score_lease_usage_temp as
with raw_data as (
select
  accountid as userid,
  json_value(products,  '$[0].modelName') as model_name,
  json_value(products,  '$[0].type') as product_type,
  to_number(loanamount) as loanamount,
  to_number(to_char(trunc(to_date(substr(createdat, 1, 10), 'yyyy-mm-dd')), 'yyyymmdd')) as createdat
from (
  select * from toki.handset_orders
  where orderstatus not in ('PENDING', 'CANCELLED')
)

union all

select
  json_value(customer, '$.accountId') as userid,
  json_value(products,  '$[0].modelName') as model_name,
  json_value(products,  '$[0].inventoryType') as product_type,
  to_number(totalprice) as loanamount,
  to_number(to_char(trunc(createdat), 'yyyymmdd')) as createdat
from (
  select * from toki.marketplace_handset_orders
  where orderstatus not in ('PENDING', 'CANCELLED')
)
),
base_data as (
  select
    r.userid,
    t.base_month,
    r.model_name,
    r.product_type,
    r.loanamount,
    r.createdat,
    to_date(to_char(r.createdat), 'yyyymmdd') as usage_date,
    case
      when regexp_like(r.model_name, 'iphone',                                        'i') then 'phone_iphone'
      when regexp_like(r.model_name, 'apple.+watch|apple watch',                      'i') then 'watch_apple'
      when regexp_like(r.model_name, 'airpod|magsafe',                                'i') then 'accessory_apple'
      when regexp_like(r.model_name, '(samsung|galaxy).*(watch|band)',                'i') then 'watch_samsung'
      when regexp_like(r.model_name, 'galaxy.*buds|samsung.*(adapter|headphone)|akg', 'i') then 'accessory_samsung'
      when regexp_like(r.model_name, 'samsung|galaxy',                                'i') then 'phone_samsung'
      when regexp_like(r.model_name, 'huawei.*(watch|band|fit)',                      'i') then 'watch_huawei'
      when regexp_like(r.model_name, 'huawei.*(free.?buds|freebuds)',                 'i') then 'accessory_huawei'
      when regexp_like(r.model_name, 'huawei',                                        'i') then 'phone_huawei'
      when regexp_like(r.model_name, 'zte',                                           'i') then 'phone_zte'
      when regexp_like(r.model_name, 'adapter',                                       'i') then 'accessory_adapter'
      else 'other'
    end as model_group

  from raw_data r
  inner join t_temp_union_pool t on r.userid = t.user_id
  and trunc(to_date(to_char(r.createdat), 'yyyymmdd'), 'MM') between add_months(to_date(to_char(t.base_month), 'yyyymm'), -24)
  and add_months(to_date(to_char(t.base_month), 'yyyymm'), -1)
),

daily_usage as (
  select
    userid,
    base_month,
    usage_date,
    usage_date - row_number() over (partition by userid, base_month order by usage_date) as island_id
  from (
    select distinct userid, base_month, usage_date
    from base_data
  )
)
  select
    userid,
    base_month,

    count(*)                                                                                 as lease_usage_cnt_w_2y,
    sum(loanamount)                                                                          as lease_usage_amt_w_2y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -12) then loanamount end)                   as lease_usage_amt_w_1y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -3) then loanamount end)                   as lease_usage_amt_w_3m,

    to_date(to_char(base_month), 'yyyymm') - max(usage_date)                                                                    as days_since_last_lease_usage

  from base_data
  group by userid, base_month

create table t_user_score_age_test as
select
  user_id,
  base_month,
  floor(months_between(
    to_date(to_char(base_month, 'FM000000'), 'YYYYMM'),
    parsed_dob
  ) / 12) as age
from (
  select
    a.user_id,
    a.base_month,
    case
      when b.dob like '____-__-__'
        and to_number(substr(b.dob, 6, 2)) between 1 and 12
        and to_number(substr(b.dob, 9, 2)) between 1 and 31
        then to_date(b.dob, 'YYYY-MM-DD')
      when b.dob like '__/__/____'
        and to_number(substr(b.dob, 4, 2)) between 1 and 12
        and to_number(substr(b.dob, 1, 2)) between 1 and 31
        then to_date(b.dob, 'DD/MM/YYYY')
    end as parsed_dob
  from t_temp_union_pool a
  inner join toki.dpr_maat_customers b on a.user_id = b.identifier
  where b.dob is not null

create table t_user_score_bnpl_usage_temp as
with merchant_raw as (
  select
    a.account_id,
    trunc(b.transaction_date) as usage_date,
    a.transaction_id,
    a.amount,
    c.merchant_name,
    t.base_month
  from toki.dpr_tajet_bnpl_request a
  left join toki.dpr_tajet_teller_transactions b on b.identifier = a.transaction_id
  left join t_merchant_lookup c on c.merchant_id = b.target_account_identifier
  inner join t_temp_union_pool t on a.account_id = t.user_id
    and trunc(b.transaction_date, 'MM') between add_months(to_date(to_char(t.base_month), 'yyyymm'), -24)
    and add_months(to_date(to_char(t.base_month), 'yyyymm'), -1)
  where status <> 'CANCELED'
)
  select
    account_id,
    base_month,

    count(*)                                                                                 as bnpl_usage_cnt_w_2y,
    sum(amount)                                                                              as bnpl_usage_amt_w_2y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -12) then amount end)                       as bnpl_usage_amt_w_1y,
    sum(case when usage_date >= add_months(to_date(to_char(base_month), 'yyyymm'), -3) then amount end)                       as bnpl_usage_amt_w_3m,

    to_date(to_char(base_month), 'yyyymm') - max(usage_date)                                                                          as days_since_last_bnpl_usage

  from merchant_raw
  group by account_id, base_month
)