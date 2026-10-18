import Foundation
import CoreBluetooth
import Combine

final class PendantReceiver: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Stopped"
    @Published var running = UserDefaults.standard.bool(forKey: "captureWanted")
    @Published var stats = PacketStats()
    @Published var storageMB: Double = 0
    @Published var lastPacket = "None"
    @Published var deviceName = "Keepsake-P0"
    @Published var streamDescription = "Awaiting firmware descriptor"
    @Published var firmwareDiagnostics = "Not read yet"
    private let info = CBUUID(string: "6b656570-7361-6b65-0001-000000000003")
    private let diagnostics = CBUUID(string: "6b656570-7361-6b65-0001-000000000004")
    private var descriptor: StreamDescriptor?
    private var audioCharacteristic: CBCharacteristic?
    private var diagnosticsCharacteristic: CBCharacteristic?
    private var handshakeBegan: TimeInterval?
    private var lastNotificationUptime: TimeInterval?
    private var lastDiagnosticsUptime: TimeInterval = 0
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
        guard settings.dreamAIStreaming, !liveStreamBuffer.isEmpty else { return }
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
                if self.running, now - self.lastDiagnosticsUptime >= 10,
                   let peripheral = self.peripheral, peripheral.state == .connected,
                   let characteristic = self.diagnosticsCharacteristic {
                    self.lastDiagnosticsUptime = now
                    peripheral.readValue(for: characteristic)
                }
                // Flush live stream if 2+ seconds since last flush
                if self.settings.dreamAIStreaming && !self.liveStreamBuffer.isEmpty &&
                   now - self.lastLiveStreamFlush >= 2.0 {
                    self.flushLiveStream()
                }
            } catch { self.fail(error) }
        }
        logger.info("PendantReceiver initialized", category: "ble")
    }

    func start() {
        running = true
        UserDefaults.standard.set(true, forKey: "captureWanted")
        logger.info("Capture started by user", category: "ble")
        connect()
    }

    func stop() {
        running = false
        UserDefaults.standard.set(false, forKey: "captureWanted")
        lastNotificationUptime = nil
        handshakeBegan = nil
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        do { try store.checkpointNow(); status = "Stopped — queued uploads continue" }
        catch { status = error.localizedDescription }
        checkpointed?()
        logger.info("Capture stopped by user", category: "ble")
    }

    private func fail(_ error: Error) {
        stop()
        status = "Capture stopped: \(error.localizedDescription)"
        logger.error("Capture failed: \(error.localizedDescription)", category: "ble")
    }

    private func recoverConnection(_ error: Error) {
        guard running else { return }
        status = "Bluetooth error — reconnecting: \(error.localizedDescription)"
        handshakeBegan = nil
        lastNotificationUptime = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        logger.warning("Connection recovery: \(error.localizedDescription)", category: "ble")
    }

    private func connect() {
        guard running else { return }
        guard central.state == .poweredOn else { status = "Waiting for Bluetooth permission / power"; return }
        if let peripheral {
            if peripheral.state == .connected { discover(peripheral) }
            else if peripheral.state != .connecting { status = "Reconnecting"; central.connect(peripheral) }
        } else if let saved = UserDefaults.standard.string(forKey: "peripheralID"),
                  let uuid = UUID(uuidString: saved),
                  let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripheral = known; known.delegate = self
            status = "Reconnecting"; central.connect(known)
        } else {
            status = "Scanning for Keepsake pendant"
            central.scanForPeripherals(withServices: [service])
            logger.info("Scanning for pendant", category: "ble")
        }
    }

    func forget() {
        stop()
        if let peripheral {
            UserDefaults.standard.removeObject(forKey: "streamInfo." + peripheral.identifier.uuidString)
        }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: "peripheralID")
        status = "Device forgotten"
        logger.info("Device forgotten — will scan for new device", category: "ble")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Bluetooth state: \(central.state.rawValue)", category: "ble")
        if central.state == .poweredOn { connect() }
        else {
            do { try store.checkpointNow() } catch { fail(error); return }
            status = central.state == .unauthorized ? "Allow Bluetooth in Settings" : "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored; restored.delegate = self
        logger.info("Bluetooth state restored", category: "ble")
        if !running { central.cancelPeripheralConnection(restored) }
        else if restored.state == .connected {
            // A restored subscription can deliver before discovery finishes. Use only
            // its previously verified descriptor; a new connection verifies afresh.
            if let data = UserDefaults.standard.data(forKey: "streamInfo." + restored.identifier.uuidString),
               let known = try? StreamDescriptor(data) { descriptor = known }
            else { fail(GatewayError.message("Restored stream has no verified format. Start capture again.")) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running && self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "peripheralID")
        status = "Connecting"
        logger.info("Discovered \(peripheral.name ?? "unknown") RSSI=\(RSSI)", category: "ble")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running else { central.cancelPeripheralConnection(peripheral); return }
        descriptor = nil
        audioCharacteristic = nil
        diagnosticsCharacteristic = nil
        lastNotificationUptime = nil
        sessionID = UUID().uuidString.lowercased()
        liveStats = PacketStats()
        stats = liveStats
        logger.info("Connected to \(peripheral.name ?? "pendant")", category: "ble")
        discover(peripheral)
    }

    private func discover(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        deviceName = peripheral.name ?? "Keepsake pendant"
        handshakeBegan = ProcessInfo.processInfo.systemUptime
        status = "Discovering audio stream"
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Connection failed; retrying"
        logger.warning("Connection failed: \(error?.localizedDescription ?? "unknown")", category: "ble")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        descriptor = nil
        audioCharacteristic = nil
        diagnosticsCharacteristic = nil
        lastNotificationUptime = nil
        handshakeBegan = nil
        do { try store.checkpointNow() } catch { fail(error); return }
        checkpointed?()
        logger.info("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")", category: "ble")
        if running {
            status = "Disconnected — reconnecting; missed device audio cannot be recovered"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { recoverConnection(error); return }
        guard let found = peripheral.services?.first(where: { $0.uuid == service }) else {
            fail(GatewayError.message("Pendant service missing")); return
        }
        peripheral.discoverCharacteristics([audio, info, diagnostics], for: found)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { recoverConnection(error); return }
        guard let found = service.characteristics?.first(where: { $0.uuid == audio }) else {
            fail(GatewayError.message("Audio characteristic missing")); return
        }
        audioCharacteristic = found
        diagnosticsCharacteristic = service.characteristics?.first(where: { $0.uuid == diagnostics })
        guard let format = service.characteristics?.first(where: { $0.uuid == info }) else {
            fail(GatewayError.message("Firmware has no stream descriptor. Flash the new Keepsake raw firmware first.")); return
        }
        if running { peripheral.readValue(for: format) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { recoverConnection(error); return }
        handshakeBegan = nil
        lastNotificationUptime = characteristic.isNotifying ? ProcessInfo.processInfo.systemUptime : nil
        status = characteristic.isNotifying ? "Receiving raw packets" : "Notifications stopped"
        logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled")", category: "ble")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running else { return }
        if characteristic.uuid == diagnostics {
            guard error == nil, let data = characteristic.value else { return }
            let b = Array(data)
            if b.count == 20 && Array(b[0..<4]) == Array("KST1".utf8) {
                func u32(_ n: Int) -> UInt32 {
                    UInt32(b[n]) | UInt32(b[n+1]) << 8 | UInt32(b[n+2]) << 16 | UInt32(b[n+3]) << 24
                }
                firmwareDiagnostics = "Boot counters: queue drops \(u32(4)), TX drops \(u32(8)), mic restarts \(u32(12)); reset flags 0x\(String(u32(16), radix: 16))"
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
                UserDefaults.standard.set(data, forKey: "streamInfo." + peripheral.identifier.uuidString)
                streamDescription = "\(format.sampleRate) Hz · mono PCM16 · \(format.blockMilliseconds) ms blocks"
                logger.info("Stream format: \(streamDescription)", category: "ble")
                if let audioCharacteristic { peripheral.setNotifyValue(true, for: audioCharacteristic) }
            } catch { fail(error) }
            return
        }
        guard characteristic.uuid == audio else { return }
        guard let descriptor else {
            fail(GatewayError.message("Audio arrived without a verified firmware format.")); return
        }
        lastNotificationUptime = ProcessInfo.processInfo.systemUptime
        do {
            try store.append(data, deviceID: peripheral.identifier.uuidString,
                             sessionID: sessionID, sampleRate: descriptor.sampleRate,
                             checkpoint: settings.checkpoint, streamInfo: descriptor.raw)
            liveStats.observe(data)
            if settings.dreamAIStreaming && data.count > 5 {
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
}
