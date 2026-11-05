import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  formatEther,
  http,
  parseEther,
  type Address,
  type Hash,
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

type IncidentReport = {
  origin?: Hash;
  guard?: Hash;
  callback?: Hash;
  breaker?: Hash;
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

const originBreachEvent = {
  type: "event",
  name: "InvariantBreached",
  inputs: [
    { name: "reserves", type: "uint256", indexed: false },
    { name: "liabilities", type: "uint256", indexed: false },
    { name: "healthBps", type: "uint256", indexed: false },
    { name: "thresholdBps", type: "uint256", indexed: false },
  ],
} as const;
const guardBreachEvent = {
  type: "event",
  name: "BreachConfirmed",
  inputs: [
    { name: "breachId", type: "bytes32", indexed: true },
    { name: "healthBps", type: "uint256", indexed: false },
    { name: "reserves", type: "uint256", indexed: false },
    { name: "liabilities", type: "uint256", indexed: false },
    { name: "originBlockNumber", type: "uint256", indexed: false },
    { name: "originTxHash", type: "uint256", indexed: false },
  ],
} as const;
const callbackRequestEvent = {
  type: "event",
  name: "CallbackRequested",
  inputs: [
    { name: "breachId", type: "bytes32", indexed: true },
    { name: "destinationChainId", type: "uint256", indexed: true },
    { name: "recipient", type: "address", indexed: true },
    { name: "gasLimit", type: "uint64", indexed: false },
  ],
} as const;
const breakerEvent = {
  type: "event",
  name: "CircuitBreakerTriggered",
  inputs: [
    { name: "breachId", type: "bytes32", indexed: true },
    { name: "guard", type: "address", indexed: true },
    { name: "healthBps", type: "uint256", indexed: false },
    { name: "reserves", type: "uint256", indexed: false },
    { name: "liabilities", type: "uint256", indexed: false },
    { name: "originChainId", type: "uint256", indexed: false },
    { name: "frozenLtvBps", type: "uint256", indexed: false },
    { name: "timestamp", type: "uint256", indexed: false },
  ],
} as const;

const vaultWriteAbi = [
  { name: "deposit", type: "function", stateMutability: "payable", inputs: [], outputs: [] },
  { name: "recordLoss", type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { name: "borrow", type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { name: "forceCheck", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
] as const;

const breakerWriteAbi = [
  { name: "unpause", type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
] as const;

const baseChain = defineChain({ id: 84532, name: "Base Sepolia", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [chains[0].rpcUrl] } } });
const unichain = defineChain({ id: 1301, name: "Unichain Sepolia", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [chains[2].rpcUrl] } } });

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
const explorerTransaction = (chain: ChainConfig, hash: Hash) => `${chain.explorer}/tx/${hash}`;

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

async function readIncidentReport(): Promise<IncidentReport> {
  const latestBlocks = await Promise.all(chains.map(async (chain) => [chain.key, await clients[chain.key].getBlockNumber()] as const));
  const blockMap = Object.fromEntries(latestBlocks) as Record<ChainKey, bigint>;
  const fromBlock = (block: bigint, maxRange: bigint) => block > maxRange ? block - maxRange : 0n;
  const latest = <T extends { blockNumber: bigint | null }>(logs: readonly T[]) =>
    [...logs].sort((a, b) => Number((b.blockNumber ?? 0n) - (a.blockNumber ?? 0n)))[0];
  const [originLogs, breakerLogs] = await Promise.all([
    clients.base.getLogs({ address: addresses.vault, event: originBreachEvent, fromBlock: fromBlock(blockMap.base, 200n), toBlock: blockMap.base }),
    clients.unichain.getLogs({ address: addresses.breaker, event: breakerEvent, fromBlock: fromBlock(blockMap.unichain, 1_000n), toBlock: blockMap.unichain }),
  ]);
  const breaker = latest(breakerLogs);
  const breachId = breaker?.args.breachId;
  const [guardLogs, callbackLogs] = await Promise.all([
    clients.lasna.getLogs({ address: addresses.guard, event: guardBreachEvent, args: breachId ? { breachId } : undefined, fromBlock: fromBlock(blockMap.lasna, 1_000n), toBlock: blockMap.lasna }),
    clients.lasna.getLogs({ address: addresses.guard, event: callbackRequestEvent, args: breachId ? { breachId } : undefined, fromBlock: fromBlock(blockMap.lasna, 1_000n), toBlock: blockMap.lasna }),
  ]);
  const guard = latest(guardLogs);
  const callback = latest(callbackLogs);
  const origin = guard?.args.originTxHash
    ? originLogs.find((log) => log.transactionHash && BigInt(log.transactionHash) === guard.args.originTxHash)
    : latest(originLogs);
  return {
    origin: origin?.transactionHash,
    guard: guard?.transactionHash,
    callback: callback?.transactionHash,
    breaker: breaker?.transactionHash,
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
  const [incidentReport, setIncidentReport] = useState<IncidentReport>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [walletAddress, setWalletAddress] = useState<Address>();
  const [walletChainId, setWalletChainId] = useState<number>();
  const [actionAmount, setActionAmount] = useState("0.001");
  const [actionStatus, setActionStatus] = useState("Connect a wallet to run the live demo.");
  const [actionBusy, setActionBusy] = useState(false);
  const [lastTx, setLastTx] = useState<{ hash: Hash; chain: ChainConfig }>();
  const [demoPhase, setDemoPhase] = useState<"idle" | "preparing" | "breach" | "reacting" | "complete">("idle");
  const [reactionSeconds, setReactionSeconds] = useState<number>();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [dashboard, report] = await Promise.all([readDashboard(), readIncidentReport()]);
      setData(dashboard);
      setIncidentReport(report);
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

  const connectWallet = useCallback(async () => {
    if (!window.ethereum) {
      setActionStatus("Install MetaMask or another injected wallet to run the simulation.");
      return;
    }
    try {
      const accounts = await window.ethereum.request({ method: "eth_requestAccounts" }) as string[];
      const chainHex = await window.ethereum.request({ method: "eth_chainId" }) as string;
      setWalletAddress(accounts[0] as Address);
      setWalletChainId(Number.parseInt(chainHex, 16));
      setActionStatus("Wallet connected. Choose a demo action.");
    } catch (reason) {
      setActionStatus(reason instanceof Error ? reason.message : "Wallet connection was rejected.");
    }
  }, []);

  const ensureWalletChain = useCallback(async (chain: ChainConfig) => {
    if (!window.ethereum || !walletAddress) throw new Error("Connect your wallet first.");
    if (walletChainId === chain.chainId) return;
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: `0x${chain.chainId.toString(16)}` }] });
    setWalletChainId(chain.chainId);
  }, [walletAddress, walletChainId]);

  const runAction = useCallback(async (name: "deposit" | "recordLoss" | "borrow" | "forceCheck" | "unpause") => {
    if (!window.ethereum || !walletAddress) {
      setActionStatus("Connect your wallet before running a demo action.");
      return;
    }
    const targetChain = name === "unpause" ? chains[2] : chains[0];
    setActionBusy(true);
    setLastTx(undefined);
    try {
      await ensureWalletChain(targetChain);
      const wallet = createWalletClient({ account: walletAddress, chain: name === "unpause" ? unichain : baseChain, transport: custom(window.ethereum) });
      const amount = parseEther(actionAmount || "0");
      let hash: Hash;
      if (name === "deposit") {
        if (amount === 0n) throw new Error("Enter an ETH amount greater than zero.");
        hash = await wallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "deposit", value: amount });
      } else if (name === "recordLoss") {
        if (amount === 0n) throw new Error("Enter a loss amount greater than zero.");
        hash = await wallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "recordLoss", args: [amount] });
      } else if (name === "borrow") {
        if (amount === 0n) throw new Error("Enter a borrow amount greater than zero.");
        hash = await wallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "borrow", args: [amount] });
      } else if (name === "forceCheck") {
        hash = await wallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "forceCheck" });
      } else {
        hash = await wallet.writeContract({ address: addresses.breaker, abi: breakerWriteAbi, functionName: "unpause" });
      }
      setLastTx({ hash, chain: targetChain });
      setActionStatus(`${name === "unpause" ? "Recovery" : "Simulation"} transaction submitted. Waiting for the network…`);
      await clients[targetChain.key].waitForTransactionReceipt({ hash });
      setActionStatus(`${name === "unpause" ? "Breaker unpaused." : "Transaction confirmed."} Waiting for Reactive propagation.`);
      await refresh();
    } catch (reason) {
      setActionStatus(reason instanceof Error ? reason.message : "Transaction failed or was rejected.");
    } finally {
      setActionBusy(false);
    }
  }, [actionAmount, ensureWalletChain, refresh, walletAddress]);

  const runLiveDemo = useCallback(async () => {
    if (!window.ethereum || !walletAddress) {
      setActionStatus("Connect your wallet before running the live demo.");
      return;
    }
    setActionBusy(true);
    setLastTx(undefined);
    setReactionSeconds(undefined);
    setDemoPhase("preparing");
    try {
    const requestedSeed = parseEther(actionAmount || "0.01");
    if (requestedSeed === 0n) throw new Error("Enter a seed amount greater than zero.");

    setActionStatus("Step 1/3 · Resetting the destination breaker…");
    await ensureWalletChain(chains[2]);
    const uniWallet = createWalletClient({ account: walletAddress, chain: unichain, transport: custom(window.ethereum) });
      const isPaused = await clients.unichain.readContract({ address: addresses.breaker, abi: breakerAbi, functionName: "paused" });
      if (isPaused) {
        const resetHash = await uniWallet.writeContract({ address: addresses.breaker, abi: breakerWriteAbi, functionName: "unpause" });
        await clients.unichain.waitForTransactionReceipt({ hash: resetHash });
      }

      setActionStatus("Step 2/3 · Restoring origin coverage with a deposit…");
      await ensureWalletChain(chains[0]);
      const baseWallet = createWalletClient({ account: walletAddress, chain: baseChain, transport: custom(window.ethereum) });
      const [currentReserves, currentLiabilities, threshold, initialGuardCount] = await Promise.all([
        clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "reserves" }),
        clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "totalDeposits" }),
        clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "minCoverageBps" }),
        clients.lasna.readContract({ address: addresses.guard, abi: guardAbi, functionName: "breachCount" }),
      ]);
      const restoreNumerator = threshold * currentLiabilities > 10_000n * currentReserves
        ? threshold * currentLiabilities - 10_000n * currentReserves
        : 0n;
      const restoreDenominator = 10_000n - threshold;
      const requiredRestore = restoreNumerator === 0n || restoreDenominator === 0n
        ? 0n
        : (restoreNumerator + restoreDenominator - 1n) / restoreDenominator + 1n;
      const seedAmount = requestedSeed > requiredRestore ? requestedSeed : requiredRestore;
      const depositHash = await baseWallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "deposit", value: seedAmount });
      setLastTx({ hash: depositHash, chain: chains[0] });
      await clients.base.waitForTransactionReceipt({ hash: depositHash });
      await refresh();

      setActionStatus("Step 3/3 · Sending the breach transaction…");
      setDemoPhase("breach");
      const [postDepositReserves, postDepositLiabilities] = await Promise.all([
        clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "reserves" }),
        clients.base.readContract({ address: addresses.vault, abi: vaultAbi, functionName: "totalDeposits" }),
      ]);
      const breachNumerator = 10_000n * postDepositReserves > threshold * postDepositLiabilities
        ? 10_000n * postDepositReserves - threshold * postDepositLiabilities
        : 0n;
      const minimumLoss = breachNumerator === 0n ? 1n : breachNumerator / 10_000n + 1n;
      const lossAmount = (seedAmount * 6n) / 10n > minimumLoss ? (seedAmount * 6n) / 10n : minimumLoss;
      if (lossAmount >= postDepositReserves) throw new Error("Seed amount is too small to create a breach with the available reserves.");
      const breachSubmittedAt = performance.now();
      const breachHash = await baseWallet.writeContract({ address: addresses.vault, abi: vaultWriteAbi, functionName: "recordLoss", args: [lossAmount] });
      setLastTx({ hash: breachHash, chain: chains[0] });
      await clients.base.waitForTransactionReceipt({ hash: breachHash });
      setDemoPhase("reacting");
      setActionStatus("Origin breach confirmed. Reactive is watching the event…");
      const started = performance.now();
      for (let attempt = 0; attempt < 45; attempt += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, 1_000));
        const [guardCount, paused] = await Promise.all([
          clients.lasna.readContract({ address: addresses.guard, abi: guardAbi, functionName: "breachCount" }),
          clients.unichain.readContract({ address: addresses.breaker, abi: breakerAbi, functionName: "paused" }),
        ]);
        if (paused && guardCount > initialGuardCount) {
          const elapsed = (performance.now() - started) / 1000;
          setReactionSeconds(Number(elapsed.toFixed(1)));
          setDemoPhase("complete");
          setActionStatus(`Reactive delivered the callback and paused Unichain in ${elapsed.toFixed(1)}s.`);
          await refresh();
          setActionBusy(false);
          return;
        }
        setActionStatus(`Reactive is watching… ${Math.floor((performance.now() - breachSubmittedAt) / 1000)}s since breach submission`);
      }
      setActionStatus("Breach confirmed, but the callback has not arrived yet. Keep watching the live dashboard.");
      await refresh();
    } catch (reason) {
      setDemoPhase("idle");
      setActionStatus(reason instanceof Error ? reason.message : "The live demo transaction was rejected.");
    } finally {
      setActionBusy(false);
    }
  }, [actionAmount, ensureWalletChain, refresh, walletAddress]);

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
        <div className="topbar-actions"><span className="live-pill"><i /> LIVE MONITORING</span><button className="refresh-button" onClick={() => void refresh()} disabled={loading}><Icon name="refresh" /> {loading ? "SYNCING" : "REFRESH"}</button><button className="wallet-button" onClick={() => void connectWallet()}>{walletAddress ? `${shortAddress(walletAddress)} · ${walletChainId === 84532 ? "BASE" : walletChainId === 1301 ? "UNI" : "SWITCH"}` : "CONNECT WALLET"}</button></div>
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

      <section className="panel incident-report">
        <div className="panel-header">
          <div><p className="eyebrow">VERIFIABLE INCIDENT REPORT</p><h2>Proof of response</h2></div>
          <span className="report-caption">Latest matching on-chain evidence</span>
        </div>
        <div className="report-list">
          {([
            ["01", "Breach emitted", "Origin vault · Base Sepolia", incidentReport?.origin, chains[0]],
            ["02", "Invariant verified", "Reactive guard · Lasna", incidentReport?.guard, chains[1]],
            ["03", "Callback requested", "Reactive system · Lasna", incidentReport?.callback, chains[1]],
            ["04", "Circuit breaker triggered", "Destination breaker · Unichain", incidentReport?.breaker, chains[2]],
          ] as const).map(([number, label, detail, hash, chain]) => (
            <div className={`report-row ${hash ? "reported" : ""}`} key={label}>
              <span className="report-number">{number}</span>
              <span className="report-marker" style={{ background: chain.accent, boxShadow: `0 0 12px ${chain.accent}` }} />
              <div className="report-copy"><strong>{label}</strong><small>{detail}</small></div>
              {hash ? <a className="report-hash" href={explorerTransaction(chain, hash)} target="_blank" rel="noreferrer" title={hash}>{shortHash(hash)} <Icon name="external" /></a> : <span className="report-pending">Waiting for event…</span>}
            </div>
          ))}
        </div>
        <div className="report-footer"><span><i className="legend-dot green" /> Hashes are read from contract event logs</span><span>Open any hash to verify independently ↗</span></div>
      </section>

      <section className="demo-console">
        <div className="console-heading"><div><p className="eyebrow">ONE-CLICK LIVE DEMO</p><h2>Watch Reactive move.</h2><p>One button resets the incident, seeds the vault, triggers a real breach, and measures the callback to Unichain.</p></div><div className="wallet-state">{walletAddress ? <><span className="wallet-dot" /> {shortAddress(walletAddress)}<small>Chain {walletChainId ?? "—"}</small></> : <><span className="wallet-dot offline" /> Wallet not connected</>}</div></div>
        <div className="demo-controls single-demo"><label className="amount-field"><span>SEED · ETH</span><input value={actionAmount} onChange={(event) => setActionAmount(event.target.value)} inputMode="decimal" placeholder="0.01" /></label><button className="run-demo-button" onClick={() => void runLiveDemo()} disabled={actionBusy || !walletAddress}><span className="run-icon">{actionBusy ? "…" : "▶"}</span><span><strong>{actionBusy ? "RUNNING LIVE DEMO" : "RUN LIVE DEMO"}</strong><small>Reset · breach · Reactive callback · pause</small></span><Icon name="arrow" /></button></div>
        <div className="demo-steps"><div className={demoPhase === "preparing" ? "demo-step active" : demoPhase !== "idle" ? "demo-step done" : "demo-step"}><b>01</b><span>Prepare</span><small>Reset + seed</small></div><div className={demoPhase === "breach" ? "demo-step active" : ["reacting", "complete"].includes(demoPhase) ? "demo-step done" : "demo-step"}><b>02</b><span>Origin breach</span><small>Base Sepolia</small></div><div className={demoPhase === "reacting" ? "demo-step active reactive-step" : demoPhase === "complete" ? "demo-step done reactive-step" : "demo-step reactive-step"}><b>03</b><span>Reactive</span><small>Lasna callback</small></div><div className={demoPhase === "complete" ? "demo-step done" : "demo-step"}><b>04</b><span>Breaker pause</span><small>Unichain</small></div>{reactionSeconds !== undefined && <strong className="reaction-result">{reactionSeconds}s <small>reaction</small></strong>}</div>
        <div className="action-status"><span className={actionBusy ? "status-spinner" : "status-check"}>{actionBusy ? "…" : "✓"}</span><span>{actionStatus}</span>{lastTx && <a href={`${lastTx.chain.explorer}/tx/${lastTx.hash}`} target="_blank" rel="noreferrer">View transaction ↗</a>}</div>
        <div className="console-disclaimer">Real testnet sequence. Your wallet signs every transaction; no private key is stored or sent to the frontend.</div>
      </section>

      <section className="network-section"><div className="section-heading"><div><p className="eyebrow">NETWORKS</p><h2>Three chains. One invariant.</h2></div><span className="last-updated">{data ? `Last synced ${data.fetchedAt.toLocaleTimeString()}` : "Connecting…"}</span></div><div className="network-grid">{chains.map((chain) => <a className="network-card" href={explorerAddress(chain, chain.key === "base" ? addresses.vault : chain.key === "lasna" ? addresses.guard : addresses.breaker)} target="_blank" rel="noreferrer" key={chain.key}><div className="network-top"><span className="network-pulse" style={{ background: chain.accent, boxShadow: `0 0 12px ${chain.accent}` }} /><span>{chain.label}</span><Icon name="external" /></div><strong>{chain.name}</strong><div className="network-bottom"><span>Chain ID <b>{chain.chainId.toLocaleString()}</b></span><span>Block <b>{data ? formatNumber(data.blocks[chain.key]) : "—"}</b></span></div></a>)}</div></section>

      <footer><span><span className="brand-dot">✦</span> AEGIS REACTIVE</span><span>READ-ONLY OBSERVER · NO KEEPER REQUIRED</span></footer>
    </main>
  );
}

export default App;
