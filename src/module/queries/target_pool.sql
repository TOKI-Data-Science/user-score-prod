create table t_temp_bnpl_pool as
with latest_records as (
    select
        bnpl_account_id,
        user_id,
        bnpl_limit,
        status,
        row_number() over (partition by bnpl_account_id order by created_date desc) as rn
    from toki.bnpl_account_history
    where product in ('DEFAULT')
      and last_action_made_date is not null
      and trunc(created_date) <= trunc(sysdate) - 1
),
current_snapshot as (
    select bnpl_account_id, user_id, bnpl_limit, status
    from latest_records
    where rn = 1
),
first_loan_dates as (
  select
    user_id,
    min(created_date) as first_loan_date
  from toki.bnpl_account_history
  where created_by_action in ('loan')
  group by user_id
)
select
  cs.user_id,
  to_number(to_char(sysdate - 1, 'yyyymm')) as base_month,
  sum(cs.bnpl_limit) as total_bnpl_limit,
  min(cs.status)     as status,
  floor(months_between(trunc(sysdate - 1, 'mm'), trunc(fld.first_loan_date, 'mm'))) as mob
from current_snapshot cs
join first_loan_dates fld on cs.user_id = fld.user_id
group by cs.user_id, fld.first_loan_date
having floor(months_between(trunc(sysdate - 1, 'mm'), trunc(fld.first_loan_date, 'mm'))) >= 0
order by cs.user_id;

create table t_temp_bnpl_pool_od as
with user_pool as (
    select distinct user_id, base_month, mob from t_temp_bnpl_pool
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
  inner join toki.dpr_tajet_bnpl_invoice b on a.transaction_id = b.transaction_id and a.status not in ('CANCELLED', 'PENDING')
  inner join toki.dpr_tajet_bnpl_repayment c on b.id_ = c.invoice_id and c.status in ('SUCCESS') and c.payment_type not in ('REFUND')
),
repayment_aggregation as (
  select
    i.loan_request_id,
    i.invoice_id,
    i.loan_type,
    i.loan_request_amt,
    i.invoice_amt,
    m.base_month,
    m.mob,
    sum(case when i.loan_type = 'UNSTRICTED_1' and i.repayment_date <= to_number(to_char(last_day(to_date(to_char(m.base_month), 'yyyymm')), 'yyyymmdd')) then i.repayment_amt else 0 end) as total_repayment_model_unrestricted,
    max(case when i.loan_type = 'STRICTED_4' and i.repayment_date <= to_number(to_char(last_day(to_date(to_char(m.base_month), 'yyyymm')), 'yyyymmdd')) then i.repayment_amt else 0 end) as repayment_amt_model_restricted,
    sum(case when i.loan_type = 'UNSTRICTED_1' and i.repayment_date < to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), 12), 'yyyymmdd')) then i.repayment_amt else 0 end) as total_repayment_before_base_unrestricted,
    max(case when i.loan_type = 'STRICTED_4' and i.repayment_date < to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), 12), 'yyyymmdd')) then i.repayment_amt else 0 end) as repayment_amt_restricted
  from invoice_raw i
  right join user_pool m on i.user_id = m.user_id
  where to_number(substr(to_char(i.invoice_date), 1, 6))
    between to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -6), 'yyyymm'))
        and to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), 12), 'yyyymm'))
  group by i.loan_request_id, i.invoice_id, i.loan_type, i.loan_request_amt, i.invoice_amt, m.base_month, m.mob
),
calculated_od as (
  select
    i.user_id,
    i.loan_request_id,
    i.invoice_id,
    i.loan_type,
    i.invoice_amt,
    i.loan_request_amt,
    i.repayment_type,
    i.repayment_transaction_date,
    i.invoice_payment_date,
    m.base_month,
    m.mob,
    r.total_repayment_before_base_unrestricted,
    r.repayment_amt_restricted,
    case
      when i.loan_type = 'UNSTRICTED_1' and r.total_repayment_before_base_unrestricted >= i.loan_request_amt then 1
      when i.loan_type = 'STRICTED_4' and r.repayment_amt_restricted >= i.invoice_amt then 1
      else 0
    end as is_paid,
    case
      when to_number(substr(to_char(i.invoice_date), 1, 6)) between
           to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -6), 'yyyymm'))
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
    end as model_od_raw
  from invoice_raw i
  right join user_pool m on i.user_id = m.user_id
  left join repayment_aggregation r on i.loan_request_id = r.loan_request_id and i.invoice_id = r.invoice_id and m.base_month = r.base_month
  where to_number(substr(to_char(i.invoice_date), 1, 6))
    between to_number(to_char(add_months(to_date(to_char(m.base_month), 'yyyymm'), -6), 'yyyymm'))
        and to_number(to_char(add_months(last_day(to_date(to_char(m.base_month), 'yyyymm')), 12), 'yyyymm'))
)
select
  user_id,
  base_month,
  mob,
  max(case when model_od_raw >= 0 then model_od_raw else 0 end) as model_od
from calculated_od
group by user_id, base_month, mob;

create table t_temp_credit_pool as
with first_loans as (
  select
    cc.user_id,
    trunc(min(cch.created_date)) as first_loan_date
  from toki.credit_credit_history cch
  join toki.credit_credit cc on cch.credit_id = cc.credit_id
  where cch.created_by_action in ('add_loan', 'issued_loan')
  group by cc.user_id
)
select
  to_char(trunc(sysdate) - 1, 'yyyymmdd') as p_date,
  cc.user_id,
  floor(months_between(
    trunc(sysdate - 1, 'mm'),
    trunc(f.first_loan_date, 'mm')
  )) as mob
from toki.credit_m_credit cm
join toki.credit_credit cc on cm.credit_id = cc.credit_id
join first_loans f on cc.user_id = f.user_id
where cm.p_date = to_char(trunc(sysdate) - 1, 'yyyymmdd')
group by cc.user_id, f.first_loan_date;

create table t_temp_credit_pool_od as
with tmp_credit_invoice as (
  select
    b.user_id,
    b.p_date,
    b.mob,
    i.invoice_id,
    i.invoice_type,
    i.principal_amt     as invoice_amt,
    i.target_month_date as invoice_month,
    i.fully_paid_date,
    i.due_date,
    case
      when trunc(i.due_date) between add_months(to_date(b.p_date, 'yyyymmdd'), -6)
                                 and to_date(b.p_date, 'yyyymmdd')
      then
        case
          when i.fully_paid_date is not null
            and i.fully_paid_date <= to_date(b.p_date, 'yyyymmdd')
            then case when round(i.fully_paid_date - i.due_date, 0) >= 0
                      then round(i.fully_paid_date - i.due_date, 0) else 0 end
          else case when round(to_date(b.p_date, 'yyyymmdd') - i.due_date, 0) >= 0
                    then round(to_date(b.p_date, 'yyyymmdd') - i.due_date, 0) else 0 end
        end
      else null
    end as model_overdue_days
  from toki.credit_invoice i
  inner join toki.credit_credit cc on i.credit_id = cc.credit_id   
  right join t_temp_credit_pool b on cc.user_id = b.user_id
    and trunc(i.due_date) between add_months(to_date(b.p_date, 'yyyymmdd'), -6)
                              and add_months(to_date(b.p_date, 'yyyymmdd'), 12)
    and i.invoice_type = 'MONTHLY'
)
select
  user_id,
  p_date,
  mob,
  max(model_overdue_days) as model_od
from tmp_credit_invoice
group by user_id, p_date, mob;

create table t_temp_lease_pool as
with first_activations as (
  select
    ssn,
    min(activated_date) as first_activated_date
  from toki.t_dm_handset
  group by ssn
)
select
  to_char(trunc(sysdate) - 1, 'yyyymmdd') as p_date,
  h.ssn,
  floor(months_between(
    trunc(sysdate - 1, 'mm'),
    trunc(to_date(f.first_activated_date, 'yyyymmdd'), 'mm')
  )) as mob
from toki.t_dm_handset h
join first_activations f on h.ssn = f.ssn
where h.p_date = to_char(trunc(sysdate) - 1, 'yyyymmdd')
group by h.ssn, f.first_activated_date;

create table t_temp_lease_pool_od as
with tmp_handset_invoice as (
    select 
        b.loan_id,
        a.id as invoice_id,
        b.id as loan_invoice_id,
        a.invoice_type,
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
        d.ssn,
        d.p_date,
        d.mob,
        a.loan_id,
        to_number(to_char(trunc(c.loan_activated_date), 'yyyymmdd')) as loan_activated_date,
        c.principal_amt,
        a.invoice_id,
        to_number(to_char(trunc(rep.createdat), 'yyyymmdd')) as paid_date,
        to_number(to_char(trunc(a.due_date), 'yyyymmdd')) as due_date,
        case
            when trunc(a.due_date) between add_months(to_date(d.p_date, 'yyyymmdd'), -6)
                                       and to_date(d.p_date, 'yyyymmdd')
            then
                case
                    when rep.createdat is not null and rep.createdat <= to_date(d.p_date, 'yyyymmdd')
                    then rep.createdat - a.due_date
                    else to_date(d.p_date, 'yyyymmdd') - trunc(a.due_date)
                end
            else null
        end as model_overdue_days
    from tmp_handset_invoice a
    left join tmp_handset_repayment rep on a.loan_id = rep.loan_id and a.loan_invoice_id = rep.loan_invoice_id
    inner join toki.handset_orders b on to_number(a.loan_id) = b.loanid
    inner join toki.handset_loan c on a.loan_id = c.id
    right join t_temp_lease_pool d on b.nationalid = d.ssn
        and trunc(a.due_date) between add_months(to_date(d.p_date, 'yyyymmdd'), -6)
                                  and add_months(to_date(d.p_date, 'yyyymmdd'), 12)
    where a.invoice_type = 'SCHEDULED' --and c.is_staff_deal = 0
) 
select 
  ssn,
  p_date,
  mob,
  max(model_overdue_days) as model_od
from handset_combined
group by ssn, p_date, mob;

create table t_temp_lease_pool_od2 as 
select b.identifier as user_id, to_number(substr(to_char(a.p_date), 1, 6)) as base_month, a.mob, a.model_od
from t_temp_lease_pool_od a
inner join toki.dpr_maat_customers b on lower(a.ssn) = lower(b.id_value) 
and to_number(to_char(trunc(b.created_on), 'yyyymm')) <= to_number(substr(to_char(a.p_date), 1, 6))
;

-- CREATE TABLE t_temp_mongo_pool AS
-- WITH run_parameters AS (
--   SELECT TO_NUMBER(TO_CHAR(SYSDATE - 1, 'YYYYMM')) AS base_month
--   FROM dual
-- ), mongo_contracts AS (
--   SELECT
--     id_,
--     CASE
--       WHEN REGEXP_LIKE(timestamp_ms, '^[0-9]{13}$')
--       THEN DATE '1970-01-01' + TO_NUMBER(timestamp_ms) / 86400000
--     END AS contract_date
--   FROM (
--     SELECT
--       id_,
--       COALESCE(
--         REGEXP_SUBSTR(imsaccount, 'signedAt[^0-9]*([0-9]{13})', 1, 1, NULL, 1),
--         REGEXP_SUBSTR(imsaccount, 'FILE_([0-9]{13})', 1, 1, NULL, 1),
--         REGEXP_SUBSTR(imsaccount, 'IDENTIFIER_([0-9]{13})', 1, 1, NULL, 1)
--       ) AS timestamp_ms
--     FROM toki.mongo_users
--   ) parsed_users
-- ), base_data AS (
--   SELECT
--     customer.identifier AS user_id,
--     TO_NUMBER(TO_CHAR(TRUNC(contract.contract_date), 'YYYYMM')) AS contract_month,
--     CASE
--       WHEN customer.current_state NOT IN ('ACTIVE')
--       THEN TO_NUMBER(TO_CHAR(TRUNC(archive.lastactivitytime), 'YYYYMM'))
--     END AS end_month
--   FROM toki.dpr_maat_customers customer
--   LEFT JOIN mongo_contracts contract
--     ON customer.identifier = contract.id_
--      AND customer.customer_type = 'REGISTERED'
--   LEFT JOIN toki.mongo_userarchives archive
--     ON customer.identifier = archive.id_
-- )
-- SELECT
--   data.user_id,
--   parameters.base_month,
--   0 AS mob,
--   0 AS model_od
-- FROM base_data data
-- CROSS JOIN run_parameters parameters
-- WHERE data.contract_month <= parameters.base_month
--   AND (data.end_month IS NULL OR data.end_month >= parameters.base_month)
-- ORDER BY data.user_id;

CREATE TABLE t_temp_mongo_pool AS
SELECT
  identifier AS user_id,
  TO_NUMBER(TO_CHAR(SYSDATE - 1, 'YYYYMM')) AS base_month,
  0 AS mob,
  0 AS model_od
FROM toki.dpr_maat_customers
WHERE customer_type = 'REGISTERED'
  AND current_state = 'ACTIVE';

create table t_temp_union_pool as
select a.*, c.register_based_id from (
select distinct user_id, base_month, product, mob, model_od
from (
  select user_id, to_number(substr(to_char(p_date), 1, 6)) as base_month, 'credit' as product, mob, model_od
  from t_temp_credit_pool_od

  union all

  select user_id, base_month, 'lease' as product, mob, model_od
  from t_temp_lease_pool_od2

  union all

  select user_id, base_month, 'bnpl' as product, mob, model_od
  from t_temp_bnpl_pool_od
  where base_month >= 202412

  union all

  select user_id, base_month, 'other' as product, mob, model_od
  from t_temp_mongo_pool
)
where user_id is not null
) a
left join toki.dpr_maat_customers b on a.user_id = b.identifier
left join toki.t_toki_user_identity c on lower(b.id_value) = lower(c.ssn);

create table t_temp_user_map as
select distinct
  coalesce(c.register_based_id, b.identifier) as register_based_id,
  b.identifier as user_id
from toki.dpr_maat_customers b
left join toki.t_toki_user_identity c on lower(b.id_value) = lower(c.ssn);

drop table t_temp_bnpl_pool;
drop table t_temp_bnpl_pool_od;
drop table t_temp_credit_pool;
drop table t_temp_credit_pool_od;
drop table t_temp_lease_pool;
drop table t_temp_lease_pool_od;
drop table t_temp_lease_pool_od2;
drop table t_temp_mongo_pool;
