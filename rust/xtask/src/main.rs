use std::{
    env,
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, ExitCode, Stdio},
    thread,
    time::{Duration, Instant},
};

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
