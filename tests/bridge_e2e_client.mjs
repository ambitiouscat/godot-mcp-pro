import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { createRequire } from "node:module";

const [serverBuild, projectPath] = process.argv.slice(2);
if (!serverBuild || !projectPath) {
  throw new Error("Usage: node bridge_e2e_client.mjs <server-build-directory> <project-path>");
}

const moduleUrl = pathToFileURL(resolve(serverBuild, "godot-connection.js")).href;
const { GodotConnection } = await import(moduleUrl);
const protocolUrl = pathToFileURL(resolve(serverBuild, "bridge-protocol.js")).href;
const sessionUrl = pathToFileURL(resolve(serverBuild, "bridge-session.js")).href;
const identityUrl = pathToFileURL(resolve(serverBuild, "process-identity.js")).href;
const { createProof, proofMatches } = await import(protocolUrl);
const { DiscoveryPublisher, loadBridgeSession, sessionIsCurrent } = await import(sessionUrl);
const { systemProcessIdentity } = await import(identityUrl);
const requireFromServer = createRequire(resolve(serverBuild, "bridge-e2e-loader.cjs"));
const { WebSocketServer } = requireFromServer("ws");

async function runValidAgent(label) {
  const sessionSnapshot = loadBridgeSession(projectPath);
  if (!sessionIsCurrent(sessionSnapshot)) {
    throw new Error(`${label} session snapshot is not current before listener startup`);
  }
  let reportedSessionChange = false;
  const sessionMonitor = setInterval(() => {
    if (reportedSessionChange || sessionIsCurrent(sessionSnapshot)) return;
    reportedSessionChange = true;
    try {
      const current = loadBridgeSession(projectPath);
      console.error(`SESSION_FINGERPRINT_CHANGED ${label} expected=${sessionSnapshot.fingerprint} current=${current.fingerprint}`);
    } catch (error) {
      console.error(`SESSION_CONTRACT_UNAVAILABLE ${label} ${error instanceof Error ? error.message : String(error)}`);
    }
  }, 500);
  const connection = new GodotConnection(undefined, undefined, {
    projectPath,
    managedParent: false,
  });
  try {
    await connection.connect();
    await connection.waitUntilReady(20_000);
    const result = await connection.sendCommand("get_project_info", {}, 15_000);
    if (result === null || typeof result !== "object") {
      throw new Error(`Unexpected ${label} get_project_info result: ${JSON.stringify(result)}`);
    }
    console.log(`BRIDGE_E2E_${label}_OK ${JSON.stringify(result)}`);
  } finally {
    clearInterval(sessionMonitor);
    await connection.disconnect();
  }
}

async function listen(server) {
  await new Promise((resolveListening, reject) => {
    server.once("listening", resolveListening);
    server.once("error", reject);
  });
}

async function closeServer(server) {
  await new Promise((resolveClose) => server.close(() => resolveClose()));
}

async function runAdversarialAgent() {
  const session = loadBridgeSession(projectPath);
  const owner = systemProcessIdentity.get(process.pid);
  if (!owner) throw new Error("Could not establish the adversarial test server process identity");
  const publisher = new DiscoveryPublisher(
    session.discoveryPath,
    session.projectPath,
    owner,
    null,
    session.ownerNonce,
    systemProcessIdentity,
  );
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
  await listen(server);
  const address = server.address();
  if (!address || typeof address === "string" || address.address !== "127.0.0.1") {
    throw new Error(`Adversarial server did not bind loopback: ${JSON.stringify(address)}`);
  }
  const endpoint = `ws://127.0.0.1:${address.port}`;
  let refresh = null;
  try {
  let attempt = 0;
  let firstClientNonce = "";
  let firstServerNonce = "";
  let firstServerProof = "";
  let firstClientProofVerified = false;
  let preReadyVerified = false;

  const scenario = new Promise((resolveScenario, rejectScenario) => {
      const timer = setTimeout(() => rejectScenario(new Error(
        `Timed out in adversarial cross-language scenario at attempt ${attempt}`,
      )), 40_000);
      const fail = (error) => {
        clearTimeout(timer);
        rejectScenario(error instanceof Error ? error : new Error(String(error)));
      };

      server.on("connection", (socket) => {
        const currentAttempt = ++attempt;
        if (currentAttempt > 2) {
          socket.terminate();
          fail(new Error("Godot made more adversarial reconnect attempts than expected"));
          return;
        }
        let handshakeId = "";
        let clientNonce = "";
        let authenticateSeen = false;

        socket.on("message", (raw) => {
          let message;
          try { message = JSON.parse(raw.toString()); }
          catch (error) { fail(new Error(`Godot sent malformed JSON: ${error}`)); return; }

          if (message.id === "pre-ready-probe") {
            if (message.error?.code !== -32000) {
              fail(new Error(`Expected -32000 before READY, received ${JSON.stringify(message)}`));
              return;
            }
            preReadyVerified = true;
            firstServerNonce = Buffer.alloc(16, 55).toString("base64url");
            firstServerProof = createProof(
              session.token,
              "server",
              session.projectPath,
              session.ownerNonce,
              firstClientNonce,
              firstServerNonce,
            );
            socket.send(JSON.stringify({ jsonrpc: "2.0", id: handshakeId, result: {
              server_nonce: firstServerNonce,
              server_proof: firstServerProof,
            } }));
            return;
          }

          if (message.method === "bridge.handshake") {
            handshakeId = message.id;
            clientNonce = message.params?.client_nonce;
            if (typeof handshakeId !== "string" || typeof clientNonce !== "string") {
              fail(new Error(`Godot handshake fields are malformed: ${JSON.stringify(message)}`));
              return;
            }
            if (message.params.protocol_version !== 1 ||
              message.params.project_path !== session.projectPath ||
              message.params.owner_nonce !== session.ownerNonce) {
              fail(new Error(`Godot handshake contract mismatch: ${JSON.stringify(message.params)}`));
              return;
            }
            if (currentAttempt === 1) {
              firstClientNonce = clientNonce;
              socket.send(JSON.stringify({
                jsonrpc: "2.0", id: "pre-ready-probe", method: "get_project_info", params: {},
              }));
            } else if (currentAttempt === 2) {
              if (clientNonce === firstClientNonce) {
                fail(new Error("Godot reused its client nonce after reconnect"));
                return;
              }
              socket.send(JSON.stringify({ jsonrpc: "2.0", id: handshakeId, result: {
                server_nonce: firstServerNonce,
                server_proof: firstServerProof,
              } }));
            }
            return;
          }

          if (message.method === "bridge.authenticate") {
            authenticateSeen = true;
            if (currentAttempt !== 1) {
              fail(new Error(`Replayed or malformed proof reached authenticate on attempt ${currentAttempt}`));
              return;
            }
            const expected = createProof(
              session.token,
              "client",
              session.projectPath,
              session.ownerNonce,
              firstClientNonce,
              firstServerNonce,
            );
            if (!proofMatches(expected, message.params?.client_proof)) {
              fail(new Error("Godot reciprocal client proof did not verify in Node"));
              return;
            }
            firstClientProofVerified = true;
            socket.close(1012, "scripted reconnect");
          }
        });

        socket.once("close", (code) => {
          if (currentAttempt === 1) {
            if (!preReadyVerified || !firstClientProofVerified || !authenticateSeen) {
              fail(new Error("Initial reciprocal-proof scenario did not complete"));
            }
          } else if (currentAttempt === 2) {
            if (authenticateSeen || code !== 1008) {
              fail(new Error(`Replayed server proof was not rejected with policy close: ${code}`));
              return;
            }
            clearTimeout(timer);
            resolveScenario();
          }
        });
        socket.on("error", () => undefined);
      });
  });
  publisher.publish(endpoint);
  refresh = setInterval(() => publisher.publish(endpoint), 8_000);
  await scenario;
  console.log("BRIDGE_E2E_REJECTION_MATRIX_OK");
  } finally {
    if (refresh !== null) clearInterval(refresh);
    publisher.removeOwned();
    for (const client of server.clients) client.terminate();
    await closeServer(server);
  }
}

try {
  await runValidAgent("INITIAL");
  await runAdversarialAgent();
  await runValidAgent("RESTARTED");
} catch (error) {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
}
