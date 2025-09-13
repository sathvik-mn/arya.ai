-- ARYA.AI Supabase schema (DDL)
-- (same as we discussed)

-- ===== Extensions =====
create extension if not exists pgcrypto;
create extension if not exists vector;

-- ===== Users (mirror of auth) =====
create table if not exists public.users (
  id uuid primary key default auth.uid(),
  email text unique not null,
  created_at timestamptz default now()
);
alter table public.users enable row level security;
create policy "users read own row" on public.users for select to authenticated using (id = auth.uid());
create policy "users insert self row" on public.users for insert to authenticated with check (id = auth.uid());

-- ===== Core datasets =====
create table if not exists public.datasets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id),
  name text not null,
  storage_path text not null,
  format text not null,
  schema_json jsonb not null default '{}'::jsonb,
  row_count bigint default 0,
  bytes bigint default 0,
  created_at timestamptz default now()
);

create table if not exists public.dataset_files (
  id uuid primary key default gen_random_uuid(),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  version int not null,
  storage_path text not null,
  checksum text,
  created_at timestamptz default now(),
  unique(dataset_id, version)
);

create table if not exists public.dataset_profiles (
  id uuid primary key default gen_random_uuid(),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  profile_json jsonb not null,
  created_at timestamptz default now()
);

create table if not exists public.dataset_columns (
  id uuid primary key default gen_random_uuid(),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  name text not null,
  dtype text not null,
  nullable boolean default true,
  stats_json jsonb default '{}'::jsonb
);

-- ===== Embeddings =====
create table if not exists public.embeddings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  doc_id text,
  chunk_text text not null,
  embedding vector(3072) not null
);

-- ===== Queries & steps =====
create table if not exists public.queries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id),
  dataset_id uuid references public.datasets(id),
  question_text text not null,
  llm_plan_json jsonb not null,
  result_summary text,
  chart_spec_json jsonb,
  row_preview jsonb,
  status text not null default 'success',
  created_at timestamptz default now()
);

create table if not exists public.query_steps (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries(id) on delete cascade,
  step_type text not null,  -- plan|sql|pandas|ml|viz|narrate
  payload jsonb not null,
  started_at timestamptz default now(),
  finished_at timestamptz
);

-- ===== Models =====
create table if not exists public.models (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  task_type text not null,
  params_json jsonb not null,
  best_metric text,
  metrics_json jsonb,
  artifact_path text,
  created_at timestamptz default now()
);

create table if not exists public.model_versions (
  id uuid primary key default gen_random_uuid(),
  model_id uuid not null references public.models(id) on delete cascade,
  version int not null,
  metrics_json jsonb,
  artifact_path text,
  created_at timestamptz default now(),
  unique(model_id, version)
);

-- ===== Sharing (guest via app proxy)
create table if not exists public.shares (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.users(id),
  dataset_id uuid references public.datasets(id),
  token text unique not null,
  can_query boolean default true,
  expires_at timestamptz
);

-- ===== Clickstream / Audit / Errors =====
create table if not exists public.activity_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id),
  session_id text,
  action text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz default now()
);

create table if not exists public.audit_events (
  id bigserial primary key,
  user_id uuid references public.users(id),
  actor text not null,
  event text not null,
  subject_type text,
  subject_id text,
  payload jsonb not null default '{}'::jsonb,
  ip text, ua text,
  created_at timestamptz default now()
);

create table if not exists public.error_logs (
  id bigserial primary key,
  "where" text not null,
  level text not null,
  message text not null,
  context jsonb,
  created_at timestamptz default now()
);

-- ===== IDE prompts & feature journal =====
create table if not exists public.ide_prompts (
  id bigserial primary key,
  author text not null default 'me',
  editor text not null,
  project text not null default 'arya.ai',
  file text,
  prompt text not null,
  created_at timestamptz default now()
);

create table if not exists public.feature_changes (
  id bigserial primary key,
  title text not null,
  description text,
  change_type text not null,
  ticket text,
  committed_by text,
  created_at timestamptz default now()
);

-- ===== Public demo (landing uploads) =====
create table if not exists public.demo_sessions (
  id uuid primary key default gen_random_uuid(),
  anon_token text unique not null,
  expires_at timestamptz not null,
  created_at timestamptz default now()
);

create table if not exists public.demo_files (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.demo_sessions(id) on delete cascade,
  storage_path text not null,
  format text not null,
  bytes bigint default 0,
  created_at timestamptz default now()
);

-- ===== Multi-file batch ops =====
create table if not exists public.file_batches (
  id uuid primary key default gen_random_uuid(),
  dataset_id uuid not null references public.datasets(id) on delete cascade,
  op text not null,
  params_json jsonb not null,
  created_at timestamptz default now()
);

-- ===== Enable RLS on key tables =====
do $$
declare t text;
begin
  for t in
    select 'public.' || tablename
    from pg_tables
    where schemaname='public'
      and tablename in (
        'datasets','dataset_files','dataset_profiles','dataset_columns',
        'embeddings','queries','query_steps','models','model_versions',
        'shares','activity_logs','audit_events','error_logs',
        'ide_prompts','feature_changes','screen_captures','audio_transcripts'
      )
  loop
    execute format('alter table %s enable row level security;', t);
  end loop;
end$$;

-- ===== Policy helper =====
create or replace function public.add_owner_policies(tbl regclass)
returns void language plpgsql as $$
begin
  execute format('create policy "%s_select_own" on %s for select to authenticated using (coalesce(user_id, auth.uid()) = auth.uid());', tbl::text, tbl::text);
  execute format('create policy "%s_insert_own" on %s for insert to authenticated with check (coalesce(user_id, auth.uid()) = auth.uid());', tbl::text, tbl::text);
  execute format('create policy "%s_update_own" on %s for update to authenticated using (coalesce(user_id, auth.uid()) = auth.uid()) with check (coalesce(user_id, auth.uid()) = auth.uid());', tbl::text, tbl::text);
  execute format('create policy "%s_delete_own" on %s for delete to authenticated using (coalesce(user_id, auth.uid()) = auth.uid());', tbl::text, tbl::text);
end$$;

select public.add_owner_policies('public.datasets');
select public.add_owner_policies('public.dataset_files');
select public.add_owner_policies('public.dataset_profiles');
select public.add_owner_policies('public.dataset_columns');
select public.add_owner_policies('public.embeddings');
select public.add_owner_policies('public.queries');
select public.add_owner_policies('public.query_steps');
select public.add_owner_policies('public.models');
select public.add_owner_policies('public.model_versions');
select public.add_owner_policies('public.activity_logs');
select public.add_owner_policies('public.ide_prompts');
select public.add_owner_policies('public.feature_changes');

alter table public.audit_events enable row level security;
create policy "audit read own" on public.audit_events for select to authenticated using (user_id = auth.uid());

alter table public.error_logs enable row level security;
create policy "errors read own" on public.error_logs for select to authenticated using (true);

alter table public.demo_sessions enable row level security;
alter table public.demo_files enable row level security;

-- ===== Optional: screen/audio capture refs =====
create table if not exists public.screen_captures (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id),
  frame_hash text not null,
  ocr_excerpt text,
  created_at timestamptz default now()
);
alter table public.screen_captures enable row level security;
select public.add_owner_policies('public.screen_captures');

create table if not exists public.audio_transcripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id),
  transcript text not null,
  duration_ms int,
  created_at timestamptz default now()
);
alter table public.audio_transcripts enable row level security;
select public.add_owner_policies('public.audio_transcripts');

-- ===== Helper functions =====
create or replace function public.log_audit(
  p_user_id uuid,
  p_actor text,
  p_event text,
  p_subject_type text,
  p_subject_id text,
  p_payload jsonb,
  p_ip text default null,
  p_ua text default null
) returns void language sql security definer as $$
  insert into public.audit_events(user_id, actor, event, subject_type, subject_id, payload, ip, ua)
  values (p_user_id, p_actor, p_event, p_subject_type, p_subject_id, coalesce(p_payload,'{}'::jsonb), p_ip, p_ua);
$$;

create or replace function public.upsert_user(p_id uuid, p_email text)
returns void language sql security definer as $$
  insert into public.users(id, email)
  values (p_id, p_email)
  on conflict (id) do update set email = excluded.email;
$$;
