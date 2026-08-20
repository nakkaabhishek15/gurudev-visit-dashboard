import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ parent }) => {
  const { user } = await parent();

  // Client-side guard only, same as /dashboard. Real enforcement is require_auth
  // on the reports router -- the charts stay empty without a session.
  if (!user) {
    redirect(307, '/login');
  }

  return {};
};
