create table t_user_score_balance_temp as 
with lease_raw as (
  select distinct
    a.user_id,
    a.decision_engine_successful_date,
    a.limit                as total_limit,
    c.principal_amt        as total_loan_amt
  from (
    select * from toki.handset_tmp_limit_request
    where limit > 0
      and user_id is not null
  ) a
  inner join toki.handset_borrower b on a.user_id = b.user_id
  inner join toki.handset_loan c
    on b.id = c.borrower_id
    and c.loan_activated_date between a.decision_engine_successful_date
                                  and a.decision_engine_successful_date + 1
    and c.status not in ('PENDING')
),
lease_monthly as (
  select
    user_id,
    to_char(trunc(decision_engine_successful_date), 'yyyymm') as year_month,
    sum(total_limit)     as total_limit,
    sum(total_loan_amt)  as total_loan_amt
  from lease_raw
  group by user_id, to_char(trunc(decision_engine_successful_date), 'yyyymm')
),
lease_util as (
  select
    a.register_based_id,
    a.base_month,
    ms.year_month,
    sum(ms.total_loan_amt) as balance,
    sum(ms.total_limit)    as total_limit
  from (select distinct register_based_id, base_month from t_temp_union_pool) a
  inner join t_temp_user_map m on a.register_based_id = m.register_based_id
  inner join lease_monthly ms on ms.user_id = m.user_id
    and to_number(ms.year_month) between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -12), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
  group by a.register_based_id, a.base_month, ms.year_month
),

credit_monthly as (
  select
    p.register_based_id,
    p.base_month,
    c.credit_id,
    to_char(cch.created_date, 'yyyymm')                                                     as year_month,
    max(cch.credit_limit) keep (dense_rank last order by cch.created_date)                  as credit_limit,
    coalesce(max(cch.balance) keep (dense_rank last order by cch.created_date), 0)          as balance
  from toki.credit_credit_history cch
  inner join toki.credit_credit c on cch.credit_id = c.credit_id
  inner join t_temp_user_map m on c.user_id = m.user_id
  inner join (select distinct register_based_id, base_month from t_temp_union_pool) p on m.register_based_id = p.register_based_id
  where cch.created_date is not null
    and to_number(to_char(cch.created_date, 'yyyymm')) between
        to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -12), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(p.base_month), 'yyyymm'), -1), 'yyyymm'))
  group by p.register_based_id, p.base_month, c.credit_id, to_char(cch.created_date, 'yyyymm')
),
credit_latest_month as (
  select register_based_id, base_month, credit_id, max(year_month) as latest_month
  from credit_monthly
  group by register_based_id, base_month, credit_id
),
latest_credit as (
  select register_based_id, base_month, credit_id,
    row_number() over (
      partition by register_based_id, base_month
      order by latest_month desc, credit_id desc
    ) as rn
  from credit_latest_month
),
credit_util as (
  select
    ms.register_based_id,
    ms.base_month,
    ms.year_month,
    ms.balance,
    ms.credit_limit as total_limit
  from latest_credit lc
  inner join credit_monthly ms
    on ms.register_based_id = lc.register_based_id and ms.base_month = lc.base_month and ms.credit_id = lc.credit_id
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
    a.register_based_id,
    a.base_month,
    to_char(b.month, 'FM000000') as year_month,
    sum(b.latest_balance)        as balance,
    sum(b.latest_bnpl_limit)     as total_limit
  from (select distinct register_based_id, base_month from t_temp_union_pool) a
  inner join t_temp_user_map m on a.register_based_id = m.register_based_id
  inner join bnpl_account_result b on m.user_id = b.user_id
    and b.month between
        to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -12), 'yyyymm'))
        and to_number(to_char(add_months(to_date(to_char(a.base_month), 'yyyymm'), -1), 'yyyymm'))
  group by a.register_based_id, a.base_month, b.month
),

all_raw as (
  select register_based_id, base_month, year_month, balance, total_limit from lease_util
  union all
  select register_based_id, base_month, year_month, balance, total_limit from credit_util
  union all
  select register_based_id, base_month, year_month, balance, total_limit from bnpl_util
)
  select
    register_based_id,
    base_month,
    sum(balance) as total_balance
  from all_raw
  group by register_based_id, base_month;

create table t_user_score_inactive_tag as
select distinct
  a.*,
  case
    when nvl(a.loan_usage_amt_w_1y, 0) = 0 and (nvl(a.loan_od_inv_amt_w_1y, 0)) = 0 and nvl(total_balance, 0) = 0 then 1
    else 0 end as is_inactive_w_12m
from t_user_score_feature_set_temp a
left join t_user_score_balance_temp b on a.register_based_id = b.register_based_id and a.base_month = b.base_month;

drop table t_temp_union_pool;
drop table t_temp_user_map;
drop table t_user_score_balance_temp;
drop table t_user_score_feature_set_temp;
