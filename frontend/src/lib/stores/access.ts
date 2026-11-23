import { get, writable } from 'svelte/store';
import { apiFetch, setUnauthorizedHandler } from '$lib/api/client';
import { t } from '$lib/i18n';
import type { AccessStatus } from '$lib/api/types';

export type AccessState = {
  authenticated: boolean;
  registered: boolean;
  username: string;
  loading: boolean;
  gateVisible: boolean;
  error: string;
};

const initialAccessState: AccessState = {
  authenticated: false,
  registered: true,
  username: '',
  loading: false,
  gateVisible: false,
  error: ''
};

function createAccessStore() {
  const { subscribe, set, update } = writable<AccessState>(initialAccessState);

  function applyStatus(data: AccessStatus, gateVisible: boolean, error = '') {
    update((state) => ({
      ...state,
      authenticated: data.authenticated,
      registered: data.registered,
      username: data.username || '',
      gateVisible,
      error
    }));
  }

  function setGateVisible(gateVisible: boolean, error = '') {
    update((state) => ({
      ...state,
      authenticated: !gateVisible,
      gateVisible,
      error
    }));
  }

  async function checkAccess(onAuthenticated: () => Promise<void>) {
    try {
      const data = await apiFetch<AccessStatus>('/api/access/status', {}, 'checking access');
      if (data.authenticated) {
        applyStatus(data, false);
        await onAuthenticated();
        return;
      }
      applyStatus(data, true);
    } catch (error) {
      setGateVisible(true, error instanceof Error ? error.message : get(t).messages.accessCheckFailed);
    }
  }

  async function submitCredentials(
    path: string,
    username: string,
    password: string,
    onAuthenticated: () => Promise<void>,
    fallbackError: string
  ) {
    update((state) => ({ ...state, loading: true, error: '' }));
    try {
      const data = await apiFetch<AccessStatus>(
        path,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username, password })
        },
        'authenticating'
      );
      if (!data.authenticated) throw new Error(fallbackError);
      applyStatus(data, false);
      await onAuthenticated();
    } catch (error) {
      update((state) => ({
        ...state,
        error: error instanceof Error ? error.message : fallbackError
      }));
    } finally {
      update((state) => ({ ...state, loading: false }));
    }
  }

  function register(username: string, password: string, onAuthenticated: () => Promise<void>) {
    return submitCredentials('/api/access/register', username, password, onAuthenticated, get(t).messages.accessFailed);
  }

  function login(username: string, password: string, onAuthenticated: () => Promise<void>) {
    return submitCredentials('/api/access/login', username, password, onAuthenticated, get(t).messages.invalidAccessKey);
  }

  async function logout() {
    try {
      await apiFetch<AccessStatus>('/api/access/logout', { method: 'POST' }, 'signing out');
    } catch {
      // ignore network errors; clear local state regardless
    }
    update((state) => ({ ...state, authenticated: false, gateVisible: true, username: '' }));
  }

  function installUnauthorizedHandler() {
    setUnauthorizedHandler((message) => {
      setGateVisible(true, message || '');
    });
  }

  return {
    subscribe,
    set,
    checkAccess,
    register,
    login,
    logout,
    installUnauthorizedHandler
  };
}

export const accessStore = createAccessStore();
