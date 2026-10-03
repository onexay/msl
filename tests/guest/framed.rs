#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn pair() -> (File, File) {
        let (a, b) = UnixStream::pair().unwrap();
        (File::from(std::os::fd::OwnedFd::from(a)), File::from(std::os::fd::OwnedFd::from(b)))
    }

    #[test]
    fn transfers_more_than_the_window_both_ways() {
        let (a, b) = pair();
        let (a_sink, a_b) = sender(a).unwrap();
        let (mut b_src, b_b) = receiver(b).unwrap();
        let payload: Vec<u8> = (0..(5 * WINDOW + 123)).map(|i| (i % 251) as u8).collect();
        let p2 = payload.clone();
        let t = std::thread::spawn(move || {
            let mut s = a_sink;
            s.write_all(&p2).unwrap();
        });
        let mut got = Vec::new();
        b_src.read_to_end(&mut got).unwrap();
        t.join().unwrap();
        assert_eq!(got, payload);
        a_b.done.recv().unwrap();
        b_b.done.recv().unwrap();
    }

    #[test]
    fn slow_consumer_does_not_block_the_socket_reader() {
        // The receiver must keep reading the socket (credits keep flowing)
        // even while the local consumer is not reading.
        let (a, b) = pair();
        let (a_sink, _a_b) = sender(a).unwrap();
        let (mut b_src, _b_b) = receiver(b).unwrap();
        let writer = std::thread::spawn(move || {
            let mut s = a_sink;
            s.write_all(&vec![7u8; 3 * WINDOW]).unwrap();
        });
        std::thread::sleep(std::time::Duration::from_millis(300)); // consumer paused
        let mut got = Vec::new();
        b_src.read_to_end(&mut got).unwrap();
        writer.join().unwrap();
        assert_eq!(got.len(), 3 * WINDOW);
    }
}
