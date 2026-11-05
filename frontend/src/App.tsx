import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createPublicClient,
  formatEther,
  formatUnits,
  http,
  type Address,
  type PublicClient,
} from "viem";

type ChainKey = "base" | "lasna" | "unichain";

type ChainConfig = {
  key: ChainKey;
  name: string;
  label: string;
  chainId: number;
  rpcUrl: string;
  explorer: string;
  accent: string;
};

type DashboardData = {
  vault: {
    health: bigint;
    threshold: bigint;
    reserves: bigint;
    liabilities: bigint;
    breached: boolean;
  };
  guard: {
    active: boolean;
    threshold: bigint;
    breachCount: bigint;
    lastOriginBlock: bigint;
    recipient: Address;
  };
  breaker: {
    paused: boolean;
    ltv: bigint;
    frozenLtv: bigint;
    breachCount: bigint;
    pausedAt: bigint;
    lastBreachId: string;
  };
  blocks: Record<ChainKey, bigint>;
  fetchedAt: Date;
};

const addresses = {
  vault: (import.meta.env.VITE_ORIGIN_VAULT ?? "") as Address,
  guard: (import.meta.env.VITE_GUARD_ADDRESS ?? "") as Address,
  breaker: (import.meta.env.VITE_BREAKER_ADDRESS ?? "") as Address,
};

const chains: ChainConfig[] = [
  {
    key: "base",
    name: "Base Sepolia",
    label: "ORIGIN",
    chainId: 84532,
    rpcUrl: import.meta.env.VITE_BASE_SEPOLIA_RPC_URL ?? "https://sepolia.base.org",
    explorer: "https://sepolia.basescan.org",
    accent: "#48d6a5",
  },
  {
    key: "lasna",
    name: "Reactive Lasna",
    label: "REACTIVE",
    chainId: 5318007,
    rpcUrl: import.meta.env.VITE_LASNA_RPC_URL ?? "https://lasna-rpc.rnk.dev/",
    explorer: "https://lasna.reactscan.net",
    accent: "#9b8cff",
  },
  {
    key: "unichain",
    name: "Unichain Sepolia",
    label: "DESTINATION",
    chainId: 1301,
    rpcUrl: import.meta.env.VITE_UNICHAIN_SEPOLIA_RPC_URL ?? "https://sepolia.unichain.org",
    explorer: "https://sepolia.uniscan.xyz",
    accent: "#ffb454",
  },
];

const vaultAbi = [
  { name: "healthBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "minCoverageBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "reserves", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalDeposits", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "breached", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

const guardAbi = [
  { name: "active", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "breachThresholdBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "breachCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "lastOriginBlock", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "callbackRecipient", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

const breakerAbi = [
  { name: "paused", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "ltvBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "frozenLtvBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "breachCount", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "pausedAt", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "lastBreachId", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
] as const;

const clients = Object.fromEntries(
  chains.map((chain) => [
    chain.key,
    createPublicClient({ transport: http(chain.rpcUrl) }),
  ]),
) as Record<ChainKey, PublicClient>;

const shortAddress = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const shortHash = (value: string) => `${value.slice(0, 10)}…${value.slice(-8)}`;
const percentage = (value: bigint) => `${Number(value) / 100}%`;
const formatNumber = (value: bigint) => new Intl.NumberFormat("en-US").format(Number(value));
const formatDate = (value: bigint) =>
  value === 0n ? "—" : new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(Number(value) * 1000);
const explorerAddress = (chain: ChainConfig, address: string) => `${chain.explorer}/address/${address}`;

async function readDashboard(): Promise<DashboardData> {
  const vaultReads = ["healthBps", "minCoverageBps", "reserves", "totalDeposits", "breached"] as const;
  const guardReads = ["active", "breachThresholdBps", "breachCount", "lastOriginBlock", "callbackRecipient"] as const;
  const breakerReads = ["paused", "ltvBps", "frozenLtvBps", "breachCount", "pausedAt", "lastBreachId"] as const;
  const [health, threshold, reserves, liabilities, breached] = await Promise.all(
    vaultReads.map((functionName) =>
      clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName }),
    ),
  ) as [bigint, bigint, bigint, bigint, boolean];
  const [active, guardThreshold, guardCount, lastOriginBlock, recipient] = await Promise.all(
    guardReads.map((functionName) =>
      clients.lasna.readContract({ address: addresses.guard, abi: guardAbi, functionName }),
    ),
  ) as [boolean, bigint, bigint, bigint, Address];
  const [paused, ltv, frozenLtv, breakerCount, pausedAt, lastBreachId] = await Promise.all(
    breakerReads.map((functionName) =>
      clients.unichain.readContract({ address: addresses.breaker, abi: breakerAbi, functionName }),
    ),
  ) as [boolean, bigint, bigint, bigint, bigint, string];
  const blocks = await Promise.all(chains.map(async (chain) => [chain.key, await clients[chain.key].getBlockNumber()] as const));
  return {
    vault: { health, threshold, reserves, liabilities, breached },
    guard: { active, threshold: guardThreshold, breachCount: guardCount, lastOriginBlock, recipient },
    breaker: { paused, ltv, frozenLtv, breachCount: breakerCount, pausedAt, lastBreachId },
    blocks: Object.fromEntries(blocks) as Record<ChainKey, bigint>,
    fetchedAt: new Date(),
  };
}

function Icon({ name }: { name: "shield" | "activity" | "arrow" | "external" | "refresh" | "lock" }) {
  const paths = {
    shield: <><path d="M12 3 4.7 6.1v5.1c0 4.5 3 7.3 7.3 8.8 4.3-1.5 7.3-4.3 7.3-8.8V6.1L12 3Z" /><path d="m8.6 12 2.2 2.2 4.7-5" /></>,
    activity: <><path d="M3 12h4l2.2-6 4.1 12 2.2-6H21" /></>,
    arrow: <><path d="M5 12h13" /><path d="m13 6 6 6-6 6" /></>,
    external: <><path d="M14 5h5v5" /><path d="m19 5-8 8" /><path d="M19 13v5H6V6h5" /></>,
    refresh: <><path d="M20 11a8 8 0 0 0-14.9-3L3 11" /><path d="M3 5v6h6" /><path d="M4 13a8 8 0 0 0 14.9 3L21 13" /><path d="M21 19v-6h-6" /></>,
    lock: <><rect x="5" y="10" width="14" height="10" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3" /></>,
  };
  return <svg viewBox="0 0 24 24" aria-hidden="true">{paths[name]}</svg>;
}

function App() {
  const [data, setData] = useState<DashboardData>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setData(await readDashboard());
      setError("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to read the live protocol state.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 15_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const healthRatio = data ? Math.min(Number(data.vault.health) / Number(data.vault.threshold), 1) : 0;
  const incident = data?.breaker.paused ?? false;
  const timeline = useMemo(() => [
    { label: "Origin vault", detail: data?.vault.breached ? "Invariant breached" : "Coverage healthy", state: data?.vault.breached ? "danger" : "good", chain: chains[0] },
    { label: "Reactive guard", detail: data?.guard.active ? `${formatNumber(data.guard.breachCount)} callbacks confirmed` : "Guard inactive", state: data?.guard.active ? "good" : "muted", chain: chains[1] },
    { label: "Circuit breaker", detail: incident ? "Destination protocol paused" : "Protocol operational", state: incident ? "danger" : "good", chain: chains[2] },
  ], [data, incident]);

  return (
    <main className="app-shell">
      <div className="ambient ambient-one" />
      <div className="ambient ambient-two" />
      <nav className="topbar">
        <div className="brand"><span className="brand-mark"><Icon name="shield" /></span><span>AEGIS<span className="brand-dot">.</span></span><small>COMMAND CENTER</small></div>
        <div className="topbar-actions"><span className="live-pill"><i /> LIVE MONITORING</span><button className="refresh-button" onClick={() => void refresh()} disabled={loading}><Icon name="refresh" /> {loading ? "SYNCING" : "REFRESH"}</button></div>
      </nav>

      <section className="hero">
        <div>
          <p className="eyebrow"><span className="eyebrow-line" /> CROSS-CHAIN INVARIANT GUARD</p>
          <h1>Solvency, <em>watched.</em><br />Incidents, contained.</h1>
          <p className="hero-copy">Aegis observes the origin vault, independently verifies coverage, and trips the destination circuit breaker without a keeper or off-chain oracle.</p>
        </div>
        <div className={`incident-card ${incident ? "incident-active" : "incident-clear"}`}>
          <div className="incident-icon"><Icon name={incident ? "lock" : "shield"} /></div>
          <div><span className="card-kicker">{incident ? "ACTIVE INCIDENT" : "SYSTEM NOMINAL"}</span><strong>{incident ? "Destination paused" : "All systems operational"}</strong><small>{incident ? "Human review required before recovery" : "Coverage is within configured limits"}</small></div>
          <span className="incident-dot" />
        </div>
      </section>

      {error && <div className="error-banner">Live read failed: {error}</div>}

      <section className="metrics-grid">
        <article className="metric-card primary-metric">
          <div className="metric-heading"><span>ORIGIN COVERAGE</span><Icon name="activity" /></div>
          <div className="metric-value">{data ? percentage(data.vault.health) : "—"}</div>
          <div className="meter"><span style={{ width: `${healthRatio * 100}%` }} /></div>
          <div className="metric-foot"><span>Current health ratio</span><b>Threshold {data ? percentage(data.vault.threshold) : "—"}</b></div>
        </article>
        <article className="metric-card">
          <div className="metric-heading"><span>RESERVES</span><span className="metric-status good">● LIVE</span></div>
          <div className="metric-value compact">{data ? `${formatEther(data.vault.reserves)} ETH` : "—"}</div>
          <div className="metric-foot"><span>Origin vault liquidity</span><b>{data ? formatNumber(data.vault.liabilities) : "—"} wei liabilities</b></div>
        </article>
        <article className={`metric-card ${incident ? "warning-card" : ""}`}>
          <div className="metric-heading"><span>BREACHES CONFIRMED</span><span className="metric-status purple">GUARD</span></div>
          <div className="metric-value compact">{data ? formatNumber(data.guard.breachCount) : "—"}</div>
          <div className="metric-foot"><span>Deduplicated callbacks</span><b>{data ? `Block ${formatNumber(data.guard.lastOriginBlock)}` : "—"}</b></div>
        </article>
        <article className={`metric-card ${incident ? "danger-card" : ""}`}>
          <div className="metric-heading"><span>BREAKER STATE</span><Icon name="lock" /></div>
          <div className="metric-value compact">{data ? (data.breaker.paused ? "PAUSED" : "OPEN") : "—"}</div>
          <div className="metric-foot"><span>Unichain Sepolia</span><b>{data ? `${percentage(data.breaker.ltv)} LTV` : "—"}</b></div>
        </article>
      </section>

      <section className="content-grid">
        <article className="panel flow-panel">
          <div className="panel-header"><div><p className="eyebrow">REACTION PIPELINE</p><h2>Breach to break</h2></div><span className="latency"><strong>~3s</strong> reaction time</span></div>
          <div className="flow-list">
            {timeline.map((item, index) => <div className="flow-row" key={item.label}><div className={`flow-node ${item.state}`}><Icon name={index === 2 ? "lock" : index === 1 ? "activity" : "shield"} /></div><div className="flow-copy"><div><strong>{item.label}</strong><span className="chain-tag" style={{ color: item.chain.accent }}>{item.chain.label}</span></div><p>{item.detail}</p></div>{index < timeline.length - 1 && <div className="flow-arrow"><Icon name="arrow" /></div>}</div>)}
          </div>
          <div className="flow-footer"><span><i className="legend-dot green" /> Event observed</span><span><i className="legend-dot purple-dot" /> Guard verified</span><span><i className="legend-dot orange" /> Action executed</span></div>
        </article>

        <article className="panel state-panel">
          <div className="panel-header"><div><p className="eyebrow">DESTINATION CONTROL</p><h2>Breaker snapshot</h2></div><span className={`state-badge ${incident ? "paused" : "open"}`}>{incident ? "● PAUSED" : "● OPEN"}</span></div>
          <div className="snapshot-grid"><div><span>Frozen LTV</span><strong>{data ? percentage(data.breaker.frozenLtv) : "—"}</strong></div><div><span>Incidents</span><strong>{data ? formatNumber(data.breaker.breachCount) : "—"}</strong></div><div><span>Paused since</span><strong>{data ? formatDate(data.breaker.pausedAt) : "—"}</strong></div><div><span>Last breach</span><strong className="mono">{data ? shortHash(data.breaker.lastBreachId) : "—"}</strong></div></div>
          <div className="protection-note"><Icon name="shield" /><div><strong>{incident ? "Protection is holding" : "Protection is armed"}</strong><p>{incident ? "All destination-side credit and redemption paths are frozen until an owner reviews the incident." : "The breaker is ready to contain a verified breach."}</p></div></div>
        </article>
      </section>

      <section className="network-section"><div className="section-heading"><div><p className="eyebrow">NETWORKS</p><h2>Three chains. One invariant.</h2></div><span className="last-updated">{data ? `Last synced ${data.fetchedAt.toLocaleTimeString()}` : "Connecting…"}</span></div><div className="network-grid">{chains.map((chain) => <a className="network-card" href={explorerAddress(chain, chain.key === "base" ? addresses.vault : chain.key === "lasna" ? addresses.guard : addresses.breaker)} target="_blank" rel="noreferrer" key={chain.key}><div className="network-top"><span className="network-pulse" style={{ background: chain.accent, boxShadow: `0 0 12px ${chain.accent}` }} /><span>{chain.label}</span><Icon name="external" /></div><strong>{chain.name}</strong><div className="network-bottom"><span>Chain ID <b>{chain.chainId.toLocaleString()}</b></span><span>Block <b>{data ? formatNumber(data.blocks[chain.key]) : "—"}</b></span></div></a>)}</div></section>

      <footer><span><span className="brand-dot">✦</span> AEGIS REACTIVE</span><span>READ-ONLY OBSERVER · NO KEEPER REQUIRED</span></footer>
    </main>
  );
}

export default App;
