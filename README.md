# Irsam Fruit Store

The root `index.html` is the main, product-category-independent storefront. It starts with fruit examples from `49.html`; add products and categories in the authenticated admin panel. `49.html` and `assets/index.html` are preserved as earlier prototypes.

## Connect Supabase

1. Create a Supabase project and run [`supabase/schema.sql`](supabase/schema.sql) once in the SQL Editor. It creates the catalog, store settings, orders, stock reservation, and row-level access rules. The four fruit rows are sample data; edit or remove them before launch.
2. Copy the project URL and **publishable/anon key** from Project Settings → API into `supabase-config.js`. This browser key is public by design. Never put a service-role key in this file or in browser code.
3. Install the Supabase CLI, log in, link the project, and deploy the public order function from the repository root:

   ```sh
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase functions deploy create-order
   ```

   The function uses the project's server-side `SUPABASE_SERVICE_ROLE_KEY` and calls the SQL order routine, which checks current prices and stock, calculates delivery, reserves stock, and creates the order atomically.
4. Create an admin user in Supabase → Authentication → Users. Copy that user's UUID and register it in the SQL Editor:

   ```sql
   insert into public.admin_users (user_id)
   values ('AUTH_USER_UUID');
   ```

5. Serve the repository over HTTP (not `file://`) and open `index.html`. For example, with Python installed:

   ```sh
   python -m http.server 8000
   ```

   Visit `http://localhost:8000`. Sign in to Admin CMS, set the shop's Indonesian WhatsApp number, review delivery rates, and replace sample listings with real product details and images.

## Current scope and launch checklist

- Catalog, store settings, stock, and admin orders are shared through Supabase. Customer order history is deliberately stored only in that customer's browser; customers do not get public access to other orders.
- Checkout creates a real order and reserves stock, then opens WhatsApp for manual confirmation. It does **not** collect payment online, calculate a live courier quote, or provide customer accounts/order tracking.
- Delivery is currently fixed at Rp 10,000 (near), Rp 15,000 (medium), or Rp 25,000 (far), with free delivery from Rp 150,000. Confirm these rules match your service area before taking orders.
- The public order function is designed for anonymous checkout and validates order data server-side. Before public launch, add abuse controls such as CAPTCHA/rate limiting, configure Supabase Auth email security, set backups, and test order/cancellation flows with real project credentials.
- Use a production host with HTTPS and a restrictive Content Security Policy. The current prototype loads Tailwind, icons, fonts, and Supabase JS from CDNs.

Without Supabase configuration, the page displays fruit sample data in clearly labeled preview mode; checkout and admin writes are disabled.
