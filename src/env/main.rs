use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::ffi::{CStr, CString, c_char, c_int};
use std::fs;
use std::path::{Path, PathBuf};

const DOTENV_KEYCHAIN_SERVICE: &str = "com.automicvault.dotenv";
const DOTENV_PUBLIC_KEY_PREFIX: &str = "DOTENV_PUBLIC_KEY";
const ENCRYPTED_PREFIX: &str = "encrypted:";
const ERR_SEC_ITEM_NOT_FOUND: c_int = -25300;

#[derive(Debug, Clone)]
struct Assignment {
    key: String,
    value: String,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("vaultty-env: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().map(String::as_str) == Some("export") {
        args.remove(0);
    }

    let mut cwd = env::current_dir().map_err(|err| format!("failed to resolve cwd: {err}"))?;
    let mut format = "zsh".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--cwd" => {
                i += 1;
                cwd = PathBuf::from(args.get(i).ok_or("--cwd requires a path")?);
            }
            "--format" | "--shell" => {
                i += 1;
                format = args.get(i).ok_or("--format requires a shell")?.clone();
            }
            "--help" | "-h" => {
                println!("Usage: vaultty-env export --cwd PATH [--format zsh]");
                return Ok(());
            }
            other => return Err(format!("unknown argument: {other}")),
        }
        i += 1;
    }

    if format != "zsh" && format != "bash" {
        return Err(format!("unsupported shell format: {format}"));
    }

    let previous_keys = env::var("VAULTTY_DOTENV_KEYS")
        .or_else(|_| env::var("AVTTY_DOTENV_KEYS"))
        .ok()
        .map(|value| {
            value
                .split(':')
                .filter(|key| !key.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let Some(env_path) = nearest_dotenv_file(&cwd) else {
        print_unload(&previous_keys);
        return Ok(());
    };

    let env_digest = sha256_file_hex(&env_path)?;
    if env::var("VAULTTY_DOTENV_FILE").ok().as_deref() == env_path.to_str()
        && env::var("VAULTTY_DOTENV_DIGEST").ok().as_deref() == Some(env_digest.as_str())
    {
        return Ok(());
    }

    let loaded = load_dotenv(&env_path, &previous_keys)?;
    print_unload(&previous_keys);
    for (key, value) in &loaded.values {
        println!("export {}={};", key, shell_quote(value));
    }
    println!("export VAULTTY_DOTENV_FILE={};", shell_quote(&loaded.env_path));
    println!("export VAULTTY_DOTENV_DIGEST={};", shell_quote(&loaded.env_sha256));
    println!("export VAULTTY_DOTENV_KEYS={};", shell_quote(&loaded.keys.join(":")));
    if !loaded.keys.is_empty() {
        eprintln!(
            "Vaultty dotenv: loaded {} ({})",
            display_path(Path::new(&loaded.env_path)),
            loaded.keys.join(", ")
        );
    }
    Ok(())
}

struct LoadedDotenv {
    env_path: String,
    env_sha256: String,
    keys: Vec<String>,
    values: BTreeMap<String, String>,
}

fn load_dotenv(path: &Path, previous_keys: &[String]) -> Result<LoadedDotenv, String> {
    let path = fs::canonicalize(path)
        .map_err(|err| format!("failed to resolve {}: {err}", path.display()))?;
    let contents =
        fs::read_to_string(&path).map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let assignments = parse_dotenv(&contents);
    let public_key = assignments
        .iter()
        .find(|assignment| is_public_key_name(&assignment.key))
        .map(|assignment| assignment.value.clone())
        .ok_or_else(|| format!("{} is missing DOTENV_PUBLIC_KEY", path.display()))?;
    let private_key = load_private_key(&public_key)?;
    validate_private_key_list(&private_key)?;

    let mut values = BTreeMap::new();
    for assignment in assignments {
        if is_public_key_name(&assignment.key) || !is_valid_key_name(&assignment.key) {
            continue;
        }
        if env::var_os(&assignment.key).is_some()
            && !previous_keys.iter().any(|existing| existing == &assignment.key)
        {
            continue;
        }
        values.insert(
            assignment.key.clone(),
            decrypt_value(&assignment.key, &assignment.value, &private_key)?,
        );
    }
    let keys = values.keys().cloned().collect::<Vec<_>>();
    Ok(LoadedDotenv {
        env_path: path.to_string_lossy().into_owned(),
        env_sha256: sha256_file_hex(&path)?,
        keys,
        values,
    })
}

fn parse_dotenv(contents: &str) -> Vec<Assignment> {
    contents
        .lines()
        .filter_map(parse_assignment)
        .collect::<Vec<_>>()
}

fn parse_assignment(line: &str) -> Option<Assignment> {
    let mut line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    if let Some(rest) = line.strip_prefix("export ") {
        line = rest.trim_start();
    }
    let (key, raw_value) = line.split_once('=')?;
    let key = key.trim();
    if !is_valid_key_name(key) {
        return None;
    }
    Some(Assignment {
        key: key.to_string(),
        value: parse_value(raw_value.trim_start()),
    })
}

fn parse_value(value: &str) -> String {
    if let Some(inner) = value.strip_prefix('"') {
        let mut out = String::new();
        let mut escape = false;
        for ch in inner.chars() {
            if escape {
                out.push(match ch {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    other => other,
                });
                escape = false;
                continue;
            }
            match ch {
                '\\' => escape = true,
                '"' => break,
                other => out.push(other),
            }
        }
        return out;
    }
    if let Some(inner) = value.strip_prefix('\'') {
        return inner.split('\'').next().unwrap_or_default().to_string();
    }
    value
        .split('#')
        .next()
        .unwrap_or_default()
        .trim_end()
        .to_string()
}

fn nearest_dotenv_file(cwd: &Path) -> Option<PathBuf> {
    let mut cursor = fs::canonicalize(cwd).ok()?;
    loop {
        let candidate = cursor.join(".env");
        if candidate.is_file() {
            return Some(candidate);
        }
        if !cursor.pop() {
            return None;
        }
    }
}

fn decrypt_value(key: &str, value: &str, private_keys: &str) -> Result<String, String> {
    if !value.starts_with(ENCRYPTED_PREFIX) {
        return Ok(value.to_string());
    }
    let encoded = value.strip_prefix(ENCRYPTED_PREFIX).unwrap();
    let ciphertext = BASE64
        .decode(encoded)
        .map_err(|err| format!("could not decrypt {key}: malformed encrypted data: {err}"))?;
    let mut last_error = None;
    for private_key in private_keys
        .split(',')
        .map(str::trim)
        .filter(|private_key| !private_key.is_empty())
    {
        let private_key = match decode_hex(private_key) {
            Ok(bytes) => bytes,
            Err(err) => {
                last_error = Some(err);
                continue;
            }
        };
        match ecies::decrypt(&private_key, &ciphertext) {
            Ok(value) => {
                return String::from_utf8(value)
                    .map_err(|_| format!("could not decrypt {key}: plaintext is not UTF-8"));
            }
            Err(err) => last_error = Some(err.to_string()),
        }
    }
    Err(format!(
        "could not decrypt {key}: {}",
        last_error.unwrap_or_else(|| "missing private key".to_string())
    ))
}

fn load_private_key(public_key: &str) -> Result<String, String> {
    let account = format!("DOTENV_PRIVATE_KEY:{}", public_key_fingerprint(public_key));
    keychain_read(DOTENV_KEYCHAIN_SERVICE, &account)
}

fn keychain_read(service: &str, account: &str) -> Result<String, String> {
    unsafe extern "C" {
        fn vaultty_copy_generic_password(
            service_cstr: *const c_char,
            account_cstr: *const c_char,
            error_cstr: *mut *mut c_char,
            status_out: *mut c_int,
        ) -> *mut c_char;
        fn vaultty_free_c_string(value: *mut c_char);
    }

    let service_cstr =
        CString::new(service).map_err(|_| "invalid keychain service name".to_string())?;
    let account_cstr =
        CString::new(account).map_err(|_| "invalid keychain account name".to_string())?;
    let mut error = std::ptr::null_mut();
    let mut status = 0;
    let value = unsafe {
        vaultty_copy_generic_password(
            service_cstr.as_ptr(),
            account_cstr.as_ptr(),
            &mut error,
            &mut status,
        )
    };
    if value.is_null() {
        let message = unsafe { take_c_string(error) }.unwrap_or_else(|| "keychain lookup failed".to_string());
        if status == ERR_SEC_ITEM_NOT_FOUND {
            return Err(format!("failed to load dotenv private key: {message}"));
        }
        return Err(format!("failed to load dotenv private key: {message}"));
    }
    let output = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { vaultty_free_c_string(value) };
    Ok(output)
}

unsafe fn take_c_string(value: *mut c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe extern "C" {
        fn vaultty_free_c_string(value: *mut c_char);
    }
    let output = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { vaultty_free_c_string(value) };
    Some(output)
}

fn print_unload(previous_keys: &[String]) {
    for key in previous_keys {
        if is_valid_key_name(key) {
            println!("unset {};", key);
        }
    }
    if !previous_keys.is_empty() {
        println!("unset VAULTTY_DOTENV_FILE;");
        println!("unset VAULTTY_DOTENV_DIGEST;");
        println!("unset VAULTTY_DOTENV_KEYS;");
        println!("unset AVTTY_DOTENV_FILE;");
        println!("unset AVTTY_DOTENV_DIGEST;");
        println!("unset AVTTY_DOTENV_KEYS;");
    }
}

fn shell_quote(value: &str) -> String {
    let mut output = String::from("'");
    for ch in value.chars() {
        if ch == '\'' {
            output.push_str("'\\''");
        } else {
            output.push(ch);
        }
    }
    output.push('\'');
    output
}

fn display_path(path: &Path) -> String {
    if let Some(home) = env::var_os("HOME").map(PathBuf::from) {
        if path == home {
            return "~".to_string();
        }
        if let Ok(relative) = path.strip_prefix(&home) {
            return format!("~/{}", relative.to_string_lossy());
        }
    }
    path.to_string_lossy().into_owned()
}

fn is_public_key_name(key: &str) -> bool {
    key == DOTENV_PUBLIC_KEY_PREFIX
        || key
            .strip_prefix(DOTENV_PUBLIC_KEY_PREFIX)
            .is_some_and(|suffix| suffix.starts_with('_'))
}

fn is_valid_key_name(key: &str) -> bool {
    let mut chars = key.chars();
    match chars.next() {
        Some(first) if first == '_' || first.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn validate_private_key_list(value: &str) -> Result<(), String> {
    for key in value
        .split(',')
        .map(str::trim)
        .filter(|key| !key.is_empty())
    {
        let decoded = decode_hex(key)?;
        if decoded.len() != 32 {
            return Err("dotenv private key must be 32 bytes".to_string());
        }
    }
    Ok(())
}

fn public_key_fingerprint(public_key: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(public_key.as_bytes());
    encode_hex(&hasher.finalize())
}

fn sha256_file_hex(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(encode_hex(&hasher.finalize()))
}

fn encode_hex(bytes: &[u8]) -> String {
    const TABLE: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(TABLE[(byte >> 4) as usize] as char);
        output.push(TABLE[(byte & 0x0f) as usize] as char);
    }
    output
}

fn decode_hex(value: &str) -> Result<Vec<u8>, String> {
    let value = value
        .trim()
        .strip_prefix("0x")
        .or_else(|| value.trim().strip_prefix("0X"))
        .unwrap_or(value.trim());
    if value.len() % 2 != 0 {
        return Err("hex value must have an even number of characters".to_string());
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    for chunk in value.as_bytes().chunks(2) {
        let high = hex_nibble(chunk[0])?;
        let low = hex_nibble(chunk[1])?;
        bytes.push((high << 4) | low);
    }
    Ok(bytes)
}

fn hex_nibble(byte: u8) -> Result<u8, String> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err("hex value contains invalid characters".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_dotenv_handles_quotes_comments_and_export() {
        let parsed = parse_dotenv(
            "export FOO=\"bar\\n baz\" # comment\nPLAIN=value # trailing\nSINGLE='literal#hash'\n# skip\n",
        );
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].key, "FOO");
        assert_eq!(parsed[0].value, "bar\n baz");
        assert_eq!(parsed[1].key, "PLAIN");
        assert_eq!(parsed[1].value, "value");
        assert_eq!(parsed[2].value, "literal#hash");
    }

    #[test]
    fn fingerprint_and_account_match_automic_vault_shape() {
        let public_key = "02c322fc0e7516f734f94bbfe5093d2d44eff775a7fbab1f867ee6ece812bf7157";
        let fingerprint = public_key_fingerprint(public_key);
        assert_eq!(fingerprint.len(), 64);
        assert_eq!(
            format!("DOTENV_PRIVATE_KEY:{fingerprint}"),
            "DOTENV_PRIVATE_KEY:7be46d20733687aa3ff5778c778edf02cbb19e0f29e35e36506ff8e988b2294a"
        );
    }

    #[test]
    fn shell_quote_round_trips_single_quotes() {
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
    }
}
