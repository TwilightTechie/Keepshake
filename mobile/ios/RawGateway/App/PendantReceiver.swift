import Foundation
import CoreBluetooth
import Combine

final class PendantReceiver: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Standby (Disconnected)"
    @Published var running = UserDefaults.standard.bool(forKey: "captureWanted")
    @Published var isDeviceConnected = false
    @Published var stats = PacketStats()
    @Published var storageMB: Double = 0
    @Published var lastPacket = "None"
    @Published var deviceName = "Keepsake-P0"
    @Published var streamDescription = "Awaiting firmware descriptor"
    @Published var firmwareDiagnostics = "Not read yet"
    @Published var linkDiagnostics = "Not read yet"
    @Published var resetTrace = "Not read yet"
    @Published var transportDiagnostics = "Not read yet"
    @Published var previousTransportDiagnostics = "Not read yet"
    @Published var lastRSSI: Int?
    @Published var bootID: UInt32?
    @Published var batteryMillivolts: Int?
    @Published var isCharging: Bool?

    // Persisted last-known battery values
    @Published var lastKnownBatteryPercent: Int?
    @Published var lastKnownBatteryMillivolts: Int?
    @Published var lastKnownIsCharging: Bool?
    @Published var lastKnownBatteryDate: Date?

    private let info = CBUUID(string: "6b656570-7361-6b65-0001-000000000003")
    private let diagnostics = CBUUID(string: "6b656570-7361-6b65-0001-000000000004")
    private let battery = CBUUID(string: "6b656570-7361-6b65-0001-000000000005")
    private let linkEvents = CBUUID(string: "6b656570-7361-6b65-0001-000000000006")
    private let resetTraceUUID = CBUUID(string: "6b656570-7361-6b65-0001-000000000007")
    private let transportUUID = CBUUID(string: "6b656570-7361-6b65-0001-000000000008")
    private let previousTransportUUID = CBUUID(string: "6b656570-7361-6b65-0001-000000000009")
    private var transportCharacteristic: CBCharacteristic?
    private var previousTransportCharacteristic: CBCharacteristic?
    private var descriptor: StreamDescriptor?
    private var audioCharacteristic: CBCharacteristic?
    private var diagnosticsCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var linkEventsCharacteristic: CBCharacteristic?
    private var resetTraceCharacteristic: CBCharacteristic?
    private var lastResetTraceSnapshot: String?
    private var lastFirmwareSnapshot: String?
    private var lastLinkEventCount: UInt32?
    private var lastLoggedBatteryMillivolts: Int?
    private var connectedAtUptime: TimeInterval?
    private var handshakeBegan: TimeInterval?
    private var lastNotificationUptime: TimeInterval?
    private var lastDiagnosticsUptime: TimeInterval = 0
    private var lastBatteryUptime: TimeInterval = 0
    private var connectionAttemptBegan: TimeInterval?
    private var reconnectTask: DispatchWorkItem?
    private var connectionWanted = true

    static func calculatePercent(fromMillivolts mv: Int?) -> Int? {
        guard let mv = mv else { return nil }
        let levels = [(3300, 0), (3500, 5), (3600, 10), (3700, 20),
                      (3750, 30), (3800, 40), (3850, 50), (3900, 60),
                      (3950, 70), (4000, 80), (4100, 90), (4200, 100)]
        if mv <= levels[0].0 { return 0 }
        for index in 1..<levels.count where mv <= levels[index].0 {
            let lower = levels[index - 1]
            let upper = levels[index]
            return lower.1 + (mv - lower.0) * (upper.1 - lower.1) / (upper.0 - lower.0)
        }
        return 100
    }

    var batteryPercent: Int? {
        Self.calculatePercent(fromMillivolts: batteryMillivolts)
    }

    var displayBatteryPercent: Int? {
        batteryPercent ?? lastKnownBatteryPercent
    }

    var displayBatteryMillivolts: Int? {
        batteryMillivolts ?? lastKnownBatteryMillivolts
    }

    var displayIsCharging: Bool? {
        isCharging ?? lastKnownIsCharging
    }
    private let service = CBUUID(string: "6b656570-7361-6b65-0001-000000000001")
    private let audio = CBUUID(string: "6b656570-7361-6b65-0001-000000000002")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var liveStats = PacketStats()
    private var sessionID = UUID().uuidString.lowercased()
    private var timer: Timer?
    private let store: ChunkStore
    private let settings: Settings
    private let logger: DiagnosticLogger
    var checkpointed: (() -> Void)?
    private var liveStreamBuffer = Data()
    private var lastLiveStreamFlush: TimeInterval = 0
    private let liveSession = URLSession(configuration: .default)

    private func flushLiveStream() {
        guard settings.deliveryMode == .live, !liveStreamBuffer.isEmpty else { return }
        guard let url = settings.webhookURL else {
            logger.warning("Live stream: invalid webhook URL", category: "stream")
            return
        }
        let payload = liveStreamBuffer
        liveStreamBuffer = Data()
        lastLiveStreamFlush = ProcessInfo.processInfo.systemUptime
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !settings.webhookToken.isEmpty {
            req.setValue("Bearer \(settings.webhookToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = payload
        liveSession.dataTask(with: req) { [weak self] _, response, error in
            if let error {
                self?.logger.warning("Live stream POST failed: \(error.localizedDescription)", category: "stream")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                self?.logger.warning("Live stream POST HTTP \(http.statusCode)", category: "stream")
            }
        }.resume()
    }

    init(store: ChunkStore, settings: Settings, logger: DiagnosticLogger) {
        self.store = store; self.settings = settings; self.logger = logger
        super.init()

        // Restore last known battery state from persistent storage
        if let mv = UserDefaults.standard.object(forKey: "lastKnownBatteryMV") as? Int {
            lastKnownBatteryMillivolts = mv
        }
        if let pct = UserDefaults.standard.object(forKey: "lastKnownBatteryPercent") as? Int {
            lastKnownBatteryPercent = pct
        } else if let mv = lastKnownBatteryMillivolts {
            lastKnownBatteryPercent = Self.calculatePercent(fromMillivolts: mv)
        }
        if let chg = UserDefaults.standard.object(forKey: "lastKnownIsCharging") as? Bool {
            lastKnownIsCharging = chg
        }
        if let ts = UserDefaults.standard.object(forKey: "lastKnownBatteryTimestamp") as? Double {
            lastKnownBatteryDate = Date(timeIntervalSince1970: ts)
        }

        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "KeepsakeRawGateway.bluetooth.v1"])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.checkpointIfDue()
                self.stats = self.liveStats
                self.storageMB = Double(try self.store.storageBytes()) / 1_000_000
                if self.running && self.storageMB >= 1024 { throw GatewayError.message("Local queue reached 1 GB. Capture stopped; queued data retained. Upload before restarting.") }
                self.checkpointed?()
                let now = ProcessInfo.processInfo.systemUptime
                if let began = self.connectionAttemptBegan, now - began >= 20,
                   let peripheral = self.peripheral, peripheral.state == .connecting {
                    self.logger.warning("Connection attempt pending for 20s — cancelling and retrying", category: "ble")
                    self.connectionAttemptBegan = nil
                    self.central.cancelPeripheralConnection(peripheral)
                    self.scheduleReconnect(after: 2)
                }
                if self.running, let began = self.handshakeBegan, now - began > 12 {
                    self.handshakeBegan = nil
                    self.logger.warning("Firmware handshake timed out after 12s", category: "ble")
                    self.recoverConnection(GatewayError.message("Firmware handshake timed out"))
                }
                if self.running, let last = self.lastNotificationUptime, now - last > 8,
                   let peripheral = self.peripheral, peripheral.state == .connected {
                    self.lastNotificationUptime = nil
                    self.status = "Audio stalled — reconnecting"
                    self.logger.warning("Audio stalled (no packets for 8s) — reconnecting", category: "ble")
                    self.central.cancelPeripheralConnection(peripheral)
                }

                // Read battery, telemetry, and link status whenever connected, even if capture is paused
                if let peripheral = self.peripheral, peripheral.state == .connected {
                    if now - self.lastDiagnosticsUptime >= 10,
                       let characteristic = self.diagnosticsCharacteristic {
                        self.lastDiagnosticsUptime = now
                        peripheral.readValue(for: characteristic)
                        if let events = self.linkEventsCharacteristic { peripheral.readValue(for: events) }
                        if let trace = self.resetTraceCharacteristic { peripheral.readValue(for: trace) }
                        if let transport = self.transportCharacteristic { peripheral.readValue(for: transport) }
                        peripheral.readRSSI()
                    }
                    if now - self.lastBatteryUptime >= 6,
                       let characteristic = self.batteryCharacteristic {
                        self.lastBatteryUptime = now
                        peripheral.readValue(for: characteristic)
                    }
                }

                // Flush live stream if 2+ seconds since last flush
                if self.running && self.settings.deliveryMode == .live && !self.liveStreamBuffer.isEmpty &&
                   now - self.lastLiveStreamFlush >= 2.0 {
                    self.flushLiveStream()
                }
            } catch { self.fail(error) }
        }
        logger.info("PendantReceiver initialized", category: "ble")
    }

    func start() {
        connectionWanted = true
        running = true
        UserDefaults.standard.set(true, forKey: "captureWanted")
        logger.info("Audio capture started by user", category: "ble")
        if let peripheral = peripheral, peripheral.state == .connected {
            handshakeBegan = ProcessInfo.processInfo.systemUptime
            if let format = peripheral.services?.first(where: { $0.uuid == service })?.characteristics?.first(where: { $0.uuid == info }) {
                status = "Configuring audio stream"
                peripheral.readValue(for: format)
            } else if let audio = audioCharacteristic {
                status = "Starting capture"
                peripheral.setNotifyValue(true, for: audio)
            } else {
                discover(peripheral)
            }
        } else {
            connect()
        }
    }

    func changeDeliveryMode(to mode: DeliveryMode) {
        guard mode != settings.deliveryMode else { return }
        do {
            try store.checkpointNow()
            if settings.deliveryMode == .live {
                flushLiveStream()
                if !liveStreamBuffer.isEmpty {
                    logger.warning("Unsent live audio remains in the closed checkpoint", category: "stream")
                    liveStreamBuffer.removeAll()
                }
            }
            settings.deliveryMode = mode
            if mode == .checkpoint { settings.uploadsEnabled = true }
            checkpointed?()
            logger.info("Delivery mode changed to \(mode.rawValue)", category: "app")
        } catch { fail(error) }
    }

    func stop() {
        if settings.deliveryMode == .live { flushLiveStream() }
        running = false
        UserDefaults.standard.set(false, forKey: "captureWanted")
        lastNotificationUptime = nil
        handshakeBegan = nil
        if let audio = audioCharacteristic, let peripheral = peripheral, peripheral.state == .connected {
            peripheral.setNotifyValue(false, for: audio)
        }
        do {
            try store.checkpointNow()
            status = (peripheral?.state == .connected) ? "Connected (Standby)" : "Standby (Disconnected)"
        } catch {
            status = error.localizedDescription
        }
        checkpointed?()
        logger.info("User stopped audio capture; device BLE link preserved for battery monitoring", category: "ble")
    }

    func disconnect() {
        connectionWanted = false
        reconnectTask?.cancel()
        connectionAttemptBegan = nil
        stop()
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        status = "Disconnected"
        isDeviceConnected = false
        logger.info("User requested Bluetooth disconnect", category: "ble")
    }

    func reconnect() {
        connectionWanted = true
        reconnectTask?.cancel()
        connectionAttemptBegan = nil
        logger.info("User requested reconnect; peripheral state=\(peripheral.map { String($0.state.rawValue) } ?? "none")", category: "ble")
        if let peripheral, peripheral.state == .connecting || peripheral.state == .connected {
            status = "Restarting Bluetooth connection"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnect(after: 1)
        } else {
            connect()
        }
    }

    private func scheduleReconnect(after seconds: TimeInterval) {
        reconnectTask?.cancel()
        guard connectionWanted else { return }
        let task = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func beginConnection(_ peripheral: CBPeripheral) {
        connectionAttemptBegan = ProcessInfo.processInfo.systemUptime
        status = "Connecting"
        logger.info("Starting BLE connection attempt to \(peripheral.identifier.uuidString)", category: "ble")
        central.connect(peripheral)
    }

    private func fail(_ error: Error) {
        stop()
        status = "Capture stopped: \(error.localizedDescription)"
        logger.error("Capture failed: \(error.localizedDescription)", category: "ble")
    }

    private func recoverConnection(_ error: Error) {
        status = "Bluetooth error — reconnecting: \(error.localizedDescription)"
        handshakeBegan = nil
        lastNotificationUptime = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        logger.warning("Connection recovery: \(error.localizedDescription)", category: "ble")
    }

    private func connect() {
        guard connectionWanted else { return }
        guard central.state == .poweredOn else { status = "Waiting for Bluetooth permission / power"; return }
        if let peripheral {
            if peripheral.state == .connected {
                isDeviceConnected = true
                if audioCharacteristic == nil || diagnosticsCharacteristic == nil || (running && descriptor == nil) {
                    discover(peripheral)
                }
            } else if peripheral.state == .disconnected {
                beginConnection(peripheral)
            } else if peripheral.state == .disconnecting {
                scheduleReconnect(after: 1)
            } else if connectionAttemptBegan == nil {
                connectionAttemptBegan = ProcessInfo.processInfo.systemUptime
            }
        } else if let saved = UserDefaults.standard.string(forKey: "peripheralID"),
                  let uuid = UUID(uuidString: saved),
                  let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripheral = known; known.delegate = self
            beginConnection(known)
        } else {
            status = "Scanning for Keepsake pendant"
            central.scanForPeripherals(withServices: [service])
            logger.info("Scanning for pendant", category: "ble")
        }
    }

    func forget() {
        connectionWanted = false
        reconnectTask?.cancel()
        connectionAttemptBegan = nil
        stop()
        if let peripheral {
            UserDefaults.standard.removeObject(forKey: "streamInfo." + peripheral.identifier.uuidString)
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        isDeviceConnected = false
        UserDefaults.standard.removeObject(forKey: "peripheralID")
        status = "Device forgotten"
        logger.info("Device forgotten — will scan for new device", category: "ble")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Bluetooth state: \(central.state.rawValue)", category: "ble")
        if central.state == .poweredOn {
            connect()
        } else {
            reconnectTask?.cancel()
            connectionAttemptBegan = nil
            isDeviceConnected = false
            do { try store.checkpointNow() } catch { fail(error); return }
            status = central.state == .unauthorized ? "Allow Bluetooth in Settings" : "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored; restored.delegate = self
        if restored.state == .connecting { connectionAttemptBegan = ProcessInfo.processInfo.systemUptime }
        logger.info("Bluetooth state restored", category: "ble")
        if restored.state == .connected {
            isDeviceConnected = true
            if running {
                if let data = UserDefaults.standard.data(forKey: "streamInfo." + restored.identifier.uuidString),
                   let known = try? StreamDescriptor(data) { descriptor = known }
                else { fail(GatewayError.message("Restored stream has no verified format. Start capture again.")) }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectionWanted, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "peripheralID")
        logger.info("Discovered \(peripheral.name ?? "unknown") RSSI=\(RSSI)", category: "ble")
        beginConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connectionWanted, self.peripheral?.identifier == peripheral.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectTask?.cancel()
        connectionAttemptBegan = nil
        isDeviceConnected = true
        NotificationManager.shared.notifyConnectionRestored(deviceName: peripheral.name ?? "Pendant", settings: settings)
        descriptor = nil
        audioCharacteristic = nil
        diagnosticsCharacteristic = nil
        batteryCharacteristic = nil
        linkEventsCharacteristic = nil
        resetTraceCharacteristic = nil
        transportCharacteristic = nil
        previousTransportCharacteristic = nil
        bootID = nil
        batteryMillivolts = nil
        isCharging = nil
        lastRSSI = nil
        firmwareDiagnostics = "Not read yet"
        linkDiagnostics = "Awaiting firmware link events"
        resetTrace = "Awaiting firmware reset trace"
        transportDiagnostics = "Awaiting firmware transport counters"
        previousTransportDiagnostics = "Awaiting previous transport snapshot"
        lastFirmwareSnapshot = nil
        lastLinkEventCount = nil
        lastResetTraceSnapshot = nil
        lastLoggedBatteryMillivolts = nil
        lastNotificationUptime = nil
        connectedAtUptime = ProcessInfo.processInfo.systemUptime
        sessionID = UUID().uuidString.lowercased()
        liveStats = PacketStats()
        stats = liveStats
        logger.info("Connected to \(peripheral.name ?? "pendant")", category: "ble")
        discover(peripheral)
    }

    private func discover(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        deviceName = peripheral.name ?? "Keepsake pendant"
        handshakeBegan = running ? ProcessInfo.processInfo.systemUptime : nil
        status = running ? "Discovering audio stream" : "Connected (Standby)"
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectionAttemptBegan = nil
        isDeviceConnected = false
        status = "Connection failed; retrying"
        logger.warning("Connection failed: \(error?.localizedDescription ?? "unknown")", category: "ble")
        scheduleReconnect(after: 3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectionAttemptBegan = nil
        let uptime = ProcessInfo.processInfo.systemUptime
        let duration = connectedAtUptime.map { String(format: "%.1f", uptime - $0) } ?? "unknown"
        let packetAge = lastNotificationUptime.map { String(format: "%.1f", uptime - $0) } ?? "unknown"
        let nsError = error as NSError?
        logger.warning("Link ended: duration=\(duration)s, last packet age=\(packetAge)s, iOS error=\(nsError.map { "\($0.domain)/\($0.code): \($0.localizedDescription)" } ?? "none"), packets=\(liveStats.packets), bytes=\(liveStats.bytes), gaps=\(liveStats.gaps), RSSI=\(lastRSSI.map { String($0) } ?? "unknown") dBm, battery=\(batteryMillivolts.map { String($0) } ?? "unknown") mV, boot=\(bootID.map { String(format: "0x%08x", $0) } ?? "unknown"), firmware=\(firmwareDiagnostics), previous link=\(linkDiagnostics), reset trace=\(resetTrace), transport=\(transportDiagnostics), previous transport=\(previousTransportDiagnostics)", category: "ble")
        if running {
            NotificationManager.shared.notifyConnectionLost(deviceName: deviceName, settings: settings)
        }
        isDeviceConnected = false
        descriptor = nil
        audioCharacteristic = nil
        diagnosticsCharacteristic = nil
        batteryCharacteristic = nil
        linkEventsCharacteristic = nil
        resetTraceCharacteristic = nil
        transportCharacteristic = nil
        previousTransportCharacteristic = nil
        batteryMillivolts = nil
        isCharging = nil
        lastNotificationUptime = nil
        handshakeBegan = nil
        connectedAtUptime = nil
        do { try store.checkpointNow() } catch { fail(error); return }
        checkpointed?()
        logger.info("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")", category: "ble")
        status = "Disconnected"
        // Auto-reconnect after 2 seconds to resume battery monitoring or capture
        scheduleReconnect(after: 2)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { recoverConnection(error); return }
        guard let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            fail(GatewayError.message("Pendant service missing")); return
        }
        peripheral.discoverCharacteristics([audio, info, diagnostics, battery, linkEvents, resetTraceUUID, transportUUID, previousTransportUUID], for: found)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { recoverConnection(error); return }
        guard let found = service.characteristics?.first(where: { $0.uuid == audio }) else {
            fail(GatewayError.message("Audio characteristic missing")); return
        }
        audioCharacteristic = found
        diagnosticsCharacteristic = service.characteristics?.first(where: { $0.uuid == diagnostics })
        batteryCharacteristic = service.characteristics?.first(where: { $0.uuid == battery })
        linkEventsCharacteristic = service.characteristics?.first(where: { $0.uuid == linkEvents })
        resetTraceCharacteristic = service.characteristics?.first(where: { $0.uuid == resetTraceUUID })
        transportCharacteristic = service.characteristics?.first(where: { $0.uuid == transportUUID })
        previousTransportCharacteristic = service.characteristics?.first(where: { $0.uuid == previousTransportUUID })
        if transportCharacteristic == nil { transportDiagnostics = "Unavailable — firmware has no transport counters" }
        if previousTransportCharacteristic == nil { previousTransportDiagnostics = "Unavailable — firmware has no retained transport counters" }
        if resetTraceCharacteristic == nil {
            resetTrace = "Unavailable — connected firmware has no reset trace characteristic"
            logger.warning(resetTrace, category: "ble")
        }
        if let batteryCharacteristic { peripheral.readValue(for: batteryCharacteristic) }
        if let diagnosticsCharacteristic { peripheral.readValue(for: diagnosticsCharacteristic) }
        if let linkEventsCharacteristic { peripheral.readValue(for: linkEventsCharacteristic) }
        if let resetTraceCharacteristic { peripheral.readValue(for: resetTraceCharacteristic) }
        if let transportCharacteristic { peripheral.readValue(for: transportCharacteristic) }
        if let previousTransportCharacteristic { peripheral.readValue(for: previousTransportCharacteristic) }
        peripheral.readRSSI()
        guard let format = service.characteristics?.first(where: { $0.uuid == info }) else {
            fail(GatewayError.message("Firmware has no stream descriptor. Flash the new Keepsake raw firmware first.")); return
        }
        status = running ? "Configuring audio stream" : "Connected (Standby)"
        // Read the current boot ID in standby too; only subscribe when running.
        peripheral.readValue(for: format)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { recoverConnection(error); return }
        handshakeBegan = nil
        lastNotificationUptime = characteristic.isNotifying ? ProcessInfo.processInfo.systemUptime : nil
        status = characteristic.isNotifying ? "Receiving raw packets" : (peripheral.state == .connected ? "Connected (Standby)" : "Notifications stopped")
        logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled")", category: "ble")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == battery {
            guard error == nil, let data = characteristic.value, data.count == 2 || data.count == 3 else {
                logger.warning("Battery read failed: \(error?.localizedDescription ?? "invalid response")", category: "ble")
                return
            }
            let mv = Int(data[0]) | (Int(data[1]) << 8)
            batteryMillivolts = (2500...4500).contains(mv) ? mv : nil
            isCharging = data.count == 3 ? data[2] == 1 : nil

            if let mv = batteryMillivolts {
                lastKnownBatteryMillivolts = mv
                let pct = Self.calculatePercent(fromMillivolts: mv)
                lastKnownBatteryPercent = pct
                lastKnownIsCharging = isCharging
                let now = Date()
                lastKnownBatteryDate = now
                UserDefaults.standard.set(mv, forKey: "lastKnownBatteryMV")
                if let pct = pct {
                    UserDefaults.standard.set(pct, forKey: "lastKnownBatteryPercent")
                }
                if let chg = isCharging {
                    UserDefaults.standard.set(chg, forKey: "lastKnownIsCharging")
                }
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastKnownBatteryTimestamp")
            }

            NotificationManager.shared.handleBatteryStateUpdate(
                percent: batteryPercent ?? lastKnownBatteryPercent,
                millivolts: batteryMillivolts,
                isCharging: isCharging,
                settings: settings
            )

            if let batteryMillivolts,
               lastLoggedBatteryMillivolts.map({ abs(batteryMillivolts - $0) >= 100 }) ?? true {
                logger.info("Battery \(batteryMillivolts) mV; charging \(isCharging.map { $0 ? "yes" : "no" } ?? "unknown")", category: "ble")
                lastLoggedBatteryMillivolts = batteryMillivolts
            }
            return
        }
        if characteristic.uuid == diagnostics {
            guard error == nil, let data = characteristic.value else {
                logger.warning("Firmware diagnostics read failed: \(error?.localizedDescription ?? "no data")", category: "ble")
                return
            }
            let b = Array(data)
            if b.count == 20 && Array(b[0..<4]) == Array("KST1".utf8) {
                func u32(_ n: Int) -> UInt32 {
                    UInt32(b[n]) | UInt32(b[n+1]) << 8 | UInt32(b[n+2]) << 16 | UInt32(b[n+3]) << 24
                }
                let flags = u32(16)
                var resetCauses: [String] = []
                if flags & 0x01 != 0 { resetCauses.append("reset pin") }
                if flags & 0x02 != 0 { resetCauses.append("watchdog") }
                if flags & 0x04 != 0 { resetCauses.append("software reset") }
                if flags & 0x08 != 0 { resetCauses.append("CPU lockup") }
                if flags == 0 { resetCauses.append("power-on or unclassified") }
                firmwareDiagnostics = "Boot counters: queue drops \(u32(4)), TX drops \(u32(8)), mic restarts \(u32(12)); reset flags 0x\(String(flags, radix: 16)) (\(resetCauses.joined(separator: ", ")))"
                if firmwareDiagnostics != lastFirmwareSnapshot {
                    logger.info(firmwareDiagnostics, category: "ble")
                    lastFirmwareSnapshot = firmwareDiagnostics
                }
            }
            return
        }
        if characteristic.uuid == linkEvents {
            guard error == nil, let data = characteristic.value else {
                logger.warning("Link events read failed: \(error?.localizedDescription ?? "no data")", category: "ble")
                return
            }
            let b = Array(data)
            if b.count == 20 && Array(b[0..<4]) == Array("KSE1".utf8) {
                func u32(_ n: Int) -> UInt32 {
                    UInt32(b[n]) | UInt32(b[n+1]) << 8 | UInt32(b[n+2]) << 16 | UInt32(b[n+3]) << 24
                }
                let count = u32(4)
                let mv = Int(b[12]) | Int(b[13]) << 8
                let mtu = Int(b[16]) | Int(b[17]) << 8
                let reason = b[14]
                let reasonName = reason == 0x08 ? "supervision timeout" : reason == 0x13 ? "remote user terminated" : "other"
                linkDiagnostics = "disconnects since boot \(count); last HCI reason 0x\(String(format: "%02x", reason)) (\(reasonName)); firmware TX-stall request \(b[15] == 1 ? "yes" : "no"); last link \(Double(u32(8)) / 1000)s; last battery sample \(mv == 0 ? "unavailable" : "\(mv) mV"); current ATT MTU \(mtu)"
                if lastLinkEventCount != count {
                    logger.info(linkDiagnostics, category: "ble")
                    lastLinkEventCount = count
                }
            } else { logger.warning("Unsupported link diagnostics format", category: "ble") }
            return
        }
        if characteristic.uuid == transportUUID || characteristic.uuid == previousTransportUUID {
            guard error == nil, let data = characteristic.value, let counters = TransportDiagnostics(data) else {
                logger.warning("Transport diagnostics read failed or unsupported: \(error?.localizedDescription ?? "invalid KTP1")", category: "ble")
                return
            }
            let isPrevious = characteristic.uuid == previousTransportUUID
            let expected: UInt32 = isPrevious ? 2 : 1
            guard counters.flags == expected || (isPrevious && counters.flags == 0) else {
                logger.warning("Transport snapshot kind does not match characteristic", category: "ble")
                return
            }
            let summary = counters.summary
            if isPrevious {
                if previousTransportDiagnostics != summary { logger.info(summary, category: "ble") }
                previousTransportDiagnostics = summary
            } else {
                // Include time in the visible report: these are sampled counters, not live delivery ACKs.
                transportDiagnostics = "\(summary); sampled \(Date().formatted(date: .omitted, time: .standard))"
                logger.info(summary, category: "ble")
            }
            return
        }
        if characteristic.uuid == resetTraceUUID {
            guard error == nil, let data = characteristic.value else {
                logger.warning("Reset trace read failed: \(error?.localizedDescription ?? "no data")", category: "ble")
                return
            }
            let b = Array(data)
            guard b.count == 20,
                  let version = String(bytes: b[0..<4], encoding: .ascii),
                  version == "KTR1" || version == "KTR2" || version == "KTR3" else {
                logger.warning("Unsupported reset trace format", category: "ble")
                return
            }
            if b[4] == 1 {
                func u32(_ n: Int) -> UInt32 {
                    UInt32(b[n]) | UInt32(b[n+1]) << 8 | UInt32(b[n+2]) << 16 | UInt32(b[n+3]) << 24
                }
                let phases = ["unknown", "boot", "feed watchdog", "check state", "stop microphone", "idle wait", "start microphone", "read microphone", "get BLE link/MTU", "queue audio", "free audio buffer", "reset: Bluetooth TX stalled for 15s", "reset: supervisor stalled for 20s"]
                let workPhases = ["idle", "sample battery", "disconnect stalled BLE", "start advertising"]
                let senderPhases = ["idle", "dequeue audio", "send BLE notification"]
                let phase = Int(b[5]) < phases.count ? phases[Int(b[5])] : "unknown \(b[5])"
                let work = Int(b[6]) < workPhases.count ? workPhases[Int(b[6])] : "unknown \(b[6])"
                let sender = Int(b[7]) < senderPhases.count ? senderPhases[Int(b[7])] : "unknown \(b[7])"
                resetTrace = "\(version): Previous firmware reset: capture=\(phase) (\(u32(12)) ms uptime), supervisor=\(work), sender=\(sender); last successful feed=\(u32(8)) ms uptime; feed error=\(Int32(bitPattern: u32(16)))"
            } else {
                resetTrace = "\(version): No retained reset trace for this boot"
            }
            if resetTrace != lastResetTraceSnapshot {
                logger.info(resetTrace, category: "ble")
                lastResetTraceSnapshot = resetTrace
            }
            return
        }
        if let error { recoverConnection(error); return }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == info {
            do {
                let format = try StreamDescriptor(data)
                if let previous = descriptor, previous.raw != data { try store.checkpointNow() }
                descriptor = format
                let bootKey = "lastBootID." + peripheral.identifier.uuidString
                let previousBoot = bootID ?? (UserDefaults.standard.object(forKey: bootKey) as? NSNumber)?.uint32Value
                if let old = previousBoot, old != format.bootID {
                    logger.warning("Firmware reboot detected: boot ID 0x\(String(format: "%08x", old)) → 0x\(String(format: "%08x", format.bootID)); reset flags: \(firmwareDiagnostics)", category: "ble")
                }
                bootID = format.bootID
                UserDefaults.standard.set(Int(format.bootID), forKey: bootKey)
                UserDefaults.standard.set(data, forKey: "streamInfo." + peripheral.identifier.uuidString)
                streamDescription = "\(format.sampleRate) Hz · mono PCM16 · \(format.blockMilliseconds) ms blocks"
                logger.info("Stream format: \(streamDescription)", category: "ble")
                if running, let audioCharacteristic { peripheral.setNotifyValue(true, for: audioCharacteristic) }
            } catch { fail(error) }
            return
        }
        guard characteristic.uuid == audio, running else { return }
        guard let descriptor else {
            fail(GatewayError.message("Audio arrived without a verified firmware format.")); return
        }
        lastNotificationUptime = ProcessInfo.processInfo.systemUptime
        do {
            try store.append(data, deviceID: peripheral.identifier.uuidString,
                             sessionID: sessionID, sampleRate: descriptor.sampleRate,
                             checkpoint: settings.checkpoint, streamInfo: descriptor.raw,
                             deliveryMode: settings.deliveryMode == .checkpoint ? "checkpoint" : nil)
            liveStats.observe(data)
            if settings.deliveryMode == .live && data.count > 5 {
                liveStreamBuffer.append(data.subdata(in: 5..<data.count))
                let now = ProcessInfo.processInfo.systemUptime
                if liveStreamBuffer.count >= 64000 || (now - lastLiveStreamFlush >= 2.0 && !liveStreamBuffer.isEmpty) {
                    flushLiveStream()
                }
            }
            // UI refresh only once per second; all packets are still written immediately.
            let time = ChunkStore.timestamp(Date())
            let second = String(time.prefix(19))
            if lastPacket != second { lastPacket = second }
        } catch { fail(error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            logger.warning("RSSI read failed: \(error.localizedDescription)", category: "ble")
            return
        }
        let value = RSSI.intValue
        if let previous = lastRSSI, abs(previous - value) >= 12 {
            logger.info("RSSI changed \(previous) → \(value) dBm", category: "ble")
        } else if lastRSSI == nil {
            logger.info("RSSI \(value) dBm", category: "ble")
        }
        lastRSSI = value
    }
}
