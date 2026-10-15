use crate::commands::ctx::Ctx;
use crate::resp::write::*;

pub fn handle(ctx: &mut Ctx, name: &str) -> Option<Vec<u8>> {
    if name != "LATENCY" {
        return None;
    }

    let cmd = &ctx.cmd;
    if cmd.len() < 2 {
        return Some(resp_error(
            "ERR wrong number of arguments for 'latency' command",
        ));
    }

    let sub = String::from_utf8_lossy(cmd[1]).to_ascii_uppercase();
    match sub.as_str() {
        "LATEST" => {
            let samples = ctx.latency.latest();
            let mut out = format!("*{}\r\n", samples.len()).into_bytes();
            for (name, ts, ms) in samples {
                out.extend_from_slice(b"*3\r\n");
                out.extend_from_slice(&resp_bulk_str(&name));
                out.extend_from_slice(&resp_integer(ts as i64));
                out.extend_from_slice(&resp_integer(ms as i64));
            }
            Some(out)
        }

        "HISTORY" => {
            if cmd.len() < 3 {
                return Some(resp_error(
                    "ERR wrong number of arguments for 'latency|history' command",
                ));
            }
            let event = String::from_utf8_lossy(cmd[2]);
            let samples = ctx.latency.history(&event);
            let mut out = format!("*{}\r\n", samples.len()).into_bytes();
            for s in samples {
                out.extend_from_slice(b"*2\r\n");
                out.extend_from_slice(&resp_integer(s.timestamp as i64));
                out.extend_from_slice(&resp_integer(s.latency_ms as i64));
            }
            Some(out)
        }

        "RESET" => {
            let events: Vec<&str> = cmd[2..]
                .iter()
                .map(|b| std::str::from_utf8(b).unwrap_or(""))
                .collect();
            // The number of event series there were to reset.
            Some(resp_integer(ctx.latency.reset(&events) as i64))
        }

        "GRAPH" => {
            // Minimal ASCII sparkline — Redis returns a bulk string
            if cmd.len() < 3 {
                return Some(resp_error(
                    "ERR wrong number of arguments for 'latency|graph' command",
                ));
            }
            let event = String::from_utf8_lossy(cmd[2]);
            let samples = ctx.latency.history(&event);
            if samples.is_empty() {
                return Some(resp_error(&format!("ERR No samples for event '{event}'")));
            }
            let graph = build_sparkline(&samples);
            Some(resp_bulk_str(&graph))
        }

        "HISTOGRAM" => {
            // LATENCY HISTOGRAM [command ...]
            //
            // For each command that has been called: how many times, and
            // the distribution of how long it took — for each time that is
            // a power of two microseconds, how many calls took less. Only
            // the commands named, if any are: a command with subcommands
            // names them all, `client|id` names one, and a name that is not
            // a command's is passed over.
            let wanted: Vec<String> = cmd[2..]
                .iter()
                .map(|raw| String::from_utf8_lossy(raw).to_ascii_lowercase())
                .collect();
            let mut reply: Vec<Vec<u8>> = Vec::new();
            for (name, totals) in crate::cmdstats::totals() {
                let named = wanted.is_empty()
                    || wanted.iter().any(|want| {
                        *want == name
                            || name
                                .split_once('|')
                                .is_some_and(|(container, _)| container == want)
                    });
                if !named {
                    continue;
                }
                let mut histogram: Vec<Vec<u8>> = Vec::new();
                let mut so_far = 0u64;
                for (i, count) in totals.buckets.iter().enumerate() {
                    if *count > 0 {
                        so_far += count;
                        histogram.push(resp_integer(1i64 << i.min(62)));
                        histogram.push(resp_integer(so_far as i64));
                    }
                }
                let resp = crate::commands::handler::effective_resp_for_reply(ctx);
                reply.push(resp_bulk_str(&name));
                reply.push(resp_map_for(
                    resp,
                    vec![
                        resp_bulk_str("calls"),
                        resp_integer(totals.calls as i64),
                        resp_bulk_str("histogram_usec"),
                        resp_map_for(resp, histogram),
                    ],
                ));
            }
            Some(resp_map_for(
                crate::commands::handler::effective_resp_for_reply(ctx),
                reply,
            ))
        }

        "DOCTOR" => {
            // LATENCY DOCTOR — human-readable diagnostic report.
            //
            // Walks the latest latency samples and flags any event whose
            // most recent latency exceeds common thresholds. If nothing
            // looks wrong, emit Redis's exact clean-bill-of-health message
            // so tooling (redis-cli --latency-doctor) parses it correctly.
            let samples = ctx.latency.latest();

            if samples.is_empty() {
                return Some(resp_bulk_str(
                    "Dave, I have observed the system for some time \
                     and I have no problem to report.",
                ));
            }

            // Thresholds that indicate something worth reporting.
            // These match Redis's own heuristics.
            const WARN_MS: u32 = 100; // warn if latest sample >= 100ms
            const CRIT_MS: u32 = 500; // critical if >= 500ms

            let mut issues: Vec<String> = Vec::new();

            for (event, _ts, ms) in &samples {
                if *ms >= CRIT_MS {
                    issues.push(format!(
                        "- Event '{}': latency is {}ms — CRITICAL. \
                         This is severely impacting response times. \
                         Check for blocking operations or system resource contention.",
                        event, ms
                    ));
                } else if *ms >= WARN_MS {
                    issues.push(format!(
                        "- Event '{}': latency is {}ms — WARNING. \
                         This may indicate slow commands, memory pressure, \
                         or OS scheduling delays.",
                        event, ms
                    ));
                }
            }

            if issues.is_empty() {
                Some(resp_bulk_str(
                    "Dave, I have observed the system for some time \
                     and I have no problem to report.",
                ))
            } else {
                let mut report = String::from("I detected the following latency issues:\n\n");
                for issue in &issues {
                    report.push_str(issue);
                    report.push('\n');
                }
                report.push_str("\nRefer to https://redis.io/topics/latency for more information.");
                Some(resp_bulk_str(&report))
            }
        }

        _ => Some(resp_error("ERR unknown subcommand for LATENCY")),
    }
}

fn build_sparkline(samples: &[crate::latency::LatencySample]) -> String {
    // 7-row, up-to-80-col ASCII chart
    let bars = "▁▂▃▄▅▆▇█";
    let bar_chars: Vec<char> = bars.chars().collect();
    let max_ms = samples
        .iter()
        .map(|s| s.latency_ms)
        .max()
        .unwrap_or(1)
        .max(1);

    samples
        .iter()
        .take(80)
        .map(|s| {
            let idx = ((s.latency_ms as f64 / max_ms as f64) * (bar_chars.len() - 1) as f64).round()
                as usize;
            bar_chars[idx.min(bar_chars.len() - 1)]
        })
        .collect()
}
