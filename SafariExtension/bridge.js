const kadrajOrigin = "http://127.0.0.1/*";
const kadrajEndpoint = "http://127.0.0.1:49196/kadraj";
const kadrajConnect = new URL("/connect", kadrajEndpoint);

async function callKadraj(token, request) {
  if (!/^[a-f0-9]{32}$/.test(token ?? "")) {
    return {ok: false, needsPairing: true, reason: "format"};
  }
  return await postKadraj({...request, token});
}

async function postKadraj(request) {
  try {
    const frames = request.operation === "frame" || request.operation === "frameWait";
    const endpoint = frames ? new URL("/frames", kadrajEndpoint) : kadrajEndpoint;
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {"Content-Type": "text/plain;charset=UTF-8"},
      body: JSON.stringify(request),
      credentials: "omit",
      redirect: "error",
      signal: AbortSignal.timeout(3500),
    });
    if (response.status === 403) return {ok: false, reason: "code"};
    if (response.status === 409 && frames) {
      const status = await response.json().catch(() => null);
      return {ok: false, streaming: false, dismissed: status?.dismissed ?? true};
    }
    if (!response.ok) return {ok: false, reason: "server"};
    return await response.json();
  } catch {
    return {ok: false, reason: "network"};
  }
}
