import { loadCurrentUser } from '$lib/auth';
import type { LayoutLoad } from './$types';

// Static build: no server to render on, and nothing is safe to prerender behind
// a login. Everything runs in the browser.
export const ssr = false;
export const prerender = false;

export const load: LayoutLoad = async () => {
  return { user: await loadCurrentUser() };
};
