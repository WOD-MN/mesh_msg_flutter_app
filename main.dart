import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:animations/animations.dart';
import 'package:fl_chart/fl_chart.dart';

// ==================== DATA MODELS ====================
part 'models.g.dart';

@HiveType(typeId: 0)
class User {
  @HiveField(0)
  String id;
  
  @HiveField(1)
  String username;
  
  @HiveField(2)
  DateTime createdAt;
  
  User({required this.id, required this.username, required this.createdAt});
}

@HiveType(typeId: 1)
class Channel {
  @HiveField(0)
  String id;
  
  @HiveField(1)
  String name;
  
  @HiveField(2)
  bool isPrivate;
  
  @HiveField(3)
  List<String> memberIds;
  
  @HiveField(4)
  DateTime createdAt;
  
  Channel({
    required this.id,
    required this.name,
    this.isPrivate = false,
    required this.memberIds,
    required this.createdAt,
  });
}

@HiveType(typeId: 2)
class Message {
  @HiveField(0)
  String id;
  
  @HiveField(1)
  String channelId;
  
  @HiveField(2)
  String senderId;
  
  @HiveField(3)
  String senderName;
  
  @HiveField(4)
  String content;
  
  @HiveField(5)
  DateTime timestamp;
  
  @HiveField(6)
  MessageStatus status;
  
  @HiveField(7)
  int? hopCount;
  
  Message({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.timestamp,
    this.status = MessageStatus.pending,
    this.hopCount,
  });
}

enum MessageStatus {
  pending,
  delivered,
  failed,
  acknowledged,
}

@HiveType(typeId: 3)
class Neighbor {
  @HiveField(0)
  String deviceId;
  
  @HiveField(1)
  int rssi;
  
  @HiveField(2)
  DateTime lastSeen;
  
  @HiveField(3)
  String? username;
  
  Neighbor({
    required this.deviceId,
    required this.rssi,
    required this.lastSeen,
    this.username,
  });
}

// ==================== PROVIDERS ====================
class AppState extends ChangeNotifier {
  late Box<User> _userBox;
  late Box<Channel> _channelBox;
  late Box<Message> _messageBox;
  late Box<Neighbor> _neighborBox;
  
  User? _currentUser;
  Channel? _selectedChannel;
  bool _isDarkMode = false;
  
  // BLE State
  BluetoothDevice? _connectedDevice;
  bool _isConnected = false;
  int _connectionQuality = 0; // 0-100
  
  AppState() {
    _initBoxes();
  }
  
  Future<void> _initBoxes() async {
    await Hive.initFlutter();
    Hive.registerAdapter(UserAdapter());
    Hive.registerAdapter(ChannelAdapter());
    Hive.registerAdapter(MessageAdapter());
    Hive.registerAdapter(NeighborAdapter());
    
    _userBox = await Hive.openBox<User>('users');
    _channelBox = await Hive.openBox<Channel>('channels');
    _messageBox = await Hive.openBox<Message>('messages');
    _neighborBox = await Hive.openBox<Neighbor>('neighbors');
    
    // Create default user if none exists
    if (_userBox.isEmpty) {
      final user = User(
        id: const Uuid().v4(),
        username: 'User${DateTime.now().millisecondsSinceEpoch % 1000}',
        createdAt: DateTime.now(),
      );
      await _userBox.put('current_user', user);
    }
    
    _currentUser = _userBox.get('current_user');
    
    // Create default channel
    if (_channelBox.isEmpty) {
      final channel = Channel(
        id: 'public',
        name: '🌍 Public Mesh',
        isPrivate: false,
        memberIds: [],
        createdAt: DateTime.now(),
      );
      await _channelBox.put(channel.id, channel);
    }
    
    notifyListeners();
  }
  
  // Getters
  User? get currentUser => _currentUser;
  Channel? get selectedChannel => _selectedChannel;
  bool get isDarkMode => _isDarkMode;
  bool get isConnected => _isConnected;
  int get connectionQuality => _connectionQuality;
  
  List<Channel> get channels => _channelBox.values.toList();
  List<Message> get messages => _messageBox.values.toList();
  List<Neighbor> get neighbors {
    final now = DateTime.now();
    // Remove stale neighbors (not seen for 5 minutes)
    final active = _neighborBox.values.where((n) => now.difference(n.lastSeen).inMinutes < 5).toList();
    active.sort((a, b) => b.rssi.compareTo(a.rssi));
    return active;
  }
  
  List<Message> getChannelMessages(String channelId) {
    return _messageBox.values
        .where((m) => m.channelId == channelId)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }
  
  // Actions
  void setTheme(bool darkMode) {
    _isDarkMode = darkMode;
    notifyListeners();
  }
  
  void setSelectedChannel(Channel channel) {
    _selectedChannel = channel;
    notifyListeners();
  }
  
  void updateConnectionState(bool connected, int quality) {
    _isConnected = connected;
    _connectionQuality = quality;
    notifyListeners();
  }
  
  Future<void> sendMessage(String content) async {
    if (_selectedChannel == null || _currentUser == null) return;
    
    final message = Message(
      id: const Uuid().v4(),
      channelId: _selectedChannel!.id,
      senderId: _currentUser!.id,
      senderName: _currentUser!.username,
      content: content,
      timestamp: DateTime.now(),
      status: MessageStatus.pending,
    );
    
    await _messageBox.put(message.id, message);
    notifyListeners();
  }
  
  Future<void> updateMessageStatus(String messageId, MessageStatus status) async {
    final message = _messageBox.get(messageId);
    if (message != null) {
      message.status = status;
      await _messageBox.put(messageId, message);
      notifyListeners();
    }
  }
  
  Future<void> addOrUpdateNeighbor(String deviceId, int rssi, String? username) async {
    final neighbor = Neighbor(
      deviceId: deviceId,
      rssi: rssi,
      lastSeen: DateTime.now(),
      username: username,
    );
    await _neighborBox.put(deviceId, neighbor);
    notifyListeners();
  }
  
  Future<void> createChannel(String name, bool isPrivate) async {
    final channel = Channel(
      id: const Uuid().v4(),
      name: name,
      isPrivate: isPrivate,
      memberIds: [_currentUser!.id],
      createdAt: DateTime.now(),
    );
    await _channelBox.put(channel.id, channel);
    notifyListeners();
  }
  
  Future<void> updateUsername(String newUsername) async {
    if (_currentUser != null) {
      _currentUser!.username = newUsername;
      await _userBox.put('current_user', _currentUser!);
      notifyListeners();
    }
  }
}

// ==================== BLE SERVICE ====================
class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  
  final String uartServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String uartTxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  final String uartRxUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
  
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  
  Timer? _healthCheckTimer;
  Timer? _beaconTimer;
  
  final _messageController = StreamController<String>.broadcast();
  Stream<String> get messages => _messageController.stream;
  
  BleService._internal();
  
  Future<void> startScan() async {
    await _requestPermissions();
    
    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [Guid(uartServiceUuid)],
    );
    
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      // Filter and notify UI
    });
  }
  
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }
  
  Future<bool> connect(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevice = device;
      
      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.str16.toLowerCase() == uartServiceUuid.replaceAll("-", "").toLowerCase()) {
          for (var char in service.characteristics) {
            if (char.uuid.str16.toLowerCase() == uartTxUuid.replaceAll("-", "").toLowerCase()) {
              _txCharacteristic = char;
              await char.setNotifyValue(true);
              _notificationSubscription = char.onValueReceived.listen(_onMessageReceived);
            } else if (char.uuid.str16.toLowerCase() == uartRxUuid.replaceAll("-", "").toLowerCase()) {
              _rxCharacteristic = char;
            }
          }
        }
      }
      
      _startHealthCheck();
      return true;
    } catch (e) {
      log('Connection error: $e');
      return false;
    }
  }
  
  void _onMessageReceived(List<int> data) {
    final message = utf8.decode(data);
    _messageController.add(message);
  }
  
  Future<void> sendMessage(String message) async {
    if (_rxCharacteristic != null && _connectedDevice != null) {
      await _rxCharacteristic!.write(utf8.encode(message));
    }
  }
  
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_connectedDevice != null) {
        _connectedDevice!.readRssi().then((rssi) {
          final quality = _rssiToQuality(rssi);
          // Notify app state
        });
      }
    });
  }
  
  int _rssiToQuality(int rssi) {
    if (rssi >= -50) return 100;
    if (rssi >= -60) return 75;
    if (rssi >= -70) return 50;
    if (rssi >= -80) return 25;
    return 0;
  }
  
  void disconnect() {
    _healthCheckTimer?.cancel();
    _beaconTimer?.cancel();
    _notificationSubscription?.cancel();
    _connectionSubscription?.cancel();
    _connectedDevice?.disconnect();
    _connectedDevice = null;
  }
}

// ==================== APP ENTRY ====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  
  // Register adapters
  Hive.registerAdapter(UserAdapter());
  Hive.registerAdapter(ChannelAdapter());
  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(NeighborAdapter());
  
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const OffGridMessengerApp(),
    ),
  );
}

class OffGridMessengerApp extends StatelessWidget {
  const OffGridMessengerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    
    return MaterialApp(
      title: 'Off-Grid Mesh',
      themeMode: appState.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

// ==================== SCREENS ====================
class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  
  final List<Widget> _screens = [
    const ChatTab(),
    const NeighborsTab(),
    const ChannelsTab(),
  ];

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Off-Grid Mesh'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(appState.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => appState.setTheme(!appState.isDarkMode),
          ),
          IconButton(
            icon: Icon(appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
            color: appState.isConnected ? Colors.green : Colors.red,
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BleScanScreen())),
          ),
        ],
      ),
      body: _screens[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.network_wifi_3_bar), label: 'Mesh'),
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Channels'),
        ],
      ),
    );
  }
}

class ChatTab extends StatefulWidget {
  const ChatTab({Key? key}) : super(key: key);

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final TextEditingController _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final messages = appState.getChannelMessages(appState.selectedChannel?.id ?? 'public');
    
    return Column(
      children: [
        // Connection Bar
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: appState.isConnected ? Colors.green.shade100 : Colors.red.shade100,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Icon(appState.isConnected ? Icons.check_circle : Icons.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  appState.isConnected 
                      ? 'Connected (${appState.connectionQuality}%)' 
                      : 'Disconnected - Tap Bluetooth icon to connect',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        
        // Channel Header
        if (appState.selectedChannel != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Theme.of(context).primaryColor,
                  child: Text(appState.selectedChannel!.name.substring(0, 1)),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appState.selectedChannel!.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${appState.selectedChannel!.memberIds.length} members',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        
        // Messages List
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.satellite_alt, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(
                        'No messages yet',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Start the conversation in the mesh',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    return _MessageBubble(message: message);
                  },
                ),
        ),
        
        // Message Input
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    hintText: 'Type message...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceVariant,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(appState),
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton(
                onPressed: () => _sendMessage(appState),
                child: const Icon(Icons.send),
                mini: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  void _sendMessage(AppState appState) {
    if (_controller.text.trim().isEmpty) return;
    appState.sendMessage(_controller.text.trim());
    _controller.clear();
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  
  const _MessageBubble({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final isMe = message.senderId == appState.currentUser?.id;
    final time = DateFormat.Hm().format(message.timestamp);
    
    return Container(
      margin: EdgeInsets.only(
        left: isMe ? 48 : 16,
        right: isMe ? 16 : 48,
        top: 4,
        bottom: 4,
      ),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!isMe)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                message.senderName,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Row(
            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (isMe) ...[
                _buildStatusIcon(message.status),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMe 
                        ? Theme.of(context).primaryColor 
                        : Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(20).copyWith(
                      bottomRight: isMe ? const Radius.circular(4) : null,
                      bottomLeft: isMe ? null : const Radius.circular(4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.content,
                        style: TextStyle(
                          color: isMe ? Colors.white : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 10,
                              color: (isMe ? Colors.white : Colors.grey).withOpacity(0.7),
                            ),
                          ),
                          if (message.hopCount != null) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.network_wifi_3_bar,
                              size: 10,
                              color: (isMe ? Colors.white : Colors.grey).withOpacity(0.7),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${message.hopCount} hops',
                              style: TextStyle(
                                fontSize: 10,
                                color: (isMe ? Colors.white : Colors.grey).withOpacity(0.7),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildStatusIcon(MessageStatus status) {
    IconData icon;
    Color color;
    
    switch (status) {
      case MessageStatus.pending:
        icon = Icons.schedule;
        color = Colors.grey;
        break;
      case MessageStatus.delivered:
        icon = Icons.check;
        color = Colors.grey;
        break;
      case MessageStatus.acknowledged:
        icon = Icons.done_all;
        color = Colors.blue;
        break;
      case MessageStatus.failed:
        icon = Icons.error;
        color = Colors.red;
        break;
    }
    
    return Icon(icon, size: 16, color: color);
  }
}

class NeighborsTab extends StatelessWidget {
  const NeighborsTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final neighbors = appState.neighbors;
    
    return Scaffold(
      body: neighbors.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.network_wifi_3_bar, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No neighbors detected',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Move closer to other nodes in the mesh',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: neighbors.length,
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final neighbor = neighbors[index];
                return _NeighborCard(neighbor: neighbor);
              },
            ),
    );
  }
}

class _NeighborCard extends StatelessWidget {
  final Neighbor neighbor;
  
  const _NeighborCard({Key? key, required this.neighbor}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final signalPercent = (neighbor.rssi + 100).clamp(0, 100);
    final signalColor = signalPercent > 70 ? Colors.green : signalPercent > 40 ? Colors.orange : Colors.red;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Theme.of(context).primaryColor.withOpacity(0.2),
              child: Text(
                neighbor.username?.substring(0, 1).toUpperCase() ?? '?',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    neighbor.username ?? 'Unknown User',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    neighbor.deviceId,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    Icon(Icons.signal_cellular_alt, color: signalColor, size: 20),
                    const SizedBox(width: 4),
                    Text(
                      '${signalPercent.toStringAsFixed(0)}%',
                      style: TextStyle(color: signalColor, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${neighbor.rssi} dBm',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ChannelsTab extends StatelessWidget {
  const ChannelsTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateChannelDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Create Channel'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: appState.channels.length,
        itemBuilder: (context, index) {
          final channel = appState.channels[index];
          final messageCount = appState.getChannelMessages(channel.id).length;
          
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: channel.isPrivate ? Colors.deepPurple : Colors.blue,
                child: Icon(channel.isPrivate ? Icons.lock : Icons.public),
              ),
              title: Text(channel.name),
              subtitle: Text('$messageCount messages'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                appState.setSelectedChannel(channel);
                // Switch to chat tab
                (context as Element).markNeedsBuild();
              },
            ),
          );
        },
      ),
    );
  }
  
  void _showCreateChannelDialog(BuildContext context) {
    final appState = Provider.of<AppState>(context, listen: false);
    final controller = TextEditingController();
    bool isPrivate = false;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Channel Name',
                hintText: 'e.g., Emergency Coordination',
              ),
            ),
            const SizedBox(height: 16),
            StatefulBuilder(
              builder: (context, setState) => SwitchListTile(
                title: const Text('Private Channel'),
                value: isPrivate,
                onChanged: (value) => setState(() => isPrivate = value),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                appState.createChannel(controller.text.trim(), isPrivate);
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class BleScanScreen extends StatefulWidget {
  const BleScanScreen({Key? key}) : super(key: key);

  @override
  State<BleScanScreen> createState() => _BleScanScreenState();
}

class _BleScanScreenState extends State<BleScanScreen> {
  final BleService _bleService = BleService();
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  
  @override
  void initState() {
    super.initState();
    _startScan();
  }
  
  void _startScan() {
    setState(() => _isScanning = true);
    
    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [Guid(_bleService.uartServiceUuid)],
    );
    
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _scanResults = results;
      });
    });
    
    FlutterBluePlus.isScanning.listen((scanning) {
      setState(() => _isScanning = scanning);
    });
  }
  
  void _stopScan() {
    FlutterBluePlus.stopScan();
  }
  
  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to Gateway'),
        actions: [
          IconButton(
            icon: Icon(_isScanning ? Icons.stop : Icons.refresh),
            onPressed: _isScanning ? _stopScan : _startScan,
          ),
        ],
      ),
      body: _scanResults.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_isScanning ? 'Scanning...' : 'No devices found'),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final result = _scanResults[index];
                final device = result.device;
                final name = device.platformName.isNotEmpty 
                    ? device.platformName 
                    : 'LoRa Gateway';
                
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.router_outlined, size: 32),
                    title: Text(name),
                    subtitle: Text('MAC: ${device.remoteId}\nRSSI: ${result.rssi} dBm'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.bluetooth),
                    onTap: () async {
                      final connected = await _bleService.connect(device);
                      if (connected && mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ Connected successfully'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}
