import { redirect } from '@sveltejs/kit';
import { api } from '$lib/api';
import type { PageLoad } from './$types';

type Dashboard = { greeting: string; role: string };

export const load: PageLoad = async ({ parent }) => {
  const { user } = await parent();

  // Client-side guard only. The real enforcement is `require_auth` on the API;
  // a user who skips this redirect still gets 401s from every endpoint.
  if (!user) {
    redirect(307, '/login');
  }

  return { dashboard: await api<Dashboard>('/dashboard') };
};
