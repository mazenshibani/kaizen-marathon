-- =====================================================================
--  PIO Kaizen Marathon - Evaluation Portal
--  Database setup for Supabase (PostgreSQL)
--
--  How to use
--    1. Supabase dashboard > SQL Editor > New query
--    2. Paste this whole file and press Run
--    3. Then run ONE more line to create your first admin account
--       (see the end of this file / the setup guide)
--
--  Re-running this file is safe: it never deletes scores, users or
--  projects. It only (re)creates the functions and fills in missing
--  reference data.
--
--  Security model
--    - All data lives in the private schema "kaizen", which the public
--      API cannot reach.
--    - The web pages can only call the kz_* functions below. Every
--      function (except login) demands a valid session token and checks
--      the caller's role inside the database.
--    - Passwords are stored as bcrypt hashes; session tokens are stored
--      as SHA-256 hashes.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists kaizen;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists kaizen.users (
  id              uuid primary key default gen_random_uuid(),
  username        text not null unique
                  check (username ~ '^[a-z0-9._-]{3,32}$'),
  full_name       text not null check (length(btrim(full_name)) between 2 and 120),
  role            text not null check (role in ('judge', 'admin')),
  password_hash   text not null,
  active          boolean not null default true,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  created_at      timestamptz not null default now(),
  last_login_at   timestamptz
);

create table if not exists kaizen.sessions (
  token_hash text primary key,
  user_id    uuid not null references kaizen.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists sessions_user_idx on kaizen.sessions (user_id);

create table if not exists kaizen.settings (
  id           boolean primary key default true check (id),
  event_name   text not null default 'PIO Kaizen Marathon 2026',
  judging_open boolean not null default true
);

-- The evaluation forms of the 2026 KM Evaluation Form workbook.
--   basic   = sheet "Basic (ALJM)":          7 criteria, rated 1 - 10
--   advance = sheet "Advanced Kaizen (KSA)": 17 criteria, rated 1 - 4
create table if not exists kaizen.forms (
  code      text primary key,
  name      text not null,
  scale_max int  not null check (scale_max between 2 and 10),
  scale     jsonb not null          -- rating labels, highest first
);

create table if not exists kaizen.categories (
  code text primary key,
  name text not null,
  form text not null references kaizen.forms (code),
  sort int not null
);

create table if not exists kaizen.criteria (
  id             int primary key,
  form           text not null references kaizen.forms (code),
  section_no     int not null,
  section        text not null,
  name           text not null,
  points         jsonb not null,    -- what is assessed
  help           jsonb,             -- {"meaning": ..., "looks_for": ...} guidance for judges
  weight         numeric(5,2) not null check (weight > 0),   -- percent of the form
  is_methodology boolean not null   -- part of the problem-solving steps (used to break ties)
);

create table if not exists kaizen.projects (
  code       text primary key check (code ~ '^[A-Z0-9][A-Z0-9-]{1,19}$'),
  category   text not null references kaizen.categories (code),
  title      text not null check (length(btrim(title)) between 2 and 200),
  presenter  text not null check (length(btrim(presenter)) between 2 and 120),
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists kaizen.team_members (
  id           bigint generated always as identity primary key,
  project_code text not null references kaizen.projects (code) on delete cascade,
  full_name    text not null,
  sort         int not null default 0
);
create index if not exists team_members_project_idx on kaizen.team_members (project_code);

create table if not exists kaizen.prizes (
  category      text not null references kaizen.categories (code),
  place         int  not null check (place >= 1),
  leader_amount int  not null check (leader_amount >= 0),
  member_amount int  not null default 0 check (member_amount >= 0),
  members       int  not null default 0 check (members >= 0),
  primary key (category, place)
);

create table if not exists kaizen.evaluations (
  judge_id     uuid not null references kaizen.users (id),
  project_code text not null references kaizen.projects (code),
  scores       jsonb not null default '{}'::jsonb,   -- {"<criterion id>": rating}
  comments     jsonb not null default '{}'::jsonb,   -- {"<criterion id>": "comment"}
  notes        text  not null default '',
  status       text  not null default 'draft' check (status in ('draft', 'submitted')),
  total        numeric(7,3) not null default 0,   -- weighted result, 0 - 100
  methodology  numeric(7,3) not null default 0,   -- problem-solving part, 0 - 100 (tie-break)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  submitted_at timestamptz,
  primary key (judge_id, project_code)
);

create table if not exists kaizen.audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_id     uuid,
  actor_name   text,
  action       text not null,
  project_code text,
  judge_id     uuid,
  details      jsonb
);
create index if not exists audit_log_at_idx on kaizen.audit_log (at desc);

-- When the portal was installed. The first-admin setup page only works for 48 hours after this.
alter table kaizen.settings add column if not exists installed_at timestamptz not null default now();

-- Nothing in this schema is reachable from the public API.
alter table kaizen.users        enable row level security;
alter table kaizen.sessions     enable row level security;
alter table kaizen.settings     enable row level security;
alter table kaizen.forms        enable row level security;
alter table kaizen.categories   enable row level security;
alter table kaizen.criteria     enable row level security;
alter table kaizen.projects     enable row level security;
alter table kaizen.team_members enable row level security;
alter table kaizen.prizes       enable row level security;
alter table kaizen.evaluations  enable row level security;
alter table kaizen.audit_log    enable row level security;

-- ---------------------------------------------------------------------
--  Reference data (only inserted when missing)
-- ---------------------------------------------------------------------
insert into kaizen.settings (id) values (true) on conflict do nothing;

insert into kaizen.forms (code, name, scale_max, scale) values
  ('basic', 'Basic form', 10,
   '[{"from": 9, "to": 10, "label": "Excellent"}, {"from": 7, "to": 8, "label": "Very Good"}, {"from": 5, "to": 6, "label": "Average"}, {"from": 3, "to": 4, "label": "Below Average"}, {"from": 1, "to": 2, "label": "Poor"}]'),
  ('advance', 'Advance Kaizen form', 4,
   '[{"from": 4, "to": 4, "label": "Strongly Demonstrated"}, {"from": 3, "to": 3, "label": "Clearly Demonstrated"}, {"from": 2, "to": 2, "label": "Partially Demonstrated"}, {"from": 1, "to": 1, "label": "Not Demonstrated"}]')
on conflict (code) do nothing;

insert into kaizen.categories (code, name, form, sort) values
  ('B', 'Basic',                       'basic',   1),
  ('T', 'Advance Kaizen (Team)',       'advance', 2),
  ('I', 'Advance Kaizen (Individual)', 'advance', 3)
on conflict (code) do nothing;

-- Basic form: sheet "Basic (ALJM)". Result = SUMPRODUCT(weights, ratings) / 10.
insert into kaizen.criteria (id, form, section_no, section, name, points, help, weight, is_methodology) values
  (1, 'basic', 1, 'Problem-Solving Methodology', 'Background',
      '["Clearly explain why the project was initiated, including the necessity and timing."]', null, 10, true),
  (2, 'basic', 1, 'Problem-Solving Methodology', 'Achievement vs. Target',
      '["Present measurable results before vs. after.", "Show progress with charts or tables (financial impact if applicable).", "Indicate systems or materials created or modified."]', null, 20, true),
  (3, 'basic', 1, 'Problem-Solving Methodology', 'Future Actions',
      '["Outline how improvements will be sustained and further enhanced (plans, standards, monitoring, etc.)."]', null, 10, true),
  (4, 'basic', 2, 'Presentation', 'Quality and clarity of project delivery',
      '["Clear, audible voice with good tone and pacing.", "Logical story flow with emphasis on key points.", "Confident explanation, eye contact, and effective responses to questions."]', null, 20, false),
  (5, 'basic', 3, 'Visualization', 'Clarity and professionalism of supporting visuals',
      '["Readable text size and font.", "Charts and graphs with clear labels and explanations.", "Balanced use of content and white space.", "Define all technical terms, acronyms, or jargon."]', null, 20, false),
  (6, 'basic', 4, 'Impact on Division', 'Tangible effect of the project on the division',
      '["Demonstrate financial results, business improvements, or other measurable impacts."]', null, 10, false),
  (7, 'basic', 5, 'Judge''s Overall Rating', 'Overall impression of the project',
      '["Evaluate based on evidence presented in both the written material and the oral presentation. The score should reflect both the rigor of the problem-solving process and the practical impact of the project."]', null, 10, false)
on conflict (id) do nothing;

-- Advance form: sheet "Advanced Kaizen (KSA)". Final Score = SUMPRODUCT(ratings, weights) / (4 x SUM(weights)) x 100.
insert into kaizen.criteria (id, form, section_no, section, name, points, help, weight, is_methodology) values
  (11, 'advance', 1, '1. Clarify the Problem', 'Background',
      '["The background and reason for addressing the problem are clearly explained."]',
      '{"meaning": "What is the problem, and why does it matter?", "looks_for": "Enough context for someone unfamiliar with the operation to understand the problem. Assess the clarity of the explanation, not presentation skills and polish."}', 5, true),
  (12, 'advance', 1, '1. Clarify the Problem', 'Purpose (Own Vision)',
      '["The purpose of the team or department (Own Vision) is clearly explained and connected to the organization''s broader direction."]',
      '{"meaning": "What is your team or department ultimately trying to achieve and how is it contributing to the department / company objective?", "looks_for": "A meaningful purpose that explains why improving this area matters, rather than simply a list of activities. How well is it connected with the department / company objectives?"}', 5, true),
  (13, 'advance', 1, '1. Clarify the Problem', 'Ideal Situation',
      '["The Ideal Situation is clearly defined and appropriately challenging relative to the problem and project scope."]',
      '{"meaning": "What should the situation ideally look like?", "looks_for": "A clear desired condition that can be compared with the Current Situation. It should describe an outcome, not a proposed solution."}', 4, true),
  (14, 'advance', 1, '1. Clarify the Problem', 'Current Situation',
      '["The Current Situation is described objectively, using relevant facts, observations or KPIs where available."]',
      '{"meaning": "What is actually happening today?", "looks_for": "Facts, measurements or observations that describe the real current condition rather than assumptions."}', 4, true),
  (15, 'advance', 1, '1. Clarify the Problem', 'Gap',
      '["The difference between the Current Situation and Ideal Situation is clearly identified and explained."]',
      '{"meaning": "What is the difference between where you are today and where you want to be?", "looks_for": "A clear, logical gap, supported by facts or simple measurements where practical. A separate slide titled \"Gap\" is not required."}', 4, true),
  (16, 'advance', 1, '1. Clarify the Problem', 'Sense of Urgency',
      '["The necessity to address the identified gap now is clearly explained."]',
      '{"meaning": "Why is this problem worth addressing now?", "looks_for": "A reasonable explanation of the consequences of the gap, its recurrence or the opportunity to improve. An emergency is not required."}', 2, true),
  (17, 'advance', 1, '1. Clarify the Problem', 'Alignment with Kaizen Theme',
      '["The project demonstrates a clear and strong connection to the relevant Kaizen Theme."]',
      '{"meaning": "How strongly does the Kaizen project contribute to the relevant Kaizen Theme?", "looks_for": "The strength and relevance of the connection between the project and the Kaizen Theme. Assess how meaningfully the project contributes to the theme, relative to the participant''s role and scope."}', 10, false),
  (18, 'advance', 2, '2. Breakdown the Problem', 'Breakdown and prioritized problem',
      '["The gap between the Current and Ideal Situations was broken down, and the prioritized problem was identified logically."]',
      '{"meaning": "Did the participant break the larger gap into smaller parts to decide where to focus?", "looks_for": "A logical, fact-based breakdown showing where the problem is concentrated and why the selected issue was prioritized."}', 5, true),
  (19, 'advance', 3, '3. Target Setting', 'SMART target',
      '["A specific, measurable, achievable, relevant and time-bound (SMART) target was set for the prioritized problem."]',
      '{"meaning": "What improvement is the participant trying to achieve, and by when?", "looks_for": "A clear, measurable, time-bound and appropriately challenging target linked to the prioritized problem. This criterion assesses target setting, not target achievement."}', 5, true),
  (20, 'advance', 4, '4. Root Cause Analysis', 'Asking "Why?"',
      '["The participant repeatedly asked \"Why?\" to identify a logical underlying root cause (hypothesis) of the prioritized problem."]',
      '{"meaning": "Why is the problem really happening?", "looks_for": "Logical investigation beyond symptoms to a plausible underlying cause. The prioritized problem was not only looked at from one narrow perspective."}', 5, true),
  (21, 'advance', 4, '4. Root Cause Analysis', 'Genchi Genbutsu',
      '["Genchi Genbutsu was used to verify the suspected root cause through firsthand observation and relevant evidence."]',
      '{"meaning": "Did the participant go and see the actual situation to check the suspected cause?", "looks_for": "Direct observation, discussions with people involved, process checks or other firsthand evidence supporting or challenging the hypothesis."}', 5, true),
  (22, 'advance', 5, '5. Develop Countermeasures / 6. See Countermeasures Through', 'Develop Countermeasures',
      '["Countermeasures were logically selected to address the verified root cause, considering effectiveness and feasibility."]',
      '{"meaning": "Was a suitable solution selected to address the actual cause?", "looks_for": "A clear link between the verified root cause and selected countermeasure, with sensible consideration of feasibility and alternatives where appropriate."}', 5, true),
  (23, 'advance', 5, '5. Develop Countermeasures / 6. See Countermeasures Through', 'See Countermeasures Through',
      '["The selected countermeasures were implemented through a clear action plan with defined responsibilities and timelines."]',
      '{"meaning": "Were the planned countermeasures actually carried out?", "looks_for": "Clear actions, owners and timelines, with evidence of implementation. Any significant delays or difficulties should be explained."}', 5, true),
  (24, 'advance', 6, '7. Evaluate both Result & Process', 'Results reviewed against the target',
      '["Results and implementation were reviewed against the target, with lessons learned and remaining gaps clearly identified."]',
      '{"meaning": "Did the countermeasure work, and what was learned?", "looks_for": "Target-versus-actual comparison, review of implementation, and learning from remaining gaps. Missing a target does not automatically mean poor problem-solving."}', 7, true),
  (25, 'advance', 6, '7. Evaluate both Result & Process', 'Business Impact',
      '["The project demonstrated a measurable benefit, with the magnitude of improvement clearly established relative to the original problem and project scope."]',
      '{"meaning": "What actual benefit did the Kaizen project deliver, and how significant was the improvement?", "looks_for": "Credible evidence of the actual benefit achieved and its magnitude. Assess the significance of the improvement relative to the original problem and project scope."}', 20, false),
  (26, 'advance', 7, '8. Standardize Successful Processes', 'Standardization',
      '["Successful countermeasures were standardized through suitable methods (e.g., SOPs, work instructions, checklists or visual controls)."]',
      '{"meaning": "How will the improvement be sustained?", "looks_for": "Evidence that the improved way of working has been adopted and supported by appropriate controls to prevent a return to the old condition."}', 6, true),
  (27, 'advance', 7, '8. Standardize Successful Processes', 'Next actions',
      '["Practical next actions were identified to address remaining gaps and move closer to the Ideal Situation."]',
      '{"meaning": "What should be the next steps?", "looks_for": "Realistic follow-up actions based on results, or remaining gaps (if the ideal situation is not reached) for further improvement."}', 3, true)
on conflict (id) do nothing;

insert into kaizen.prizes (category, place, leader_amount, member_amount, members) values
  ('B', 1, 5000, 0, 0),
  ('B', 2, 4000, 0, 0),
  ('B', 3, 3000, 0, 0),
  ('B', 4, 2000, 0, 0),
  ('B', 5, 1000, 0, 0),
  ('T', 1, 4000, 3000, 4),
  ('T', 2, 3000, 2000, 4),
  ('T', 3, 2000, 1000, 4),
  ('I', 1, 5000, 0, 0)
on conflict (category, place) do nothing;

insert into kaizen.projects (code, category, title, presenter, sort) values
  ('B-182-26', 'B', 'Safety Knowledge Reinforcement Through MCQ-Based System', 'MD Aktaruzzaman', 1),
  ('B-198-26', 'B', 'Systematic Way of JIG Control', 'Alexander Bereket Berhe', 2),
  ('B-184-26', 'B', 'Safety and Time Improvement, Reducing Cost', 'Hassan Abdulghaffar Bakheet', 3),
  ('B-181-26', 'B', 'Redesign Jig for Highlander Rear Sensor: Reduced Cost & Lifespan', 'Ayub Zubair', 4),
  ('B-197-26', 'B', 'RAV4 Front Bumper Foam Protection Improvement', 'Abdul Muthalef Samath', 5),
  ('B-191-26', 'B', 'Improve Cost Efficiency by Increasing Jig Quantities', 'Mohammed Munnaf Mollah', 6),
  ('B-189-26', 'B', 'Establish Effective JIG Control by Standardizing Organization', 'Mohammed Munnaf Mollah', 7),
  ('B-180-26', 'B', 'Cost Savings Through Wireless Pin Removal Jig', 'Mohammed Munnaf Mollah', 8),
  ('B-196-26', 'B', 'Lifter Safety Improvement', 'Marwan Mohammed Jubarah', 9),
  ('B-187-26', 'B', 'Optimizing the Installer to Enhance Production Quality', 'Crisanto Mendoza', 10),
  ('B-174-26', 'B', 'Effect of Visible Color on the Size of Holes', 'Mohammed Mohammed Saeed', 11),
  ('B-183-26', 'B', 'Optimizing the Process by Merging LC 300 PIO/DIO Items', 'Ayub Zubair', 12),
  ('B-177-26', 'B', 'Installer Performance Scorecard', 'Raed Almutaz Mohmmed Ahmed', 13),
  ('B-186-26', 'B', 'Cable Tie Cutting Tools Improvement', 'Charlie Salon Luisen', 14),
  ('B-175-26', 'B', 'Automated Production Hours Reconciliation System', 'Mazen Mohammed Al Shibani', 15),
  ('B-193-26', 'B', 'Digital Lean Quality - Streamlining Reporting Across Quality', 'Ahmed Abdu Bukhur', 16),
  ('I-188-26', 'I', 'Advance Production Monitoring Through ML Vision to Cost Saving', 'Abdulaziz Alahmadi', 17),
  ('I-203-26', 'I', 'Skill Matrix UX & UI', 'Islam Mohamed Abdelfatah', 18),
  ('T-202-26', 'T', 'Vacuum Sanding Machine', 'Adi Wahyu Bn Mohamad', 19),
  ('T-207-26', 'T', 'Enhance Production Process Capability by Changing Drill Bit Size', 'Mohammed Munnaf Mollah', 20),
  ('T-208-26', 'T', 'Enhance Back Job Report Accuracy Through Corrections', 'Mohammed Munnaf Mollah', 21),
  ('T-205-26', 'T', 'Optimize Material Consumption Based on Stock Availability', 'Asim Tayrah', 22),
  ('T-190-26', 'T', 'Enhance Cost & Efficiency Through Real-Time Data Collection', 'Abdulaziz Alahmadi', 23),
  ('T-199-26', 'T', 'Skill Alignment & Training Compliance System', 'Mazen Mohammed Al Shibani', 24),
  ('T-204-26', 'T', 'Enhance Aftersales Service Rate & Optimize MOC Performance', 'Eissa Abdullah Mohammed Ba Awaidhan', 25),
  ('T-290-26', 'T', 'Utilize Warehouse Storage Capacity', 'Salem Saeed N.A. Al Sulmy', 26)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
--  Internal helpers (schema kaizen - not callable from the web)
-- ---------------------------------------------------------------------

-- Validates a session token and returns the user. Raises on failure.
create or replace function kaizen.auth(p_token text, p_role text default null)
returns kaizen.users
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception 'KZ_SESSION';
  end if;

  select u.* into v_user
  from kaizen.sessions s
  join kaizen.users u on u.id = s.user_id
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.expires_at > now()
    and u.active;

  if not found then
    raise exception 'KZ_SESSION';
  end if;
  if p_role is not null and v_user.role <> p_role then
    raise exception 'KZ_FORBIDDEN';
  end if;
  return v_user;
end;
$$;

create or replace function kaizen.log(p_actor kaizen.users, p_action text,
                                      p_project text default null,
                                      p_judge uuid default null,
                                      p_details jsonb default null)
returns void
language sql
security definer
set search_path = kaizen, pg_temp
as $$
  insert into kaizen.audit_log (actor_id, actor_name, action, project_code, judge_id, details)
  values (p_actor.id, p_actor.full_name, p_action, p_project, p_judge, p_details);
$$;

-- Weighted result for one evaluation, out of 100:
--   total = SUM(weight x rating) x 100 / (SUM(weight) x highest rating of the form)
-- Basic form (1-10):   same as the workbook's SUMPRODUCT(weights, ratings) / 10
-- Advance form (1-4):  same as SUMPRODUCT(ratings, weights) / (4 x SUM(weights)) x 100
create or replace function kaizen.score_eval(p_form text, p_scores jsonb,
                                             out total numeric, out methodology numeric,
                                             out answered int, out required int)
language sql
stable
security definer
set search_path = kaizen, pg_temp
as $$
  with c as (
    select cr.id, cr.weight, cr.is_methodology, f.scale_max,
           case when jsonb_typeof(p_scores -> cr.id::text) = 'number'
                then (p_scores ->> cr.id::text)::numeric end as score
    from kaizen.criteria cr join kaizen.forms f on f.code = cr.form
    where cr.form = p_form
  )
  select
    round(coalesce(sum(weight * score), 0) * 100 / (sum(weight) * max(scale_max)), 3),
    round(coalesce(sum(weight * score) filter (where is_methodology), 0) * 100
          / nullif(sum(weight) filter (where is_methodology) * max(scale_max), 0), 3),
    count(score)::int,
    count(*)::int
  from c;
$$;

create or replace function kaizen.user_json(p_user kaizen.users)
returns jsonb
language sql
immutable
set search_path = pg_temp
as $$
  select jsonb_build_object('id', p_user.id, 'username', p_user.username,
                            'full_name', p_user.full_name, 'role', p_user.role);
$$;

create or replace function kaizen.reference_json()
returns jsonb
language sql
stable
security definer
set search_path = kaizen, pg_temp
as $$
  select jsonb_build_object(
    'settings',   (select jsonb_build_object('event_name', event_name, 'judging_open', judging_open)
                   from kaizen.settings),
    'forms',      (select coalesce(jsonb_agg(jsonb_build_object(
                     'code', code, 'name', name, 'scale_max', scale_max, 'scale', scale) order by code), '[]'::jsonb)
                   from kaizen.forms),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
                     'code', code, 'name', name, 'form', form) order by sort), '[]'::jsonb)
                   from kaizen.categories),
    'criteria',   (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', id, 'form', form, 'section_no', section_no, 'section', section, 'name', name,
                     'points', points, 'help', help, 'weight', weight,
                     'is_methodology', is_methodology) order by id), '[]'::jsonb)
                   from kaizen.criteria),
    'projects',   (select coalesce(jsonb_agg(jsonb_build_object(
                     'code', code, 'category', category, 'title', title,
                     'presenter', presenter) order by sort, code), '[]'::jsonb)
                   from kaizen.projects)
  );
$$;

create or replace function kaizen.check_password(p_password text)
returns void
language plpgsql
immutable
set search_path = pg_temp
as $$
begin
  if p_password is null or length(p_password) < 8 or length(p_password) > 72 then
    raise exception 'KZ_WEAK_PASSWORD';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
--  Helpers you run yourself from the Supabase SQL Editor
-- ---------------------------------------------------------------------

-- Creates the first admin account. Refuses once any admin exists.
--   select kaizen.create_first_admin('your.username', 'Your Full Name', 'a-strong-password');
create or replace function kaizen.create_first_admin(p_username text, p_full_name text, p_password text)
returns text
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
begin
  if exists (select 1 from kaizen.users where role = 'admin') then
    raise exception 'An admin account already exists. Create further accounts from the admin portal.';
  end if;
  perform kaizen.check_password(p_password);
  insert into kaizen.users (username, full_name, role, password_hash)
  values (lower(btrim(p_username)), btrim(p_full_name), 'admin',
          extensions.crypt(p_password, extensions.gen_salt('bf', 10)));
  return 'Admin account "' || lower(btrim(p_username)) || '" created. You can sign in at admin.html';
end;
$$;

-- Emergency password reset (e.g. every admin forgot their password).
--   select kaizen.set_password('your.username', 'a-new-strong-password');
create or replace function kaizen.set_password(p_username text, p_password text)
returns text
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_id uuid;
begin
  perform kaizen.check_password(p_password);
  update kaizen.users
     set password_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
         failed_attempts = 0, locked_until = null, active = true
   where username = lower(btrim(p_username))
   returning id into v_id;
  if v_id is null then
    raise exception 'No user named %', p_username;
  end if;
  delete from kaizen.sessions where user_id = v_id;
  insert into kaizen.audit_log (action, details)
  values ('password_reset_from_sql_editor', jsonb_build_object('username', lower(btrim(p_username))));
  return 'Password updated for ' || lower(btrim(p_username));
end;
$$;

-- =====================================================================
--  PUBLIC API  (the only things the web pages can call)
-- =====================================================================

-- ---- Sign in --------------------------------------------------------
-- p_portal is 'judge' or 'admin'. An account only works on its own portal.
-- Returns {ok:false, error:...} instead of raising, so that failed attempts
-- are recorded (5 wrong passwords lock the account for 10 minutes).
create or replace function public.kz_login(p_username text, p_password text, p_portal text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user  kaizen.users;
  v_token text;
  v_exp   timestamptz;
begin
  if p_portal not in ('judge', 'admin') then
    return jsonb_build_object('ok', false, 'error', 'BAD_LOGIN');
  end if;

  select * into v_user from kaizen.users
   where username = lower(btrim(coalesce(p_username, '')))
   for update;

  if not found or not v_user.active then
    -- spend the same time as a real check
    perform extensions.crypt(coalesce(p_password, ''), extensions.gen_salt('bf', 10));
    return jsonb_build_object('ok', false, 'error', 'BAD_LOGIN');
  end if;

  if v_user.locked_until is not null and v_user.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'LOCKED',
      'minutes', ceil(extract(epoch from (v_user.locked_until - now())) / 60)::int);
  end if;

  if v_user.password_hash <> extensions.crypt(coalesce(p_password, ''), v_user.password_hash) then
    if v_user.failed_attempts + 1 >= 5 then
      update kaizen.users set failed_attempts = 0, locked_until = now() + interval '10 minutes'
       where id = v_user.id;
      perform kaizen.log(v_user, 'login_locked');
    else
      update kaizen.users set failed_attempts = failed_attempts + 1 where id = v_user.id;
    end if;
    return jsonb_build_object('ok', false, 'error', 'BAD_LOGIN');
  end if;

  if v_user.role <> p_portal then
    return jsonb_build_object('ok', false, 'error', 'WRONG_PORTAL');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_exp   := now() + interval '12 hours';

  delete from kaizen.sessions where user_id = v_user.id and expires_at < now();
  insert into kaizen.sessions (token_hash, user_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_user.id, v_exp);

  update kaizen.users
     set failed_attempts = 0, locked_until = null, last_login_at = now()
   where id = v_user.id;
  perform kaizen.log(v_user, 'login');

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp,
                            'user', kaizen.user_json(v_user));
end;
$$;

-- ---- First-run setup -------------------------------------------------
-- Until the first account exists (and for at most 48 hours after the
-- database was installed) the admin portal shows a "create the first
-- admin" form instead of the sign-in form. After that these two
-- functions refuse, and accounts are created from the admin portal.
create or replace function public.kz_setup_status()
returns jsonb
language sql
stable
security definer
set search_path = kaizen, pg_temp
as $$
  select jsonb_build_object('needs_setup',
    not exists (select 1 from kaizen.users)
    and (select installed_at from kaizen.settings) > now() - interval '48 hours');
$$;

create or replace function public.kz_setup_first_admin(p_username text, p_full_name text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_installed timestamptz;
  v_name text := lower(btrim(coalesce(p_username, '')));
  v_full text := btrim(coalesce(p_full_name, ''));
  v_user kaizen.users;
begin
  -- the row lock makes two simultaneous attempts run one after the other
  select installed_at into v_installed from kaizen.settings for update;
  if exists (select 1 from kaizen.users) or v_installed <= now() - interval '48 hours' then
    raise exception 'KZ_SETUP_CLOSED';
  end if;
  if v_name !~ '^[a-z0-9._-]{3,32}$' or length(v_full) not between 2 and 120 then
    raise exception 'KZ_BAD_INPUT';
  end if;
  perform kaizen.check_password(p_password);
  insert into kaizen.users (username, full_name, role, password_hash)
  values (v_name, v_full, 'admin', extensions.crypt(p_password, extensions.gen_salt('bf', 10)))
  returning * into v_user;
  perform kaizen.log(v_user, 'first_admin_created', null, null, jsonb_build_object('username', v_name));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.kz_logout(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
begin
  delete from kaizen.sessions
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.kz_change_password(p_token text, p_old text, p_new text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token);
begin
  if v_user.password_hash <> extensions.crypt(coalesce(p_old, ''), v_user.password_hash) then
    raise exception 'KZ_WRONG_PASSWORD';
  end if;
  perform kaizen.check_password(p_new);
  update kaizen.users
     set password_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10))
   where id = v_user.id;
  -- sign out every other device
  delete from kaizen.sessions
   where user_id = v_user.id
     and token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
  perform kaizen.log(v_user, 'password_changed');
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Judge: everything needed to draw the portal --------------------
create or replace function public.kz_judge_load(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'judge');
begin
  return kaizen.reference_json() || jsonb_build_object(
    'user', kaizen.user_json(v_user),
    'evaluations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_code', project_code, 'scores', scores, 'comments', comments, 'notes', notes,
        'status', status, 'total', total, 'updated_at', updated_at, 'submitted_at', submitted_at)), '[]'::jsonb)
      from kaizen.evaluations where judge_id = v_user.id)
  );
end;
$$;

-- Earlier versions of these two functions had different arguments.
drop function if exists public.kz_judge_save(text, text, jsonb, text, boolean);
drop function if exists public.kz_admin_set_model(text, text, text);

-- ---- Judge: save a draft or submit ----------------------------------
-- p_scores   is {"<criterion id>": <rating>, ...}  (1-10 on the Basic form, 1-4 on the Advance form)
-- p_comments is {"<criterion id>": "<text>", ...}  (optional per-criterion comments)
-- Once submitted, the evaluation is locked until an admin reopens it.
create or replace function public.kz_judge_save(p_token text, p_project text, p_scores jsonb,
                                                p_comments jsonb, p_notes text, p_submit boolean)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user     kaizen.users := kaizen.auth(p_token, 'judge');
  v_form     text;
  v_max      int;
  v_status   text;
  v_bad      int;
  v_calc     record;
  v_row      kaizen.evaluations;
  v_scores   jsonb := coalesce(p_scores, '{}'::jsonb);
  v_comments jsonb := coalesce(p_comments, '{}'::jsonb);
  v_notes    text  := left(coalesce(p_notes, ''), 2000);
begin
  if not (select judging_open from kaizen.settings) then
    raise exception 'KZ_JUDGING_CLOSED';
  end if;

  select f.code, f.scale_max into v_form, v_max
  from kaizen.projects p
  join kaizen.categories c on c.code = p.category
  join kaizen.forms f on f.code = c.form
  where p.code = p_project;
  if not found then
    raise exception 'KZ_NO_PROJECT';
  end if;

  select status into v_status from kaizen.evaluations
   where judge_id = v_user.id and project_code = p_project
   for update;
  if v_status = 'submitted' then
    raise exception 'KZ_LOCKED';
  end if;

  if jsonb_typeof(v_scores) <> 'object' or jsonb_typeof(v_comments) <> 'object' then
    raise exception 'KZ_BAD_SCORES';
  end if;
  select count(*) into v_bad
  from jsonb_each(v_scores) e
  where not exists (select 1 from kaizen.criteria c where c.id::text = e.key and c.form = v_form)
     or not (case when jsonb_typeof(e.value) = 'number'
                  then (e.value::text)::numeric = trunc((e.value::text)::numeric)
                       and (e.value::text)::numeric between 1 and v_max
                  else false end);
  if v_bad > 0 then
    raise exception 'KZ_BAD_SCORES';
  end if;
  select count(*) into v_bad
  from jsonb_each(v_comments) e
  where not exists (select 1 from kaizen.criteria c where c.id::text = e.key and c.form = v_form)
     or jsonb_typeof(e.value) <> 'string';
  if v_bad > 0 then
    raise exception 'KZ_BAD_SCORES';
  end if;
  -- keep only non-empty comments, at most 600 characters each
  select coalesce(jsonb_object_agg(e.key, left(btrim(e.value #>> '{}'), 600)), '{}'::jsonb) into v_comments
  from jsonb_each(v_comments) e
  where btrim(e.value #>> '{}') <> '';

  select * into v_calc from kaizen.score_eval(v_form, v_scores);
  if coalesce(p_submit, false) and v_calc.answered < v_calc.required then
    raise exception 'KZ_INCOMPLETE';
  end if;

  insert into kaizen.evaluations as e
    (judge_id, project_code, scores, comments, notes, status, total, methodology, submitted_at)
  values
    (v_user.id, p_project, v_scores, v_comments, v_notes,
     case when coalesce(p_submit, false) then 'submitted' else 'draft' end,
     v_calc.total, v_calc.methodology,
     case when coalesce(p_submit, false) then now() end)
  on conflict (judge_id, project_code) do update
    set scores = excluded.scores, comments = excluded.comments, notes = excluded.notes,
        status = excluded.status, total = excluded.total, methodology = excluded.methodology,
        submitted_at = excluded.submitted_at, updated_at = now()
  returning e.* into v_row;

  if v_row.status = 'submitted' then
    perform kaizen.log(v_user, 'evaluation_submitted', p_project, v_user.id,
      jsonb_build_object('total', v_row.total, 'scores', v_row.scores,
                         'comments', v_row.comments, 'notes', v_row.notes));
  end if;

  return jsonb_build_object(
    'project_code', v_row.project_code, 'scores', v_row.scores, 'comments', v_row.comments,
    'notes', v_row.notes, 'status', v_row.status, 'total', v_row.total,
    'updated_at', v_row.updated_at, 'submitted_at', v_row.submitted_at);
end;
$$;

-- ---- Admin: full picture --------------------------------------------
-- Scores are withheld until every active judge has submitted every
-- project. Passing p_reveal = true shows provisional scores earlier and
-- records that in the audit log.
create or replace function public.kz_admin_load(p_token text, p_reveal boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user     kaizen.users := kaizen.auth(p_token, 'admin');
  v_judges   int;
  v_projects int;
  v_done     int;
  v_complete boolean;
  v_reveal   boolean;
begin
  select count(*) into v_judges   from kaizen.users where role = 'judge' and active;
  select count(*) into v_projects from kaizen.projects;
  select count(*) into v_done
  from kaizen.evaluations e join kaizen.users u on u.id = e.judge_id
  where e.status = 'submitted' and u.active and u.role = 'judge';

  v_complete := v_judges > 0 and v_projects > 0 and v_done = v_judges * v_projects;
  v_reveal   := v_complete or coalesce(p_reveal, false);

  if v_reveal and not v_complete and not exists (
       select 1 from kaizen.audit_log
        where action = 'provisional_results_viewed' and actor_id = v_user.id
          and at > now() - interval '30 minutes') then
    perform kaizen.log(v_user, 'provisional_results_viewed', null, null,
      jsonb_build_object('submitted', v_done, 'expected', v_judges * v_projects));
  end if;

  return kaizen.reference_json() || jsonb_build_object(
    'user', kaizen.user_json(v_user),
    'complete', v_complete,
    'revealed', v_reveal,
    'submitted', v_done,
    'expected', v_judges * v_projects,
    'users', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'username', username, 'full_name', full_name, 'role', role, 'active', active,
        'locked', (locked_until is not null and locked_until > now()),
        'last_login_at', last_login_at) order by role, full_name), '[]'::jsonb)
      from kaizen.users),
    'prizes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category', category, 'place', place, 'leader_amount', leader_amount,
        'member_amount', member_amount, 'members', members) order by category, place), '[]'::jsonb)
      from kaizen.prizes),
    'team_members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_code', project_code, 'full_name', full_name) order by project_code, sort, id), '[]'::jsonb)
      from kaizen.team_members),
    'evaluations', (
      select coalesce(jsonb_agg(
        jsonb_build_object('judge_id', judge_id, 'project_code', project_code, 'status', status,
                           'updated_at', updated_at, 'submitted_at', submitted_at)
        || case when v_reveal and status = 'submitted'
                then jsonb_build_object('total', total, 'methodology', methodology,
                                        'scores', scores, 'comments', comments, 'notes', notes)
                else '{}'::jsonb end), '[]'::jsonb)
      from kaizen.evaluations)
  );
end;
$$;

-- ---- Admin: reopen a submitted evaluation ---------------------------
create or replace function public.kz_admin_reopen(p_token text, p_judge uuid, p_project text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
  v_row  kaizen.evaluations;
begin
  if length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'KZ_REASON_REQUIRED';
  end if;
  select * into v_row from kaizen.evaluations
   where judge_id = p_judge and project_code = p_project for update;
  if not found or v_row.status <> 'submitted' then
    raise exception 'KZ_NOT_SUBMITTED';
  end if;

  update kaizen.evaluations
     set status = 'draft', submitted_at = null, updated_at = now()
   where judge_id = p_judge and project_code = p_project;

  -- keep a copy of what was submitted before the reopen
  perform kaizen.log(v_user, 'evaluation_reopened', p_project, p_judge,
    jsonb_build_object('reason', btrim(p_reason), 'previous_total', v_row.total,
                       'previous_scores', v_row.scores, 'previous_comments', v_row.comments,
                       'previous_notes', v_row.notes));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Admin: open / close judging for everyone -----------------------
create or replace function public.kz_admin_set_judging(p_token text, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
begin
  update kaizen.settings set judging_open = coalesce(p_open, false);
  perform kaizen.log(v_user, case when coalesce(p_open, false) then 'judging_opened' else 'judging_closed' end);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Admin: which evaluation form a category uses -------------------
-- Only allowed before any judge has started scoring that category.
create or replace function public.kz_admin_set_form(p_token text, p_category text, p_form text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
  v_old  text;
begin
  if not exists (select 1 from kaizen.forms where code = p_form) then
    raise exception 'KZ_BAD_INPUT';
  end if;
  select form into v_old from kaizen.categories where code = p_category for update;
  if not found then
    raise exception 'KZ_BAD_INPUT';
  end if;
  if exists (select 1 from kaizen.evaluations e join kaizen.projects p on p.code = e.project_code
              where p.category = p_category) then
    raise exception 'KZ_HAS_EVALUATIONS';
  end if;
  update kaizen.categories set form = p_form where code = p_category;
  perform kaizen.log(v_user, 'category_form_changed', null, null,
    jsonb_build_object('category', p_category, 'from', v_old, 'to', p_form));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Admin: create / edit accounts ----------------------------------
-- p_id null = new account. p_password null/empty = keep the current one.
create or replace function public.kz_admin_save_user(p_token text, p_id uuid, p_username text,
                                                     p_full_name text, p_role text,
                                                     p_password text, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user   kaizen.users := kaizen.auth(p_token, 'admin');
  v_target kaizen.users;
  v_name   text := lower(btrim(coalesce(p_username, '')));
  v_full   text := btrim(coalesce(p_full_name, ''));
  v_active boolean := coalesce(p_active, true);
  v_new_pw boolean := length(coalesce(p_password, '')) > 0;
begin
  if p_role not in ('judge', 'admin') or v_name !~ '^[a-z0-9._-]{3,32}$'
     or length(v_full) not between 2 and 120 then
    raise exception 'KZ_BAD_INPUT';
  end if;
  if exists (select 1 from kaizen.users where username = v_name and id is distinct from p_id) then
    raise exception 'KZ_USERNAME_TAKEN';
  end if;

  if p_id is null then
    perform kaizen.check_password(p_password);
    insert into kaizen.users (username, full_name, role, password_hash, active)
    values (v_name, v_full, p_role, extensions.crypt(p_password, extensions.gen_salt('bf', 10)), v_active)
    returning * into v_target;
    perform kaizen.log(v_user, 'user_created', null, null,
      jsonb_build_object('username', v_name, 'full_name', v_full, 'role', p_role));
    return jsonb_build_object('ok', true, 'id', v_target.id);
  end if;

  select * into v_target from kaizen.users where id = p_id for update;
  if not found then
    raise exception 'KZ_BAD_INPUT';
  end if;
  if v_target.id = v_user.id and (p_role <> v_target.role or not v_active) then
    raise exception 'KZ_SELF';          -- an admin cannot demote or disable themselves
  end if;
  if p_role <> v_target.role
     and exists (select 1 from kaizen.evaluations where judge_id = v_target.id) then
    raise exception 'KZ_HAS_EVALUATIONS';
  end if;
  if v_new_pw then
    perform kaizen.check_password(p_password);
  end if;

  update kaizen.users
     set username = v_name, full_name = v_full, role = p_role, active = v_active,
         password_hash = case when v_new_pw
                              then extensions.crypt(p_password, extensions.gen_salt('bf', 10))
                              else password_hash end,
         failed_attempts = case when v_new_pw then 0 else failed_attempts end,
         locked_until    = case when v_new_pw then null else locked_until end
   where id = p_id;

  if v_new_pw or not v_active then
    delete from kaizen.sessions where user_id = p_id and p_id <> v_user.id;
  end if;

  perform kaizen.log(v_user, 'user_updated', null, null,
    jsonb_build_object('username', v_name, 'full_name', v_full, 'role', p_role,
                       'active', v_active, 'password_changed', v_new_pw,
                       'was', jsonb_build_object('username', v_target.username,
                                                 'full_name', v_target.full_name,
                                                 'role', v_target.role, 'active', v_target.active)));
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;

-- ---- Admin: projects ------------------------------------------------
create or replace function public.kz_admin_save_project(p_token text, p_code text, p_category text,
                                                        p_title text, p_presenter text, p_is_new boolean)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_old  kaizen.projects;
begin
  if v_code !~ '^[A-Z0-9][A-Z0-9-]{1,19}$'
     or not exists (select 1 from kaizen.categories where code = p_category)
     or length(btrim(coalesce(p_title, ''))) not between 2 and 200
     or length(btrim(coalesce(p_presenter, ''))) not between 2 and 120 then
    raise exception 'KZ_BAD_INPUT';
  end if;

  select * into v_old from kaizen.projects where code = v_code for update;

  if coalesce(p_is_new, false) then
    if found then
      raise exception 'KZ_CODE_TAKEN';
    end if;
    insert into kaizen.projects (code, category, title, presenter, sort)
    values (v_code, p_category, btrim(p_title), btrim(p_presenter),
            (select coalesce(max(sort), 0) + 1 from kaizen.projects));
    perform kaizen.log(v_user, 'project_created', v_code, null,
      jsonb_build_object('category', p_category, 'title', btrim(p_title), 'presenter', btrim(p_presenter)));
  else
    if not found then
      raise exception 'KZ_NO_PROJECT';
    end if;
    if v_old.category <> p_category
       and exists (select 1 from kaizen.evaluations where project_code = v_code) then
      raise exception 'KZ_HAS_EVALUATIONS';
    end if;
    update kaizen.projects
       set category = p_category, title = btrim(p_title), presenter = btrim(p_presenter)
     where code = v_code;
    perform kaizen.log(v_user, 'project_updated', v_code, null,
      jsonb_build_object('category', p_category, 'title', btrim(p_title), 'presenter', btrim(p_presenter),
                         'was', jsonb_build_object('category', v_old.category, 'title', v_old.title,
                                                   'presenter', v_old.presenter)));
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.kz_admin_delete_project(p_token text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
  v_old  kaizen.projects;
begin
  select * into v_old from kaizen.projects where code = p_code for update;
  if not found then
    raise exception 'KZ_NO_PROJECT';
  end if;
  if exists (select 1 from kaizen.evaluations where project_code = p_code) then
    raise exception 'KZ_HAS_EVALUATIONS';
  end if;
  delete from kaizen.projects where code = p_code;
  perform kaizen.log(v_user, 'project_deleted', p_code, null,
    jsonb_build_object('category', v_old.category, 'title', v_old.title, 'presenter', v_old.presenter));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Admin: team member names (for the prize sheet) -----------------
-- p_members is a JSON array of names; it replaces the current list.
create or replace function public.kz_admin_set_members(p_token text, p_project text, p_members jsonb)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
begin
  if not exists (select 1 from kaizen.projects where code = p_project) then
    raise exception 'KZ_NO_PROJECT';
  end if;
  if jsonb_typeof(coalesce(p_members, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_members, '[]'::jsonb)) > 20 then
    raise exception 'KZ_BAD_INPUT';
  end if;

  delete from kaizen.team_members where project_code = p_project;
  insert into kaizen.team_members (project_code, full_name, sort)
  select p_project, left(btrim(m.name), 120), m.ord::int
  from jsonb_array_elements_text(coalesce(p_members, '[]'::jsonb)) with ordinality as m(name, ord)
  where length(btrim(m.name)) > 0;

  perform kaizen.log(v_user, 'team_members_updated', p_project, null,
    jsonb_build_object('members', coalesce(p_members, '[]'::jsonb)));
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- Admin: audit log -----------------------------------------------
create or replace function public.kz_admin_audit(p_token text, p_limit int default 500)
returns jsonb
language plpgsql
security definer
set search_path = kaizen, extensions, pg_temp
as $$
declare
  v_user kaizen.users := kaizen.auth(p_token, 'admin');
begin
  return (
    select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]'::jsonb)
    from (select id, at, actor_name, action, project_code, judge_id, details
            from kaizen.audit_log
           order by id desc
           limit least(greatest(coalesce(p_limit, 500), 1), 2000)) a
  );
end;
$$;

-- ---------------------------------------------------------------------
--  Permissions
-- ---------------------------------------------------------------------
revoke all on schema kaizen from public;
revoke all on all tables    in schema kaizen from public;
revoke all on all functions in schema kaizen from public;

revoke all on function
  public.kz_setup_status(),
  public.kz_setup_first_admin(text, text, text),
  public.kz_login(text, text, text),
  public.kz_logout(text),
  public.kz_change_password(text, text, text),
  public.kz_judge_load(text),
  public.kz_judge_save(text, text, jsonb, jsonb, text, boolean),
  public.kz_admin_load(text, boolean),
  public.kz_admin_reopen(text, uuid, text, text),
  public.kz_admin_set_judging(text, boolean),
  public.kz_admin_set_form(text, text, text),
  public.kz_admin_save_user(text, uuid, text, text, text, text, boolean),
  public.kz_admin_save_project(text, text, text, text, text, boolean),
  public.kz_admin_delete_project(text, text),
  public.kz_admin_set_members(text, text, jsonb),
  public.kz_admin_audit(text, int)
from public;

do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema kaizen from %I', r);
      execute format('revoke all on all tables in schema kaizen from %I', r);
      execute format('revoke all on all functions in schema kaizen from %I', r);
      execute format('grant execute on function
        public.kz_setup_status(),
        public.kz_setup_first_admin(text, text, text),
        public.kz_login(text, text, text),
        public.kz_logout(text),
        public.kz_change_password(text, text, text),
        public.kz_judge_load(text),
        public.kz_judge_save(text, text, jsonb, jsonb, text, boolean),
        public.kz_admin_load(text, boolean),
        public.kz_admin_reopen(text, uuid, text, text),
        public.kz_admin_set_judging(text, boolean),
        public.kz_admin_set_form(text, text, text),
        public.kz_admin_save_user(text, uuid, text, text, text, text, boolean),
        public.kz_admin_save_project(text, text, text, text, text, boolean),
        public.kz_admin_delete_project(text, text),
        public.kz_admin_set_members(text, text, jsonb),
        public.kz_admin_audit(text, int)
        to %I', r);
    end if;
  end loop;
end;
$$;

-- Tell the API layer about the new functions.
notify pgrst, 'reload schema';

-- =====================================================================
--  NEXT STEP - create your first admin account.
--  Easiest: open admin.html within 48 hours; it shows a one-time
--  "create the first admin" form. Or do it here: open a NEW query,
--  put your own values in, and run it once:
--
--    select kaizen.create_first_admin('your.username', 'Your Full Name', 'a-strong-password');
--
--  (username: small letters / digits / . _ -   |   password: 8+ characters)
-- =====================================================================
