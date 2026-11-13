-- FOOTBALL CARD ARENA: Stage 2 database (Supabase / PostgreSQL)
-- Paste this whole file into Supabase > SQL Editor > Run.

create extension if not exists pgcrypto;

-- ========== SETTINGS (admin controlled) ==========
create table settings (
  id int primary key default 1 check (id = 1),
  daily_reward int not null default 10 check (daily_reward >= 0),
  min_price numeric(10,2) not null default 15,
  max_price numeric(10,2) not null default 10000,
  store_price numeric(10,2) not null default 15,
  commission_percent numeric(5,2) not null default 0 check (commission_percent between 0 and 100),
  ads_enabled boolean not null default false
);
insert into settings default values;

-- ========== USERS ==========
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  google_id text unique,
  email text unique not null,
  role text not null default 'user' check (role in ('user','admin')),
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now()
);

-- demo_bdt is a DEMO balance, not real money
create table wallets (
  user_id uuid primary key references profiles on delete cascade,
  coins int not null default 0 check (coins >= 0),
  demo_bdt numeric(12,2) not null default 100 check (demo_bdt >= 0)
);

create function is_admin() returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and status = 'active');
$$;

create function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, google_id, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'provider_id', new.raw_user_meta_data->>'sub'), new.email);
  insert into wallets (user_id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ========== CARDS ==========
-- creator_id is UNIQUE: one personal card per account.
-- Rating is NOT stored. It is calculated from created_at on the server.
create table player_cards (
  id uuid primary key default gen_random_uuid(),
  card_code text unique not null default ('FCA-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8))),
  creator_id uuid unique not null references profiles on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  photo_path text,
  position text not null check (position in ('GK','CB','LB','RB','CDM','CM','CAM','LW','RW','ST')),
  jersey_number int not null check (jersey_number between 1 and 99),
  design text not null default 'classic' check (design in ('classic','night','pitch','flame')),
  background text not null default 'default',
  color text not null default '#f1ce72' check (color ~ '^#[0-9a-fA-F]{6}$'),
  visibility text not null default 'public' check (visibility in ('public','private')),
  created_at timestamptz not null default now()
);

-- One owner per card at a time. Max 26 cards per user.
create table card_ownership (
  card_id uuid primary key references player_cards on delete cascade,
  owner_id uuid not null references profiles on delete cascade,
  acquired_at timestamptz not null default now()
);
create index on card_ownership (owner_id);

create function enforce_collection_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform 1 from wallets where user_id = new.owner_id for update;  -- serializes this user's changes
  if (select count(*) from card_ownership where owner_id = new.owner_id and card_id <> new.card_id) >= 26 then
    raise exception 'Collection is full (26/26)';
  end if;
  return new;
end $$;
create trigger limit_collection before insert or update of owner_id on card_ownership
  for each row execute function enforce_collection_limit();

create function on_card_created() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into card_ownership (card_id, owner_id) values (new.id, new.creator_id);
  return new;
end $$;
create trigger card_created after insert on player_cards
  for each row execute function on_card_created();

create function protect_card_fields() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.id <> old.id or new.creator_id <> old.creator_id or new.created_at <> old.created_at or new.card_code <> old.card_code then
    raise exception 'These fields cannot be changed';
  end if;
  if new.visibility = 'private' and exists (select 1 from listings where card_id = new.id and status = 'active') then
    raise exception 'Cancel the listing before making the card private';
  end if;
  return new;
end $$;

-- Public view with the server-calculated rating: 50 + 1 per completed 15 days
create view card_public with (security_invoker = true) as
select id, card_code, name, photo_path, position, jersey_number, design, background, color, visibility, created_at,
       50 + floor(extract(epoch from (now() - created_at)) / 86400 / 15)::int as overall_rating
from player_cards;

-- ========== DAILY CLAIM ==========
create table daily_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  claim_date date not null,
  coins_awarded int not null,
  created_at timestamptz not null default now(),
  unique (user_id, claim_date)
);

create function claim_daily() returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); today date := (now() at time zone 'Asia/Dhaka')::date; amt int;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  select daily_reward into amt from settings;
  begin
    insert into daily_claims (user_id, claim_date, coins_awarded) values (uid, today, amt);
  exception when unique_violation then
    raise exception 'Already claimed today';
  end;
  update wallets set coins = coins + amt where user_id = uid;
  return amt;
end $$;

-- ========== MARKETPLACE ==========
create table listings (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references player_cards on delete cascade,
  seller_id uuid not null references profiles,
  price numeric(10,2) not null,
  status text not null default 'active' check (status in ('active','sold','cancelled')),
  created_at timestamptz not null default now()
);
create unique index one_active_listing_per_card on listings (card_id) where status = 'active';

create trigger protect_card before update on player_cards
  for each row execute function protect_card_fields();

create table transactions (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references player_cards,
  listing_id uuid references listings,
  buyer_id uuid not null references profiles,
  seller_id uuid not null references profiles,
  price numeric(10,2) not null,
  commission numeric(10,2) not null default 0,
  transaction_status text not null default 'completed' check (transaction_status in ('completed','failed','refunded')),
  created_at timestamptz not null default now()
);

create function list_card(p_card uuid, p_price numeric) returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s settings%rowtype; lid uuid;
begin
  select * into s from settings;
  if p_price < s.min_price or p_price > s.max_price then
    raise exception 'Price must be between % and % BDT', s.min_price, s.max_price;
  end if;
  if not exists (select 1 from card_ownership where card_id = p_card and owner_id = uid) then
    raise exception 'You do not own this card';
  end if;
  if (select visibility from player_cards where id = p_card) <> 'public' then
    raise exception 'Private cards cannot be sold';
  end if;
  insert into listings (card_id, seller_id, price) values (p_card, uid, p_price) returning id into lid;
  return lid;
exception when unique_violation then
  raise exception 'This card already has an active listing';
end $$;

create function cancel_listing(p_listing uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update listings set status = 'cancelled' where id = p_listing and seller_id = auth.uid() and status = 'active';
  if not found then raise exception 'Listing not found'; end if;
end $$;

-- Buying: one transaction, row locks, all-or-nothing
create function buy_listing(p_listing uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); l listings%rowtype; s settings%rowtype; fee numeric(10,2); tid uuid;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  perform 1 from wallets where user_id = uid for update;            -- lock buyer first
  select * into l from listings where id = p_listing and status = 'active' for update;
  if not found then raise exception 'This listing is no longer available'; end if;
  if l.seller_id = uid then raise exception 'You cannot buy your own card'; end if;
  perform 1 from card_ownership where card_id = l.card_id and owner_id = l.seller_id for update;
  if not found then raise exception 'Seller no longer owns this card'; end if;
  if (select count(*) from card_ownership where owner_id = uid) >= 26 then
    raise exception 'Your collection is full (26/26)';
  end if;
  select * into s from settings;
  fee := round(l.price * s.commission_percent / 100, 2);
  update wallets set demo_bdt = demo_bdt - l.price where user_id = uid and demo_bdt >= l.price;
  if not found then raise exception 'Not enough demo balance'; end if;
  update wallets set demo_bdt = demo_bdt + (l.price - fee) where user_id = l.seller_id;
  update card_ownership set owner_id = uid, acquired_at = now() where card_id = l.card_id;
  update listings set status = 'sold' where id = l.id;
  insert into transactions (card_id, listing_id, buyer_id, seller_id, price, commission)
  values (l.card_id, l.id, uid, l.seller_id, l.price, fee) returning id into tid;
  return tid;
end $$;

-- ========== CHAT (buyer <-> seller) ==========
create table conversations (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references player_cards on delete cascade,
  buyer_id uuid not null references profiles,
  seller_id uuid not null references profiles,
  created_at timestamptz not null default now(),
  unique (card_id, buyer_id),
  check (buyer_id <> seller_id)
);
create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations on delete cascade,
  sender_id uuid not null references profiles,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index on messages (conversation_id, created_at);

create function start_conversation(p_card uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); l listings%rowtype; cid uuid;
begin
  select * into l from listings where card_id = p_card and status = 'active';
  if not found then raise exception 'This card is not for sale'; end if;
  if l.seller_id = uid then raise exception 'You cannot message yourself'; end if;
  insert into conversations (card_id, buyer_id, seller_id) values (p_card, uid, l.seller_id)
  on conflict (card_id, buyer_id) do update set card_id = excluded.card_id returning id into cid;
  return cid;
end $$;

create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles,
  card_id uuid references player_cards,
  conversation_id uuid references conversations,
  reason text not null check (char_length(reason) between 3 and 500),
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now()
);

-- ========== SECURITY RULES (row level security) ==========
alter table settings enable row level security;
alter table profiles enable row level security;
alter table wallets enable row level security;
alter table player_cards enable row level security;
alter table card_ownership enable row level security;
alter table daily_claims enable row level security;
alter table listings enable row level security;
alter table transactions enable row level security;
alter table conversations enable row level security;
alter table messages enable row level security;
alter table reports enable row level security;

create policy "read settings" on settings for select to authenticated using (true);
create policy "admin edits settings" on settings for update to authenticated using (is_admin()) with check (is_admin());

create policy "own profile" on profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy "admin edits profiles" on profiles for update to authenticated using (is_admin()) with check (is_admin());

create policy "own wallet" on wallets for select to authenticated using (user_id = auth.uid() or is_admin());
-- no insert/update policy on wallets: coins change only through the functions above

create policy "see public or own cards" on player_cards for select to authenticated
  using (visibility = 'public'
         or exists (select 1 from card_ownership o where o.card_id = id and o.owner_id = auth.uid())
         or is_admin());
create policy "create my one card" on player_cards for insert to authenticated with check (creator_id = auth.uid());
create policy "edit my card" on player_cards for update to authenticated
  using (creator_id = auth.uid() and exists (select 1 from card_ownership o where o.card_id = id and o.owner_id = auth.uid()))
  with check (creator_id = auth.uid());
create policy "admin edits cards" on player_cards for update to authenticated using (is_admin()) with check (is_admin());

create policy "see ownership" on card_ownership for select to authenticated
  using (owner_id = auth.uid() or is_admin()
         or exists (select 1 from player_cards c where c.id = card_id and c.visibility = 'public'));

create policy "own claims" on daily_claims for select to authenticated using (user_id = auth.uid() or is_admin());

create policy "see listings" on listings for select to authenticated
  using (seller_id = auth.uid() or is_admin()
         or (status = 'active' and exists (select 1 from player_cards c where c.id = card_id and c.visibility = 'public')));

create policy "own transactions" on transactions for select to authenticated
  using (buyer_id = auth.uid() or seller_id = auth.uid() or is_admin());

create policy "my conversations" on conversations for select to authenticated
  using (buyer_id = auth.uid() or seller_id = auth.uid() or is_admin());

create policy "read my messages" on messages for select to authenticated
  using (exists (select 1 from conversations c where c.id = conversation_id
                 and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())) or is_admin());
create policy "send message while for sale" on messages for insert to authenticated
  with check (sender_id = auth.uid()
    and exists (select 1 from conversations c
                where c.id = conversation_id and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
                and exists (select 1 from listings l where l.card_id = c.card_id and l.status = 'active')));

create policy "file a report" on reports for insert to authenticated with check (reporter_id = auth.uid());
create policy "admin reads reports" on reports for select to authenticated using (is_admin());
create policy "admin updates reports" on reports for update to authenticated using (is_admin()) with check (is_admin());

-- Only signed-in users may call the functions
revoke execute on all functions in schema public from public, anon;

-- ========== PHOTO STORAGE (JPG/PNG/WebP, max 3 MB, private bucket) ==========
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('card-photos', 'card-photos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'card-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "replace own photo" on storage.objects for update to authenticated
  using (bucket_id = 'card-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "delete own photo" on storage.objects for delete to authenticated
  using (bucket_id = 'card-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "read own or public card photos" on storage.objects for select to authenticated
  using (bucket_id = 'card-photos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from player_cards c where c.photo_path = name and c.visibility = 'public')));

-- After you sign in once, make yourself admin (replace the email, run it alone):
-- update profiles set role = 'admin' where email = 'YOUR_EMAIL@gmail.com';
