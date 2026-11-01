//! The head poller's log line names the host, never the URL's key. In its own test binary: a
//! `tracing` callsite caches whether any subscriber wants it, and the other head tests run on
//! threads with no subscriber, which made this test flaky when it shared their process.
use bex_backrun::head::poll_heads;
use futures::StreamExt;
use std::time::Duration;

/// A `tracing` writer into a shared buffer.
#[derive(Clone, Default)]
struct Buf(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);
impl std::io::Write for Buf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn test_poll_error_never_logs_url_token() {
    let buf = Buf::default();
    let w = buf.clone();
    let sub = tracing_subscriber::fmt()
        .with_writer(move || w.clone())
        // explicit: alloy's own TRACE spans carry the URL; the bot's WARN must not
        .with_max_level(tracing::Level::WARN)
        .finish();
    let _guard = tracing::subscriber::set_default(sub);
    // nothing listens on port 1: every poll is a reqwest connect error
    let s = poll_heads(
        "http://127.0.0.1:1/secret-token".parse().unwrap(),
        Duration::from_millis(20),
    );
    let _ = tokio::time::timeout(Duration::from_millis(200), s.take(1).collect::<Vec<_>>()).await;
    let log = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
    assert!(log.contains("head poll failed"), "{log}");
    assert!(log.contains("127.0.0.1:1"), "the host stays: {log}");
    assert!(!log.contains("secret-token"), "{log}");
}
