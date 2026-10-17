# Chat

A chat app in one page. It has one main group chat for everyone, private DMs, and group chats you make yourself. It also has online status, replies, reactions, typing indicators, unread markers, and light and dark themes. The backend is [Supabase](https://supabase.com).

## Setup (about 5 minutes)

1. Create a free project at [supabase.com](https://supabase.com).
2. **Run the schema:** open **SQL Editor → New query**, paste everything from [`supabase/schema.sql`](supabase/schema.sql), and click **Run**.
3. **Turn on anonymous sign-ins:** go to **Authentication → Sign In / Providers** and switch on **Allow anonymous sign-ins**. This gives everyone an account without needing a password. Each browser keeps its own account.
4. **Add your keys:** go to **Project Settings → API** and copy the **Project URL** and the **anon public** key. Paste them at the top of the `<script>` in `index.html`:
   ```js
   const SUPABASE_URL='https://xxxx.supabase.co';
   const SUPABASE_ANON_KEY='eyJ...';
   ```
   The anon key is meant to be public. The database rules are what keep chats private.
5. Open `index.html`, or host it on GitHub Pages, Netlify, or anywhere similar.

## How privacy works

Row Level Security in Postgres decides who can read a chat:

- **Main chat:** everyone can see it.
- **DMs and groups:** only members can read the messages. Other people can't load them, even if they call the API themselves.
- Reactions, deletes, renames, and membership changes all go through database functions. Those functions check that you're a member before doing anything.
