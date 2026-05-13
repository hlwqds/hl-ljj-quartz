# Chapter 48: Wireshark QUIC Debugging

## 48.1 Setting Up Wireshark for QUIC

Wireshark 3.4+ has native QUIC protocol support. To capture and decrypt QUIC traffic:

### 48.1.1 Capture Setup

```bash
# Capture on interface (requires root)
tshark -i eth0 -w quic-capture.pcap

# Or use tcpdump and analyze later
tcpdump -i eth0 -w quic-capture.pcap 'port 443'
```

### 48.1.2 Decryption Keys

Wireshark can decrypt QUIC if you provide the TLS key log:

```bash
# Set environment variable before running browser/app
export SSLKEYLOGFILE=/tmp/quic-keys.log

# Or in Wireshark: Edit -> Preferences -> Protocols -> TLS
# Add the keylog file path
```

For 0-RTT keys, you'll need early data keys as well.

## 48.2 QUIC Dissector Overview

When you open a QUIC capture:

```
Frame 1: 74 bytes on eth0
    1. QUIC Version: 0xff00001d (draft-34)
    2. Long Header Packet
    3. Source Connection ID: 0x7a3f...
    4. Destination Connection ID: 0x89c2...

Frame 1-5: QUIC Initial Handshake
Frame 6-10: QUIC Handshake (CRYPTO frames)
Frame 11+: QUIC 1-RTT (Short Header)
```

Wireshark's QUIC dissector parses:
- Packet headers (long/short)
- Frames (all types)
- CRYPTO content (TLS records)
- Stream data (HTTP/3, etc.)

## 48.3 Decoding the QUIC Header

### 48.3.1 Long Header Format

```
+--------------------------------------------------+
|  Header Form (1): 1 = Long                       |
|  Fixed Bit (1): 1 = Fixed                        |
|  Long Packet Type (2): 0x0 = Initial             |
|  Reserved Bits (2): 00                           |
|  Packet Number Length (2): 3 bytes              |
+--------------------------------------------------+
|                    Version (32)                  |
+--------------------------------------------------+
|    Destination Connection ID Length (8)        |
+--------------------------------------------------+
|      Destination Connection ID (0-160)          |
+--------------------------------------------------+
|      Source Connection ID Length (8)            |
+--------------------------------------------------+
|          Source Connection ID (0-160)           |
+--------------------------------------------------+
|                   Token (*)                     |
+--------------------------------------------------+
|                  Length (*)                     |
+--------------------------------------------------+
|              Packet Number (1-4)                |
+--------------------------------------------------+
|                   Payload (*)                   |
+--------------------------------------------------+
```

In Wireshark:

```
QUIC
    Header Form: 1 (Long)
    Fixed Bit: 1
    Long Packet Type: Initial (0)
    Reserved Bits: 0
    Packet Number Length: 3 bytes
    Version: 0xff00001d
    Destination Connection ID Length: 8
    Destination Connection ID: 89c2...
    Source Connection ID Length: 8
    Source Connection ID: 7a3f...
    Token Length: 0
    Length: 1201
    Packet Number: 0
    [Decrypted payload]
```

### 48.3.2 Short Header Format

```
+--------------------------------------------------+
|  Header Form (1): 0 = Short                     |
|  Fixed Bit (1): 1 = Fixed                        |
|  Spin Bit (1): 0 = latency sample               |
|  Reserved Bits (2): 00                           |
|  Packet Number Length (2): from encoder         |
+--------------------------------------------------+
|    Destination Connection ID (0-160)            |
+--------------------------------------------------+
|              Packet Number (1-4)                |
+--------------------------------------------------+
|                   Payload (*)                   |
+--------------------------------------------------+
```

## 48.4 Common Frame Types

### 48.4.1 PING Frame (Keepalive)

```
Frame
    Frame Type: PING (0x01)
    # Used to keep connection alive
    # Triggers ACK
```

### 48.4.2 ACK Frame

```
Frame
    Frame Type: ACK (0x02) or ACK_MAY (0x03)
    Largest Acknowledged: 1042
    ACK Delay: 23 (microseconds, scaled by PTO)
    ACK Range Count: 1
    First ACK Range: 50
    ACK Ranges:
        [1000..1042]
        [0..49]
```

Note: QUIC ACK ranges are in reverse order (largest first).

### 48.4.3 CRYPTO Frame

```
Frame
    Frame Type: CRYPTO (0x06)
    Offset: 0
    Length: 1180
    Crypto Data:
        TLS 1.3 Handshake:
            Handshake Type: Client Hello
            ...
```

### 48.4.4 STREAM Frame

```
Frame
    Frame Type: STREAM (0x08)
    Stream ID: 0
    Offset: 0
    Length: 1143
    Stream Data:
        HTTP/3:
            HEADERS Frame:
                ...
```

### 48.4.5 DATAGRAM Frame

```
Frame
    Frame Type: DATAGRAM (0x30)
    Datagram ID: 5
    Length: 512
    Datagram Data:
        [Raw application data]
```

## 48.5 HTTP/3 Over QUIC

When QUIC carries HTTP/3, Wireshark decodes the frames:

```
Frame 23: QUIC Short Header, 1-RTT
    QUIC
        Packet Number: 87
        Frames:
            STREAM Frame
                Stream ID: 0
                HTTP/3
                    Frame Type: HEADERS (0x01)
                    Headers:
                        :method: GET
                        :scheme: https
                        :authority: example.com
                        :path: /
                        user-agent: curl/...

Frame 24: QUIC Short Header, 1-RTT
    QUIC
        Packet Number: 88
        Frames:
            STREAM Frame
                Stream ID: 0
                HTTP/3
                    Frame Type: DATA (0x00)
                    Length: 1448
                    Data: "<!DOCTYPE html>..."
```

## 48.6 Filtering QUIC Traffic

### 48.6.1 Display Filters

```wireshark
# All QUIC traffic
quic

# By connection ID
quic.conn_id == 89c27a3f...

# By packet number
quic.packet_number == 42

# By frame type
quic.frame_type == STREAM

# By stream ID
quic.stream_id == 0

# HTTP/3 specific
http3

# All CRYPTO frames
quic.frame_type == CRYPTO

# Packets with PADDING
quic.padding
```

### 48.6.2 Capture Filters

```bash
# Capture only QUIC (UDP port 443)
port 443

# Capture specific server
host example.com and port 443
```

## 48.7 Debugging Connection Issues

### 48.7.1 Connection Establishment Failures

```
Symptom: Initial packets only, no further communication

Check:
1. Is this actually QUIC? (could be TCP/443)
   filter: quic || tcp.port == 443

2. Version mismatch?
   Look at Version field in Initial packet
   Check if server supports client's version

3. Stateless retry?
   Look for TOKEN in Initial
   Client should echo token in subsequent Initial

4. Crypto failure?
   Check CRYPTO frames for alerts
   Verify TLS keys logged correctly
```

### 48.7.2 Handshake Stalls

```
Symptom: Handshake completes Initial/Handshake but no 1-RTT

Common causes:
1. Server didn't receive Finished
   -> Check for 1-RTT packets from client

2. Certificate issues
   -> Look at CRYPTO frames for Certificate

3. ALPN mismatch
   -> Check crypto frames for alpn extension
```

### 48.7.3 Packet Loss Detection

In Wireshark:
```
# Check for gaps in packet numbers
Frame 1: Packet Number 0
Frame 2: Packet Number 1
Frame 3: Packet Number 2
Frame 5: Packet Number 4  <- Gap at 3!

# ACK processing
Frame 6: ACK for 0,1,2 <- Packet 3 was lost
```

### 48.7.4 Retransmission Detection

```
Same cryptographic data appears multiple times:
Frame 10: CRYPTO Offset 0, Length 1180
Frame 15: CRYPTO Offset 0, Length 1180  <- Retransmission

Look at "Frames加密" or similar field to verify
```

## 48.8 QUIC Statistics

Wireshark provides protocol statistics:

```
Statistics -> QUIC
    Connection Duration: 45.2 seconds
    Packets:
        Initial: 4
        Handshake: 6
        1-RTT: 892
    Bytes:
        Sent: 1.2 MB
        Received: 4.5 MB
    Lost Packets: 3
    Spurious: 0
    RTT:
        Min: 12ms
        Max: 45ms
        Avg: 18ms
```

## 48.9 Expert Information

Wireshark's Expert Information highlights issues:

```
Error:
    QUIC: Connection timed out
    QUIC: Invalid frame

Warning:
    QUIC: Lost packet
    QUIC: Negative acknowledgment

Note:
    QUIC: Connection migration detected
    QUIC: Path challenge received
```

## 48.10 Common QUIC Trace Analysis

### 48.10.1 Successful 1-RTT Handshake

```
Time    Src->Dst   Info
0.000   Client->Server  Initial, SCID=0x7a3f, DCID=0x89c2
0.018   Server->Client  Initial, SCID=0x89c2, DCID=0x7a3f
0.018   Server->Client  Handshake, ...
0.035   Client->Server  Handshake, Finished
0.052   Client->Server  1-RTT, STREAM: HTTP GET
0.068   Server->Client  1-RTT, STREAM: HTTP Response
```

### 48.10.2 Connection Migration

```
Before migration (WiFi):
Frame 1-50:  Client IP 192.168.1.100 -> Server, Short Header
Frame 51:    PATH_CHALLENGE (path 1)
Frame 52:    PATH_RESPONSE (cellular path validated)
Frame 53+:   Client IP 10.0.0.50 -> Server, Short Header

Wireshark shows:
    "Connection migration: address changed from 192.168.1.100 to 10.0.0.50"
```

### 48.10.3 0-RTT Resumption

```
Initial connection:
Time 0.000:  Initial + Early Data (0-RTT)
Time 0.018:  Initial + 0-RTT rejected (0-RTT not supported)
Time 0.018:  Handshake begins

With resumption support:
Time 0.000:  Initial + Early Data (0-RTT) [Same packets as before]
Time 0.018:  Initial + 0-RTT accepted
Time 0.035:  Handshake (0-RTT already done)
```

## 48.11 Summary

Wireshark is essential for QUIC debugging:

- **Setup**: Provide TLS key log for decryption
- **Headers**: Long/short header formats are fully decoded
- **Frames**: All frame types visible and filterable
- **HTTP/3**: Decoded automatically when keys available
- **Filters**: Powerful display and capture filters
- **Expert Info**: Quick identification of problems

Key debugging scenarios:
1. Version/ALPN mismatches in crypto frames
2. Packet loss via gaps in packet numbers
3. Retransmissions via duplicate CRYPTO offsets
4. Connection migration via address changes
5. 0-RTT acceptance/rejection in handshake

Practice with Wireshark on captured QUIC traces to build intuition for normal vs. problematic behavior.
