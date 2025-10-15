// Minimalny wrapper dla Etherscan V2. Wymaga Node 18+ (globalny fetch).
const BASE = "https://api.etherscan.io/v2/api";

function toQuery(params = {}) {
  return Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
}

/**
 * callEtherscanV2({ chainid, module, action, params })
 * @param {{ chainid:number, module:string, action:string, params?:Record<string,string|number> }} opts
 */
async function callEtherscanV2({ chainid, module, action, params = {} }) {
  const apikey = process.env.ETHERSCAN_API_KEY;
  if (!apikey) throw new Error("ETHERSCAN_API_KEY is required");

  const qs = toQuery({ ...params, apikey });
  const url = `${BASE}?chainid=${chainid}&module=${encodeURIComponent(module)}&action=${encodeURIComponent(action)}&${qs}`;

  const res = await fetch(url);
  if (!res.ok) throw new Error(`Etherscan V2 HTTP ${res.status}`);
  const json = await res.json();

  // V2 zwykle zwraca { status, message, result } lub samo { result }
  if (json.status && json.status !== "1") {
    throw new Error(`Etherscan V2 error: ${json.message || "unknown"} (status=${json.status})`);
  }
  return json.result ?? json;
}

module.exports = { callEtherscanV2 };