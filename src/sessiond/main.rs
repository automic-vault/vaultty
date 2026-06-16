use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use libc::{c_int, c_void, pid_t, winsize, TIOCGPGRP, TIOCSWINSZ};
use std::collections::HashMap;
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Clone)]
struct AttachRequest {
    session_id: String,
    cwd: PathBuf,
    shell: String,
    environment: Vec<(String, String)>,
}

struct Session {
    master_fd: RawFd,
    child_pid: pid_t,
    history: Mutex<Vec<u8>>,
    clients: Mutex<Vec<Sender<Vec<u8>>>>,
}

impl Session {
    fn new(request: &AttachRequest) -> io::Result<Arc<Self>> {
        let mut master_fd: c_int = -1;
        let mut size = winsize {
            ws_row: 30,
            ws_col: 100,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let pid = unsafe {
            libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        };
        if pid < 0 {
            return Err(io::Error::last_os_error());
        }

        if pid == 0 {
            let _ = env::set_current_dir(&request.cwd);
            for (key, value) in &request.environment {
                unsafe {
                    env::set_var(key, value);
                }
            }

            let shell = CString::new(request.shell.as_bytes()).unwrap_or_else(|_| {
                CString::new("/bin/zsh").expect("static shell path must be valid")
            });
            let shell_name = Path::new(&request.shell)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("zsh");
            let login_shell = CString::new(format!("-{shell_name}")).unwrap_or_else(|_| {
                CString::new("-zsh").expect("static argv must be valid")
            });
            let mut argv = [login_shell.as_ptr(), std::ptr::null()];
            unsafe {
                libc::execv(shell.as_ptr(), argv.as_mut_ptr());
                libc::perror(c"exec".as_ptr());
                libc::_exit(127);
            }
        }

        let session = Arc::new(Self {
            master_fd,
            child_pid: pid,
            history: Mutex::new(Vec::new()),
            clients: Mutex::new(Vec::new()),
        });
        Self::start_reader(session.clone());
        Ok(session)
    }

    fn add_client(&self, sender: Sender<Vec<u8>>) {
        self.clients.lock().expect("clients lock poisoned").push(sender);
    }

    fn history(&self) -> Vec<u8> {
        self.history.lock().expect("history lock poisoned").clone()
    }

    fn write_input(&self, bytes: &[u8]) {
        let mut offset = 0;
        while offset < bytes.len() {
            let written = unsafe {
                libc::write(
                    self.master_fd,
                    bytes[offset..].as_ptr() as *const c_void,
                    bytes.len() - offset,
                )
            };
            if written > 0 {
                offset += written as usize;
            } else if written == -1 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            } else {
                break;
            }
        }
    }

    fn resize(&self, rows: u16, cols: u16) {
        let mut size = winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            libc::ioctl(self.master_fd, TIOCSWINSZ, &mut size);
        }
    }

    fn interrupt(&self) {
        let mut foreground_process_group: pid_t = 0;
        let signaled = unsafe {
            libc::ioctl(self.master_fd, TIOCGPGRP, &mut foreground_process_group) == 0
                && foreground_process_group > 0
                && libc::kill(-foreground_process_group, libc::SIGINT) == 0
        };
        if !signaled {
            self.write_input(&[0x03]);
        }
    }

    fn kill(&self) {
        unsafe {
            libc::kill(-self.child_pid, libc::SIGTERM);
            libc::kill(self.child_pid, libc::SIGTERM);
            libc::close(self.master_fd);
        }
    }

    fn start_reader(session: Arc<Self>) {
        thread::spawn(move || {
            let mut buffer = [0_u8; 8192];
            loop {
                let count = unsafe {
                    libc::read(
                        session.master_fd,
                        buffer.as_mut_ptr() as *mut c_void,
                        buffer.len(),
                    )
                };
                if count <= 0 {
                    break;
                }

                let bytes = buffer[..count as usize].to_vec();
                session
                    .history
                    .lock()
                    .expect("history lock poisoned")
                    .extend_from_slice(&bytes);

                let mut clients = session.clients.lock().expect("clients lock poisoned");
                clients.retain(|client| client.send(bytes.clone()).is_ok());
            }

            let status = reap_child(session.child_pid);
            let exit_line = format!("EXIT {status}\n").into_bytes();
            let mut clients = session.clients.lock().expect("clients lock poisoned");
            clients.retain(|client| client.send(exit_line.clone()).is_ok());
        });
    }
}

struct DaemonState {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
}

fn main() -> io::Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("serve") => serve(),
        _ => {
            eprintln!("usage: vaultty-sessiond serve");
            std::process::exit(64);
        }
    }
}

fn serve() -> io::Result<()> {
    let socket_path = socket_path()?;
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    if socket_path.exists() {
        let _ = fs::remove_file(&socket_path);
    }

    let listener = UnixListener::bind(&socket_path)?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))?;
    let state = Arc::new(DaemonState {
        sessions: Mutex::new(HashMap::new()),
    });

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = state.clone();
                thread::spawn(move || {
                    if let Err(error) = handle_client(stream, state) {
                        eprintln!("vaultty-sessiond client error: {error}");
                    }
                });
            }
            Err(error) => eprintln!("vaultty-sessiond accept error: {error}"),
        }
    }
    Ok(())
}

fn handle_client(mut stream: UnixStream, state: Arc<DaemonState>) -> io::Result<()> {
    validate_peer(&stream)?;

    let reader_stream = stream.try_clone()?;
    let mut reader = BufReader::new(reader_stream);
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(());
    }

    let request = parse_attach(line.trim_end())?;
    let (session, created) = {
        let mut sessions = state.sessions.lock().expect("sessions lock poisoned");
        if let Some(session) = sessions.get(&request.session_id) {
            (session.clone(), false)
        } else {
            let session = Session::new(&request)?;
            sessions.insert(request.session_id.clone(), session.clone());
            (session, true)
        }
    };

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    session.add_client(tx);
    writeln!(stream, "READY {}", if created { 1 } else { 0 })?;

    let history = session.history();
    if !history.is_empty() {
        writeln!(stream, "OUTPUT {}", BASE64.encode(history))?;
    }

    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    let writer_for_output = writer.clone();
    thread::spawn(move || {
        while let Ok(bytes) = rx.recv() {
            let mut writer = writer_for_output.lock().expect("writer lock poisoned");
            if bytes.starts_with(b"EXIT ") {
                if writer.write_all(&bytes).is_err() || writer.flush().is_err() {
                    break;
                }
                continue;
            }
            if writeln!(writer, "OUTPUT {}", BASE64.encode(bytes)).is_err()
                || writer.flush().is_err()
            {
                break;
            }
        }
    });

    line.clear();
    while reader.read_line(&mut line)? > 0 {
        let command = line.trim_end();
        if command == "DETACH" {
            break;
        } else if let Some(encoded) = command.strip_prefix("INPUT ") {
            if let Ok(bytes) = BASE64.decode(encoded) {
                session.write_input(&bytes);
            }
        } else if let Some(rest) = command.strip_prefix("RESIZE ") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() == 2 {
                if let (Ok(rows), Ok(cols)) = (parts[0].parse::<u16>(), parts[1].parse::<u16>()) {
                    session.resize(rows, cols);
                }
            }
        } else if command == "INTERRUPT" {
            session.interrupt();
        } else if command == "KILL" {
            session.kill();
            state
                .sessions
                .lock()
                .expect("sessions lock poisoned")
                .remove(&request.session_id);
            break;
        }
        line.clear();
    }

    Ok(())
}

fn parse_attach(line: &str) -> io::Result<AttachRequest> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() != 5 || parts[0] != "ATTACH" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected ATTACH session cwd shell env",
        ));
    }

    let session_id = decode_string(parts[1])?;
    let cwd = PathBuf::from(decode_string(parts[2])?);
    let shell = decode_string(parts[3])?;
    let env_blob = BASE64
        .decode(parts[4])
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid environment"))?;
    let environment = String::from_utf8_lossy(&env_blob)
        .split('\0')
        .filter_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            Some((key.to_owned(), value.to_owned()))
        })
        .collect();

    Ok(AttachRequest {
        session_id,
        cwd,
        shell,
        environment,
    })
}

fn decode_string(value: &str) -> io::Result<String> {
    let bytes = BASE64
        .decode(value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid base64"))?;
    String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid utf8"))
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("VAULTTY_SESSIOND_SOCKET") {
        return Ok(PathBuf::from(path));
    }
    let home = env::var_os("HOME").ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, "HOME is required for socket path")
    })?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Vaultty")
        .join("runtime")
        .join("sessiond.sock"))
}

fn validate_peer(stream: &UnixStream) -> io::Result<()> {
    if env::var_os("VAULTTY_SESSIOND_DISABLE_PEER_VALIDATION").is_some() {
        return Ok(());
    }

    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    let rc = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    if uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "peer uid does not match daemon uid",
        ));
    }

    #[cfg(target_os = "macos")]
    validate_peer_signature(stream)?;

    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_peer_signature(stream: &UnixStream) -> io::Result<()> {
    let pid = peer_pid(stream.as_raw_fd())?;
    let path = process_path(pid)?;
    let output = Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(&path)
        .output()?;
    let text = String::from_utf8_lossy(&output.stderr);
    let path_text = String::from_utf8_lossy(path.as_os_str().as_bytes());
    let looks_like_vaultty = path_text.ends_with("/Contents/MacOS/Vaultty")
        || path_text.ends_with("/Vaultty")
        || env::var_os("VAULTTY_SESSIOND_ALLOW_DEBUG_CLIENT").is_some();
    let signed_by_expected_team = text.contains("TeamIdentifier=")
        && !text.contains("TeamIdentifier=not set");

    if output.status.success() && looks_like_vaultty && signed_by_expected_team {
        return Ok(());
    }

    if env::var_os("VAULTTY_SESSIOND_ALLOW_DEBUG_CLIENT").is_some() && looks_like_vaultty {
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("peer process is not signed Vaultty: {}", path.display()),
    ))
}

#[cfg(target_os = "macos")]
fn peer_pid(fd: RawFd) -> io::Result<pid_t> {
    const LOCAL_PEERPID: c_int = 2;
    let mut pid: pid_t = 0;
    let mut len = std::mem::size_of::<pid_t>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            LOCAL_PEERPID,
            &mut pid as *mut _ as *mut c_void,
            &mut len,
        )
    };
    if rc == 0 {
        Ok(pid)
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn process_path(pid: pid_t) -> io::Result<PathBuf> {
    let mut buffer = vec![0_u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let count = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr() as *mut c_void,
            buffer.len() as u32,
        )
    };
    if count <= 0 {
        return Err(io::Error::last_os_error());
    }
    buffer.truncate(count as usize);
    Ok(PathBuf::from(std::ffi::OsString::from_vec(buffer)))
}

fn reap_child(pid: pid_t) -> i32 {
    let mut status: c_int = 0;
    loop {
        let rc = unsafe { libc::waitpid(pid, &mut status, 0) };
        if rc >= 0 {
            break;
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return -1;
        }
    }
    if status & 0x7f == 0 {
        (status >> 8) & 0xff
    } else {
        128 + (status & 0x7f)
    }
}
