// tests/shutdown.rs
use std::io::Write;
use std::net::TcpStream;
use std::process::Command;
use std::time::{Duration, Instant};
use std::{env, thread};

fn wait_for_server(port: u16, timeout: Duration) -> bool {
    let start = Instant::now();
    loop {
        if TcpStream::connect(format!("127.0.0.1:{port}")).is_ok() {
            return true;
        }
        if start.elapsed() > timeout {
            return false;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_exit(server: &mut std::process::Child, timeout: Duration) -> bool {
    let start = Instant::now();
    loop {
        // try_wait() returns Ok(Some(_)) when the child has exited,
        // Ok(None) when it's still running. This correctly handles
        // zombies on macOS unlike kill(pid, 0).
        match server.try_wait() {
            Ok(Some(_)) => return true, // exited
            Ok(None) => {}              // still running
            Err(_) => return true,      // can't query = already gone
        }
        if start.elapsed() > timeout {
            return false;
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn kividb_bin() -> String {
    env::var("CARGO_BIN_EXE_kividb").unwrap_or_else(|_| {
        let manifest = env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".into());
        format!("{manifest}/target/debug/kividb")
    })
}

#[test]
fn shutdown_nosave_exits_cleanly() {
    let port = 16399u16;
    let mut server = Command::new(kividb_bin())
        .args(["--port", &port.to_string()])
        .spawn()
        .expect("failed to start kividb — run `cargo build` first");

    assert!(
        wait_for_server(port, Duration::from_secs(5)),
        "server on port {port} did not come up within 5s"
    );

    let mut conn = TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
    conn.write_all(b"*2\r\n$8\r\nSHUTDOWN\r\n$6\r\nNOSAVE\r\n")
        .unwrap();
    drop(conn);

    assert!(
        wait_for_exit(&mut server, Duration::from_secs(5)),
        "server did not exit after SHUTDOWN NOSAVE"
    );
}

#[test]
fn shutdown_abort_keeps_server_alive() {
    let port = 16400u16;
    let mut server = Command::new(kividb_bin())
        .args(["--port", &port.to_string()])
        .spawn()
        .unwrap();

    assert!(
        wait_for_server(port, Duration::from_secs(5)),
        "server on port {port} did not come up within 5s"
    );

    let mut conn = TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
    use std::io::Read;

    conn.write_all(b"*2\r\n$8\r\nSHUTDOWN\r\n$5\r\nABORT\r\n")
        .unwrap();
    let mut buf = [0u8; 16];
    let n = conn.read(&mut buf).unwrap();
    assert_eq!(&buf[..n], b"+OK\r\n", "expected +OK from SHUTDOWN ABORT");

    conn.write_all(b"*1\r\n$4\r\nPING\r\n").unwrap();
    let n = conn.read(&mut buf).unwrap();
    assert_eq!(
        &buf[..n],
        b"+PONG\r\n",
        "server stopped responding after ABORT"
    );

    server.kill().unwrap();
    let _ = server.wait();
}
