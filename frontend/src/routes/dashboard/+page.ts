import { redirect } from '@sveltejs/kit';
import { api } from '$lib/api';
import type { PageLoad } from './$types';

type Dashboard = { greeting: string; role: string };

type Course = {
  course_id: string;
  course_name: string;
  start_date: string | null;
  end_date: string | null;
};

type Item = {
  dimension: string;
  category: string;
  course_id: string;
  registration_count: number;
  course_registration_count: number;
};

type Report = {
  courses: Course[];
  items: Item[];
  total_registration_count: number;
  total_course_count: number;
  available_countries: string[];
  data_synced_at: string | null;
};

export const load: PageLoad = async ({ parent }) => {
  const { user } = await parent();

  // Client-side guard only. The real enforcement is `require_auth` on the API;
  // a user who skips this redirect still gets 401s from every endpoint.
  if (!user) {
    redirect(307, '/login');
  }

  const dashboard = await api<Dashboard>('/dashboard');

  // Headline numbers for the landing page. The warehouse is a separate database
  // reached over its own connection, so it can be down while login and the rest
  // of the app are fine -- in that case the page still renders, without the
  // summary, rather than failing outright.
  let report: Report | null = null;
  try {
    report = await api<Report>(
      '/reports/retreat-guru-course-demographics?course_id=4521&course_id=4522'
    );
  } catch {
    report = null;
  }

  return { dashboard, report };
};
