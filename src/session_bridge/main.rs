use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> io::Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("--version") | Some("version") => {
            println!("vaultty-session-bridge {VERSION}");
            Ok(())
        }
        Some("--socket-path") => {
            println!("{}", socket_path()?.display());
            Ok(())
        }
        Some(arg) => {
            eprintln!("usage: vaultty-session-bridge [--version|--socket-path]");
            eprintln!("unexpected argument: {arg}");
            std::process::exit(64);
        }
        None => run_bridge(),
    }
}

fn run_bridge() -> io::Result<()> {
    ensure_daemon_is_running()?;
    let stream = connect_to_daemon()?;
    proxy_stdio(stream)
}

fn proxy_stdio(stream: UnixStream) -> io::Result<()> {
    let mut input_stream = stream.try_clone()?;
    let output_stream = stream;

    let input_thread = thread::spawn(move || {
        let mut stdin = io::stdin().lock();
        let result = io::copy(&mut stdin, &mut input_stream);
        let _ = input_stream.shutdown(Shutdown::Write);
        result.map(|_| ())
    });

    let output_thread = thread::spawn(move || {
        let mut output_stream = output_stream;
        let mut stdout = io::stdout().lock();
        let result = io::copy(&mut output_stream, &mut stdout);
        let _ = stdout.flush();
        result.map(|_| ())
    });

    let input_result = join_io_thread(input_thread);
    let output_result = join_io_thread(output_thread);
    tolerate_broken_pipe(input_result)?;
    output_result
}

fn join_io_thread(thread: thread::JoinHandle<io::Result<()>>) -> io::Result<()> {
    match thread.join() {
        Ok(result) => result,
        Err(_) => Err(io::Error::other("bridge proxy thread panicked")),
    }
}

fn tolerate_broken_pipe(result: io::Result<()>) -> io::Result<()> {
    match result {
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        result => result,
    }
}

fn ensure_daemon_is_running() -> io::Result<()> {
    let socket_path = socket_path()?;
    if daemon_supports_inventory() {
        return Ok(());
    }

    let daemon = sessiond_path()?;
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let _ = fs::remove_file(&socket_path);

    Command::new(daemon)
        .arg("serve")
        .env("VAULTTY_SESSIOND_SOCKET", &socket_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut last_error = None;
    while Instant::now() < deadline {
        match daemon_supports_inventory() {
            true => {
                return Ok(());
            }
            false => {
                let error = connect_to_daemon()
                    .err()
                    .unwrap_or_else(|| io::Error::other("vaultty-sessiond did not answer LIST"));
                last_error = Some(error);
                thread::sleep(Duration::from_millis(50));
            }
        }
    }

    Err(last_error.unwrap_or_else(|| io::Error::other("could not connect to vaultty-sessiond")))
}

fn daemon_supports_inventory() -> bool {
    let Ok(mut stream) = connect_to_daemon() else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));
    if stream.write_all(b"LIST\n").is_err() || stream.flush().is_err() {
        return false;
    }

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map(|count| count > 0 && line.starts_with("SESSIONS "))
        .unwrap_or(false)
}

fn connect_to_daemon() -> io::Result<UnixStream> {
    UnixStream::connect(socket_path()?)
}

fn sessiond_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND") {
        let path = PathBuf::from(path);
        if is_executable(&path) {
            return Ok(path);
        }
    }

    if let Ok(current_exe) = env::current_exe()
        && let Some(dir) = current_exe.parent()
    {
        let sibling = dir.join("vaultty-sessiond");
        if is_executable(&sibling) {
            return Ok(sibling);
        }
    }

    if let Some(path) = find_on_path("vaultty-sessiond") {
        return Ok(path);
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "vaultty-sessiond was not found next to the bridge or on PATH",
    ))
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let paths = env::var_os("PATH")?;
    env::split_paths(&paths)
        .map(|dir| dir.join(name))
        .find(|path| is_executable(path))
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND_SOCKET") {
        return Ok(PathBuf::from(path));
    }

    let home = env::var_os("HOME").ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is required for socket path")
    })?;
    let home = PathBuf::from(home);

    #[cfg(target_os = "macos")]
    {
        return Ok(home
            .join("Library")
            .join("Application Support")
            .join("Vaultty")
            .join("runtime")
            .join("sessiond.sock"));
    }

    #[cfg(not(target_os = "macos"))]
    {
        let state_home = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local").join("state"));
        Ok(state_home.join("vaultty").join("sessiond.sock"))
    }
}
