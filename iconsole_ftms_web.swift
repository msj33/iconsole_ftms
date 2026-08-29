import Foundation
import Network

struct WebDashboardSnapshot {
    var status: String
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
        let path = String(parts[1])

        if method == "GET", path == "/" {
            return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: htmlPage)
        }

        if method == "GET", path == "/api/state" {
            let snapshot = state.get()
            let payload: [String: Any] = [
                "status": snapshot.status,
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
                "tuning": snapshot.tuning
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
                  let body = String(data: bodyData, encoding: .utf8) else {
                return httpResponse(status: "500 Internal Server Error", contentType: "text/plain", body: "Encoding error")
            }
            return httpResponse(status: "200 OK", contentType: "application/json", body: body)
        }

        if method == "POST", path == "/api/action" {
            guard let bodyRange = request.range(of: "\r\n\r\n") else {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Missing body")
            }

            let body = String(request[bodyRange.upperBound...])
            guard let bodyData = body.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let action = raw["action"] as? String else {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Invalid JSON")
            }

            let level = raw["level"] as? Int
            let allowed = Set(["base_up", "base_down", "manual_up", "manual_down", "manual_set", "quit"])
            guard allowed.contains(action) else {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unsupported action")
            }
            if action == "manual_set", level == nil {
                return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: "Missing level")
            }

            commandQueue.enqueue(WebActionCommand(action: action, level: level))
            return httpResponse(status: "200 OK", contentType: "application/json", body: "{\"ok\":true}")
        }

        return httpResponse(status: "404 Not Found", contentType: "text/plain", body: "Not found")
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
            #viewport {
              width: 100vw;
              height: 100dvh;
              position: relative;
              overflow: hidden;
            }
            .app {
              width: 1400px;
              position: absolute;
              left: 0;
              top: 0;
              padding: 18px;
              display: grid;
              grid-template-rows: auto auto 1fr auto;
              gap: 12px;
              transform-origin: top left;
            }
            .topbar {
              display: flex;
              justify-content: space-between;
              align-items: end;
              border-bottom: 1px solid #27406f;
              padding-bottom: 8px;
            }
            .title { font-size: 40px; font-weight: 800; letter-spacing: 0.3px; }
            .status {
              padding: 10px 14px;
              border: 1px solid #2a4679;
              border-radius: 12px;
              background: rgba(11, 20, 39, 0.8);
              font-size: 22px;
              white-space: nowrap;
              overflow: hidden;
              text-overflow: ellipsis;
              max-width: 58%;
            }
            .controls {
              display: flex;
              flex-wrap: wrap;
              gap: 8px;
              align-items: center;
            }
            button, input {
              border: 1px solid #2a4679;
              border-radius: 10px;
              background: #152647;
              color: var(--text);
              font-size: 28px;
              padding: 10px 14px;
            }
            button { cursor: pointer; font-weight: 700; min-height: 78px; min-width: 120px; }
            button:hover { border-color: var(--accent); }
            input { width: 120px; height: 64px; text-align: center; }
            .danger { border-color: #7f2c3b; background: #3d1d29; color: #ffd7de; }
            .hero {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 12px;
            }
            .metric {
              background: linear-gradient(180deg, rgba(16, 28, 52, 0.95), rgba(10, 18, 35, 0.95));
              border: 1px solid #27406f;
              border-radius: 14px;
              padding: 12px;
              min-height: 110px;
              display: flex;
              flex-direction: column;
              justify-content: center;
            }
            .metric .label { color: var(--muted); font-size: 20px; }
            .metric .value { color: var(--good); font-size: 70px; font-weight: 800; line-height: 1.05; }
            .resistance-metric {
              display: grid;
              grid-template-columns: 1fr auto;
              gap: 12px;
              align-items: center;
            }
            .res-controls {
              display: grid;
              grid-template-columns: 1fr;
              gap: 10px;
            }
            .res-btn {
              font-size: 46px;
              min-height: 98px;
              min-width: 98px;
              padding: 0 16px;
            }
            .data-grid {
              min-height: 0;
              display: grid;
              grid-template-columns: 1fr 1fr;
              gap: 12px;
            }
            .card {
              min-height: 0;
              background: linear-gradient(180deg, rgba(16, 28, 52, 0.95), rgba(10, 18, 35, 0.95));
              border: 1px solid #27406f;
              border-radius: 14px;
              padding: 14px;
              display: flex;
              flex-direction: column;
            }
            .card h2 {
              margin: 0 0 10px;
              font-size: 30px;
              color: #d8e8ff;
            }
            .rows {
              display: grid;
              grid-template-columns: 1fr;
              gap: 7px;
              min-height: 0;
            }
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
            .line.tuning {
              font-size: 17px;
            }
            .line.tuning .v {
              white-space: nowrap;
            }
          </style>
        </head>
        <body>
          <div id="viewport">
            <div class="app" id="app">
              <div class="topbar">
                <div class="title">iConsole FTMS</div>
                <div class="status" id="status">Starting...</div>
              </div>
              <div class="controls">
                <button onclick="sendAction('base_up')">Auto base +</button>
                <button onclick="sendAction('base_down')">Auto base -</button>
                <button class="danger" onclick="sendAction('quit')">Stop app</button>
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
          <script>
            function fitLayout() {
              const viewport = document.getElementById('viewport');
              const app = document.getElementById('app');
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
            async function sendAction(action, level) {
              await fetch('/api/action', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(level === undefined ? { action } : { action, level })
              });
              await refresh();
            }
            function row(label, value, className = '') {
              const cls = className ? `line ${className}` : 'line';
              return `<div class="${cls}"><span class="k">${label}</span><span class="v">${value}</span></div>`;
            }
            async function refresh() {
              const res = await fetch('/api/state');
              const s = await res.json();

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
              fitLayout();
            }
            document.addEventListener('keydown', (e) => {
              if (e.key === 'ArrowUp') { e.preventDefault(); sendAction('base_up'); }
              if (e.key === 'ArrowDown') { e.preventDefault(); sendAction('base_down'); }
            });
            window.addEventListener('resize', fitLayout);
            fitLayout();
            setInterval(refresh, 500);
            refresh();
          </script>
        </body>
        </html>
        """
    }
}
