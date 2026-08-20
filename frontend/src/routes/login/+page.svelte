<script lang="ts">
  import { goto, invalidateAll } from '$app/navigation';
  import { login } from '$lib/auth';
  import { ApiError } from '$lib/api';

  let email = $state('');
  let password = $state('');
  let error = $state('');
  let submitting = $state(false);

  async function onSubmit(event: SubmitEvent) {
    event.preventDefault();
    error = '';
    submitting = true;
    try {
      await login(email, password);
      // Re-run the root layout load so the header picks up the new session.
      await invalidateAll();
      await goto('/dashboard');
    } catch (cause) {
      error =
        cause instanceof ApiError ? cause.message : 'Could not reach the server. Try again.';
    } finally {
      submitting = false;
    }
  }
</script>

<div class="card">
  <h1>Sign in</h1>

  <form onsubmit={onSubmit}>
    <label>
      <span>Email</span>
      <input type="email" bind:value={email} autocomplete="username" required />
    </label>

    <label>
      <span>Password</span>
      <input
        type="password"
        bind:value={password}
        autocomplete="current-password"
        required
      />
    </label>

    {#if error}
      <p class="error" role="alert">{error}</p>
    {/if}

    <button type="submit" disabled={submitting}>
      {submitting ? 'Signing in...' : 'Sign in'}
    </button>
  </form>

  <p class="hint">Accounts are created by an administrator. There is no self-service signup.</p>
</div>

<style>
  .card {
    max-width: 22rem;
    margin: 3rem auto;
    padding: 1.75rem;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
  }

  h1 {
    margin: 0 0 1.25rem;
    font-size: 1.25rem;
  }

  button {
    width: 100%;
  }

  .hint {
    margin: 1.25rem 0 0;
    font-size: 0.8rem;
    color: var(--muted);
  }
</style>
