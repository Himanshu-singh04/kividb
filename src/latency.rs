use ahash::AHashMap;
use parking_lot::RwLock;
use std::collections::VecDeque;
use std::sync::Arc;

pub struct LatencySample {
    pub timestamp: u64, // Unix seconds
    pub latency_ms: u32,
}

pub struct LatencyTracker {
    events: RwLock<AHashMap<String, VecDeque<LatencySample>>>,
    max_samples: usize,
}

pub type SharedLatencyTracker = Arc<LatencyTracker>;

pub fn new_latency_tracker() -> SharedLatencyTracker {
    Arc::new(LatencyTracker {
        events: RwLock::new(AHashMap::new()),
        max_samples: 180,
    })
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

impl LatencyTracker {
    pub fn record(&self, event: &str, latency_ms: u32) {
        let mut map = self.events.write();
        let deque = map.entry(event.to_string()).or_default();
        if deque.len() >= self.max_samples {
            deque.pop_front();
        }
        deque.push_back(LatencySample {
            timestamp: unix_secs(),
            latency_ms,
        });
    }

    /// Returns (event_name, latest_timestamp, latest_latency_ms) for each event
    pub fn latest(&self) -> Vec<(String, u64, u32)> {
        self.events
            .read()
            .iter()
            .filter_map(|(name, samples)| {
                samples
                    .back()
                    .map(|s| (name.clone(), s.timestamp, s.latency_ms))
            })
            .collect()
    }

    pub fn history(&self, event: &str) -> Vec<LatencySample> {
        self.events
            .read()
            .get(event)
            .map(|deque| {
                deque
                    .iter()
                    .map(|s| LatencySample {
                        timestamp: s.timestamp,
                        latency_ms: s.latency_ms,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Forget the samples of `events` — of every event, if none is named.
    /// Returns how many events had samples to forget.
    pub fn reset(&self, events: &[&str]) -> usize {
        let mut map = self.events.write();
        if events.is_empty() {
            let had = map.len();
            map.clear();
            had
        } else {
            events
                .iter()
                .filter(|event| map.remove(**event).is_some())
                .count()
        }
    }
}
