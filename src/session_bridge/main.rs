use std::env;
use std::collections::HashSet;
use std::ffi::OsString;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

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
        Some("--capabilities") => {
            println!("completion-v1");
            Ok(())
        }
        Some("complete-path") => complete_path_stdio(),
        Some("complete-commands") => complete_commands_stdio(),
        Some("run-generator") => run_generator_stdio(),
        Some(arg) => {
            eprintln!(
                "usage: vaultty-session-bridge [--version|--socket-path|--capabilities|complete-path|complete-commands|run-generator]"
            );
            eprintln!("unexpected argument: {arg}");
            std::process::exit(64);
        }
        None => run_bridge(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PathCompletionRequest {
    cwd: String,
    prefix: String,
    folders_only: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommandCompletionRequest {
    prefix: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeneratorRequest {
    command_line: String,
    cwd: String,
    environment: Option<Vec<EnvironmentPair>>,
    timeout_ms: Option<u64>,
    output_limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct EnvironmentPair {
    key: String,
    value: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletionResponse {
    suggestions: Vec<CompletionSuggestion>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CompletionSuggestion {
    display_text: String,
    insert_text: String,
    description: Option<String>,
    kind: &'static str,
    priority: i32,
    source: String,
    is_executable: bool,
}

#[derive(Debug, Serialize)]
struct GeneratorOutput {
    stdout: String,
    stderr: String,
    status: i32,
}

fn complete_path_stdio() -> io::Result<()> {
    let request: PathCompletionRequest = read_json_stdin()?;
    write_json_stdout(&CompletionResponse {
        suggestions: complete_path(&request)?,
    })
}

fn complete_commands_stdio() -> io::Result<()> {
    let request: CommandCompletionRequest = read_json_stdin()?;
    write_json_stdout(&CompletionResponse {
        suggestions: complete_commands_from_path(completion_path(), &request.prefix),
    })
}

fn run_generator_stdio() -> io::Result<()> {
    let request: GeneratorRequest = read_json_stdin()?;
    write_json_stdout(&run_generator(&request))
}

fn read_json_stdin<T: for<'de> Deserialize<'de>>() -> io::Result<T> {
    let mut input = Vec::new();
    io::stdin().lock().read_to_end(&mut input)?;
    serde_json::from_slice(&input).map_err(invalid_input)
}

fn write_json_stdout<T: Serialize>(value: &T) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn complete_path(request: &PathCompletionRequest) -> io::Result<Vec<CompletionSuggestion>> {
    if is_remote_path_prefix(&request.prefix) {
        return Ok(Vec::new());
    }

    let expanded = expand_tilde(&request.prefix);
    let (directory, file_prefix) = path_search_parts(&expanded, &request.cwd);
    let mut suggestions = Vec::new();

    for entry in fs::read_dir(&directory)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == "." || name == ".." {
            continue;
        }
        if !file_prefix.starts_with('.') && name.starts_with('.') {
            continue;
        }
        if !file_prefix.is_empty() && !has_case_insensitive_prefix(&name, &file_prefix) {
            continue;
        }

        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let is_directory = metadata.is_dir();
        if request.folders_only && !is_directory {
            continue;
        }

        let visible_name = if is_directory {
            format!("{name}/")
        } else {
            name.clone()
        };
        suggestions.push(CompletionSuggestion {
            display_text: visible_name.clone(),
            insert_text: path_insert_value(&request.prefix, &visible_name, is_directory),
            description: None,
            kind: if is_directory { "folder" } else { "file" },
            priority: if is_directory { 60 } else { 55 },
            source: directory.to_string_lossy().into_owned(),
            is_executable: is_directory || metadata.permissions().mode() & 0o111 != 0,
        });
        if suggestions.len() >= 512 {
            break;
        }
    }

    Ok(suggestions)
}

fn complete_commands_from_path(path: Option<OsString>, prefix: &str) -> Vec<CompletionSuggestion> {
    let mut names = HashSet::new();
    let Some(path) = path else {
        return Vec::new();
    };

    for directory in env::split_paths(&path) {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !prefix.is_empty() && !has_case_insensitive_prefix(&name, prefix) {
                continue;
            }
            let path = entry.path();
            if is_executable(&path) {
                names.insert(name);
            }
        }
    }

    names
        .into_iter()
        .map(|name| CompletionSuggestion {
            display_text: name.clone(),
            insert_text: format!("{name} "),
            description: None,
            kind: "command",
            priority: 50,
            source: "PATH".to_owned(),
            is_executable: true,
        })
        .collect()
}

fn run_generator(request: &GeneratorRequest) -> GeneratorOutput {
    let timeout = Duration::from_millis(request.timeout_ms.unwrap_or(10_000).clamp(1, 15_000));
    let output_limit = request.output_limit.unwrap_or(64 * 1024).clamp(1, 128 * 1024);
    let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
    let command_line = shell_command_line_for(&shell, &request.command_line);

    let mut command = Command::new(shell);
    command
        .arg("-lc")
        .arg(command_line)
        .current_dir(&request.cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(path) = completion_path() {
        command.env("PATH", path);
    }
    if let Some(environment) = &request.environment {
        for pair in environment {
            if should_forward_environment_key(&pair.key) {
                command.env(&pair.key, &pair.value);
            }
        }
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return GeneratorOutput {
                stdout: String::new(),
                stderr: error.to_string(),
                status: 1,
            };
        }
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_thread = thread::spawn(move || read_limited(stdout, output_limit));
    let stderr_thread = thread::spawn(move || read_limited(stderr, output_limit));
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(1),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                timed_out = true;
                let _ = child.kill();
                let _ = child.wait();
                break 124;
            }
            Err(error) => {
                return GeneratorOutput {
                    stdout: String::new(),
                    stderr: error.to_string(),
                    status: 1,
                };
            }
        }
    };

    let stdout = stdout_thread.join().unwrap_or_default();
    let mut stderr = stderr_thread.join().unwrap_or_default();
    if timed_out {
        if !stderr.is_empty() {
            stderr.push('\n');
        }
        stderr.push_str("vaultty-session-bridge: generator timed out");
    }

    GeneratorOutput {
        stdout,
        stderr,
        status,
    }
}

fn path_search_parts(expanded: &str, cwd: &str) -> (PathBuf, String) {
    if expanded.ends_with('/') {
        let directory = if expanded.starts_with('/') {
            PathBuf::from(expanded)
        } else {
            Path::new(cwd).join(expanded)
        };
        return (directory, String::new());
    }

    let (directory_part, file_prefix) = match expanded.rsplit_once('/') {
        Some(("", file_prefix)) => ("/", file_prefix),
        Some((directory_part, file_prefix)) => (directory_part, file_prefix),
        None => ("", expanded),
    };
    if directory_part.is_empty() || directory_part == "." {
        (PathBuf::from(cwd), file_prefix.to_owned())
    } else if directory_part.starts_with('/') {
        (PathBuf::from(directory_part), file_prefix.to_owned())
    } else {
        (Path::new(cwd).join(directory_part), file_prefix.to_owned())
    }
}

fn expand_tilde(prefix: &str) -> String {
    if prefix == "~" {
        env::var("HOME").unwrap_or_else(|_| prefix.to_owned())
    } else if let Some(rest) = prefix.strip_prefix("~/") {
        match env::var("HOME") {
            Ok(home) => format!("{home}/{rest}"),
            Err(_) => prefix.to_owned(),
        }
    } else {
        prefix.to_owned()
    }
}

fn path_insert_value(prefix: &str, suggestion_name: &str, is_directory: bool) -> String {
    let base_prefix = if prefix.ends_with('/') {
        prefix.to_owned()
    } else {
        let path = Path::new(prefix);
        let directory_name = path
            .parent()
            .map(|parent| parent.to_string_lossy().into_owned())
            .unwrap_or_default();
        if directory_name.is_empty() {
            String::new()
        } else if directory_name == "." {
            if prefix.starts_with("./") {
                "./".to_owned()
            } else {
                String::new()
            }
        } else {
            format!("{directory_name}/")
        }
    };
    let raw = format!("{base_prefix}{suggestion_name}");
    format!("{}{}", shell_escape_path(&raw), if is_directory { "" } else { " " })
}

fn shell_escape_path(path: &str) -> String {
    if path
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "-_./~".contains(character))
    {
        return path.to_owned();
    }
    let mut escaped = String::new();
    for character in path.chars() {
        if character == '\'' {
            escaped.push_str("'\\''");
        } else {
            escaped.push(character);
        }
    }
    format!("'{escaped}'")
}

fn shell_command_line_for(shell: &str, command_line: &str) -> String {
    if Path::new(shell).file_name().and_then(|name| name.to_str()) == Some("zsh") {
        return command_line.to_owned();
    }
    if let Some(rest) = command_line.strip_prefix("noglob ") {
        format!("set -f; {rest}")
    } else {
        command_line.to_owned()
    }
}

fn completion_path() -> Option<OsString> {
    let mut paths = Vec::new();
    append_split_paths(&mut paths, path_from_user_shell());
    append_split_paths(&mut paths, env::var_os("PATH"));
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        paths.push(home.join(".local").join("bin"));
        paths.push(home.join(".cargo").join("bin"));
    }
    paths.push(PathBuf::from("/opt/homebrew/bin"));
    paths.push(PathBuf::from("/usr/local/bin"));

    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
    env::join_paths(paths).ok()
}

fn append_split_paths(paths: &mut Vec<PathBuf>, path: Option<OsString>) {
    if let Some(path) = path {
        paths.extend(env::split_paths(&path));
    }
}

fn path_from_user_shell() -> Option<OsString> {
    let shell = env::var_os("SHELL")?;
    let shell_path = PathBuf::from(&shell);
    let shell_name = shell_path.file_name().and_then(|name| name.to_str());
    let shell_flag = match shell_name {
        Some("bash" | "zsh") => "-lic",
        _ => "-lc",
    };
    let output = Command::new(&shell)
        .arg(shell_flag)
        .arg("printf '%s' \"$PATH\"")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_owned();
    if path.is_empty() {
        None
    } else {
        Some(OsString::from(path))
    }
}

fn should_forward_environment_key(key: &str) -> bool {
    !matches!(key, "PATH" | "SHELL" | "HOME" | "USER" | "LOGNAME" | "PWD")
}

fn read_limited(pipe: Option<impl Read>, limit: usize) -> String {
    let Some(mut pipe) = pipe else {
        return String::new();
    };
    let mut output = Vec::new();
    let mut buffer = [0; 8192];
    loop {
        let Ok(count) = pipe.read(&mut buffer) else {
            break;
        };
        if count == 0 {
            break;
        }
        let remaining = limit.saturating_sub(output.len());
        if remaining > 0 {
            output.extend_from_slice(&buffer[..count.min(remaining)]);
        }
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn has_case_insensitive_prefix(value: &str, prefix: &str) -> bool {
    value
        .get(..prefix.len())
        .map(|head| head.eq_ignore_ascii_case(prefix))
        .unwrap_or(false)
}

fn is_remote_path_prefix(prefix: &str) -> bool {
    prefix.contains(':') && !prefix.starts_with("./") && !prefix.starts_with("../")
}

fn invalid_input(error: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, error)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(name: &str) -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock should be valid")
                .as_nanos();
            let path = env::temp_dir().join(format!(
                "vaultty-session-bridge-{name}-{}-{unique}",
                std::process::id()
            ));
            fs::create_dir_all(&path).expect("temp dir should be created");
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn names(suggestions: &[CompletionSuggestion]) -> Vec<String> {
        let mut names = suggestions
            .iter()
            .map(|suggestion| suggestion.display_text.clone())
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    #[test]
    fn path_completion_handles_relative_prefixes_and_spaces() {
        let temp = TempDir::new("path-relative");
        fs::create_dir(temp.path.join("src")).expect("folder should be created");
        fs::write(temp.path.join("space file.txt"), b"ok").expect("file should be created");

        let suggestions = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: "s".to_owned(),
            folders_only: false,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&suggestions), vec!["space file.txt", "src/"]);
        let spaced = suggestions
            .iter()
            .find(|suggestion| suggestion.display_text == "space file.txt")
            .expect("spaced file should be suggested");
        assert_eq!(spaced.insert_text, "'space file.txt' ");
    }

    #[test]
    fn path_completion_respects_folder_only_and_hidden_prefixes() {
        let temp = TempDir::new("path-filter");
        fs::create_dir(temp.path.join("alpha")).expect("folder should be created");
        fs::write(temp.path.join("atom"), b"ok").expect("file should be created");
        fs::write(temp.path.join(".secret"), b"ok").expect("hidden file should be created");

        let folders = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: "a".to_owned(),
            folders_only: true,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&folders), vec!["alpha/"]);

        let hidden = complete_path(&PathCompletionRequest {
            cwd: temp.path.to_string_lossy().into_owned(),
            prefix: ".".to_owned(),
            folders_only: false,
        })
        .expect("path completion should succeed");
        assert_eq!(names(&hidden), vec![".secret"]);
    }

    #[test]
    fn command_completion_scans_executables_from_path() {
        let temp = TempDir::new("commands");
        let executable = temp.path.join("vault-command");
        let non_executable = temp.path.join("vault-note");
        fs::write(&executable, b"#!/bin/sh\n").expect("executable should be created");
        fs::write(&non_executable, b"note").expect("file should be created");
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755))
            .expect("permissions should be updated");
        fs::set_permissions(&non_executable, fs::Permissions::from_mode(0o644))
            .expect("permissions should be updated");

        let suggestions =
            complete_commands_from_path(Some(OsString::from(temp.path.as_os_str())), "vault-");
        assert_eq!(names(&suggestions), vec!["vault-command"]);
    }

    #[test]
    fn generator_runs_with_cwd_environment_and_output_limit() {
        let temp = TempDir::new("generator");
        let output = run_generator(&GeneratorRequest {
            command_line: "printf '%s:%s' \"$VAULTTY_TEST_VALUE\" \"$(pwd)\"".to_owned(),
            cwd: temp.path.to_string_lossy().into_owned(),
            environment: Some(vec![EnvironmentPair {
                key: "VAULTTY_TEST_VALUE".to_owned(),
                value: "remote".to_owned(),
            }]),
            timeout_ms: Some(2_000),
            output_limit: Some(8),
        });
        assert_eq!(output.status, 0);
        assert_eq!(output.stdout, "remote:/");
    }

    #[test]
    fn generator_times_out() {
        let temp = TempDir::new("generator-timeout");
        let output = run_generator(&GeneratorRequest {
            command_line: "sleep 2".to_owned(),
            cwd: temp.path.to_string_lossy().into_owned(),
            environment: None,
            timeout_ms: Some(20),
            output_limit: Some(1024),
        });
        assert_eq!(output.status, 124);
        assert!(output.stderr.contains("timed out"));
    }
}
