use std::{
    env,
    ffi::OsStr,
    fs,
    fs::OpenOptions,
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, ExitCode, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

const DB_NAME: &str = "tilegrove-dev";
const LISTEN_ADDR: &str = "127.0.0.1:3000";

fn main() -> ExitCode {
    let args = env::args().skip(1).collect::<Vec<_>>();
    let result = match args.as_slice() {
        [] => {
            help();
            Ok(())
        }
        [cmd] if cmd == "doctor" => doctor(),
        [cmd] if cmd == "check" => check(),
        [cmd] if cmd == "verify" => verify(),
        [cmd] if cmd == "dev" => dev(),
        [cmd] if cmd == "players" => players(),
        [cmd, rest @ ..] if cmd == "play" => play(rest),
        [cmd, sub] if cmd == "db" && sub == "start" => db_start(),
        [cmd, sub] if cmd == "db" && sub == "build" => db_build(),
        [cmd, sub] if cmd == "db" && sub == "publish" => db_publish(),
        [cmd, sub] if cmd == "db" && sub == "generate" => db_generate(),
        [cmd, sub] if cmd == "client" && sub == "build" => client_build(),
        [cmd, sub] if cmd == "godot" && sub == "run" => godot_run(),
        [cmd, sub] if cmd == "smoke" && sub == "two-clients" => smoke_two_clients(),
        _ => Err(format!("Unknown command: {}", args.join(" "))),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn help() {
    println!(
        "\
Tilegrove repository tasks

  cargo xtask doctor
  cargo xtask check
  cargo xtask verify
  cargo xtask db start|build|publish|generate
  cargo xtask client build
  cargo xtask godot run
  cargo xtask play --profile NAME [--name DISPLAY] [--uri URI] [--database DB] [--port PORT]
  cargo xtask players
  cargo xtask smoke two-clients
  cargo xtask dev"
    );
}

fn doctor() -> Result<(), String> {
    check_tool("cargo", ["--version"])?;
    check_tool("spacetime", ["--version"])?;
    check_tool("godot", ["--version"])?;
    println!("doctor: all required tools are available");
    Ok(())
}

fn check() -> Result<(), String> {
    run("cargo", ["check", "--workspace"], repo())
}
fn verify() -> Result<(), String> {
    check()?;
    client_build()?;
    run(
        "godot",
        [
            "--headless",
            "--path",
            "godot",
            "--script",
            "res://scripts/verify_probe.gd",
        ],
        repo(),
    )
}
fn db_start() -> Result<(), String> {
    exec(
        "spacetime",
        [
            "start",
            "--listen-addr",
            LISTEN_ADDR,
            "--data-dir",
            ".spacetime-data",
        ],
        repo(),
    )
}
fn db_build() -> Result<(), String> {
    run(
        "spacetime",
        ["build", "--module-path", "rust/server"],
        repo(),
    )
}
fn db_publish() -> Result<(), String> {
    run(
        "spacetime",
        [
            "publish",
            DB_NAME,
            "--server",
            "local",
            "--module-path",
            "rust/server",
            "--delete-data=always",
            "--yes",
        ],
        repo(),
    )
}
fn db_generate() -> Result<(), String> {
    run(
        "spacetime",
        [
            "generate",
            DB_NAME,
            "--lang",
            "rust",
            "--out-dir",
            "rust/client/generated",
            "--module-path",
            "rust/server",
            "--yes",
        ],
        repo(),
    )
}
fn client_build() -> Result<(), String> {
    run("cargo", ["build", "-p", "tilegrove-client"], repo())?;
    let (source_name, dest_name) = if cfg!(target_os = "macos") {
        ("libtilegrove_client.dylib", "libtilegrove.dylib")
    } else if cfg!(target_os = "windows") {
        ("tilegrove_client.dll", "tilegrove.dll")
    } else {
        ("libtilegrove_client.so", "libtilegrove.so")
    };
    let source = repo().join("target/debug").join(source_name);
    let destination = repo().join("godot/bin").join(dest_name);
    fs::create_dir_all(destination.parent().unwrap()).map_err(|error| error.to_string())?;
    fs::copy(&source, &destination)
        .map_err(|error| format!("copy {}: {error}", source.display()))?;
    Ok(())
}
fn godot_run() -> Result<(), String> {
    exec("godot", ["--path", "godot"], repo())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RuntimeDescriptor {
    profile: String,
    display_name: String,
    pid: u32,
    uri: String,
    database: String,
    control_port: u16,
    started_at_millis: u128,
}

struct PlayOptions {
    profile: String,
    display_name: String,
    uri: String,
    database: String,
    control_port: Option<u16>,
}

fn play(args: &[String]) -> Result<(), String> {
    let options = parse_play_options(args)?;
    let runtime_path = runtime_path(&options.profile)?;
    let lock_path = runtime_path.with_extension("lock");
    if let Some(existing) = read_descriptor(&runtime_path)? {
        if process_is_running(existing.pid) {
            return Err(format!(
                "profile {:?} is already running as pid {} on control port {}; use a different profile",
                existing.profile, existing.pid, existing.control_port
            ));
        }
        fs::remove_file(&runtime_path).map_err(|error| error.to_string())?;
    }
    acquire_profile_lock(&lock_path, &options.profile)?;

    let control_port = match options.control_port {
        Some(port) => {
            ensure_port_available(port)?;
            port
        }
        None => choose_control_port(&options.profile)?,
    };
    let descriptor = RuntimeDescriptor {
        profile: options.profile.clone(),
        display_name: options.display_name.clone(),
        pid: std::process::id(),
        uri: options.uri.clone(),
        database: options.database.clone(),
        control_port,
        started_at_millis: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| error.to_string())?
            .as_millis(),
    };
    if let Err(error) = write_descriptor(&runtime_path, &descriptor) {
        let _ = fs::remove_file(&lock_path);
        return Err(error);
    }
    println!(
        "starting profile {:?} ({}) on control port {}",
        descriptor.profile, descriptor.display_name, descriptor.control_port
    );
    let port = control_port.to_string();
    let result = exec_with_env(
        "godot",
        ["--path", "godot"],
        repo(),
        &[
            ("TILEGROVE_PROFILE", options.profile.as_str()),
            ("TILEGROVE_PLAYER_NAME", options.display_name.as_str()),
            ("TILEGROVE_SPACETIME_URI", options.uri.as_str()),
            ("TILEGROVE_DATABASE", options.database.as_str()),
            ("TILEGROVE_CONTROL_PORT", port.as_str()),
        ],
    );
    let _ = fs::remove_file(runtime_path);
    let _ = fs::remove_file(lock_path);
    result
}

fn players() -> Result<(), String> {
    let directory = runtime_dir();
    if !directory.exists() {
        println!("no Tilegrove profiles are running");
        return Ok(());
    }
    let mut active = Vec::new();
    for entry in fs::read_dir(&directory).map_err(|error| error.to_string())? {
        let path = entry.map_err(|error| error.to_string())?.path();
        if path.extension().and_then(OsStr::to_str) != Some("json") {
            continue;
        }
        if let Some(descriptor) = read_descriptor(&path)? {
            if process_is_running(descriptor.pid) {
                active.push(descriptor);
            } else {
                let _ = fs::remove_file(path);
            }
        }
    }
    active.sort_by(|left, right| left.profile.cmp(&right.profile));
    if active.is_empty() {
        println!("no Tilegrove profiles are running");
    } else {
        for descriptor in active {
            println!(
                "{}\t{}\tpid={}\tcontrol=http://127.0.0.1:{}\t{} / {}",
                descriptor.profile,
                descriptor.display_name,
                descriptor.pid,
                descriptor.control_port,
                descriptor.uri,
                descriptor.database
            );
        }
    }
    Ok(())
}

fn parse_play_options(args: &[String]) -> Result<PlayOptions, String> {
    let mut profile = None;
    let mut display_name = None;
    let mut uri = "http://127.0.0.1:3000".to_owned();
    let mut database = DB_NAME.to_owned();
    let mut control_port = None;
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        let value = args
            .get(index + 1)
            .ok_or_else(|| format!("{flag} requires a value"))?;
        match flag.as_str() {
            "--profile" => profile = Some(normalize_profile(value)?),
            "--name" => display_name = Some(value.clone()),
            "--uri" => uri = value.clone(),
            "--database" => database = value.clone(),
            "--port" => {
                control_port = Some(
                    value
                        .parse::<u16>()
                        .map_err(|_| format!("invalid control port: {value}"))?,
                )
            }
            _ => return Err(format!("unknown play option: {flag}")),
        }
        index += 2;
    }
    let profile = profile.ok_or_else(|| "play requires --profile NAME".to_owned())?;
    let display_name = display_name.unwrap_or_else(|| profile.clone());
    Ok(PlayOptions {
        profile,
        display_name,
        uri,
        database,
        control_port,
    })
}

fn normalize_profile(value: &str) -> Result<String, String> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized.is_empty()
        || !normalized
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err("profile names may contain only letters, numbers, '-' and '_'".to_owned());
    }
    Ok(normalized)
}

fn runtime_dir() -> PathBuf {
    repo().join(".tilegrove/runtimes")
}

fn runtime_path(profile: &str) -> Result<PathBuf, String> {
    let directory = runtime_dir();
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    Ok(directory.join(format!("{profile}.json")))
}

fn read_descriptor(path: &Path) -> Result<Option<RuntimeDescriptor>, String> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| format!("read {}: {error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("read {}: {error}", path.display())),
    }
}

fn write_descriptor(path: &Path, descriptor: &RuntimeDescriptor) -> Result<(), String> {
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(descriptor).map_err(|error| error.to_string())?;
    fs::write(&temporary, bytes).map_err(|error| error.to_string())?;
    fs::rename(&temporary, path).map_err(|error| error.to_string())
}

fn acquire_profile_lock(path: &Path, profile: &str) -> Result<(), String> {
    for _ in 0..2 {
        match OpenOptions::new().write(true).create_new(true).open(path) {
            Ok(mut file) => {
                return writeln!(file, "{}", std::process::id()).map_err(|error| error.to_string());
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let owner = fs::read_to_string(path)
                    .ok()
                    .and_then(|text| text.trim().parse::<u32>().ok());
                if owner.is_some_and(process_is_running) {
                    return Err(format!(
                        "profile {profile:?} is already starting or running as pid {}",
                        owner.unwrap()
                    ));
                }
                fs::remove_file(path).map_err(|error| {
                    format!("remove stale profile lock {}: {error}", path.display())
                })?;
            }
            Err(error) => return Err(format!("lock profile {profile:?}: {error}")),
        }
    }
    Err(format!("could not acquire profile lock for {profile:?}"))
}

fn process_is_running(pid: u32) -> bool {
    #[cfg(unix)]
    {
        Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }
    #[cfg(windows)]
    {
        output("tasklist", ["/FI", &format!("PID eq {pid}")], repo())
            .is_ok_and(|text| text.contains(&pid.to_string()))
    }
}

fn choose_control_port(profile: &str) -> Result<u16, String> {
    let hash = profile.bytes().fold(0u16, |value, byte| {
        value.wrapping_mul(31).wrapping_add(byte as u16)
    });
    let start = 38473 + hash % 1000;
    for offset in 0..1000u16 {
        let candidate = 38473 + (start - 38473 + offset) % 1000;
        if std::net::TcpListener::bind(("127.0.0.1", candidate)).is_ok() {
            return Ok(candidate);
        }
    }
    Err("no free Tilegrove control port was found".to_owned())
}

fn ensure_port_available(port: u16) -> Result<(), String> {
    std::net::TcpListener::bind(("127.0.0.1", port))
        .map(|_| ())
        .map_err(|_| format!("control port {port} is already in use"))
}
fn dev() -> Result<(), String> {
    db_publish()?;
    db_generate()?;
    client_build()?;
    godot_run()
}

fn smoke_two_clients() -> Result<(), String> {
    let data_dir = repo().join(".spacetime-smoke-data");
    let _ = fs::remove_dir_all(&data_dir);
    let mut server = spawn(
        "spacetime",
        [
            "start",
            "--listen-addr",
            LISTEN_ADDR,
            "--data-dir",
            ".spacetime-smoke-data",
            "--non-interactive",
        ],
        &[],
    )?;
    let result = (|| {
        thread::sleep(Duration::from_millis(1200));
        db_publish()?;
        db_generate()?;
        client_build()?;
        let mut alice = smoke_client("smoke-alice", "Alice", "east", "38611")?;
        let mut bob = smoke_client("smoke-bob", "Bob", "north", "38612")?;
        wait_child("Alice client", &mut alice, Duration::from_secs(30))?;
        wait_child("Bob client", &mut bob, Duration::from_secs(30))?;
        let players = sql("SELECT * FROM player")?;
        require(&players, "Alice", "player replication")?;
        require(&players, "Bob", "player replication")?;
        let positions = sql("SELECT * FROM player_position")?;
        require(&positions, "LittlerootTown", "position replication")?;
        require(&positions, "1", "authoritative movement revision")?;
        let maps = sql("SELECT map_name FROM world_map")?;
        require(
            &maps,
            "LittlerootTown_ProfessorBirchsLab",
            "world map seeding",
        )?;
        let npcs = sql("SELECT object_id, revision FROM npc_state")?;
        require(&npcs, "object_0_16_10", "NPC authority")?;
        let traces = sql("SELECT source_id, sequence FROM world_trace")?;
        require(&traces, "object_0_16_10", "persistent NPC trails")?;
        println!(
            "smoke two-clients: identities, replicated movement, 20-map authority, NPC state, and persistent trails verified"
        );
        Ok(())
    })();
    stop_child(&mut server);
    let _ = fs::remove_dir_all(data_dir);
    result
}

fn smoke_client(profile: &str, name: &str, direction: &str, port: &str) -> Result<Child, String> {
    spawn(
        "godot",
        ["--headless", "--path", "godot", "--quit-after", "30"],
        &[
            ("TILEGROVE_PROFILE", profile),
            ("TILEGROVE_PLAYER_NAME", name),
            ("TILEGROVE_CONTROL_PORT", port),
            ("TILEGROVE_SMOKE", "1"),
            ("TILEGROVE_SMOKE_DIRECTION", direction),
        ],
    )
}

fn sql(query: &str) -> Result<String, String> {
    output(
        "spacetime",
        ["sql", DB_NAME, query, "--server", "local", "--yes"],
        repo(),
    )
}
fn require(text: &str, expected: &str, label: &str) -> Result<(), String> {
    if text.contains(expected) {
        Ok(())
    } else {
        Err(format!("{label} did not contain {expected:?}\n{text}"))
    }
}
fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}
fn check_tool<const N: usize>(program: &str, args: [&str; N]) -> Result<(), String> {
    let text = output(program, args, repo())?;
    println!("{program}: {}", text.lines().next().unwrap_or("ok"));
    Ok(())
}
fn run<I, S>(program: &str, args: I, cwd: PathBuf) -> Result<(), String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let status = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}
fn output<I, S>(program: &str, args: I, cwd: PathBuf) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .output()
        .map_err(|error| error.to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(format!(
            "{program} exited with {}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}
fn exec<I, S>(program: &str, args: I, cwd: PathBuf) -> Result<(), String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let status = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}

fn exec_with_env<I, S>(
    program: &str,
    args: I,
    cwd: PathBuf,
    envs: &[(&str, &str)],
) -> Result<(), String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let status = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .envs(envs.iter().copied())
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}
fn spawn<I, S>(program: &str, args: I, envs: &[(&str, &str)]) -> Result<Child, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Command::new(program)
        .args(args)
        .current_dir(repo())
        .envs(envs.iter().copied())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| error.to_string())
}
fn wait_child(label: &str, child: &mut Child, timeout: Duration) -> Result<(), String> {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            return if status.success() {
                Ok(())
            } else {
                Err(format!("{label} exited with {status}"))
            };
        }
        if started.elapsed() >= timeout {
            stop_child(child);
            return Err(format!("{label} timed out"));
        }
        thread::sleep(Duration::from_millis(100));
    }
}
fn stop_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn play_options_require_an_explicit_valid_profile() {
        assert!(parse_play_options(&[]).is_err());
        assert!(normalize_profile("aster/../buzz").is_err());
        assert_eq!(normalize_profile(" Thimble_One ").unwrap(), "thimble_one");
    }

    #[test]
    fn play_options_keep_identity_separate_from_display_name() {
        let args = [
            "--profile".to_owned(),
            "agent-thimble".to_owned(),
            "--name".to_owned(),
            "Thimble".to_owned(),
            "--uri".to_owned(),
            "https://tilegrove.example".to_owned(),
            "--database".to_owned(),
            "grove".to_owned(),
        ];
        let options = parse_play_options(&args).unwrap();
        assert_eq!(options.profile, "agent-thimble");
        assert_eq!(options.display_name, "Thimble");
        assert_eq!(options.uri, "https://tilegrove.example");
        assert_eq!(options.database, "grove");
    }
}
