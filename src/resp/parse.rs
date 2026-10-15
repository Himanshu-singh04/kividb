fn read_line(buf: &[u8], start: usize) -> Option<(usize, &[u8])> {
    let window = &buf[start..];
    let pos = memchr::memchr(b'\r', window)?;
    if window.get(pos + 1).copied() == Some(b'\n') {
        Some((start + pos + 2, &buf[start..start + pos]))
    } else {
        None
    }
}

pub fn parse_resp_command(buf: &[u8]) -> Option<(usize, Vec<&[u8]>)> {
    if buf.is_empty() || buf[0] != b'*' {
        return None;
    }

    let (mut idx, count_line) = read_line(buf, 1)?;
    let count = parse_number(count_line)?;
    // Not `with_capacity(count)`: the count is whatever the peer wrote.
    let mut parts: Vec<&[u8]> = Vec::with_capacity(count.min(64));

    for _ in 0..count {
        if idx >= buf.len() || buf[idx] != b'$' {
            return None;
        }

        let (next, len_line) = read_line(buf, idx + 1)?;
        let bulk_len = parse_number(len_line)?;
        idx = next;

        if idx + bulk_len + 2 > buf.len() {
            return None;
        }

        let data = &buf[idx..idx + bulk_len];
        idx += bulk_len;

        if buf[idx] != b'\r' || buf[idx + 1] != b'\n' {
            return None;
        }
        idx += 2;

        parts.push(data);
    }

    Some((idx, parts))
}

// ── Requests from clients ─────────────────────────────────────────────────────
//
// What a client sends is not to be trusted to be a request. The parser above
// answers "not yet" to everything it cannot read, which is right for the
// replication link — the peer is a server, and what it has sent so far is
// the start of something well formed. A client that sends `*3000000000` or
// a megabyte with no line end in it is not going to complete a request, and
// "not yet" there means a connection that waits for ever while its buffer
// grows. (And the first of those used to be an allocation of that many
// arguments' worth of memory, which took the server down.)
//
// So for clients there are three answers: a request, not yet, and *never* —
// with Redis's limits and Redis's words for what is wrong. The connection
// replies `-ERR Protocol error: …` and closes.

/// The longest line: an inline request, or the count that begins a request
/// or an argument.
const LINE_MAX: usize = 64 * 1024;
/// The longest argument (Redis's `proto-max-bulk-len`).
const BULK_MAX: i64 = 512 * 1024 * 1024;

/// What is wrong with what the client sent.
pub type ProtocolError = String;

type Request<'a> = (usize, Vec<&'a [u8]>);

/// A decimal number, as Redis reads one: digits, with an optional `-`.
fn parse_integer(bytes: &[u8]) -> Option<i64> {
    let (negative, digits) = match bytes.split_first() {
        Some((b'-', rest)) => (true, rest),
        _ => (false, bytes),
    };
    if digits.is_empty() {
        return None;
    }
    let mut n: i64 = 0;
    for &b in digits {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n.checked_mul(10)?.checked_add((b - b'0') as i64)?;
    }
    Some(if negative { -n } else { n })
}

fn parse_multibulk(buf: &[u8]) -> Result<Option<Request<'_>>, ProtocolError> {
    let Some(cr) = memchr::memchr(b'\r', buf) else {
        if buf.len() > LINE_MAX {
            return Err("too big mbulk count string".into());
        }
        return Ok(None);
    };
    if cr + 1 >= buf.len() {
        return Ok(None);
    }
    let count = parse_integer(&buf[1..cr])
        .filter(|count| *count <= i32::MAX as i64)
        .ok_or("invalid multibulk length")?;
    let mut idx = cr + 2;
    // `*0` and `*-1` are requests for nothing.
    if count <= 0 {
        return Ok(Some((idx, Vec::new())));
    }
    let mut parts: Vec<&[u8]> = Vec::with_capacity((count as usize).min(64));
    for _ in 0..count {
        if idx >= buf.len() {
            return Ok(None);
        }
        let Some(cr) = memchr::memchr(b'\r', &buf[idx..]) else {
            if buf.len() - idx > LINE_MAX {
                return Err("too big bulk count string".into());
            }
            return Ok(None);
        };
        if buf[idx] != b'$' {
            let got = if buf[idx].is_ascii_graphic() {
                buf[idx] as char
            } else {
                '?'
            };
            return Err(format!("expected '$', got '{got}'"));
        }
        let line_end = idx + cr;
        if line_end + 1 >= buf.len() {
            return Ok(None);
        }
        let len = parse_integer(&buf[idx + 1..line_end])
            .filter(|len| (0..=BULK_MAX).contains(len))
            .ok_or("invalid bulk length")? as usize;
        idx = line_end + 2;
        if idx + len + 2 > buf.len() {
            return Ok(None);
        }
        parts.push(&buf[idx..idx + len]);
        idx += len + 2;
    }
    Ok(Some((idx, parts)))
}

/// The next request in `buf`, if all of it has arrived.
pub fn parse_request(buf: &[u8]) -> Result<Option<Request<'_>>, ProtocolError> {
    match buf.first() {
        None => Ok(None),
        Some(b'*') => parse_multibulk(buf),
        Some(_) => match parse_inline_command(buf) {
            Some(request) => Ok(Some(request)),
            None if buf.len() > LINE_MAX => Err("too big inline request".into()),
            None => Ok(None),
        },
    }
}

/// The arguments of an inline request, as Redis splits one: words apart at
/// white space, with `"double quotes"` — inside which `\n`, `\xHH` and the
/// like are what they are in C — and `'single quotes'`, which take
/// everything as it is but `\'`. `None` if a quote is left open, or closed
/// in the middle of a word.
fn split_quoted(line: &[u8]) -> Option<Vec<Vec<u8>>> {
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    let mut args = Vec::new();
    let mut i = 0;
    loop {
        while i < line.len() && line[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= line.len() {
            return Some(args);
        }
        let mut arg = Vec::new();
        let (mut in_double, mut in_single) = (false, false);
        loop {
            let at = line.get(i).copied();
            if in_double {
                match at {
                    None => return None,
                    Some(b'\\') if line.get(i + 1) == Some(&b'x') => {
                        match (
                            line.get(i + 2).copied().and_then(hex),
                            line.get(i + 3).copied().and_then(hex),
                        ) {
                            (Some(high), Some(low)) => {
                                arg.push(high * 16 + low);
                                i += 3;
                            }
                            // Not a byte in hex: an `x`.
                            _ => {
                                arg.push(b'x');
                                i += 1;
                            }
                        }
                    }
                    Some(b'\\') if i + 1 < line.len() => {
                        i += 1;
                        arg.push(match line[i] {
                            b'n' => b'\n',
                            b'r' => b'\r',
                            b't' => b'\t',
                            b'b' => 0x08,
                            b'a' => 0x07,
                            other => other,
                        });
                    }
                    Some(b'"') => {
                        // A closing quote ends the word.
                        if line
                            .get(i + 1)
                            .is_some_and(|next| !next.is_ascii_whitespace())
                        {
                            return None;
                        }
                        i += 1;
                        break;
                    }
                    Some(byte) => arg.push(byte),
                }
            } else if in_single {
                match at {
                    None => return None,
                    Some(b'\\') if line.get(i + 1) == Some(&b'\'') => {
                        i += 1;
                        arg.push(b'\'');
                    }
                    Some(b'\'') => {
                        if line
                            .get(i + 1)
                            .is_some_and(|next| !next.is_ascii_whitespace())
                        {
                            return None;
                        }
                        i += 1;
                        break;
                    }
                    Some(byte) => arg.push(byte),
                }
            } else {
                match at {
                    None => break,
                    Some(byte) if byte.is_ascii_whitespace() || byte == 0 => break,
                    Some(b'"') => in_double = true,
                    Some(b'\'') => in_single = true,
                    Some(byte) => arg.push(byte),
                }
            }
            i += 1;
        }
        args.push(arg);
    }
}

/// The next request in `buf`, from `at` on.
///
/// An inline request with quoted arguments cannot be handed out as slices
/// of the buffer: what is between the quotes is not what the argument is.
/// Such a request is first put, where it stands in the buffer, into the
/// other form — a count, and each argument with its length — and read as
/// that.
pub fn next_request(buf: &mut Vec<u8>, at: usize) -> Result<Option<Request<'_>>, ProtocolError> {
    let pending = &buf[at..];
    if pending.first().is_some_and(|first| *first != b'*')
        && let Some(end) = memchr::memchr(b'\n', pending)
        && pending[..end].iter().any(|b| *b == b'"' || *b == b'\'')
    {
        let args = split_quoted(&pending[..end]).ok_or("unbalanced quotes in request")?;
        let mut framed = format!("*{}\r\n", args.len()).into_bytes();
        for arg in &args {
            framed.extend_from_slice(format!("${}\r\n", arg.len()).as_bytes());
            framed.extend_from_slice(arg);
            framed.extend_from_slice(b"\r\n");
        }
        buf.splice(at..at + end + 1, framed);
    }
    parse_request(&buf[at..])
}

/// Line reader for *inline* commands, which — unlike RESP framing — may be
/// terminated by a bare `\n`.
///
/// Redis's `processInlineBuffer` searches for `\n` and then drops a single
/// preceding `\r` if present; it does not require CRLF. `read_line` above
/// deliberately still does, because CRLF *is* mandatory inside a RESP frame and
/// relaxing it there would let malformed frames through.
///
/// This is not a hypothetical difference: `redis-cli --pipe`, the standard bulk
/// import path, writes inline commands separated by bare `\n`. Requiring CRLF
/// made the server sit waiting for a terminator that never arrived, so the
/// whole batch hung and then mis-parsed as one giant command
/// ("ERR wrong number of arguments"). `--pipe` did not work against kividb at
/// all.
fn read_inline_line(buf: &[u8]) -> Option<(usize, &[u8])> {
    let pos = memchr::memchr(b'\n', buf)?;
    // Strip one optional `\r` immediately before the `\n`.
    let end_of_text = if pos > 0 && buf[pos - 1] == b'\r' {
        pos - 1
    } else {
        pos
    };
    Some((pos + 1, &buf[..end_of_text]))
}

fn parse_inline_command(buf: &[u8]) -> Option<(usize, Vec<&[u8]>)> {
    let (end, line) = read_inline_line(buf)?;
    if line.is_empty() {
        return Some((end, Vec::new()));
    }
    let mut parts: Vec<&[u8]> = Vec::new();
    for w in line.split(|&b| b == b' ' || b == b'\t') {
        if !w.is_empty() {
            parts.push(w);
        }
    }
    Some((end, parts))
}

/// [`parse_request`], for a caller with nothing to say to a peer that sends
/// something else.
#[cfg(test)]
pub fn parse_redis_command(buf: &[u8]) -> Option<(usize, Vec<&[u8]>)> {
    parse_request(buf).ok().flatten()
}

fn parse_number(bytes: &[u8]) -> Option<usize> {
    let mut n: usize = 0;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        n = n * 10 + (b - b'0') as usize;
    }
    Some(n)
}

#[cfg(test)]
mod inline_line_ending_tests {
    use super::*;

    fn parse_all(mut buf: &[u8]) -> Vec<Vec<Vec<u8>>> {
        let mut out = Vec::new();
        while let Some((consumed, parts)) = parse_redis_command(buf) {
            if !parts.is_empty() {
                out.push(parts.iter().map(|p| p.to_vec()).collect());
            }
            buf = &buf[consumed..];
            if buf.is_empty() {
                break;
            }
        }
        out
    }

    #[test]
    fn what_is_not_a_request_is_refused_rather_than_waited_for() {
        let refused = |sent: &[u8]| parse_request(sent).unwrap_err();
        assert_eq!(refused(b"*3000000000\r\n"), "invalid multibulk length");
        assert_eq!(refused(b"*x\r\n"), "invalid multibulk length");
        assert_eq!(
            refused(b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\nfooz\r\n"),
            "expected '$', got 'f'"
        );
        assert_eq!(refused(b"*1\r\nfoo\r\n"), "expected '$', got 'f'");
        for bad in [&b"$-10\r\n"[..], b"$2000000000\r\n", b"$blabla\r\n"] {
            let mut sent = b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\n".to_vec();
            sent.extend_from_slice(bad);
            assert_eq!(refused(&sent), "invalid bulk length");
        }
        // No line end in sight, and more than a line's worth.
        assert_eq!(refused(&vec![b'a'; 70_000]), "too big inline request");
        let mut count = b"*".to_vec();
        count.extend(vec![b'1'; 70_000]);
        assert_eq!(refused(&count), "too big mbulk count string");
        // What has only not arrived yet is waited for.
        assert_eq!(parse_request(b"*2\r\n$4\r\nECHO\r\n$2\r\nh"), Ok(None));
        assert_eq!(parse_request(b"*2\r"), Ok(None));
        assert_eq!(parse_request(b"PIN"), Ok(None));
        // A count of nothing is a request for nothing.
        assert_eq!(parse_request(b"*-10\r\n"), Ok(Some((6, Vec::new()))));
        assert_eq!(parse_request(b"*0\r\nPING\r\n"), Ok(Some((4, Vec::new()))));
    }

    #[test]
    fn quoted_inline_arguments() {
        let read = |sent: &[u8]| {
            let mut buf = sent.to_vec();
            next_request(&mut buf, 0).map(|request| {
                request.map(|(_, parts)| parts.iter().map(|p| p.to_vec()).collect::<Vec<_>>())
            })
        };
        assert_eq!(
            read(b"set \"a key\" 'it''s'\r\n"),
            Err("unbalanced quotes in request".into())
        );
        assert_eq!(
            read(b"set \"a key\" 'it\\'s' \"\\x41\\n\"\r\n"),
            Ok(Some(vec![
                b"set".to_vec(),
                b"a key".to_vec(),
                b"it's".to_vec(),
                b"A\n".to_vec()
            ]))
        );
        assert_eq!(
            read(b"set \"\"\"test-key\"\"\" test-value\r\n"),
            Err("unbalanced quotes in request".into())
        );
        assert_eq!(
            read(b"set \"open\r\n"),
            Err("unbalanced quotes in request".into())
        );
        // What follows the request is left where it was.
        let mut buf = b"echo \"a b\"\nping\n".to_vec();
        let (consumed, _) = next_request(&mut buf, 0).unwrap().unwrap();
        assert_eq!(&buf[consumed..], b"ping\n");
    }

    #[test]
    fn inline_accepts_bare_lf() {
        // `redis-cli --pipe` writes exactly this: inline commands with no \r.
        let got = parse_all(b"set k1 v1\nset k2 v2\n");
        assert_eq!(
            got,
            vec![
                vec![b"set".to_vec(), b"k1".to_vec(), b"v1".to_vec()],
                vec![b"set".to_vec(), b"k2".to_vec(), b"v2".to_vec()],
            ],
            "bare-LF inline commands must parse; requiring CRLF broke redis-cli --pipe"
        );
    }

    #[test]
    fn inline_still_accepts_crlf() {
        let got = parse_all(b"SET a 1\r\nSET b 2\r\n");
        assert_eq!(
            got,
            vec![
                vec![b"SET".to_vec(), b"a".to_vec(), b"1".to_vec()],
                vec![b"SET".to_vec(), b"b".to_vec(), b"2".to_vec()],
            ],
            "CRLF inline must keep working"
        );
        // The \r must be stripped, not left on the last token.
        assert!(!got[0][2].ends_with(b"\r"));
    }

    #[test]
    fn incomplete_inline_command_waits_for_more_data() {
        // No terminator yet — the caller must be told to read more rather than
        // being handed a truncated command.
        assert!(parse_redis_command(b"SET partial").is_none());
        assert!(parse_redis_command(b"SET partial\r").is_none());
    }

    #[test]
    fn resp_framing_still_requires_crlf() {
        // The inline relaxation must NOT leak into RESP frame parsing, where
        // CRLF is mandatory. An LF-only RESP frame is malformed and must not
        // be accepted as if it were well-formed.
        assert!(
            parse_redis_command(b"*1\n$4\nPING\n").is_none(),
            "LF-only RESP frame must not parse"
        );
        assert!(parse_redis_command(b"*1\r\n$4\r\nPING\r\n").is_some());
    }

    #[test]
    fn mixed_inline_then_resp_in_one_buffer() {
        // What --pipe actually produces: bare-LF inline commands followed by a
        // CRLF RESP frame (its end-of-stream ECHO marker).
        let got = parse_all(b"set k v\n*2\r\n$4\r\nECHO\r\n$2\r\nhi\r\n");
        assert_eq!(
            got,
            vec![
                vec![b"set".to_vec(), b"k".to_vec(), b"v".to_vec()],
                vec![b"ECHO".to_vec(), b"hi".to_vec()],
            ]
        );
    }
}
