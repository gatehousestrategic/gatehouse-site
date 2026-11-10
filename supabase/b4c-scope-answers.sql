-- Run once in the Supabase project hlohdnjxemwpnnkxnhqx:
-- Dashboard > SQL Editor > New query > paste > Run.
-- Answers from gatehousestrategic.com/b4c/scope land here.
-- The public key can only add rows; read them in Table Editor > b4c_scope_answers.

create table if not exists b4c_scope_answers (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null check (char_length(name) between 1 and 120),
  role text check (char_length(role) <= 120),
  email text check (char_length(email) <= 200),
  answers jsonb not null check (pg_column_size(answers) < 70000)
);

alter table b4c_scope_answers enable row level security;

drop policy if exists "b4c_scope_answers_insert" on b4c_scope_answers;
create policy "b4c_scope_answers_insert" on b4c_scope_answers
  for insert to anon with check (true);

-- No select, update or delete policy: the public key cannot read or change answers.
grant insert on b4c_scope_answers to anon;
