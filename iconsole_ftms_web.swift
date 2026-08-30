import Foundation
import Network

struct WebDeviceOption {
    var name: String
    var address: String
}

struct WebDashboardSnapshot {
    var appVersion: String
    var status: String
    var isConnected: Bool
    var localWebURL: String
    var lanWebURL: String?
    var bikeTime: String
    var bikeSpeed: String
    var bikeCadence: String
    var bikePower: String
    var bikeResistance: String
    var bikeDistance: String
    var bikeCalories: String
    var bikeHeartRate: String
    var event: String
    var source: String
    var opcode: String
    var commandedResistance: Int
    var autoBaseResistance: Int
    var receivedGrade: String
    var appliedGrade: String
    var targetPower: String
    var targetResistance: String
    var tuning: String
    var selectedDeviceAddress: String?
    var deviceOptions: [WebDeviceOption]
}

final class SharedWebState {
    private let lock = NSLock()
    private var snapshot: WebDashboardSnapshot

    init(initial: WebDashboardSnapshot) {
        self.snapshot = initial
    }

    func set(_ newSnapshot: WebDashboardSnapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    func get() -> WebDashboardSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

struct WebActionCommand {
    let action: String
    let level: Int?
    let address: String?
}

final class WebCommandQueue {
    private let lock = NSLock()
    private var commands: [WebActionCommand] = []

    func enqueue(_ command: WebActionCommand) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func drain() -> [WebActionCommand] {
        lock.lock()
        defer { lock.unlock() }
        let pending = commands
        commands.removeAll(keepingCapacity: true)
        return pending
    }
}

final class WebControlServer {
    private let port: UInt16
    private let state: SharedWebState
    private let commandQueue: WebCommandQueue
    private var listener: NWListener?

    init(port: UInt16, state: SharedWebState, commandQueue: WebCommandQueue) {
        self.port = port
        self.state = state
        self.commandQueue = commandQueue
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: DispatchQueue.global(qos: .utility))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: DispatchQueue.global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let response = self.makeResponse(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func makeResponse(for data: Data) -> Data {
        guard let request = String(data: data, encoding: .utf8) else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Bad request")
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Bad request")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Bad request")
        }

        let method = String(parts[0])
        let pathWithQuery = String(parts[1])
        let actionRequest = parseActionRequest(pathWithQuery: pathWithQuery)
        let path = actionRequest.path

        if method == "GET", path == "/" {
            return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: htmlPage)
        }

        if method == "GET", path == "/api/state" {
            let snapshot = state.get()
            let payload: [String: Any] = [
                "appVersion": snapshot.appVersion,
                "status": snapshot.status,
                "isConnected": snapshot.isConnected,
                "localWebURL": snapshot.localWebURL,
                "lanWebURL": snapshot.lanWebURL as Any,
                "bikeTime": snapshot.bikeTime,
                "bikeSpeed": snapshot.bikeSpeed,
                "bikeCadence": snapshot.bikeCadence,
                "bikePower": snapshot.bikePower,
                "bikeResistance": snapshot.bikeResistance,
                "bikeDistance": snapshot.bikeDistance,
                "bikeCalories": snapshot.bikeCalories,
                "bikeHeartRate": snapshot.bikeHeartRate,
                "event": snapshot.event,
                "source": snapshot.source,
                "opcode": snapshot.opcode,
                "commandedResistance": snapshot.commandedResistance,
                "autoBaseResistance": snapshot.autoBaseResistance,
                "receivedGrade": snapshot.receivedGrade,
                "appliedGrade": snapshot.appliedGrade,
                "targetPower": snapshot.targetPower,
                "targetResistance": snapshot.targetResistance,
                "tuning": snapshot.tuning,
                "selectedDeviceAddress": snapshot.selectedDeviceAddress as Any,
                "deviceOptions": snapshot.deviceOptions.map { ["name": $0.name, "address": $0.address] }
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
                  let body = String(data: bodyData, encoding: .utf8) else {
                return httpResponse(status: "500 Internal Server Error", contentType: "text/plain", body: "Encoding error")
            }
            return httpResponse(status: "200 OK", contentType: "application/json", body: body)
        }

        if method == "POST", path == "/api/action" {
            var action = actionRequest.query["action"]
            var level: Int? = actionRequest.query["level"].flatMap { Int($0) }
            var address = actionRequest.query["address"]

            if action == nil {
                guard let bodyRange = request.range(of: "\r\n\r\n") else {
                    return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Missing body")
                }

                let body = String(request[bodyRange.upperBound...])
                guard let bodyData = body.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                    return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Invalid JSON")
                }

                action = raw["action"] as? String
                level = raw["level"] as? Int
                address = raw["address"] as? String
            }

            guard let action else {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Missing action")
            }

            let allowed = Set(["base_up", "base_down", "manual_up", "manual_down", "quit", "select_device"])
            guard allowed.contains(action) else {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unsupported action")
            }
            if action == "select_device", (address ?? "").isEmpty {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Missing address")
            }

            commandQueue.enqueue(WebActionCommand(action: action, level: level, address: address))
            return httpResponse(status: "200 OK", contentType: "application/json", body: "{\"ok\":true}")
        }

        return httpResponse(status: "404 Not Found", contentType: "text/plain", body: "Not found")
    }

    private func parseActionRequest(pathWithQuery: String) -> (path: String, query: [String: String]) {
        let full = "http://localhost\(pathWithQuery)"
        guard let components = URLComponents(string: full) else {
            return (pathWithQuery, [:])
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (components.path, query)
    }

    private func httpResponse(status: String, contentType: String, body: String) -> Data {
        let utf8Count = body.lengthOfBytes(using: .utf8)
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(utf8Count)\r
        Connection: close\r
        \r
        \(body)
        """
        return Data(response.utf8)
    }

    private var htmlPage: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width,initial-scale=1" />
          <title>iConsole FTMS</title>
          <style>
            :root {
              --bg: #0a0f1d;
              --line: #1b2a4a;
              --text: #e8efff;
              --muted: #9eb0d4;
              --accent: #4cc9ff;
              --good: #5df2a7;
              --danger: #ff6a7a;
            }
            * { box-sizing: border-box; }
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              background: radial-gradient(130% 140% at 20% 0%, #18294d 0%, var(--bg) 45%, #050913 100%);
              color: var(--text);
              font-family: "Inter", "Avenir Next", "Segoe UI", system-ui, sans-serif;
            }
            #viewport { width: 100vw; height: 100dvh; position: relative; overflow: hidden; }
            .app {
              width: 1400px;
              position: absolute;
              left: 0;
              top: 0;
              padding: 18px;
              display: grid;
              grid-template-rows: auto auto 1fr;
              gap: 12px;
              transform-origin: top left;
            }
            .screen.hidden { display: none !important; }
            .connect-screen {
              height: 100%;
              display: grid;
              grid-template-rows: auto auto auto 1fr;
              gap: 14px;
            }
            .connect-title { font-size: 54px; font-weight: 800; }
            .connect-sub { font-size: 24px; color: var(--muted); }
            .connect-tip {
              font-size: 17px;
              color: #8ea6d8;
              margin-top: -6px;
            }
            .version-chip {
              display: inline-block;
              margin-left: 10px;
              padding: 4px 10px;
              border: 1px solid #2a4679;
              border-radius: 999px;
              font-size: 15px;
              color: #b7cdf5;
              background: rgba(11, 20, 39, 0.75);
              vertical-align: middle;
            }
            .device-list {
              min-height: 0;
              display: grid;
              grid-template-columns: 1fr;
              gap: 10px;
              align-content: start;
            }
            .connect-overlay {
              position: absolute;
              inset: 0;
              background: rgba(4, 10, 20, 0.72);
              display: flex;
              align-items: center;
              justify-content: center;
              z-index: 20;
            }
            .connect-overlay.hidden { display: none; }
            .connect-popup {
              min-width: 420px;
              max-width: 78vw;
              border: 1px solid #2a4679;
              border-radius: 16px;
              background: #0f1c34;
              padding: 18px 20px;
              text-align: center;
              box-shadow: 0 16px 40px rgba(0, 0, 0, 0.45);
            }
            .connect-popup-title {
              font-size: 30px;
              font-weight: 800;
              margin-bottom: 8px;
            }
            .connect-popup-status {
              font-size: 22px;
              color: var(--muted);
              line-height: 1.35;
            }
            .device-btn {
              text-align: left;
              min-height: 74px;
              padding: 12px 16px;
              border: 1px solid #2a4679;
              border-radius: 14px;
              background: linear-gradient(180deg, rgba(16, 28, 52, 0.95), rgba(10, 18, 35, 0.95));
              color: var(--text);
              font-size: 26px;
              font-weight: 700;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
              cursor: pointer;
            }
            .topbar {
              display: flex;
              justify-content: space-between;
              align-items: end;
              border-bottom: 1px solid #27406f;
              padding-bottom: 8px;
            }
            .title-wrap { display: flex; align-items: baseline; gap: 14px; min-width: 0; }
            .title { font-size: 40px; font-weight: 800; letter-spacing: 0.3px; }
            .title-tip {
              font-size: 17px;
              color: #8ea6d8;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
              max-width: 52vw;
            }
            .top-actions { display: flex; gap: 10px; align-items: center; }
            .status {
              padding: 10px 14px;
              border: 1px solid #2a4679;
              border-radius: 12px;
              background: rgba(11, 20, 39, 0.8);
              font-size: 22px;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
              max-width: 44vw;
            }
            button {
              border: 1px solid #2a4679;
              border-radius: 10px;
              background: #152647;
              color: var(--text);
              font-size: 28px;
              padding: 10px 14px;
              cursor: pointer;
              font-weight: 700;
              min-height: 78px;
              min-width: 120px;
            }
            button:hover { border-color: var(--accent); }
            .danger { border-color: #7f2c3b; background: #3d1d29; color: #ffd7de; }
            .controls { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
            .hero { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
            .metric {
              background: linear-gradient(180deg, rgba(16, 28, 52, 0.95), rgba(10, 18, 35, 0.95));
              border: 1px solid #27406f;
              border-radius: 14px;
              padding: 12px;
              min-height: 140px;
              display: flex;
              flex-direction: column;
              justify-content: center;
            }
            .metric .label { color: var(--muted); font-size: 22px; }
            .metric .value { color: var(--good); font-size: 76px; font-weight: 800; line-height: 1.05; }
            .resistance-metric { display: grid; grid-template-columns: 1fr auto; gap: 12px; align-items: center; }
            .res-controls { display: grid; grid-template-columns: 1fr; gap: 10px; }
            .res-btn { font-size: 46px; min-height: 102px; min-width: 102px; padding: 0 16px; }
            .data-grid { min-height: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
            .card {
              min-height: 0;
              background: linear-gradient(180deg, rgba(16, 28, 52, 0.95), rgba(10, 18, 35, 0.95));
              border: 1px solid #27406f;
              border-radius: 14px;
              padding: 14px;
              display: flex;
              flex-direction: column;
            }
            .card h2 { margin: 0 0 10px; font-size: 30px; color: #d8e8ff; }
            .rows { display: grid; grid-template-columns: 1fr; gap: 7px; min-height: 0; }
            .line {
              display: flex;
              justify-content: space-between;
              gap: 14px;
              padding-bottom: 4px;
              border-bottom: 1px solid var(--line);
              font-size: 24px;
            }
            .k { color: var(--muted); }
            .v { color: var(--text); font-weight: 700; text-align: right; }
            .line.tuning { font-size: 17px; }
            .line.tuning .v { white-space: nowrap; }
            body.advanced-mode .app {
              width: 100%;
              height: 100%;
            }
            body.simple-mode .controls,
            body.simple-mode .data-grid { display: none; }
            body.simple-mode .app {
              grid-template-rows: auto 1fr;
            }
            body.simple-mode .hero {
              height: 100%;
              align-content: stretch;
            }
            body.simple-mode .metric {
              min-height: 260px;
            }
            body.simple-mode .resistance-metric {
              grid-template-columns: 1fr;
              gap: 16px;
            }
            body.simple-mode .res-controls {
              grid-template-columns: 1fr;
              gap: 14px;
              width: 100%;
            }
            body.simple-mode .res-btn {
              width: 100%;
              min-width: 0;
              min-height: 120px;
              padding: 0 26px;
            }
          </style>
        </head>
        <body>
          <div id="viewport">
            <div class="app" id="app">
              <div id="connectScreen" class="connect-screen screen">
              <div class="connect-title">Connect your bike <span class="version-chip" id="connectVersion">v-</span></div>
                <div class="connect-sub" id="connectStatus">Choose your bike to continue.</div>
              <div class="connect-tip" id="connectTip">Tip: Other devices can open this interface in a browser via http://192.x.x.x:8080 (use your Mac's local IP).</div>
                <div id="deviceList" class="device-list"></div>
                <div id="connectOverlay" class="connect-overlay hidden">
                  <div class="connect-popup">
                    <div class="connect-popup-title">Connecting...</div>
                    <div class="connect-popup-status" id="connectOverlayStatus">Please wait while connecting to bike.</div>
                  </div>
                </div>
              </div>

              <div id="dashboardScreen" class="screen hidden">
                <div class="topbar">
                  <div class="title-wrap">
                    <div class="title">iConsole FTMS</div>
                    <span class="version-chip" id="versionBadge">v-</span>
                    <div class="title-tip" id="titleTip">Tip: Open on another device via http://192.x.x.x:8080 (your Mac IP)</div>
                  </div>
                  <div class="top-actions">
                    <button id="modeToggle" onclick="toggleMode()">Mode: Simple</button>
                    <div class="status" id="status">Connected</div>
                  </div>
                </div>
                <div class="controls">
                  <button onclick="sendAction('base_up')">Auto base +</button>
                  <button onclick="sendAction('base_down')">Auto base -</button>
                </div>
                <div class="hero">
                  <div class="metric"><div class="label">Speed</div><div class="value" id="mSpeed">-</div></div>
                  <div class="metric"><div class="label">Power</div><div class="value" id="mPower">-</div></div>
                  <div class="metric"><div class="label">Cadence</div><div class="value" id="mCadence">-</div></div>
                  <div class="metric resistance-metric">
                    <div>
                      <div class="label">Resistance</div>
                      <div class="value" id="mResistance">-</div>
                    </div>
                    <div class="res-controls">
                      <button class="res-btn" onclick="sendAction('manual_up')">+</button>
                      <button class="res-btn" onclick="sendAction('manual_down')">-</button>
                    </div>
                  </div>
                </div>
                <div class="data-grid">
                  <div class="card"><h2>Bike Data</h2><div class="rows" id="bike"></div></div>
                  <div class="card"><h2>FTMS Data</h2><div class="rows" id="ftms"></div></div>
                </div>
              </div>
            </div>
          </div>
          <script>
            let uiMode = localStorage.getItem('iconsole-ui-mode') || 'simple';
            const connectFlow = {
              pending: false,
              selectedName: '',
              selectedAddress: '',
              startedAtMs: 0,
              lastDeviceListKey: ''
            };
            function fitLayout() {
              const viewport = document.getElementById('viewport');
              const app = document.getElementById('app');
              if (uiMode === 'advanced') {
                app.style.width = '100%';
                app.style.height = '100%';
                app.style.transform = 'none';
                return;
              }
              app.style.width = '1400px';
              app.style.height = 'auto';
              const vw = viewport.clientWidth;
              const vh = viewport.clientHeight;
              app.style.transform = 'translate(0px, 0px) scale(1)';
              const baseW = app.offsetWidth;
              const baseH = app.scrollHeight;
              const scale = Math.min(vw / baseW, vh / baseH);
              const x = Math.max(0, (vw - baseW * scale) / 2);
              const y = Math.max(0, (vh - baseH * scale) / 2);
              app.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
            }
            function applyMode() {
              const simple = uiMode === 'simple';
              document.body.classList.toggle('simple-mode', simple);
              document.body.classList.toggle('advanced-mode', !simple);
              document.getElementById('modeToggle').textContent = simple ? 'Mode: Simple' : 'Mode: Advanced';
            }
            function remoteTipText(state) {
              if (state.lanWebURL) {
                return `Tip: Open on another device via ${state.lanWebURL}`;
              }
              return "Tip: Open on another device via your Mac local IP (e.g. http://192.x.x.x:8080)";
            }
            function toggleMode() {
              uiMode = uiMode === 'simple' ? 'advanced' : 'simple';
              localStorage.setItem('iconsole-ui-mode', uiMode);
              applyMode();
              fitLayout();
            }
            async function sendAction(action, payload = {}) {
              const params = new URLSearchParams({ action });
              if (payload.level !== undefined) params.set('level', String(payload.level));
              if (payload.address !== undefined) params.set('address', String(payload.address));
              const response = await fetch(`/api/action?${params.toString()}`, { method: 'POST' });
              if (!response.ok) {
                throw new Error(`Request failed: ${response.status}`);
              }
              await refresh();
            }
            async function postSelectDevice(address) {
              const params = new URLSearchParams({ action: 'select_device', address });
              const response = await fetch(`/api/action?${params.toString()}`, { method: 'POST' });
              if (!response.ok) {
                throw new Error(`Select failed: ${response.status}`);
              }
            }
            function showConnectOverlay(message) {
              const overlay = document.getElementById('connectOverlay');
              const status = document.getElementById('connectOverlayStatus');
              status.textContent = message;
              overlay.classList.remove('hidden');
            }
            function hideConnectOverlay() {
              const overlay = document.getElementById('connectOverlay');
              overlay.classList.add('hidden');
            }
            function row(label, value, className = '') {
              const cls = className ? `line ${className}` : 'line';
              return `<div class="${cls}"><span class="k">${label}</span><span class="v">${value}</span></div>`;
            }
            function renderDeviceList(state) {
              const list = document.getElementById('deviceList');
              const options = Array.isArray(state.deviceOptions) ? state.deviceOptions : [];
              const renderKey = options.map((option) => `${option.address}|${option.name}`).join('||');
              if (renderKey === connectFlow.lastDeviceListKey && list.childElementCount > 0) {
                return;
              }
              connectFlow.lastDeviceListKey = renderKey;
              list.innerHTML = '';
              if (options.length === 0) {
                list.innerHTML = '<div class="connect-sub">No paired Bluetooth devices found. Pair your bike in macOS Bluetooth settings.</div>';
                return;
              }

              for (const option of options) {
                const button = document.createElement('button');
                button.className = 'device-btn';
                button.textContent = `${option.name} (${option.address})`;
                button.addEventListener('click', async (event) => {
                  event.preventDefault();
                  if (connectFlow.pending) {
                    return;
                  }
                  connectFlow.pending = true;
                  connectFlow.selectedName = option.name;
                  connectFlow.selectedAddress = option.address;
                  connectFlow.startedAtMs = Date.now();
                  showConnectOverlay(`Connecting to ${option.name}...`);
                  try {
                    await postSelectDevice(option.address);
                  } catch (error) {
                    connectFlow.pending = false;
                    showConnectOverlay('Could not send connect request. Retrying...');
                  }
                });
                list.appendChild(button);
              }
            }
            async function refresh() {
              const res = await fetch('/api/state');
              const s = await res.json();
              const versionText = s.appVersion ? `v${s.appVersion}` : 'v-';
              document.getElementById('connectVersion').textContent = versionText;
              document.getElementById('versionBadge').textContent = versionText;
              document.getElementById('connectTip').textContent = remoteTipText(s);
              document.getElementById('titleTip').textContent = remoteTipText(s);
              document.getElementById('connectStatus').textContent = 'Choose your bike to continue.';

              if (!s.isConnected) {
                document.getElementById('connectScreen').classList.remove('hidden');
                document.getElementById('dashboardScreen').classList.add('hidden');
                renderDeviceList(s);
                if (connectFlow.pending) {
                  const elapsedMs = Date.now() - connectFlow.startedAtMs;
                  const minHoldMs = 3800;
                  const maxHoldMs = 12000;
                  const statusText = String(s.status || '').toLowerCase();
                  const connectingText = statusText.includes('no bike selected')
                    ? `Connecting to ${connectFlow.selectedName}...`
                    : (s.status || `Connecting to ${connectFlow.selectedName}...`);
                  showConnectOverlay(connectingText);
                  const stillTrying = statusText.includes('connecting') || statusText.includes('retrying');
                  const selectedAddress = s.selectedDeviceAddress || '';
                  const selectionApplied = selectedAddress === connectFlow.selectedAddress;
                  const failed =
                    statusText.includes('not connectable') ||
                    statusText.includes('not found') ||
                    statusText.includes('no bike selected') ||
                    statusText.includes('could not initialize') ||
                    statusText.includes('could not start') ||
                    statusText.includes('failed');
                  if (failed && elapsedMs >= minHoldMs) {
                    connectFlow.pending = false;
                    hideConnectOverlay();
                  } else if (!stillTrying && selectionApplied && elapsedMs >= minHoldMs) {
                    connectFlow.pending = false;
                    hideConnectOverlay();
                  } else if (!selectionApplied && elapsedMs >= 5200) {
                    connectFlow.pending = false;
                    hideConnectOverlay();
                  } else if (elapsedMs >= maxHoldMs) {
                    connectFlow.pending = false;
                    hideConnectOverlay();
                  }
                } else {
                  hideConnectOverlay();
                }
                if (!connectFlow.pending && s.status && !s.status.toLowerCase().includes('connecting')) {
                  hideConnectOverlay();
                }
                fitLayout();
                return;
              }

              connectFlow.pending = false;
              hideConnectOverlay();
              document.getElementById('connectScreen').classList.add('hidden');
              document.getElementById('dashboardScreen').classList.remove('hidden');
              document.getElementById('mSpeed').textContent = s.bikeSpeed;
              document.getElementById('mPower').textContent = s.bikePower;
              document.getElementById('mCadence').textContent = s.bikeCadence;
              document.getElementById('mResistance').textContent = String(s.commandedResistance);
              document.getElementById('bike').innerHTML = [
                row('Time', s.bikeTime),
                row('Speed', s.bikeSpeed),
                row('Cadence', s.bikeCadence),
                row('Power', s.bikePower),
                row('Bike resistance', s.bikeResistance),
                row('Distance', s.bikeDistance),
                row('Calories', s.bikeCalories),
                row('Heart rate', s.bikeHeartRate),
                row('Tuning', s.tuning, 'tuning')
              ].join('');
              document.getElementById('ftms').innerHTML = [
                row('Cmd resistance', s.commandedResistance),
                row('Auto base resistance', s.autoBaseResistance),
                row('Source', s.source),
                row('Last opcode', s.opcode),
                row('Received grade', s.receivedGrade),
                row('Applied grade', s.appliedGrade),
                row('Target power', s.targetPower),
                row('Target resistance', s.targetResistance),
                row('Last event', s.event)
              ].join('');
              document.getElementById('status').textContent = s.status;
              applyMode();
              fitLayout();
            }
            document.addEventListener('keydown', (e) => {
              if (e.key === 'ArrowUp') { e.preventDefault(); sendAction('base_up'); }
              if (e.key === 'ArrowDown') { e.preventDefault(); sendAction('base_down'); }
            });
            window.addEventListener('resize', fitLayout);
            applyMode();
            fitLayout();
            setInterval(refresh, 500);
            refresh();
          </script>
        </body>
        </html>
        """
    }
}
