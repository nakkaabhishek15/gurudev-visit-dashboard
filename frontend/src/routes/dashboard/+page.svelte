<script lang="ts">
  let { data } = $props();
</script>

<section>
  <h1>{data.dashboard.greeting}</h1>
  <p>
    You are signed in as <strong>{data.user?.email}</strong> with the
    <strong>{data.dashboard.role}</strong> role.
  </p>
  <p class="next">
    Replace this route with the real page. Add API endpoints in
    <code>backend/app/api/</code> &mdash; anything mounted under the protected router in
    <code>backend/app/main.py</code> already requires a signed-in user.
  </p>
</section>

<style>
  section {
    max-width: 42rem;
  }

  h1 {
    font-size: 1.4rem;
    margin-top: 0;
  }

  .next {
    margin-top: 2rem;
    padding: 1rem;
    border-left: 3px solid var(--border);
    color: var(--muted);
    font-size: 0.9rem;
  }

  code {
    font-size: 0.85em;
  }
</style>
