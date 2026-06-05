# LED Panel Controller Network Protocol

## Overview
The LED panel controller supports both UDP and TCP protocols for network-based control and configuration.

## Network Configuration
- **Default IP Address**: 192.168.1.100
- **Default MAC Address**: 00:11:22:33:44:55
- **UDP Command Port**: 4660 (0x1234)
- **TCP Configuration Port**: 4661 (0x1235)

## UDP Command Protocol

### Packet Structure
```
[UDP Header] [Command Data]
```

### Command Format
```
[Command Byte] [Address Bytes] [Data Bytes]
```

### Commands

#### 1. Write Pixel (0x01)
```
0x01 [Address LSB] [Address MSB] [Data LSB] [Data MSB]
```
- **Address**: 16-bit pixel address (little-endian)
- **Data**: 12-bit RGB color data (little-endian)

#### 2. Flip Buffer (0x02)
```
0x02
```
- Swaps the front and back buffers

#### 3. Read Pixel (0x03)
```
0x03 [Address LSB] [Address MSB]
```
- **Response**: Returns pixel data via TCP

#### 4. Set Brightness (0x04)
```
0x04 [Brightness]
```
- **Brightness**: 8-bit value (0-255)

#### 5. Set Display Mode (0x05)
```
0x05 [Mode]
```
- **Mode**: 0=Normal, 1=Test Pattern, 2=Off

### Example UDP Commands

#### Write a red pixel at address 100:
```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server_address = ('192.168.1.100', 4660)

# Red pixel at address 100
command = b'\x01\x64\x00\xF0\x0F'  # 0x01, addr=100, data=0xFF0 (red)
sock.sendto(command, server_address)
```

#### Flip the display buffers:
```python
command = b'\x02'  # Flip command
sock.sendto(command, server_address)
```

## TCP Configuration Protocol

### Connection
- **Port**: 4661
- **Protocol**: TCP
- **Authentication**: None (for simplicity)

### Configuration Commands

#### 1. Set IP Address
```
SET_IP <new_ip>
```

#### 2. Set UDP Port
```
SET_UDP_PORT <port>
```

#### 3. Set TCP Port
```
SET_TCP_PORT <port>
```

#### 4. Get Status
```
STATUS
```
**Response**: JSON status information

#### 5. Get Configuration
```
CONFIG
```
**Response**: Current network configuration

### Example TCP Configuration

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('192.168.1.100', 4661))

# Get status
sock.send(b'STATUS\n')
response = sock.recv(1024)
print(response.decode())

# Set new IP
sock.send(b'SET_IP 192.168.1.101\n')
response = sock.recv(1024)
print(response.decode())

sock.close()
```

## Status Response Format

### JSON Status Response
```json
{
  "device": "LED Panel Controller",
  "version": "1.0.0",
  "network": {
    "ip": "192.168.1.100",
    "mac": "00:11:22:33:44:55",
    "udp_port": 4660,
    "tcp_port": 4661,
    "link_up": true,
    "rx_packets": 1234,
    "tx_packets": 567,
    "rx_errors": 0
  },
  "display": {
    "width": 32,
    "height": 32,
    "color_depth": 4,
    "brightness": 255,
    "mode": "normal"
  },
  "memory": {
    "total_pixels": 1024,
    "buffer_status": "ready"
  }
}
```

## Security Considerations

### MAC Address Filtering
- Device only accepts packets with matching MAC address or broadcast
- Default MAC: 00:11:22:33:44:55

### Port Filtering
- Only processes packets on configured UDP/TCP ports
- Default UDP: 4660, TCP: 4661

### Rate Limiting
- Maximum 1000 commands per second
- Commands exceeding rate limit are dropped

## Error Handling

### UDP Errors
- Invalid commands are ignored
- Malformed packets are dropped
- No acknowledgment sent for errors

### TCP Errors
- Invalid commands return "ERROR: Invalid command"
- Connection errors return "ERROR: Connection failed"
- Configuration errors return "ERROR: Invalid parameter"

## Performance Considerations

### Latency
- UDP command processing: < 1ms
- TCP configuration: < 10ms
- Memory write operations: < 5ms

### Throughput
- Maximum UDP commands: 1000/second
- Maximum TCP connections: 10 concurrent
- Memory bandwidth: 100MB/s

## Implementation Notes

### Hardware Requirements
- **Ethernet PHY**: RMII interface
- **MAC Address**: Stored in configuration memory
- **IP Address**: DHCP or static configuration
- **Clock**: 50MHz for RMII interface

### Software Requirements
- **UDP Server**: Listens on configured port
- **TCP Server**: Handles configuration commands
- **Command Parser**: Validates and routes commands
- **Status Monitor**: Tracks network statistics

### Configuration Storage
- **MAC Address**: Factory programmed
- **IP Address**: DHCP or stored in flash
- **Port Numbers**: Stored in flash memory
- **Display Settings**: Stored in flash memory 