/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_BASE_SEPOLIA_RPC_URL?: string;
  readonly VITE_LASNA_RPC_URL?: string;
  readonly VITE_UNICHAIN_SEPOLIA_RPC_URL?: string;
  readonly VITE_ORIGIN_VAULT?: string;
  readonly VITE_GUARD_ADDRESS?: string;
  readonly VITE_BREAKER_ADDRESS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface Window {
  ethereum?: {
    request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
    on?: (event: string, handler: (...args: unknown[]) => void) => void;
    removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
  };
}
