/**
 * Thin fetch wrapper.
 *
 * Paths are relative so the same code works behind the Vite dev proxy and behind
 * CloudFront. `credentials: 'include'` is what carries the session cookie.
 */

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api${path}`, {
    ...init,
    credentials: 'include',
    headers: {
      'content-type': 'application/json',
      ...(init.headers ?? {})
    }
  });

  if (!response.ok) {
    throw new ApiError(response.status, await readErrorDetail(response));
  }

  return (await response.json()) as T;
}

async function readErrorDetail(response: Response): Promise<string> {
  try {
    const body = await response.json();
    if (typeof body?.detail === 'string') {
      return body.detail;
    }
  } catch {
    // Non-JSON error body (a gateway or CloudFront page, most likely).
  }
  return `Request failed with status ${response.status}.`;
}
