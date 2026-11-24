create extension if not exists pgcrypto;

create type public.order_status as enum (
  'Menunggu',
  'Diproses',
  'Dikirim',
  'Selesai',
  'Dibatalkan'
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 160),
  category text not null check (char_length(category) between 1 and 80),
  price integer not null check (price > 0),
  stock integer not null default 0 check (stock >= 0),
  unit text not null default 'pcs' check (char_length(unit) between 1 and 20),
  image text not null default '',
  description text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.store_settings (
  id integer primary key default 1 check (id = 1),
  brand_name text not null default 'Irsam Fruit Store',
  brand_tagline text not null default 'Buah segar pilihan, langsung ke rumah Anda.',
  whatsapp_number text not null default '',
  logo_icon text not null default 'fa-solid fa-store',
  announcement_active boolean not null default true,
  announcement_text text not null default 'Buah segar pilihan, dikirim langsung ke rumah Anda.',
  hero_title text not null default 'Buah Segar Pilihan untuk Keluarga',
  hero_subtitle text not null default 'Pilih buah favorit, pesan dengan mudah, dan nikmati kesegarannya.',
  hero_bg text not null default '',
  updated_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  customer_name text not null check (char_length(customer_name) between 2 and 120),
  customer_phone text not null check (char_length(customer_phone) between 8 and 24),
  shipping_address text not null check (char_length(shipping_address) between 8 and 1000),
  subtotal integer not null check (subtotal >= 0),
  shipping_fee integer not null check (shipping_fee >= 0),
  total integer not null check (total = subtotal + shipping_fee),
  status public.order_status not null default 'Menunggu',
  created_at timestamptz not null default now()
);

create table public.order_items (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity > 0),
  unit text not null,
  unit_price integer not null check (unit_price > 0)
);

create table public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.is_store_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users
    where user_id = (select auth.uid())
  );
$$;

alter table public.products enable row level security;
alter table public.store_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.admin_users enable row level security;

create policy "Anyone can view active products"
  on public.products for select
  using (active or (select public.is_store_admin()));

create policy "Admins can manage products"
  on public.products for all
  using ((select public.is_store_admin()))
  with check ((select public.is_store_admin()));

create policy "Anyone can view store settings"
  on public.store_settings for select
  using (true);

create policy "Admins can manage store settings"
  on public.store_settings for all
  using ((select public.is_store_admin()))
  with check ((select public.is_store_admin()));

create policy "Admins can view orders"
  on public.orders for select
  using ((select public.is_store_admin()));

create policy "Admins can view order items"
  on public.order_items for select
  using (
    exists (
      select 1 from public.orders
      where orders.id = order_items.order_id
        and (select public.is_store_admin())
    )
  );

create policy "Admins can view their own admin record"
  on public.admin_users for select
  using (user_id = (select auth.uid()));

create or replace function public.restore_order_stock_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item record;
begin
  if new.status = 'Dibatalkan' and old.status <> 'Dibatalkan' then
    for v_item in
      select product_id, quantity
      from public.order_items
      where order_id = new.id and product_id is not null
    loop
      update public.products
      set stock = stock + v_item.quantity,
          updated_at = now()
      where id = v_item.product_id;
    end loop;
  end if;
  return new;
end;
$$;

create trigger restore_order_stock_after_cancel
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.restore_order_stock_on_cancel();

grant select on public.products, public.store_settings to anon, authenticated;
grant insert, update, delete on public.products, public.store_settings to authenticated;
grant select on public.orders, public.order_items, public.admin_users to authenticated;

create or replace function public.place_order(
  p_customer_name text,
  p_customer_phone text,
  p_shipping_address text,
  p_shipping_zone text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_order_code text;
  v_subtotal integer := 0;
  v_shipping_fee integer := 0;
  v_item record;
  v_item_count integer;
begin
  if p_customer_name is null or p_customer_phone is null or p_shipping_address is null
    or char_length(trim(p_customer_name)) not between 2 and 120
    or char_length(trim(p_customer_phone)) not between 8 and 24
    or trim(p_customer_phone) !~ '^[0-9]{8,24}$'
    or char_length(trim(p_shipping_address)) not between 8 and 1000 then
    raise exception 'Please provide valid customer and delivery details.';
  end if;

  if p_shipping_zone is null or p_shipping_zone not in ('dekat', 'sedang', 'jauh') then
    raise exception 'Please choose a valid delivery area.';
  end if;

  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'The cart must contain between 1 and 30 products.';
  end if;
  if jsonb_array_length(p_items) not between 1 and 30 then
    raise exception 'The cart must contain between 1 and 30 products.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) as entries(item)
    where (item->>'id') is null
      or (item->>'qty') is null
      or (item->>'qty') !~ '^[1-9][0-9]{0,3}$'
  ) then
    raise exception 'The cart contains an invalid product or quantity.';
  end if;

  if (
    select count(*) <> count(distinct item->>'id')
    from jsonb_array_elements(p_items) as entries(item)
  ) then
    raise exception 'The cart contains duplicate products.';
  end if;

  perform p.id
  from public.products p
  join (
    select (item->>'id')::uuid as product_id
    from jsonb_array_elements(p_items) as entries(item)
  ) requested on requested.product_id = p.id
  where p.active
  order by p.id
  for update of p;

  select count(*) into v_item_count
  from (
    select (item->>'id')::uuid as product_id
    from jsonb_array_elements(p_items) as entries(item)
  ) requested
  join public.products p on p.id = requested.product_id and p.active;

  if v_item_count <> jsonb_array_length(p_items) then
    raise exception 'One or more products are unavailable.';
  end if;

  for v_item in
    select
      p.id,
      p.name,
      p.price,
      p.unit,
      p.stock,
      (item->>'qty')::integer as quantity
    from jsonb_array_elements(p_items) as entries(item)
    join public.products p on p.id = (item->>'id')::uuid
    order by p.id
  loop
    if v_item.stock < v_item.quantity then
      raise exception 'Not enough stock for %.', v_item.name;
    end if;
    v_subtotal := v_subtotal + (v_item.price * v_item.quantity);
  end loop;

  if v_subtotal < 150000 then
    v_shipping_fee := case p_shipping_zone
      when 'dekat' then 10000
      when 'sedang' then 15000
      else 25000
    end;
  end if;

  v_order_code := 'ORD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.orders (
    order_code, customer_name, customer_phone, shipping_address, subtotal, shipping_fee, total
  ) values (
    v_order_code, trim(p_customer_name), trim(p_customer_phone),
    trim(p_shipping_address), v_subtotal, v_shipping_fee, v_subtotal + v_shipping_fee
  ) returning id into v_order_id;

  for v_item in
    select
      p.id,
      p.name,
      p.price,
      p.unit,
      (item->>'qty')::integer as quantity
    from jsonb_array_elements(p_items) as entries(item)
    join public.products p on p.id = (item->>'id')::uuid
    order by p.id
  loop
    update public.products
    set stock = stock - v_item.quantity,
        updated_at = now()
    where id = v_item.id;

    insert into public.order_items (
      order_id, product_id, product_name, quantity, unit, unit_price
    ) values (
      v_order_id, v_item.id, v_item.name, v_item.quantity, v_item.unit, v_item.price
    );
  end loop;

  return jsonb_build_object(
    'id', v_order_id,
    'order_code', v_order_code,
    'subtotal', v_subtotal,
    'shipping_fee', v_shipping_fee,
    'total', v_subtotal + v_shipping_fee,
    'items', (
      select jsonb_agg(
        jsonb_build_object(
          'name', product_name,
          'qty', quantity,
          'unit', unit,
          'price', unit_price
        ) order by id
      )
      from public.order_items
      where order_id = v_order_id
    )
  );
end;
$$;

revoke all on function public.place_order(text, text, text, text, jsonb) from public;
grant execute on function public.place_order(text, text, text, text, jsonb) to anon, authenticated, service_role;

create or replace function public.set_order_status(
  p_order_id uuid,
  p_status public.order_status
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_status public.order_status;
begin
  if not (select public.is_store_admin()) then
    raise exception 'Only store admins can update orders.';
  end if;

  select status into v_current_status
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found.';
  end if;

  if not (
    (v_current_status = 'Menunggu' and p_status in ('Diproses', 'Dibatalkan'))
    or (v_current_status = 'Diproses' and p_status in ('Dikirim', 'Dibatalkan'))
    or (v_current_status = 'Dikirim' and p_status = 'Selesai')
  ) then
    raise exception 'That order status transition is not allowed.';
  end if;

  update public.orders set status = p_status where id = p_order_id;
end;
$$;

revoke all on function public.set_order_status(uuid, public.order_status) from public;
grant execute on function public.set_order_status(uuid, public.order_status) to authenticated;

insert into public.store_settings (id) values (1)
on conflict (id) do nothing;

insert into public.products (name, category, price, stock, unit, image, description)
select seed.name, seed.category, seed.price, seed.stock, seed.unit, seed.image, seed.description
from (values
  ('Mangga Harum Manis', 'Buah Lokal', 28000, 50, 'kg', 'https://images.unsplash.com/photo-1553279768-865429fa0078?auto=format&fit=crop&w=800&q=80', 'Mangga matang dengan rasa manis dan aroma yang harum.'),
  ('Apel Fuji Premium', 'Buah Impor', 45000, 35, 'kg', 'https://images.unsplash.com/photo-1568702846914-96b305d2aaeb?auto=format&fit=crop&w=800&q=80', 'Apel Fuji renyah, segar, dan cocok untuk camilan keluarga.'),
  ('Alpukat Mentega Jumbo', 'Buah Lokal', 32000, 8, 'kg', 'https://images.unsplash.com/photo-1523049673857-eb18f1d7b578?auto=format&fit=crop&w=800&q=80', 'Alpukat berdaging lembut dan creamy, dipilih saat matang.'),
  ('Pisang Cavendish', 'Organik', 25000, 60, 'sisir', 'https://images.unsplash.com/photo-1528825871115-3581a5387919?auto=format&fit=crop&w=800&q=80', 'Pisang manis dan praktis untuk sarapan atau bekal.')
) as seed(name, category, price, stock, unit, image, description)
where not exists (
  select 1 from public.products existing where existing.name = seed.name
);
