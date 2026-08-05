//! ras — minimal open remote-access server, compatible with the unmodified Torizon RAC.
//!
//! One binary: HTTP API (device + admin) + a `tough`-signed `remote-sessions` TUF repo + an
//! `russh` SSH bastion. State in SQLite. See docs/remote-access-design.md.
//!
//! Device identity comes from the gateway as `x-device-uuid` (nginx sets it from the verified
//! client cert). For local/dev testing without a gateway, set RAS_DEV_FALLBACK_UUID.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::num::NonZeroU64;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::json;
use russh::server::Server as _;
use russh_keys::PublicKeyBase64 as _;
use ssh_key::rand_core::OsRng;
use tough::schema::{RemoteSessions, RoleKeys, RoleType, Root, Signed};
use tough::sign::Sign;
use url::Url;

type Result<T> = color_eyre::Result<T>;

// ---------------- config ----------------
#[derive(Clone)]
struct Config {
    http_addr: String,
    bastion_addr: String,
    bastion_port: u16,
    public_host: String,
    ssh_user: String,
    port_range_start: u16,
    port_range_count: u16,
    dev_fallback_uuid: Option<String>,
    uuid_header: String,
    data_dir: PathBuf,
}

fn env_or(k: &str, d: &str) -> String { std::env::var(k).unwrap_or_else(|_| d.to_string()) }

impl Config {
    fn from_env() -> Config {
        let bastion_addr = env_or("RAS_BASTION_ADDR", "0.0.0.0:2222");
        let bastion_port = bastion_addr.rsplit(':').next().and_then(|p| p.parse().ok()).unwrap_or(2222);
        Config {
            http_addr: env_or("RAS_HTTP_ADDR", "0.0.0.0:9080"),
            bastion_addr,
            bastion_port,
            public_host: env_or("RAS_BASTION_PUBLIC_HOST", "127.0.0.1"),
            ssh_user: env_or("RAS_SSH_USER", "torizon"),
            port_range_start: env_or("RAS_PORT_RANGE_START", "22000").parse().unwrap_or(22000),
            port_range_count: env_or("RAS_PORT_RANGE_COUNT", "4").parse().unwrap_or(4),
            dev_fallback_uuid: std::env::var("RAS_DEV_FALLBACK_UUID").ok(),
            uuid_header: env_or("RAS_UUID_HEADER", "x-device-uuid").to_lowercase(),
            data_dir: PathBuf::from(env_or("RAS_DATA_DIR", "/data")),
        }
    }
}

// ---------------- shared state ----------------
struct AppState {
    cfg: Config,
    db: Mutex<Connection>,
    tuf_key: Box<dyn Sign + Send + Sync>,
    signed_root: Signed<Root>,
    bastion_pub: ssh_key::PublicKey,
    // active reverse-tunnel listeners keyed by port, so a device reconnect cancels the stale one
    port_listeners: Mutex<HashMap<u16, tokio::task::AbortHandle>>,
}

// ---------------- persistence helpers ----------------
fn init_db(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS device_keys (uuid TEXT PRIMARY KEY, pubkey TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS sessions (uuid TEXT PRIMARY KEY, operator_pubkey TEXT NOT NULL, reverse_port INTEGER NOT NULL, expires_at TEXT NOT NULL);",
    )?;
    Ok(())
}

fn load_or_gen_bastion_key(path: &PathBuf) -> Result<ssh_key::PrivateKey> {
    if path.exists() {
        let pem = std::fs::read_to_string(path)?;
        Ok(ssh_key::PrivateKey::from_openssh(&pem)?)
    } else {
        let key = ssh_key::PrivateKey::random(OsRng, ssh_key::Algorithm::Ed25519)?;
        std::fs::write(path, key.to_openssh(ssh_key::LineEnding::LF)?.as_bytes())?;
        Ok(key)
    }
}

fn load_or_gen_tuf_key(path: &PathBuf) -> Result<Box<dyn Sign + Send + Sync>> {
    let pkcs8: Vec<u8> = if path.exists() {
        std::fs::read(path)?
    } else {
        let rng = ring::rand::SystemRandom::new();
        let bytes = ring::signature::Ed25519KeyPair::generate_pkcs8(&rng).map_err(|e| eyre::eyre!("keygen: {e}"))?;
        std::fs::write(path, bytes.as_ref())?;
        bytes.as_ref().to_vec()
    };
    Ok(Box::new(tough::sign::parse_keypair(&pkcs8)?))
}

// ---------------- TUF ----------------
async fn sign_role<T: tough::schema::Role>(key: &dyn Sign, payload: T) -> Result<Signed<T>> {
    let rng = ring::rand::SystemRandom::new();
    let mut data = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut data, olpc_cjson::CanonicalFormatter::new());
    payload.serialize(&mut ser)?;
    let sig = key.sign(&data, &rng).await.map_err(|e| eyre::eyre!("sign: {e}"))?;
    let mut signed = Signed { signed: payload, signatures: Vec::new() };
    signed.signatures.push(tough::schema::Signature { keyid: key.tuf_key().key_id()?, sig: sig.into() });
    Ok(signed)
}

async fn build_root(key: &dyn Sign) -> Result<Signed<Root>> {
    let mut keys = HashMap::new();
    keys.insert(key.tuf_key().key_id()?, key.tuf_key());
    let role_keys = RoleKeys { keyids: vec![key.tuf_key().key_id()?], threshold: NonZeroU64::new(1).unwrap(), _extra: Default::default() };
    let mut roles = HashMap::new();
    roles.insert(RoleType::Root, role_keys.clone());
    roles.insert(RoleType::RemoteSessions, role_keys);
    let root = Root {
        spec_version: String::new(), consistent_snapshot: false, version: NonZeroU64::new(1).unwrap(),
        expires: Utc::now() + chrono::Duration::days(3650), keys, roles: tough::schema::Roles::new(&roles), _extra: HashMap::new(),
    };
    sign_role(key, root).await
}

async fn build_remote_sessions(state: &AppState, operator_keys: Vec<ssh_key::PublicKey>) -> Result<Signed<RemoteSessions>> {
    let mut authorized_keys_map = HashMap::<usize, serde_json::Value>::new();
    for (idx, k) in operator_keys.iter().enumerate() { authorized_keys_map.insert(idx, json!({ "pubkey": k })); }
    let ssh = json!({ "ssh": {
        "authorized_keys": authorized_keys_map,
        "ra_server_hosts": vec![state.cfg.public_host.clone(), "0.0.0.0".to_string(), "localhost".to_string()],
        "ra_server_ssh_pubkeys": vec![state.bastion_pub.clone()],
    }});
    let rs = RemoteSessions {
        remote_sessions: ssh, remote_commands: None,
        expires: Utc::now() + chrono::Duration::days(3650), version: NonZeroU64::new(1).unwrap(), _extra: HashMap::new(),
    };
    sign_role(&*state.tuf_key, rs).await
}

// gather operator pubkeys currently armed (non-expired sessions)
fn armed_operator_keys(state: &AppState) -> Vec<ssh_key::PublicKey> {
    let db = state.db.lock().unwrap();
    let now = Utc::now().to_rfc3339();
    let mut stmt = db.prepare("SELECT operator_pubkey FROM sessions WHERE expires_at > ?1").unwrap();
    let rows = stmt.query_map([now], |r| r.get::<_, String>(0)).unwrap();
    let mut out = Vec::new();
    for r in rows.flatten() { if let Ok(k) = r.parse::<ssh_key::PublicKey>() { out.push(k); } }
    out
}

// ---------------- request/response types ----------------
#[derive(Deserialize)]
struct DeviceKeyBody { key: String }
#[derive(Serialize, Clone)]
struct SshSession {
    authorized_pubkeys: Vec<ssh_key::PublicKey>,
    reverse_port: u16,
    ra_server_url: Url,
    ra_server_ssh_pubkey: ssh_key::PublicKey,
    expires_at: DateTime<Utc>,
}
#[derive(Serialize, Clone)]
struct DeviceSession { ssh: SshSession }
#[derive(Deserialize)]
struct CreateSession { uuid: String, operator_pubkey: String, #[serde(default)] ttl_secs: Option<i64> }

fn device_uuid(state: &AppState, headers: &HeaderMap) -> Option<String> {
    if let Some(v) = headers.get(&state.cfg.uuid_header) { if let Ok(s) = v.to_str() { if !s.is_empty() { return Some(s.to_string()); } } }
    state.cfg.dev_fallback_uuid.clone()
}

// ---------------- device-facing handlers ----------------
async fn post_public_keys(State(st): State<Arc<AppState>>, headers: HeaderMap, Json(body): Json<DeviceKeyBody>) -> Response {
    let Some(uuid) = device_uuid(&st, &headers) else { return (StatusCode::BAD_REQUEST, "missing device uuid").into_response() };
    if body.key.parse::<ssh_key::PublicKey>().is_err() { return (StatusCode::BAD_REQUEST, "invalid key").into_response(); }
    let db = st.db.lock().unwrap();
    let _ = db.execute("INSERT INTO device_keys(uuid,pubkey) VALUES(?1,?2) ON CONFLICT(uuid) DO UPDATE SET pubkey=?2", rusqlite::params![uuid, body.key.trim()]);
    log::info!("registered key for device {uuid}");
    StatusCode::OK.into_response()
}

fn active_session(st: &AppState, uuid: &str) -> Option<(String, u16, DateTime<Utc>)> {
    let db = st.db.lock().unwrap();
    let now = Utc::now();
    let row = db.query_row("SELECT operator_pubkey, reverse_port, expires_at FROM sessions WHERE uuid=?1", [uuid],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u16, r.get::<_, String>(2)?))).ok()?;
    let exp = DateTime::parse_from_rfc3339(&row.2).ok()?.with_timezone(&Utc);
    if exp <= now { return None; }
    Some((row.0, row.1, exp))
}

async fn get_sessions(State(st): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let Some(uuid) = device_uuid(&st, &headers) else { return StatusCode::NOT_FOUND.into_response() };
    let Some((op_key, rport, exp)) = active_session(&st, &uuid) else { return StatusCode::NOT_FOUND.into_response() };
    let Ok(op_pub) = op_key.parse::<ssh_key::PublicKey>() else { return StatusCode::INTERNAL_SERVER_ERROR.into_response() };
    let url = match Url::parse(&format!("ssh://{}@{}:{}", uuid, st.cfg.public_host, st.cfg.bastion_port)) {
        Ok(u) => u, Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let ds = DeviceSession { ssh: SshSession {
        authorized_pubkeys: vec![op_pub], reverse_port: rport, ra_server_url: url,
        ra_server_ssh_pubkey: st.bastion_pub.clone(), expires_at: exp,
    }};
    Json(ds).into_response()
}

async fn get_commands() -> Response { Json(json!({ "values": [] })).into_response() }
async fn get_ok() -> Response { "OK".into_response() }
async fn get_root(State(st): State<Arc<AppState>>) -> Response { Json(st.signed_root.clone()).into_response() }
async fn get_remote_sessions(State(st): State<Arc<AppState>>) -> Response {
    match build_remote_sessions(&st, armed_operator_keys(&st)).await {
        Ok(s) => Json(s).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("{e}")).into_response(),
    }
}

// ---------------- admin handlers ----------------
fn alloc_port(st: &AppState) -> Option<u16> {
    let db = st.db.lock().unwrap();
    let used: Vec<u16> = {
        let mut stmt = db.prepare("SELECT reverse_port FROM sessions").unwrap();
        stmt.query_map([], |r| Ok(r.get::<_, i64>(0)? as u16)).unwrap().flatten().collect()
    };
    (st.cfg.port_range_start..st.cfg.port_range_start + st.cfg.port_range_count).find(|p| !used.contains(p))
}

async fn admin_create_session(State(st): State<Arc<AppState>>, Json(body): Json<CreateSession>) -> Response {
    if body.operator_pubkey.parse::<ssh_key::PublicKey>().is_err() { return (StatusCode::BAD_REQUEST, "invalid operator_pubkey").into_response(); }
    let ttl = body.ttl_secs.unwrap_or(3600).clamp(60, 86_400);
    let Some(port) = alloc_port(&st) else { return (StatusCode::CONFLICT, "no free tunnel port (max concurrent sessions reached)").into_response() };
    let exp = (Utc::now() + chrono::Duration::seconds(ttl)).to_rfc3339();
    {
        let db = st.db.lock().unwrap();
        let _ = db.execute("INSERT INTO sessions(uuid,operator_pubkey,reverse_port,expires_at) VALUES(?1,?2,?3,?4) ON CONFLICT(uuid) DO UPDATE SET operator_pubkey=?2, reverse_port=?3, expires_at=?4",
            rusqlite::params![body.uuid, body.operator_pubkey.trim(), port as i64, exp]);
    }
    log::info!("armed session for {} on port {}", body.uuid, port);
    Json(json!({
        "uuid": body.uuid, "reverse_port": port, "expires_at": exp,
        "ssh_command": format!("ssh {}@{} -p {}", st.cfg.ssh_user, st.cfg.public_host, port),
    })).into_response()
}

async fn admin_delete_session(State(st): State<Arc<AppState>>, Path(uuid): Path<String>) -> Response {
    let db = st.db.lock().unwrap();
    let _ = db.execute("DELETE FROM sessions WHERE uuid=?1", [uuid]);
    StatusCode::NO_CONTENT.into_response()
}

async fn admin_list_sessions(State(st): State<Arc<AppState>>) -> Response {
    let db = st.db.lock().unwrap();
    let mut stmt = db.prepare("SELECT uuid, reverse_port, expires_at FROM sessions").unwrap();
    let rows: Vec<serde_json::Value> = stmt.query_map([], |r| Ok(json!({
        "uuid": r.get::<_, String>(0)?, "reverse_port": r.get::<_, i64>(1)?, "expires_at": r.get::<_, String>(2)?,
    }))).unwrap().flatten().collect();
    Json(json!({ "values": rows })).into_response()
}

// ---------------- SSH bastion ----------------
#[derive(Clone)]
struct Bastion { state: Arc<AppState> }
impl russh::server::Server for Bastion {
    type Handler = BastionConn;
    fn new_client(&mut self, _: Option<SocketAddr>) -> BastionConn { BastionConn { state: self.state.clone(), uuid: None } }
}
struct BastionConn { state: Arc<AppState>, uuid: Option<String> }

#[async_trait]
impl russh::server::Handler for BastionConn {
    type Error = eyre::Error;

    async fn auth_publickey(&mut self, user: &str, key: &russh_keys::key::PublicKey) -> Result<russh::server::Auth> {
        // the SSH username is the device UUID; accept only the key we have on file for it
        let offered = key.public_key_base64(); // base64 of the key blob
        let stored: Option<String> = {
            let db = self.state.db.lock().unwrap();
            db.query_row("SELECT pubkey FROM device_keys WHERE uuid=?1", [user], |r| r.get(0)).ok()
        };
        if let Some(sk) = stored {
            // stored is an openssh line "ssh-ed25519 <base64> [comment]"; compare the base64 blob
            if sk.split_whitespace().nth(1) == Some(offered.as_str()) {
                self.uuid = Some(user.to_string());
                log::info!("bastion: device {user} authenticated");
                return Ok(russh::server::Auth::Accept);
            }
        }
        log::warn!("bastion: rejected auth for user {user}");
        Ok(russh::server::Auth::Reject { proceed_with_methods: None })
    }

    async fn tcpip_forward(&mut self, _address: &str, port: &mut u32, session: &mut russh::server::Session) -> Result<bool> {
        let Some(uuid) = self.uuid.clone() else { return Ok(false) };
        let want = *port as u16;
        // only honor the reverse port allocated to this device's active session
        let allowed = active_session(&self.state, &uuid).map(|(_, p, _)| p);
        if allowed != Some(want) {
            log::warn!("bastion: {uuid} requested port {want}, not its allocated port ({allowed:?}) — refusing");
            return Ok(false);
        }
        let bind_port = want;
        // cancel any stale listener for this port (e.g. from a previous connection of this device)
        if let Some(old) = self.state.port_listeners.lock().unwrap().remove(&bind_port) { old.abort(); }
        let handle = session.handle();
        let task = tokio::spawn(async move {
            // retry a few times: the aborted stale listener may take a moment to free the port
            let mut listener = None;
            for _ in 0..15 {
                match tokio::net::TcpListener::bind(("0.0.0.0", bind_port)).await {
                    Ok(l) => { listener = Some(l); break; }
                    Err(_) => tokio::time::sleep(std::time::Duration::from_millis(200)).await,
                }
            }
            let Some(listener) = listener else { log::error!("bastion: could not bind {bind_port} for {uuid}"); return; };
            log::info!("bastion: reverse listener open on 0.0.0.0:{bind_port} for {uuid}");
            loop {
                let (mut ingress, addr) = match listener.accept().await { Ok(x) => x, Err(_) => break };
                let handle = handle.clone();
                tokio::spawn(async move {
                    let ch = match handle.channel_open_forwarded_tcpip("127.0.0.1", bind_port as u32, addr.ip().to_string(), u32::from(addr.port())).await {
                        Ok(c) => c, Err(e) => { log::warn!("forwarded-tcpip open failed: {e}"); return; }
                    };
                    let mut egress = ch.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut ingress, &mut egress).await;
                });
            }
        });
        self.state.port_listeners.lock().unwrap().insert(bind_port, task.abort_handle());
        Ok(true)
    }
}

async fn run_bastion(state: Arc<AppState>, host_key: ssh_key::PrivateKey) -> Result<()> {
    let keypair = russh_keys::decode_openssh(&host_key.to_bytes()?, None)?;
    let mut config = russh::server::Config::default();
    config.keys.push(keypair);
    let config = Arc::new(config);
    let addr = state.cfg.bastion_addr.clone();
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    log::info!("bastion listening on {addr}");
    let mut server = Bastion { state };
    loop {
        let (socket, peer) = listener.accept().await?;
        let config = config.clone();
        let handler = server.new_client(socket.peer_addr().ok());
        let _ = peer;
        tokio::spawn(async move {
            match russh::server::run_stream(config, socket, handler).await {
                Ok(s) => { let _ = s.await; }
                Err(e) => log::debug!("bastion session error: {e}"),
            }
        });
    }
}

// periodic cleanup of expired sessions
async fn cleanup_loop(state: Arc<AppState>) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        let now = Utc::now().to_rfc3339();
        let db = state.db.lock().unwrap();
        if let Ok(n) = db.execute("DELETE FROM sessions WHERE expires_at <= ?1", [now]) {
            if n > 0 { log::info!("cleanup: removed {n} expired session(s)"); }
        }
    }
}

fn app_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/public-keys", post(post_public_keys))
        .route("/sessions", get(get_sessions))
        .route("/commands", get(get_commands))
        .route("/ok", get(get_ok))
        .route("/director/root.json", get(get_root))
        .route("/director/remote-sessions.json", get(get_remote_sessions))
        .route("/admin/sessions", get(admin_list_sessions).post(admin_create_session))
        .route("/admin/sessions/:uuid", delete(admin_delete_session))
        .with_state(state)
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install().ok();
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let cfg = Config::from_env();
    std::fs::create_dir_all(&cfg.data_dir).ok();

    let host_key = load_or_gen_bastion_key(&cfg.data_dir.join("bastion_host_key"))?;
    let bastion_pub = host_key.public_key().clone();
    log::info!("bastion host key: {}", bastion_pub.to_openssh()?);
    let tuf_key = load_or_gen_tuf_key(&cfg.data_dir.join("tuf_ed25519.pk8"))?;
    let signed_root = build_root(&*tuf_key).await?;

    let conn = Connection::open(cfg.data_dir.join("ras.db"))?;
    init_db(&conn)?;

    let state = Arc::new(AppState { cfg: cfg.clone(), db: Mutex::new(conn), tuf_key, signed_root, bastion_pub, port_listeners: Mutex::new(HashMap::new()) });

    tokio::spawn(cleanup_loop(state.clone()));
    let bastion_state = state.clone();
    tokio::spawn(async move { if let Err(e) = run_bastion(bastion_state, host_key).await { log::error!("bastion exited: {e}"); } });

    let http_addr: SocketAddr = cfg.http_addr.parse()?;
    log::info!("http api listening on {http_addr}");
    axum::Server::bind(&http_addr).serve(app_router(state).into_make_service()).await?;
    Ok(())
}
