<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import { page } from '$app/state';
  import { logout } from '$lib/auth';
  import '../app.css';

  let { data, children } = $props();

  const onLogin = $derived(page.url.pathname === '/login');

  async function signOut() {
    await logout();
    await invalidateAll();
    await goto('/login');
  }
</script>

<div class="shell">
  {#if data.user && !onLogin}
    <header>
      <a class="brand" href="/dashboard">Gurudev Visit Dashboard</a>
      <nav>
        <span class="who">{data.user.display_name} &middot; {data.user.role}</span>
        <button class="secondary" onclick={signOut}>Sign out</button>
      </nav>
    </header>
  {/if}

  <main>
    {@render children()}
  </main>
</div>

<style>
  .shell {
    min-height: 100vh;
    display: flex;
    flex-direction: column;
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.9rem 1.5rem;
    border-bottom: 1px solid var(--border);
    background: var(--surface);
  }

  .brand {
    font-weight: 600;
    text-decoration: none;
    color: var(--text);
  }

  nav {
    display: flex;
    align-items: center;
    gap: 1rem;
  }

  .who {
    font-size: 0.875rem;
    color: var(--muted);
  }

  main {
    flex: 1;
    padding: 2rem 1.5rem;
  }
</style>
