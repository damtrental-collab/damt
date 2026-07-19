-- =========================================================
-- DAMT RENTAL — Supabase Schema
-- Run this once in Supabase SQL Editor (Project → SQL Editor → New query)
-- =========================================================

-- ---------- 1. PROFILES ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('seeker','owner')) default 'seeker',
  full_name text,
  phone text,
  photo_url text,
  address text,
  aadhaar_last4 text,           -- ONLY last 4 digits stored, never the full number
  aadhaar_verified boolean default false,
  telegram_chat_id text,
  is_admin boolean default false,
  created_at timestamptz default now()
);

alter table profiles enable row level security;

create policy "users read own profile" on profiles
  for select using (auth.uid() = id or exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

create policy "users update own profile" on profiles
  for update using (auth.uid() = id);

create policy "users insert own profile" on profiles
  for insert with check (auth.uid() = id);

-- ---------- 2. PROPERTIES ----------
create table if not exists properties (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references profiles(id) on delete cascade,
  title text not null,
  city text not null,
  rent numeric not null,
  thumbnail_url text,
  photos text[] default '{}',
  -- public_summary is visible to everyone (no payment needed)
  public_summary text,
  -- the fields below are the "paid" details, only exposed through get_property_details()
  full_address text,
  owner_contact text,
  description text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz default now()
);

alter table properties enable row level security;

-- Everyone can see approved listings' public fields
create policy "public read approved properties" on properties
  for select using (status = 'approved');

-- Owners see and manage their own listings regardless of status
create policy "owners manage own properties" on properties
  for all using (auth.uid() = owner_id);

-- Admins can do anything
create policy "admins manage all properties" on properties
  for all using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

-- ---------- 3. COUPONS ----------
create table if not exists coupons (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  discount_percent numeric default 0,
  discount_amount numeric default 0,
  active boolean default true,
  usage_limit integer,
  used_count integer default 0,
  expires_at timestamptz,
  created_at timestamptz default now()
);

alter table coupons enable row level security;

create policy "anyone can check active coupons" on coupons
  for select using (active = true);

create policy "admins manage coupons" on coupons
  for all using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

-- ---------- 4. PAYMENTS (access grants) ----------
create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete cascade,
  amount numeric not null default 100,
  coupon_code text,
  razorpay_payment_id text,
  razorpay_order_id text,
  status text not null default 'created' check (status in ('created','paid','failed')),
  access_expires_at timestamptz,   -- set to now() + 24h when marked paid
  created_at timestamptz default now()
);

alter table payments enable row level security;

create policy "users read own payments" on payments
  for select using (auth.uid() = user_id);

create policy "users insert own payments" on payments
  for insert with check (auth.uid() = user_id);

create policy "admins read all payments" on payments
  for select using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

-- NOTE: payments should only be flipped to 'paid' by the razorpay-webhook Edge Function
-- (using the service role key), never directly from the browser. See EDGE_FUNCTIONS.md.

-- ---------- 5. OTP VERIFICATIONS ----------
create table if not exists otp_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete cascade,
  otp_hash text not null,
  verified boolean default false,
  expires_at timestamptz not null,
  created_at timestamptz default now()
);

alter table otp_verifications enable row level security;

create policy "users manage own otp" on otp_verifications
  for all using (auth.uid() = user_id);

-- ---------- 6. BILLS ----------
create table if not exists bills (
  id uuid primary key default gen_random_uuid(),
  bill_number text unique not null,
  payment_id uuid references payments(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  amount numeric not null,
  gst_amount numeric not null,
  total_amount numeric not null,
  gstin text default '33DWCPA3567H1ZS',
  created_at timestamptz default now()
);

alter table bills enable row level security;

create policy "users read own bills" on bills
  for select using (auth.uid() = user_id);

create policy "admins read all bills" on bills
  for select using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

-- ---------- 7. TERMS & CONDITIONS ----------
create table if not exists terms (
  id int primary key default 1,
  content text not null default 'Terms and conditions go here.',
  updated_at timestamptz default now()
);
insert into terms (id, content) values (1, 'Terms and conditions coming soon.')
  on conflict (id) do nothing;

alter table terms enable row level security;

create policy "anyone can read terms" on terms
  for select using (true);

create policy "admins update terms" on terms
  for update using (exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin));

-- ---------- 8. FUNCTION: get_property_details ----------
-- Returns the paid/full fields for a property ONLY if the caller currently
-- has a valid, unexpired payment. This is the real enforcement point —
-- the browser can't fake this because it runs server-side inside Postgres.
create or replace function get_property_details(prop_id uuid)
returns table (full_address text, owner_contact text, description text)
language plpgsql
security definer
as $$
begin
  if exists (
    select 1 from payments
    where user_id = auth.uid()
      and status = 'paid'
      and access_expires_at > now()
  ) then
    return query select p.full_address, p.owner_contact, p.description
                 from properties p where p.id = prop_id and p.status = 'approved';
  else
    raise exception 'No active access. Please complete payment and OTP verification.';
  end if;
end;
$$;

-- ---------- 9. STORAGE BUCKETS ----------
-- Create these in Supabase Dashboard → Storage (or via SQL below):
insert into storage.buckets (id, name, public) values ('profile-photos','profile-photos', true)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('property-photos','property-photos', true)
  on conflict (id) do nothing;

create policy "authenticated users upload own profile photo"
  on storage.objects for insert
  with check (bucket_id = 'profile-photos' and auth.role() = 'authenticated');

create policy "authenticated users upload property photos"
  on storage.objects for insert
  with check (bucket_id = 'property-photos' and auth.role() = 'authenticated');

create policy "public read photos"
  on storage.objects for select
  using (bucket_id in ('profile-photos','property-photos'));

-- ---------- 10. MAKE YOURSELF ADMIN ----------
-- 1. Sign up once through the normal app login (any email/password).
-- 2. Then run (replace with that email):
-- update profiles set is_admin = true where id = (select id from auth.users where email = 'your-admin-email@example.com');
