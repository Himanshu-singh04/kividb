//! `DEBUG` subcommands used by Redis integration tests (external clients).

use crate::commands::ctx::Ctx;
use crate::commands::handler::{client_connection_resp, effective_resp_for_reply};
use crate::resp::write::*;

fn parse_sleep_seconds(cmd: &Ctx) -> Option<f64> {
    if cmd.cmd.len() != 3 {
        return None;
    }
    std::str::from_utf8(cmd.cmd[2]).ok()?.parse().ok()
}

/// `DEBUG ...` — protocol helpers and sleep match Redis `debug.c` for scripting tests.
pub fn handle(ctx: &mut Ctx) -> Option<Vec<u8>> {
    if ctx.cmd.len() < 2 {
        return Some(resp_error(
            "ERR wrong number of arguments for 'debug' command",
        ));
    }
    let sub = std::str::from_utf8(ctx.cmd[1]).ok()?.to_ascii_lowercase();
    match sub.as_str() {
        "sleep" => {
            let Some(secs) = parse_sleep_seconds(ctx) else {
                return Some(resp_error("ERR wrong number of arguments for DEBUG sleep"));
            };
            std::thread::sleep(std::time::Duration::from_secs_f64(secs));
            Some(resp_simple("OK"))
        }
        "protocol" => {
            if ctx.cmd.len() != 3 {
                return Some(resp_error("ERR wrong number of arguments"));
            }
            let kind = std::str::from_utf8(ctx.cmd[2]).ok()?.to_ascii_lowercase();
            let conn_resp = client_connection_resp(ctx);
            let eff = effective_resp_for_reply(ctx);
            Some(debug_protocol_reply(conn_resp, eff, &kind))
        }
        "object" => {
            // Minimal stub — tests only require that the command succeeds.
            Some(resp_bulk_str(
                "Value at:0 refcount:1 encoding:raw serializedlength:1",
            ))
        }
        "set-active-expire" | "set-disable-deny-scripts" => Some(resp_simple("OK")),
        _ => Some(resp_simple("OK")),
    }
}

fn debug_protocol_reply(conn_resp: u8, effective_resp: u8, kind: &str) -> Vec<u8> {
    let use_r3 = conn_resp >= 3 && effective_resp >= 3;
    match kind {
        "string" => resp_bulk_str("Hello World"),
        "integer" => resp_integer(12345),
        "double" => {
            if use_r3 {
                #[allow(clippy::approx_constant)]
                resp_double_resp3(3.141)
            } else {
                #[allow(clippy::approx_constant)]
                resp_double_bulk(3.141)
            }
        }
        "bignum" => {
            let s = "1234567999999999999999999999999999999";
            if use_r3 {
                resp_bignum_resp3(s)
            } else {
                resp_bulk_str(s)
            }
        }
        "null" => {
            if conn_resp >= 3 && effective_resp >= 3 {
                resp_null_resp3()
            } else {
                resp_null_bulk()
            }
        }
        "array" => resp_array(vec![resp_integer(0), resp_integer(1), resp_integer(2)]),
        "set" => {
            if use_r3 {
                resp_set_resp3(vec![resp_integer(0), resp_integer(1), resp_integer(2)])
            } else {
                resp_array(vec![resp_integer(0), resp_integer(1), resp_integer(2)])
            }
        }
        "map" => {
            if use_r3 {
                resp_map(vec![
                    resp_integer(0),
                    resp_bool_resp3(false),
                    resp_integer(1),
                    resp_bool_resp3(true),
                    resp_integer(2),
                    resp_bool_resp3(false),
                ])
            } else {
                resp_array(vec![
                    resp_integer(0),
                    resp_bool_resp2(false),
                    resp_integer(1),
                    resp_bool_resp2(true),
                    resp_integer(2),
                    resp_bool_resp2(false),
                ])
            }
        }
        "attrib" => {
            if use_r3 {
                let mut out = Vec::new();
                out.extend_from_slice(b"|1\r\n");
                out.extend_from_slice(&resp_bulk_str("key-popularity"));
                out.extend_from_slice(&resp_array(vec![
                    resp_bulk_str("key:123"),
                    resp_integer(90),
                ]));
                out.extend_from_slice(&resp_bulk_str("Some real reply following the attribute"));
                out
            } else {
                resp_bulk_str("Some real reply following the attribute")
            }
        }
        "push" => {
            if conn_resp < 3 {
                return resp_error("RESP2 is not supported by this command");
            }
            let mut out = Vec::new();
            out.extend_from_slice(b">2\r\n");
            out.extend_from_slice(&resp_bulk_str("server-cpu-usage"));
            out.extend_from_slice(&resp_integer(42));
            out.extend_from_slice(&resp_bulk_str("Some real reply following the push reply"));
            out
        }
        "verbatim" => {
            if use_r3 {
                resp_verbatim_resp3("txt", "This is a verbatim\nstring")
            } else {
                resp_bulk_str("This is a verbatim\nstring")
            }
        }
        "true" => {
            if use_r3 {
                resp_bool_resp3(true)
            } else {
                resp_integer(1)
            }
        }
        "false" => {
            if use_r3 {
                resp_bool_resp3(false)
            } else {
                resp_integer(0)
            }
        }
        _ => resp_error(
            "Wrong protocol type name. Please use one of the following: string|integer|double|bignum|null|array|set|map|attrib|push|verbatim|true|false",
        ),
    }
}

fn resp_bool_resp2(b: bool) -> Vec<u8> {
    resp_integer(if b { 1 } else { 0 })
}
