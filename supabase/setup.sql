-- 여행 가계부 · Supabase 설정 스크립트
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전합니다.
--
-- 보안 구조
--  - 테이블은 직접 읽거나 쓸 수 없게 잠급니다(RLS 켜고 정책 없음).
--  - 앱은 아래 함수들만 호출합니다.
--  - 여행에 들어가려면 멤버 이름 + 비밀번호로 로그인해서 세션 토큰을 받아야 합니다.
--    (처음 들어오는 멤버는 그때 자기 비밀번호를 정합니다. 비밀번호는 bcrypt 해시로만 저장)
--  - 공동 지출·일정표는 로그인한 멤버 모두가 보고, 개인 지출은 본인 세션으로만 읽고 쓸 수 있습니다.
--  - 비밀번호를 5번 틀리면 5분 동안 잠깁니다.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists public.trips (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 40),
  fx_cur      text not null default 'JPY' check (fx_cur ~ '^[A-Z]{3}$'),
  fx_unit     int  not null default 100 check (fx_unit in (1, 100)),
  rate        numeric not null check (rate > 0 and rate < 1000000),
  start_date  date not null,
  end_date    date not null check (end_date >= start_date and end_date - start_date <= 60),
  members     jsonb not null default '[]'::jsonb
              check (jsonb_typeof(members) = 'array' and jsonb_array_length(members) between 1 and 20),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  amount      numeric not null check (amount > 0 and amount < 1000000000000),
  currency    text not null check (currency in ('KRW', 'FX')),
  category    text not null default 'food' check (char_length(category) <= 20),
  title       text not null default '' check (char_length(title) <= 60),
  day         text not null check (char_length(day) <= 10),
  payer       text not null check (char_length(payer) <= 40),
  split       jsonb not null default '[]'::jsonb
              check (jsonb_typeof(split) = 'array' and jsonb_array_length(split) between 1 and 20),
  created_at  timestamptz not null default now()
);
create index if not exists expenses_trip_idx on public.expenses (trip_id);

-- 멤버별 비밀번호 (bcrypt 해시)
create table if not exists public.trip_creds (
  trip_id      uuid not null references public.trips(id) on delete cascade,
  member_id    text not null check (char_length(member_id) <= 40),
  pw_hash      text not null,
  fails        int  not null default 0,
  locked_until timestamptz,
  primary key (trip_id, member_id)
);

-- 로그인 세션 (30일)
create table if not exists public.trip_sessions (
  token       uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  member_id   text not null,
  expires_at  timestamptz not null default now() + interval '30 days'
);
create index if not exists trip_sessions_trip_idx on public.trip_sessions (trip_id);

-- 여행 일정표 (공유)
create table if not exists public.plans (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  day         text not null check (char_length(day) <= 10),
  start_time  text not null default '' check (start_time = '' or start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  title       text not null check (char_length(title) between 1 and 60),
  place       text not null default '' check (char_length(place) <= 500),
  currency    text not null default 'FX' check (currency in ('KRW', 'FX')),
  meal        numeric not null default 0 check (meal >= 0 and meal < 1000000000000),
  transport   numeric not null default 0 check (transport >= 0 and transport < 1000000000000),
  sight       numeric not null default 0 check (sight >= 0 and sight < 1000000000000),
  memo        text not null default '' check (char_length(memo) <= 200),
  created_at  timestamptz not null default now()
);
create index if not exists plans_trip_idx on public.plans (trip_id);

-- 개인 지출 (본인만 보기)
create table if not exists public.personal_expenses (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references public.trips(id) on delete cascade,
  member_id   text not null check (char_length(member_id) <= 40),
  amount      numeric not null check (amount > 0 and amount < 1000000000000),
  currency    text not null check (currency in ('KRW', 'FX')),
  category    text not null default 'food' check (char_length(category) <= 20),
  title       text not null default '' check (char_length(title) <= 60),
  day         text not null check (char_length(day) <= 10),
  created_at  timestamptz not null default now()
);
create index if not exists personal_trip_member_idx on public.personal_expenses (trip_id, member_id);

-- 일정표 항목과 비용 연결 (일정을 지워도 비용 기록은 남음)
alter table public.expenses          add column if not exists plan_id uuid references public.plans(id) on delete set null;
alter table public.personal_expenses add column if not exists plan_id uuid references public.plans(id) on delete set null;
create index if not exists expenses_plan_idx on public.expenses (plan_id);
create index if not exists personal_plan_idx on public.personal_expenses (plan_id);

-- 일정표 순서 (드래그로 바꾼 순서. null이면 시간순)
alter table public.plans add column if not exists sort_order int;

-- 짧은 여행 코드 (헷갈리는 글자 0 O 1 I L 제외, 6자리) — 링크와 앱 입력용
create or replace function public._new_trip_code()
returns text
language plpgsql volatile set search_path = public as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(a, 1 + floor(random() * length(a))::int, 1);
    end loop;
    exit when not exists (select 1 from trips where code = c);
  end loop;
  return c;
end $$;
revoke all on function public._new_trip_code() from public, anon, authenticated;

alter table public.trips add column if not exists code text;
update public.trips set code = public._new_trip_code() where code is null;
alter table public.trips alter column code set default public._new_trip_code();
alter table public.trips alter column code set not null;
create unique index if not exists trips_code_key on public.trips (code);

-- 테이블 직접 접근 차단
alter table public.trips             enable row level security;
alter table public.expenses          enable row level security;
alter table public.trip_creds        enable row level security;
alter table public.trip_sessions     enable row level security;
alter table public.plans             enable row level security;
alter table public.personal_expenses enable row level security;
revoke all on public.trips, public.expenses, public.trip_creds, public.trip_sessions,
              public.plans, public.personal_expenses from anon, authenticated;

-- ---------------------------------------------------------------- 이전 버전 함수 제거 (로그인 없이 쓰던 함수)
drop function if exists public.create_trip(text, text, int, numeric, date, date, jsonb);
drop function if exists public.get_trip(uuid);
drop function if exists public.update_trip(uuid, text, text, int, numeric, date, date, jsonb);
drop function if exists public.delete_trip(uuid);
drop function if exists public.save_expense(uuid, uuid, numeric, text, text, text, text, text, jsonb);
drop function if exists public.delete_expense(uuid, uuid);
drop function if exists public.save_personal(uuid, uuid, numeric, text, text, text, text);

-- ---------------------------------------------------------------- 세션 확인 (내부용)
create or replace function public._auth(p_token uuid, out o_trip uuid, out o_member text)
language plpgsql stable security definer set search_path = public as $$
begin
  select s.trip_id, s.member_id into o_trip, o_member
    from trip_sessions s where s.token = p_token and s.expires_at > now();
  if o_trip is null then raise exception 'unauthorized'; end if;
end $$;
revoke all on function public._auth(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 로그인
-- 로그인 화면용: 여행 이름과 멤버 목록만 (지출·일정은 없음)
create or replace function public.trip_public(p_trip uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'name', t.name, 'start_date', t.start_date, 'end_date', t.end_date,
    'fx_cur', t.fx_cur, 'members', t.members,
    'pw_set', coalesce((select jsonb_agg(c.member_id) from trip_creds c where c.trip_id = t.id), '[]'::jsonb))
  from trips t where t.id = p_trip
$$;

-- 여행 코드 → 여행 ID
create or replace function public.resolve_trip(p_code text)
returns uuid
language sql stable security definer set search_path = public as $$
  select id from trips where code = upper(trim(p_code))
$$;

-- 처음이면 비밀번호를 정하고, 아니면 확인한 뒤 세션 토큰을 돌려줌
-- 반환: {"ok":true,"token":...} 또는 {"ok":false,"reason":"wrong"|"locked"|"member"|"short"}
create or replace function public.login(p_trip uuid, p_member text, p_pw text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c trip_creds; v_tok uuid;
begin
  if not exists (select 1 from trips t where t.id = p_trip
                   and t.members @> jsonb_build_array(jsonb_build_object('id', p_member))) then
    return jsonb_build_object('ok', false, 'reason', 'member');
  end if;
  if p_pw is null or char_length(p_pw) < 4 or char_length(p_pw) > 64 then
    return jsonb_build_object('ok', false, 'reason', 'short');
  end if;

  select * into c from trip_creds where trip_id = p_trip and member_id = p_member for update;
  if not found then
    insert into trip_creds (trip_id, member_id, pw_hash)
    values (p_trip, p_member, crypt(p_pw, gen_salt('bf')));
  else
    if c.locked_until is not null and c.locked_until > now() then
      return jsonb_build_object('ok', false, 'reason', 'locked');
    end if;
    if c.pw_hash <> crypt(p_pw, c.pw_hash) then
      update trip_creds
         set fails = case when c.fails + 1 >= 5 then 0 else c.fails + 1 end,
             locked_until = case when c.fails + 1 >= 5 then now() + interval '5 minutes' else null end
       where trip_id = p_trip and member_id = p_member;
      return jsonb_build_object('ok', false, 'reason', case when c.fails + 1 >= 5 then 'locked' else 'wrong' end);
    end if;
    update trip_creds set fails = 0, locked_until = null where trip_id = p_trip and member_id = p_member;
  end if;

  delete from trip_sessions where expires_at < now();
  insert into trip_sessions (trip_id, member_id) values (p_trip, p_member) returning token into v_tok;
  return jsonb_build_object('ok', true, 'token', v_tok);
end $$;

create or replace function public.logout(p_token uuid)
returns void
language sql security definer set search_path = public as $$
  delete from trip_sessions where token = p_token
$$;

-- 다른 멤버의 비밀번호 초기화 (그 멤버의 개인 지출과 세션도 함께 삭제해 사생활 보호)
create or replace function public.reset_password(p_token uuid, p_member text)
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  if p_member = a.o_member then raise exception 'cannot reset self'; end if;
  delete from trip_creds        where trip_id = a.o_trip and member_id = p_member;
  delete from trip_sessions     where trip_id = a.o_trip and member_id = p_member;
  delete from personal_expenses where trip_id = a.o_trip and member_id = p_member;
end $$;

-- ---------------------------------------------------------------- 여행
-- 여행 만들기: 첫 번째 멤버가 만든 사람이며, 그 비밀번호로 바로 로그인됨
create or replace function public.create_trip(
  p_name text, p_fx_cur text, p_fx_unit int, p_rate numeric,
  p_start date, p_end date, p_members jsonb, p_pw text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_code text; v_me text; v_tok uuid;
begin
  if p_pw is null or char_length(p_pw) < 4 or char_length(p_pw) > 64 then raise exception 'short password'; end if;
  v_me := p_members -> 0 ->> 'id';
  if v_me is null then raise exception 'no members'; end if;
  insert into trips (name, fx_cur, fx_unit, rate, start_date, end_date, members)
  values (p_name, p_fx_cur, p_fx_unit, p_rate, p_start, p_end, p_members)
  returning id, code into v_id, v_code;
  insert into trip_creds (trip_id, member_id, pw_hash) values (v_id, v_me, crypt(p_pw, gen_salt('bf')));
  insert into trip_sessions (trip_id, member_id) values (v_id, v_me) returning token into v_tok;
  return jsonb_build_object('id', v_id, 'code', v_code, 'token', v_tok, 'member', v_me);
end $$;

-- 여행 전체 불러오기: 공동 지출 + 일정표 + "내" 개인 지출만
create or replace function public.get_trip(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a record; r jsonb;
begin
  select * into a from _auth(p_token);
  select jsonb_build_object(
    'trip', to_jsonb(t),
    'me', a.o_member,
    'pw_set', coalesce((select jsonb_agg(c.member_id) from trip_creds c where c.trip_id = t.id), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at)
                            from expenses e where e.trip_id = t.id), '[]'::jsonb),
    'plans', coalesce((select jsonb_agg(to_jsonb(p) order by p.day, p.sort_order nulls last, p.start_time, p.created_at)
                         from plans p where p.trip_id = t.id), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(to_jsonb(x) - 'member_id' order by x.created_at)
                        from personal_expenses x
                       where x.trip_id = t.id and x.member_id = a.o_member), '[]'::jsonb)
  ) into r
  from trips t where t.id = a.o_trip;
  return r;
end $$;

create or replace function public.update_trip(
  p_token uuid, p_name text, p_fx_cur text, p_fx_unit int, p_rate numeric,
  p_start date, p_end date, p_members jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  if not (p_members @> jsonb_build_array(jsonb_build_object('id', a.o_member))) then
    raise exception 'cannot remove self';
  end if;
  update trips set name = p_name, fx_cur = p_fx_cur, fx_unit = p_fx_unit, rate = p_rate,
         start_date = p_start, end_date = p_end, members = p_members, updated_at = now()
   where id = a.o_trip;
  -- 빠진 멤버의 비밀번호·세션·개인 지출 정리
  delete from trip_creds where trip_id = a.o_trip
     and member_id not in (select m ->> 'id' from jsonb_array_elements(p_members) m);
  delete from trip_sessions where trip_id = a.o_trip
     and member_id not in (select m ->> 'id' from jsonb_array_elements(p_members) m);
  delete from personal_expenses where trip_id = a.o_trip
     and member_id not in (select m ->> 'id' from jsonb_array_elements(p_members) m);
end $$;

create or replace function public.delete_trip(p_token uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  delete from trips where id = a.o_trip;
end $$;

-- ---------------------------------------------------------------- 공동 지출
create or replace function public.save_expense(
  p_token uuid, p_id uuid, p_amount numeric, p_currency text, p_category text,
  p_title text, p_day text, p_payer text, p_split jsonb, p_plan uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid;
begin
  select * into a from _auth(p_token);
  if p_plan is not null and not exists (select 1 from plans where id = p_plan and trip_id = a.o_trip) then
    raise exception 'plan not found';
  end if;
  if p_id is null then
    if (select count(*) from expenses where trip_id = a.o_trip) >= 2000 then
      raise exception 'too many expenses';
    end if;
    insert into expenses (trip_id, amount, currency, category, title, day, payer, split, plan_id)
    values (a.o_trip, p_amount, p_currency, p_category, coalesce(p_title, ''), p_day, p_payer, p_split, p_plan)
    returning id into v_id;
  else
    update expenses set amount = p_amount, currency = p_currency, category = p_category,
           title = coalesce(p_title, ''), day = p_day, payer = p_payer, split = p_split, plan_id = p_plan
     where id = p_id and trip_id = a.o_trip
    returning id into v_id;
    if v_id is null then raise exception 'expense not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.delete_expense(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  delete from expenses where id = p_id and trip_id = a.o_trip;
end $$;

-- ---------------------------------------------------------------- 일정표
create or replace function public.save_plan(
  p_token uuid, p_id uuid, p_day text, p_time text, p_title text, p_place text,
  p_currency text, p_meal numeric, p_transport numeric, p_sight numeric, p_memo text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid;
begin
  select * into a from _auth(p_token);
  if p_id is null then
    if (select count(*) from plans where trip_id = a.o_trip) >= 500 then
      raise exception 'too many plans';
    end if;
    insert into plans (trip_id, day, start_time, title, place, currency, meal, transport, sight, memo)
    values (a.o_trip, p_day, coalesce(p_time, ''), p_title, coalesce(p_place, ''), p_currency,
            coalesce(p_meal, 0), coalesce(p_transport, 0), coalesce(p_sight, 0), coalesce(p_memo, ''))
    returning id into v_id;
  else
    update plans set day = p_day, start_time = coalesce(p_time, ''), title = p_title,
           place = coalesce(p_place, ''), currency = p_currency, meal = coalesce(p_meal, 0),
           transport = coalesce(p_transport, 0), sight = coalesce(p_sight, 0), memo = coalesce(p_memo, '')
     where id = p_id and trip_id = a.o_trip
    returning id into v_id;
    if v_id is null then raise exception 'plan not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.delete_plan(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  delete from plans where id = p_id and trip_id = a.o_trip;
end $$;

-- 드래그로 순서 바꾸기: p_ids 순서대로 그날(p_day)의 순서를 매김. 다른 날로 옮긴 일정도 함께 처리
create or replace function public.reorder_plans(p_token uuid, p_day text, p_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  if p_day is null or char_length(p_day) > 10 then raise exception 'bad day'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 500 then raise exception 'too many plans'; end if;
  update plans set day = p_day, sort_order = array_position(p_ids, id)
   where trip_id = a.o_trip and id = any(p_ids);
end $$;

-- ---------------------------------------------------------------- 개인 지출 (본인만)
create or replace function public.save_personal(
  p_token uuid, p_id uuid, p_amount numeric, p_currency text, p_category text,
  p_title text, p_day text, p_plan uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid;
begin
  select * into a from _auth(p_token);
  if p_plan is not null and not exists (select 1 from plans where id = p_plan and trip_id = a.o_trip) then
    raise exception 'plan not found';
  end if;
  if p_id is null then
    if (select count(*) from personal_expenses where trip_id = a.o_trip and member_id = a.o_member) >= 2000 then
      raise exception 'too many expenses';
    end if;
    insert into personal_expenses (trip_id, member_id, amount, currency, category, title, day, plan_id)
    values (a.o_trip, a.o_member, p_amount, p_currency, p_category, coalesce(p_title, ''), p_day, p_plan)
    returning id into v_id;
  else
    update personal_expenses set amount = p_amount, currency = p_currency, category = p_category,
           title = coalesce(p_title, ''), day = p_day, plan_id = p_plan
     where id = p_id and trip_id = a.o_trip and member_id = a.o_member
    returning id into v_id;
    if v_id is null then raise exception 'expense not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.delete_personal(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from _auth(p_token);
  delete from personal_expenses where id = p_id and trip_id = a.o_trip and member_id = a.o_member;
end $$;

-- ---------------------------------------------------------------- 권한
grant execute on function
  public.trip_public(uuid),
  public.resolve_trip(text),
  public.login(uuid, text, text),
  public.logout(uuid),
  public.reset_password(uuid, text),
  public.create_trip(text, text, int, numeric, date, date, jsonb, text),
  public.get_trip(uuid),
  public.update_trip(uuid, text, text, int, numeric, date, date, jsonb),
  public.delete_trip(uuid),
  public.save_expense(uuid, uuid, numeric, text, text, text, text, text, jsonb, uuid),
  public.delete_expense(uuid, uuid),
  public.save_plan(uuid, uuid, text, text, text, text, text, numeric, numeric, numeric, text),
  public.delete_plan(uuid, uuid),
  public.reorder_plans(uuid, text, uuid[]),
  public.save_personal(uuid, uuid, numeric, text, text, text, text, uuid),
  public.delete_personal(uuid, uuid)
to anon, authenticated;
