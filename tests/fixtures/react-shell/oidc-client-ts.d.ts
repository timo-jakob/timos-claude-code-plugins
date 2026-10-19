// A type-only stand-in for oidc-client-ts (#1326), so tests/react-shell-templates.bats
// can type-check src/shell/auth.ts with `tsc --noEmit --strict` and no npm install.
// It declares ONLY what auth.ts uses, each signature copied (narrowed, never widened)
// from oidc-client-ts 3.5.0's dist/types/oidc-client-ts.d.ts. The rendered app
// type-checks against the real package; this file only keeps bats install-free.

export interface JwtClaims {
  [claim: string]: unknown;
  iss?: string;
  sub?: string;
  aud?: string | string[];
  exp?: number;
  iat?: number;
}

export interface IdTokenClaims extends JwtClaims {
  sub: string;
  name?: string;
  preferred_username?: string;
}

export type UserProfile = IdTokenClaims;

export declare class User {
  id_token?: string;
  access_token: string;
  refresh_token?: string;
  token_type: string;
  profile: UserProfile;
  expires_at?: number;
  readonly state: unknown;
  get expires_in(): number | undefined;
}

export interface StateStore {
  set(key: string, value: string): Promise<void>;
  get(key: string): Promise<string | null>;
  remove(key: string): Promise<string | null>;
  getAllKeys(): Promise<string[]>;
}

export declare class InMemoryWebStorage implements Storage {
  clear(): void;
  getItem(key: string): string;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
  get length(): number;
  key(index: number): string;
}

export declare class WebStorageStateStore implements StateStore {
  constructor(args?: { prefix?: string; store?: Storage });
  set(key: string, value: string): Promise<void>;
  get(key: string): Promise<string | null>;
  remove(key: string): Promise<string | null>;
  getAllKeys(): Promise<string[]>;
}

export interface NavigateParams {
  url: string;
  nonce?: string;
  state?: string;
}

export interface NavigateResponse {
  url: string;
}

export interface IWindow {
  navigate(params: NavigateParams): Promise<NavigateResponse>;
  close(): void;
}

export interface INavigator {
  prepare(params: unknown): Promise<IWindow>;
  callback(url: string, params?: unknown): Promise<void>;
}

export interface UserManagerSettings {
  authority: string;
  client_id: string;
  redirect_uri: string;
  post_logout_redirect_uri?: string;
  scope?: string;
  response_type?: string;
  redirectTarget?: "top" | "self";
  userStore?: StateStore;
  stateStore?: StateStore;
  automaticSilentRenew?: boolean;
  monitorSession?: boolean;
}

export declare class UserManager {
  constructor(settings: UserManagerSettings, redirectNavigator?: INavigator);
  removeUser(): Promise<void>;
  signinRedirect(args?: { state?: unknown }): Promise<void>;
  signinRedirectCallback(url?: string): Promise<User>;
  signinSilent(): Promise<User | null>;
  signoutRedirect(args?: { id_token_hint?: string }): Promise<void>;
}
