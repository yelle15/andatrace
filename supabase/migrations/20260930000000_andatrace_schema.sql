-- =============================================================================
-- AndaTrace: central Supabase (PostgreSQL) schema. Section 3.3.7.
--
-- Mirrors the four SYNCED tables declared in lib/database/powersync_service.dart
-- (appSchema). The device-only tables (sync_queue_log, sync_metrics,
-- consistency_checks) are local-only on purpose and do NOT exist here.
--
-- Apply with the Supabase CLI:      supabase db push
-- or paste into the Supabase Dashboard SQL editor and run once.
--
-- Notes on types:
--   * id columns are TEXT (not uuid) because the app creates ids on-device,
--     offline, including prefixed ids such as 'tx_<noteId>' and 'amend_<...>'.
--   * is_verified is INTEGER 0/1 because PowerSync/SQLite has no boolean type.
-- =============================================================================

-- ── 1. Tables ────────────────────────────────────────────────────────────────

create table if not exists public.patients (
  id          text primary key,
  mrn         text,
  first_name  text,
  last_name   text,
  dob         text,
  gender      text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.clinical_notes (
  id                text primary key,
  patient_id        text not null references public.patients (id),
  author_id         text,
  local_image_path  text,
  -- Storage object path inside the private 'note-captures' bucket
  -- (e.g. 'note_<id>.jpg'), NOT a public URL.
  remote_image_url  text,
  note_date         timestamptz,
  -- Image upload status only: 'PENDING' | 'SYNCED' (Section 3.3.7.3.3).
  sync_status       text not null default 'PENDING',
  -- Record lifecycle (Section 3.3.7.3.2). 'AMENDED' is derived, never stored:
  -- a note is superseded when another row's amends_note_id points to it.
  entry_status      text not null default 'DRAFT'
                    check (entry_status in ('DRAFT', 'CONFIRMED')),
  amends_note_id    text references public.clinical_notes (id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists clinical_notes_patient_idx on public.clinical_notes (patient_id);
create index if not exists clinical_notes_amends_idx  on public.clinical_notes (amends_note_id);

create table if not exists public.htr_transcriptions (
  id                  text primary key,
  note_id             text not null references public.clinical_notes (id),
  raw_predicted_text  text,
  edited_final_text   text,
  mean_confidence     double precision,
  cer_score           double precision,
  is_verified         integer not null default 0 check (is_verified in (0, 1)),
  processed_at        timestamptz,
  updated_at          timestamptz not null default now()
);

create index if not exists htr_transcriptions_note_idx on public.htr_transcriptions (note_id);

create table if not exists public.cner_entities (
  id                text primary key,
  transcription_id  text not null references public.htr_transcriptions (id),
  entity_type       text not null,
  entity_text       text not null,
  confidence        double precision,
  start_char_idx    integer,
  end_char_idx      integer,
  created_at        timestamptz not null default now()
);

create index if not exists cner_entities_tx_idx on public.cner_entities (transcription_id);

-- ── 2. Server-side immutability of CONFIRMED records (Section 3.3.7.3.2) ─────
-- The app already refuses to edit confirmed notes. These triggers enforce the
-- same rule centrally, so no client (or bug) can overwrite a confirmed clinical
-- observation. Corrections must arrive as NEW rows via amends_note_id.
--
-- errcode 23514 (check_violation) is treated as a permanent error by the app's
-- uploadData(), so a rejected write is logged and skipped instead of blocking
-- the upload queue forever.
--
-- Columns that are sync bookkeeping, not clinical content (remote_image_url,
-- sync_status, updated_at, local_image_path), may still change so the
-- deferred image upload can record its result.

create or replace function public.guard_confirmed_clinical_note()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.entry_status = 'CONFIRMED' then
      raise exception 'clinical_notes % is CONFIRMED and cannot be deleted', old.id
        using errcode = '23514';
    end if;
    return old;
  end if;

  if old.entry_status = 'CONFIRMED' and (
       new.patient_id     is distinct from old.patient_id
    or new.author_id      is distinct from old.author_id
    or new.note_date      is distinct from old.note_date
    or new.entry_status   is distinct from old.entry_status
    or new.amends_note_id is distinct from old.amends_note_id
    or new.created_at     is distinct from old.created_at
  ) then
    raise exception 'clinical_notes % is CONFIRMED; submit an amendment instead', old.id
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists clinical_notes_confirmed_guard on public.clinical_notes;
create trigger clinical_notes_confirmed_guard
  before update or delete on public.clinical_notes
  for each row execute function public.guard_confirmed_clinical_note();

create or replace function public.guard_confirmed_transcription()
returns trigger
language plpgsql
as $$
declare
  parent_status text;
begin
  select entry_status into parent_status
  from public.clinical_notes
  where id = old.note_id;

  if parent_status = 'CONFIRMED' then
    if tg_op = 'DELETE' then
      raise exception 'transcription % belongs to a CONFIRMED note and cannot be deleted', old.id
        using errcode = '23514';
    end if;

    if new.note_id            is distinct from old.note_id
    or new.raw_predicted_text is distinct from old.raw_predicted_text
    or new.edited_final_text  is distinct from old.edited_final_text then
      raise exception 'transcription % belongs to a CONFIRMED note; submit an amendment instead', old.id
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists htr_transcriptions_confirmed_guard on public.htr_transcriptions;
create trigger htr_transcriptions_confirmed_guard
  before update or delete on public.htr_transcriptions
  for each row execute function public.guard_confirmed_transcription();

-- ── 3. Row Level Security ────────────────────────────────────────────────────
-- Prototype policy: any signed-in device (including Supabase anonymous
-- sign-in) may read and write ward records. No DELETE policy exists, so
-- deletes are denied for everyone: the record set is append-only.
-- Before deployment at the hospital, replace these with per-nurse / per-ward
-- policies tied to real accounts.

alter table public.patients           enable row level security;
alter table public.clinical_notes     enable row level security;
alter table public.htr_transcriptions enable row level security;
alter table public.cner_entities      enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['patients', 'clinical_notes', 'htr_transcriptions', 'cner_entities']
  loop
    execute format('drop policy if exists "authenticated read"   on public.%I', t);
    execute format('drop policy if exists "authenticated insert" on public.%I', t);
    execute format('drop policy if exists "authenticated update" on public.%I', t);
    execute format('create policy "authenticated read"   on public.%I for select to authenticated using (true)', t);
    execute format('create policy "authenticated insert" on public.%I for insert to authenticated with check (true)', t);
    execute format('create policy "authenticated update" on public.%I for update to authenticated using (true) with check (true)', t);
  end loop;
end;
$$;

-- ── 4. PowerSync replication ─────────────────────────────────────────────────
-- PowerSync streams changes from this publication down to devices.
-- See powersync/sync-rules.yaml for which rows each device receives.

drop publication if exists powersync;
create publication powersync for table
  public.patients,
  public.clinical_notes,
  public.htr_transcriptions,
  public.cner_entities;

-- ── 5. Storage for captured note images (Section 3.3.7.3.3) ──────────────────
-- PRIVATE bucket: images of patient notes must never be publicly reachable.
-- The app stores the object path; view images through signed URLs.

insert into storage.buckets (id, name, public)
values ('note-captures', 'note-captures', false)
on conflict (id) do update set public = false;

drop policy if exists "note-captures read"   on storage.objects;
drop policy if exists "note-captures insert" on storage.objects;
drop policy if exists "note-captures update" on storage.objects;

create policy "note-captures read" on storage.objects
  for select to authenticated using (bucket_id = 'note-captures');
create policy "note-captures insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'note-captures');
-- Needed because the upload uses upsert: true (safe retry of a half-finished upload).
create policy "note-captures update" on storage.objects
  for update to authenticated using (bucket_id = 'note-captures');

-- ── 6. Seed data for the Minimal Working Example ─────────────────────────────
insert into public.patients (id, mrn, first_name, last_name)
values ('demo-patient-001', 'MWE-0001', 'Demo', 'Patient')
on conflict (id) do nothing;
