import { api, ApiError } from '$lib/api';

export type CurrentUser = {
  app_user_id: string;
  email: string;
  display_name: string;
  roles: string[];
  role: string;
};

export async function login(email: string, password: string): Promise<CurrentUser> {
  return api<CurrentUser>('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ email, password })
  });
}

export async function logout(): Promise<void> {
  await api<{ status: string }>('/auth/logout', { method: 'POST' });
}

/** Returns null when nobody is signed in, and throws on any other failure. */
export async function loadCurrentUser(): Promise<CurrentUser | null> {
  try {
    return await api<CurrentUser>('/auth/me');
  } catch (error) {
    if (error instanceof ApiError && error.status === 401) {
      return null;
    }
    throw error;
  }
}

export function isAdmin(user: CurrentUser | null): boolean {
  return user?.roles.includes('admin') ?? false;
}
