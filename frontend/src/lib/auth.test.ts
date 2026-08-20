import { describe, expect, it, vi, afterEach } from 'vitest';
import { isAdmin, loadCurrentUser } from './auth';

const user = {
  app_user_id: '00000000-0000-0000-0000-000000000001',
  email: 'staff@example.com',
  display_name: 'Staff Member',
  roles: ['staff'],
  role: 'staff'
};

afterEach(() => {
  vi.unstubAllGlobals();
});

function stubFetch(status: number, body: unknown) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => new Response(JSON.stringify(body), { status }))
  );
}

describe('loadCurrentUser', () => {
  it('returns the user when the session is valid', async () => {
    stubFetch(200, user);
    await expect(loadCurrentUser()).resolves.toEqual(user);
  });

  it('returns null instead of throwing when signed out', async () => {
    stubFetch(401, { detail: 'Authentication required.' });
    await expect(loadCurrentUser()).resolves.toBeNull();
  });

  it('propagates errors that are not a missing session', async () => {
    stubFetch(500, { detail: 'boom' });
    await expect(loadCurrentUser()).rejects.toThrow('boom');
  });
});

describe('isAdmin', () => {
  it('is false for staff and for nobody', () => {
    expect(isAdmin(user)).toBe(false);
    expect(isAdmin(null)).toBe(false);
  });

  it('is true when the admin role is present', () => {
    expect(isAdmin({ ...user, roles: ['admin', 'staff'], role: 'admin' })).toBe(true);
  });
});
