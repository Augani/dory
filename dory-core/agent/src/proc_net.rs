//! Parse the guest `/proc/net/{tcp,tcp6,udp,udp6}` tables to discover listening ports — how the host
//! learns which container ports to publish. Pure and testable on any host; the actual `/proc` read
//! lives in the dispatcher (empty on a non-Linux host, which is fine).

/// Every LISTENING socket in a `/proc/net/{tcp,udp}` table, as `(protocol, port)`.
///
/// A TCP listener is state `0x0A` (TCP_LISTEN); a UDP "listener" is a bound socket (state `0x07`).
/// The `local_address` column is `HEXIP:HEXPORT`; we take the port after the final colon.
pub fn parse_listeners(table: &str, protocol: &str) -> Vec<(String, u16)> {
    let listen_state: u8 = if protocol.starts_with("tcp") {
        0x0A
    } else {
        0x07
    };
    let mut out = Vec::new();
    for line in table.lines().skip(1) {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 4 {
            continue;
        }
        if u8::from_str_radix(cols[3], 16).unwrap_or(0) != listen_state {
            continue;
        }
        if let Some((_, port_hex)) = cols[1].rsplit_once(':') {
            if let Ok(port) = u16::from_str_radix(port_hex, 16) {
                if port != 0 {
                    out.push((protocol.to_string(), port));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Real /proc/net/tcp shape: header, then LISTEN (0A) x2 and one ESTABLISHED (01).
    const TCP: &str = "\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 12345 1 0 0
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 12346 1 0 0
   2: 0100007F:8AE2 0100007F:1F90 01 00000000:00000000 00:00000000 00000000 0 0 12347 1 0 0
";

    fn ports(table: &str, proto: &str) -> Vec<u16> {
        parse_listeners(table, proto)
            .into_iter()
            .map(|(_, p)| p)
            .collect()
    }

    #[test]
    fn tcp_returns_only_listening_ports() {
        assert_eq!(ports(TCP, "tcp"), vec![22, 8080]); // 0x0016, 0x1F90; the ESTABLISHED row skipped
    }

    #[test]
    fn tcp6_long_address_still_parses_the_port() {
        let tcp6 = "\
  sl  local_address                         remote_address                    st
   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A rest
";
        assert_eq!(ports(tcp6, "tcp"), vec![8080]);
    }

    #[test]
    fn udp_uses_the_bound_state() {
        let udp = "\
  sl  local_address rem_address   st
   0: 00000000:14E9 00000000:0000 07 rest
   1: 00000000:0035 00000000:0000 0A rest
";
        assert_eq!(ports(udp, "udp"), vec![0x14E9]); // only the bound (07) row
    }

    #[test]
    fn garbage_and_short_lines_ignored() {
        assert!(parse_listeners("header only\n", "tcp").is_empty());
        assert!(parse_listeners("hdr\nnot enough cols\n", "tcp").is_empty());
    }
}
