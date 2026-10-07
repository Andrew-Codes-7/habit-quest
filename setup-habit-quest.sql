-- =============================================================
--  HABIT QUEST — run this ONCE in Supabase → SQL Editor.
--
--  Habit Quest is a separate app, but it lives in the same Supabase project
--  as The Board so your family logs in with the same email + password and
--  the same family members (the `people` table) show up in both.
--
--  This file only ADDS things. It doesn't change or delete anything
--  The Board uses. All new tables start with "hq_" so they're easy to spot.
--
--    hq_habits   — each person's habits (name, emoji, colour, how often)
--    hq_logs     — one row per habit per day it was ticked off
--    hq_ledger   — every gem / XP / streak-freeze earned or spent. Each row
--                  has a unique "key" (e.g. "chest:2026-09-22"), so a reward
--                  can never be claimed twice, even from two phones at once.
--    hq_profiles — each person's chosen avatar, frame and confetti style
--    hq_totals   — a read-only view that adds up the ledger into
--                  gem / XP / freeze balances per person
--
--  Safe to run more than once.
-- =============================================================


-- Lets the new tables check "this person belongs to this same family"
-- in a single rule. `id` is already unique, so this can never fail.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'people_id_household_uniq') then
    alter table people add constraint people_id_household_uniq unique (id, household_id);
  end if;
end $$;


create table if not exists hq_habits (
  id             uuid primary key default gen_random_uuid(),
  household_id   uuid not null references households(id) on delete cascade,
  person_id      uuid not null,
  name           text not null check (char_length(name) between 1 and 80),
  icon           text not null default '⭐' check (char_length(icon) <= 16),
  color          text not null default '#22c55e' check (color ~ '^#[0-9a-fA-F]{6}$'),
  -- daily | weekdays | weekends | days (only the ticked freq_days) | weekly (X per week)
  freq_type      text not null default 'daily'
                 check (freq_type in ('daily','weekdays','weekends','days','weekly')),
  freq_days      smallint[] not null default '{}',   -- 0 = Sunday … 6 = Saturday
  freq_per_week  smallint not null default 3 check (freq_per_week between 1 and 7),
  target         smallint not null default 1 check (target between 1 and 20),  -- ticks per day
  description    text check (char_length(description) <= 500),
  archived       boolean not null default false,
  sort           integer not null default 0,
  created_at     timestamptz not null default now(),
  unique (id, person_id, household_id),
  foreign key (person_id, household_id) references people(id, household_id) on delete cascade
);
create index if not exists idx_hq_habits_hh on hq_habits (household_id);


create table if not exists hq_logs (
  household_id  uuid not null references households(id) on delete cascade,
  habit_id      uuid not null,
  person_id     uuid not null,
  day           date not null,
  count         smallint not null check (count between 1 and 20),
  updated_at    timestamptz not null default now(),
  primary key (habit_id, day),
  -- the log must belong to that habit's owner, in that habit's family
  foreign key (habit_id, person_id, household_id)
    references hq_habits(id, person_id, household_id) on delete cascade
);
create index if not exists idx_hq_logs_hh_day on hq_logs (household_id, day);


create table if not exists hq_ledger (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references households(id) on delete cascade,
  person_id     uuid not null,
  key           text not null check (char_length(key) between 1 and 120),
  kind          text not null
                check (kind in ('check','perfect','chest','milestone','level','badge','buy','freeze_use','quest')),
  gems          integer not null default 0 check (gems between -5000 and 1000),
  xp            integer not null default 0 check (xp between 0 and 1000),
  freezes       smallint not null default 0 check (freezes between -1 and 1),
  item          text check (char_length(item) <= 40),
  day           date not null default current_date,
  created_at    timestamptz not null default now(),
  unique (person_id, key),
  foreign key (person_id, household_id) references people(id, household_id) on delete cascade
);
create index if not exists idx_hq_ledger_hh_day on hq_ledger (household_id, day);


create table if not exists hq_profiles (
  person_id     uuid primary key,
  household_id  uuid not null references households(id) on delete cascade,
  avatar        text check (char_length(avatar) <= 16),
  frame         text check (char_length(frame) <= 40),
  confetti      text check (char_length(confetti) <= 40),
  updated_at    timestamptz not null default now(),
  foreign key (person_id, household_id) references people(id, household_id) on delete cascade
);


-- security_invoker = the view obeys the same row rules as the ledger itself,
-- so a family can only ever add up its own rows.
create or replace view hq_totals with (security_invoker = true) as
  select person_id,
         household_id,
         coalesce(sum(gems), 0)::int    as gems,
         coalesce(sum(xp), 0)::int      as xp,
         coalesce(sum(freezes), 0)::int as freezes
  from hq_ledger
  group by person_id, household_id;


-- =============================================================
--  ROW LEVEL SECURITY — same rule as every table in The Board:
--  you may only touch rows whose household_id is one of yours.
-- =============================================================

do $$
declare t text;
begin
  foreach t in array array['hq_habits','hq_logs','hq_ledger','hq_profiles'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%1$s_select" on %1$I', t);
    execute format('drop policy if exists "%1$s_insert" on %1$I', t);
    execute format('drop policy if exists "%1$s_update" on %1$I', t);
    execute format('drop policy if exists "%1$s_delete" on %1$I', t);
    execute format($f$create policy "%1$s_select" on %1$I for select using (household_id in (select auth_household_ids()))$f$, t);
    execute format($f$create policy "%1$s_insert" on %1$I for insert with check (household_id in (select auth_household_ids()))$f$, t);
    execute format($f$create policy "%1$s_update" on %1$I for update using (household_id in (select auth_household_ids())) with check (household_id in (select auth_household_ids()))$f$, t);
    execute format($f$create policy "%1$s_delete" on %1$I for delete using (household_id in (select auth_household_ids()))$f$, t);
    -- new tables don't get access automatically (on purpose — see security-fixes.sql),
    -- and "grant to authenticated" does NOT take anything away from anon/public,
    -- so revoke those first.
    execute format('revoke all on %I from public, anon', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
  end loop;
end $$;

revoke all on hq_totals from public, anon;
grant select on hq_totals to authenticated;


-- =============================================================
--  DONE. Open Habit Quest and sign in with your Board email + password.
-- =============================================================
