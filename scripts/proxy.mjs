// Honour HTTPS_PROXY when running behind a proxy (local dev); a no-op on GitHub Actions.
if (process.env.HTTPS_PROXY || process.env.https_proxy) {
  try { const { setGlobalDispatcher, EnvHttpProxyAgent } = await import('undici'); setGlobalDispatcher(new EnvHttpProxyAgent()); } catch { /* undici not installed */ }
}
