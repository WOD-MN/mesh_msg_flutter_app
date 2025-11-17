#include <Arduino.h>
#include <NimBLEDevice.h>
#include <RadioLib.h>
#include <ArduinoJson.h>

// ==================== CONFIGURATION ====================
#define DEVICE_NAME "Mesh_Gateway_V3"
#define UART_SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define UART_TX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define UART_RX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

#define BEACON_INTERVAL    30000  // 30 seconds
#define MESSAGE_TIMEOUT    60000  // 60 seconds
#define MAX_HOPS           7
#define MAX_MESSAGE_AGE    300000 // 5 minutes

// Heltec V3 Pins
SX1262 radio = new Module(8, 14, 12, 13);

// ==================== DATA STRUCTURES ====================
struct Message {
  String id;
  String channel;
  String senderId;
  String senderName;
  String content;
  long timestamp;
  int hopCount;
  String type; // "message", "ack", "beacon"
};

struct Neighbor {
  String deviceId;
  int rssi;
  long lastSeen;
  String username;
};

struct RoutingEntry {
  String destination;
  String nextHop;
  int hopCount;
  long lastUpdated;
};

// ==================== GLOBALS ====================
NimBLEServer *pServer;
NimBLEService *pUartService;
NimBLECharacteristic *pTxCharacteristic;
NimBLECharacteristic *pRxCharacteristic;

bool deviceConnected = false;
std::string bleMessageBuffer = "";

std::vector<Message> messageQueue;
std::vector<String> processedMessageIds;
std::vector<Neighbor> neighbors;
std::vector<RoutingEntry> routingTable;

unsigned long lastBeacon = 0;
unsigned long lastRoutingCleanup = 0;

// Device identity
String deviceId = "";
String username = "Gateway";

// ==================== BLE CALLBACKS ====================
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    deviceConnected = true;
    Serial.println("✅ Client connected");
    pServer->stopAdvertising();
  }
  
  void onDisconnect(NimBLEServer* pServer) {
    deviceConnected = false;
    Serial.println("❌ Client disconnected");
    pServer->startAdvertising();
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string data = pCharacteristic->getValue();
    if (data.length() > 0) {
      bleMessageBuffer = data;
      Serial.printf("📱 BLE Rx: %s\n", bleMessageBuffer.c_str());
      parseAndProcessBleMessage(String(bleMessageBuffer.c_str()));
    }
  }
};

// ==================== LORA & MESH LOGIC ====================
void initLoRa() {
  Serial.print("Initializing LoRa...");
  int state = radio.begin(866.0, 125.0, 7, 5, 0x12, 10);
  
  if (state != RADIOLIB_ERR_NONE) {
    Serial.println(" failed!");
    while(true) {
      digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
      delay(100);
    }
  }
  
  radio.setPreambleLength(8);
  Serial.println(" OK!");
}

void sendLoRaMessage(const Message& msg) {
  JsonDocument doc;
  doc["id"] = msg.id;
  doc["channel"] = msg.channel;
  doc["senderId"] = msg.senderId;
  doc["senderName"] = msg.senderName;
  doc["content"] = msg.content;
  doc["timestamp"] = msg.timestamp;
  doc["hopCount"] = msg.hopCount;
  doc["type"] = msg.type;
  
  String jsonString;
  serializeJson(doc, jsonString);
  
  Serial.printf("📡 LoRa Tx: %s (hops: %d)\n", msg.content.c_str(), msg.hopCount);
  int state = radio.transmit(jsonString.c_str());
  
  if (state == RADIOLIB_ERR_NONE) {
    digitalWrite(LED_BUILTIN, HIGH);
    delay(50);
    digitalWrite(LED_BUILTIN, LOW);
  }
}

void checkIncomingLoRa() {
  char buffer[256];
  int state = radio.receive(buffer, sizeof(buffer));
  
  if (state == RADIOLIB_ERR_NONE) {
    Serial.printf("📡 LoRa Rx: %s\n", buffer);
    parseLoRaMessage(String(buffer));
  }
}

void parseLoRaMessage(const String& jsonString) {
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, jsonString);
  
  if (error) return;
  
  Message msg;
  msg.id = doc["id"] | "";
  msg.channel = doc["channel"] | "public";
  msg.senderId = doc["senderId"] | "";
  msg.senderName = doc["senderName"] | "Unknown";
  msg.content = doc["content"] | "";
  msg.timestamp = doc["timestamp"] | millis();
  msg.hopCount = doc["hopCount"] | 0;
  msg.type = doc["type"] | "message";
  
  // Check if already processed
  if (isMessageProcessed(msg.id)) return;
  
  // Update routing table
  updateRoutingTable(msg.senderId, msg.senderId, 0);
  
  // Process based on type
  if (msg.type == "message") {
    if (msg.hopCount < MAX_HOPS) {
      addToMessageQueue(msg);
      forwardMessage(msg);
    }
  } else if (msg.type == "beacon") {
    updateNeighbor(msg.senderId, msg.senderName);
  } else if (msg.type == "ack") {
    // Forward ack to source
    if (msg.senderId != deviceId) {
      forwardMessage(msg);
    }
  }
  
  markMessageProcessed(msg.id);
}

void addToMessageQueue(const Message& msg) {
  messageQueue.push_back(msg);
  if (deviceConnected) {
    sendToBleClient(msg);
  }
}

void sendToBleClient(const Message& msg) {
  if (deviceConnected && pTxCharacteristic) {
    JsonDocument doc;
    doc["id"] = msg.id;
    doc["channel"] = msg.channel;
    doc["sender"] = msg.senderName;
    doc["content"] = msg.content;
    
    String jsonString;
    serializeJson(doc, jsonString);
    
    pTxCharacteristic->setValue(jsonString.c_str());
    pTxCharacteristic->notify();
  }
}

void forwardMessage(const Message& msg) {
  if (msg.hopCount >= MAX_HOPS) return;
  
  Message forwardMsg = msg;
  forwardMsg.hopCount++;
  
  sendLoRaMessage(forwardMsg);
}

void parseAndProcessBleMessage(const String& jsonString) {
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, jsonString);
  
  if (error) return;
  
  String type = doc["type"] | "message";
  
  if (type == "message") {
    Message msg;
    msg.id = doc["id"] | String(millis());
    msg.channel = doc["channel"] | "public";
    msg.senderId = doc["senderId"] | deviceId;
    msg.senderName = doc["senderName"] | username;
    msg.content = doc["content"] | "";
    msg.timestamp = millis();
    msg.hopCount = 0;
    msg.type = "message";
    
    sendLoRaMessage(msg);
    
    // Send ack
    sendAckMessage(msg.id, msg.senderId);
  } else if (type == "update_username") {
    username = doc["username"] | "Gateway";
  }
}

void sendAckMessage(const String& messageId, const String& targetId) {
  Message ack;
  ack.id = "ack_" + String(millis());
  ack.channel = "system";
  ack.senderId = deviceId;
  ack.senderName = username;
  ack.content = messageId;
  ack.timestamp = millis();
  ack.hopCount = 0;
  ack.type = "ack";
  
  sendLoRaMessage(ack);
}

void updateNeighbor(const String& id, const String& name) {
  bool found = false;
  for (auto& neighbor : neighbors) {
    if (neighbor.deviceId == id) {
      neighbor.lastSeen = millis();
      neighbor.username = name;
      found = true;
      break;
    }
  }
  
  if (!found) {
    Neighbor newNeighbor;
    newNeighbor.deviceId = id;
    newNeighbor.rssi = radio.getRSSI();
    newNeighbor.lastSeen = millis();
    newNeighbor.username = name;
    neighbors.push_back(newNeighbor);
  }
}

void updateRoutingTable(const String& dest, const String& nextHop, int hops) {
  for (auto& entry : routingTable) {
    if (entry.destination == dest) {
      entry.lastUpdated = millis();
      if (hops < entry.hopCount) {
        entry.nextHop = nextHop;
        entry.hopCount = hops;
      }
      return;
    }
  }
  
  RoutingEntry newEntry;
  newEntry.destination = dest;
  newEntry.nextHop = nextHop;
  newEntry.hopCount = hops;
  newEntry.lastUpdated = millis();
  routingTable.push_back(newEntry);
}

void sendBeacon() {
  if (millis() - lastBeacon < BEACON_INTERVAL) return;
  
  Message beacon;
  beacon.id = "beacon_" + String(millis());
  beacon.channel = "system";
  beacon.senderId = deviceId;
  beacon.senderName = username;
  beacon.content = "BEACON";
  beacon.timestamp = millis();
  beacon.hopCount = 0;
  beacon.type = "beacon";
  
  sendLoRaMessage(beacon);
  lastBeacon = millis();
}

void cleanupOldData() {
  unsigned long now = millis();
  
  // Cleanup neighbors
  neighbors.erase(std::remove_if(neighbors.begin(), neighbors.end(),
    [now](const Neighbor& n) {
      return (now - n.lastSeen) > BEACON_INTERVAL * 2;
    }), neighbors.end());
  
  // Cleanup routing table
  routingTable.erase(std::remove_if(routingTable.begin(), routingTable.end(),
    [now](const RoutingEntry& r) {
      return (now - r.lastUpdated) > MESSAGE_TIMEOUT;
    }), routingTable.end());
  
  // Cleanup processed message IDs
  if (processedMessageIds.size() > 100) {
    processedMessageIds.erase(processedMessageIds.begin(), processedMessageIds.begin() + 50);
  }
}

bool isMessageProcessed(const String& id) {
  return std::find(processedMessageIds.begin(), processedMessageIds.end(), id) != processedMessageIds.end();
}

void markMessageProcessed(const String& id) {
  processedMessageIds.push_back(id);
}

// ==================== SETUP ====================
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== Heltec Mesh Gateway ===");
  
  // Generate device ID
  uint32_t chipId = ESP.getEfuseMac();
  deviceId = "Heltec_" + String((uint16_t)chipId);
  Serial.println("Device ID: " + deviceId);
  
  // Initialize LED
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
  
  // Initialize LoRa
  initLoRa();
  
  // Initialize BLE
  NimBLEDevice::init(DEVICE_NAME);
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  
  pUartService = pServer->createService(UART_SERVICE_UUID);
  
  pTxCharacteristic = pUartService->createCharacteristic(
    UART_TX_UUID,
    NIMBLE_PROPERTY::NOTIFY
  );
  
  pRxCharacteristic = pUartService->createCharacteristic(
    UART_RX_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pRxCharacteristic->setCallbacks(new RxCallbacks());
  
  pUartService->start();
  
  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(UART_SERVICE_UUID);
  pAdvertising->start();
  
  Serial.println("✅ BLE advertising");
  Serial.println("📡 Frequency: 866.0 MHz");
}

// ==================== LOOP ====================
void loop() {
  checkIncomingLoRa();
  sendBeacon();
  cleanupOldData();
  
  if (millis() % 1000 < 10) {
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN)); // Blink every second
  }
  
  delay(10);
}
