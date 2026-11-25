//! A single-host QUIC endpoint. The phone's streams terminate in the normal
//! authenticated host session on this connection. There is no forwarding hop.
use super::{HostCmd, HostEvents, Incoming, Router};
use crate::wire::{read_frame, read_msg, write_msg};
use airhand_proto::session::ByeReason;
use airhand_proto::signal::{
    ClientHello, ClientMsg, ConnectError, Peer, ServerHello, ServerMsg, SessionGrant,
};
use airhand_proto::{MAX_SIGNAL_MSG, Role, SIGNAL_VERSION, framing};
use anyhow::{Result, ensure};
use quinn::{Endpoint, EndpointConfig, ServerConfig, VarInt, crypto::rustls::QuicServerConfig};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;
use tokio::time::timeout;

pub const ALPN: &[u8] = b"airhand-host/1";
// The address selects the host. This value binds the existing Noise transcript
// on both ends. Admission always requires the pairing exchange or a known key.
pub const ADDRESS_CODE: u32 = 100_000;
const SETUP_TIMEOUT: Duration = Duration::from_secs(12);

pub fn new_certificate() -> Result<(Vec<u8>, Vec<u8>)> {
    let cert = rcgen::generate_simple_self_signed(vec!["airhand".into()])?;
    Ok((cert.cert.der().to_vec(), cert.signing_key.serialize_der()))
}

pub fn bind(port: u16, cert: Vec<u8>, key: Vec<u8>) -> Result<Endpoint> {
    let socket = crate::udp::bind((Ipv6Addr::UNSPECIFIED, port).into(), true)
        .or_else(|_| crate::udp::bind((Ipv4Addr::UNSPECIFIED, port).into(), false))?;
    endpoint(socket, cert, key)
}

fn endpoint(socket: std::net::UdpSocket, cert: Vec<u8>, key: Vec<u8>) -> Result<Endpoint> {
    let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_no_client_auth()
    .with_single_cert(
        vec![CertificateDer::from(cert)],
        PrivatePkcs8KeyDer::from(key).into(),
    )?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut server = ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    let mut transport = crate::net::transport_config();
    transport.max_concurrent_bidi_streams(VarInt::from_u32(1));
    server.transport_config(Arc::new(transport));
    Ok(Endpoint::new(
        EndpointConfig::default(),
        Some(server),
        socket,
        Arc::new(quinn::TokioRuntime),
    )?)
}

#[cfg(test)]
mod tests;

pub fn addresses(port: u16) -> Vec<SocketAddr> {
    let mut result = vec![];
    for iface in if_addrs::get_if_addrs().unwrap_or_default() {
        if iface.is_oper_up() && !iface.is_loopback() {
            let ip = iface.ip();
            if matches!(ip, std::net::IpAddr::V6(v) if v.is_unicast_link_local()) {
                continue;
            }
            result.push(SocketAddr::new(ip, port));
        }
    }
    result.sort();
    result.dedup();
    result
}

pub async fn run<E, S, F>(
    endpoint: Endpoint,
    host: (String, String),
    events: Arc<E>,
    session: S,
    mut commands: mpsc::UnboundedReceiver<HostCmd>,
    initial_resume: [u8; 16],
) where
    E: HostEvents,
    S: Fn(Incoming) -> F + Send + Sync + 'static,
    F: Future<Output = ()> + Send + 'static,
{
    let mut connections = JoinSet::new();
    let ids = Arc::new(AtomicU64::new(1));
    let session = Arc::new(session);
    let (kick, _) = watch::channel(ByeReason::Kicked);
    let (resume, _) = watch::channel(initial_resume);
    events.server(crate::ServerState::Connected);
    loop {
        tokio::select! {
            cmd = commands.recv() => {
                let Some(cmd) = cmd else { break };
                let fresh = rand::random();
                resume.send_replace(fresh);
                events.kicked(cmd);
                kick.send_replace(cmd.reason());
                events.direct_resume_changed(fresh);
            }
            Some(done) = connections.join_next() => match done {
                Ok(Ok(())) => {},
                Ok(Err(e)) => tracing::debug!("direct connection closed: {e:#}"),
                Err(e) => tracing::warn!("direct connection task ended: {e}"),
            },
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                if connections.len() >= 32 { incoming.refuse(); continue; }
                let (host, events, session, ids) = (host.clone(), events.clone(), session.clone(), ids.clone());
                let (kick, resume) = (kick.subscribe(), resume.subscribe());
                connections.spawn(async move {
                    let setup = async {
                        let conn = incoming.await?;
                        let (mut tx, mut rx) = conn.accept_bi().await?;
                        let mut buf = Vec::new();
                        ensure!(read_frame(&mut rx, MAX_SIGNAL_MSG, &mut buf).await?, "missing hello");
                        let hello: ClientHello = framing::decode_known(&buf)?;
                        write_msg(&mut tx, &ServerHello::new(None)).await?;
                        ensure!(hello.version == SIGNAL_VERSION && hello.role == Role::Controller, "incompatible controller");
                        Ok::<_, anyhow::Error>((conn, tx, rx, hello.name))
                    };
                    let (conn, mut tx, mut rx, name) = timeout(SETUP_TIMEOUT, setup).await??;
                    let (router, _router_task) = Router::start(&conn);
                    let observed = conn.remote_address();
                    let mut buf = Vec::new();
                    loop {
                        let msg = timeout(Duration::from_secs(45), read_msg(&mut rx, MAX_SIGNAL_MSG, &mut buf)).await??;
                        let Some(ClientMsg::Connect { req_id, code, init, resume: presented }) = msg else { break };
                        ensure!(init.len() <= airhand_proto::handshake::MAX_MSG, "oversized handshake");
                        let mut session_kick = kick.clone();
                        session_kick.borrow_and_update();
                        let token = *resume.borrow();
                        let id = ids.fetch_add(1, Ordering::Relaxed);
                        let grant = if code != ADDRESS_CODE {
                            Err(ConnectError::NotFound)
                        } else if presented.is_some_and(|t| t != token) {
                            Err(ConnectError::Revoked)
                        } else {
                            Ok(SessionGrant { session_id: id, host_name: host.0.clone(), host_os: host.1.clone(), resume: token, observed })
                        };
                        let accepted = grant.is_ok();
                        write_msg(&mut tx, &ServerMsg::connect_result(req_id, grant)).await?;
                        if accepted {
                            session(Incoming {
                                conn: conn.clone(), router: router.clone(), session_id: id, init, code,
                                peer: Peer { name: name.clone(), ip: observed.ip() }, kick: session_kick,
                                direct: None, file_limit: None,
                            }).await;
                            events.ended(id);
                        }
                    }
                    Ok::<_, anyhow::Error>(())
                });
            }
        }
    }
    endpoint.close(0u32.into(), b"host stopped");
    events.offline();
}
