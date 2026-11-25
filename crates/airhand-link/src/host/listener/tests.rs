use super::*;
use crate::controller::{
    Command, ConnectOptions, ControllerService, Frontend, SessionEvent, SessionUi, UiClosed,
};
use crate::host::{Gate, HostStreams, Pairing, PairingState, PairingStore, Request};
use crate::net::LinkConfig;
use crate::secure::{Identity, PairingAttempt};
use crate::{Problem, ServerState};
use airhand_proto::handshake::PublicKey;
use airhand_proto::media::{self, AudioHeader, VideoHeader};
use airhand_proto::session::{HostMsg, InputEvent};
use airhand_proto::signal::Reclaim;

struct Events;
impl HostEvents for Events {
    fn server(&self, _: ServerState) {}
    async fn registered(&self, _: Reclaim, _: bool) {}
    async fn released(&self) {}
    fn ended(&self, _: u64) {}
    fn offline(&self) {}
}
impl PairingStore for Events {
    fn changed(&self, _: &PairingState) {}
}
struct TestHost(Identity, Pairing);
impl Gate for TestHost {
    fn identity(&self) -> Identity {
        self.0.clone()
    }
    fn is_known(&self, key: &PublicKey) -> bool {
        self.1.is_known(key)
    }
    fn begin_pairing(&self) -> Option<Box<dyn PairingAttempt + '_>> {
        self.1.begin()
    }
}
struct Ui(mpsc::UnboundedSender<String>);
impl SessionUi for Ui {
    fn packet(&self, data: Vec<u8>) -> Result<(), UiClosed> {
        if data.ends_with(b"audio sample") {
            self.0.send("audio".into()).unwrap();
        }
        if data.ends_with(b"video sample") {
            self.0.send("video".into()).unwrap();
        }
        Ok(())
    }
    fn event(&self, event: SessionEvent) -> Result<(), UiClosed> {
        if let SessionEvent::Clipboard { text } = event {
            self.0.send(text).unwrap();
        }
        Ok(())
    }
}

#[tokio::test]
async fn direct_pairing_media_control_and_reconnect() {
    timeout(Duration::from_secs(25), exercise())
        .await
        .expect("direct session timed out");
}

#[tokio::test]
async fn literal_addresses_check_the_certificate_and_negotiate_direct_host_only() {
    use sha2::{Digest, Sha256};
    for ip in [
        std::net::IpAddr::V4(Ipv4Addr::LOCALHOST),
        Ipv6Addr::LOCALHOST.into(),
    ] {
        let socket = crate::udp::bind((ip, 0).into(), false).unwrap();
        let addr = socket.local_addr().unwrap();
        let (cert, key) = new_certificate().unwrap();
        let pin = crate::net::format_fingerprint(&Sha256::digest(&cert).into());
        let endpoint = endpoint(socket, cert, key).unwrap();
        let (shutdown, cmds) = mpsc::unbounded_channel();
        let host = tokio::spawn(run(
            endpoint,
            ("pc".into(), "test".into()),
            Arc::new(Events),
            |_| async { panic!("no session requested") },
            cmds,
            [0; 16],
        ));
        let dial = |target: String, fingerprint: &str| {
            LinkConfig::new(target, fingerprint, "ctl", "test").unwrap()
        };
        let target = format!("direct://{addr}");
        let good = dial(target.clone(), &pin);
        let direct = crate::net::connect_signal(&good, Role::Controller, None)
            .await
            .unwrap();
        assert_eq!(direct.conn.remote_address().port(), addr.port());
        let wrong = dial(target, &"00".repeat(32));
        assert!(matches!(
            crate::net::connect_signal(&wrong, Role::Controller, None).await,
            Err(Problem::CertMismatch)
        ));
        let legacy = dial(addr.to_string(), &pin);
        assert!(
            crate::net::connect_signal(&legacy, Role::Controller, None)
                .await
                .is_err()
        );
        drop(shutdown);
        host.await.unwrap();
    }
}

async fn exercise() {
    let (cert, key) = new_certificate().unwrap();
    let socket = crate::udp::bind((Ipv4Addr::LOCALHOST, 0).into(), false).unwrap();
    let port = socket.local_addr().unwrap().port();
    let endpoint = endpoint(socket, cert, key).unwrap();
    let (shutdown, cmds) = mpsc::unbounded_channel();
    let (seen, mut requests) = mpsc::unbounded_channel();
    let host = Arc::new(TestHost(Identity::generate(), Pairing::new(None, Events)));
    let pairing = host.1.state().code;
    let wrong = if pairing == "111111" {
        "222222"
    } else {
        "111111"
    };
    let task = tokio::spawn(run(
        endpoint,
        ("test desktop".into(), "test".into()),
        Arc::new(Events),
        move |mut inc| {
            let (host, seen) = (host.clone(), seen.clone());
            async move {
                let Ok((mut streams, adm)) = HostStreams::open(&inc, 4, 16, &*host).await else {
                    return;
                };
                streams.incoming.confirmation().await.unwrap();
                seen.send(format!("{:?}", adm.admission)).unwrap();
                let video = VideoHeader {
                    seq: 1,
                    key: true,
                    width: 16,
                    height: 16,
                    ..Default::default()
                };
                streams.video[0]
                    .send(media::frame(&video.encode(), &[b"video sample"]).into())
                    .await
                    .unwrap();
                let audio = AudioHeader {
                    seq: 1,
                    start: true,
                    capture_us: 1,
                };
                streams
                    .audio
                    .send(media::frame(&audio.encode(), &[b"audio sample"]).into())
                    .await
                    .unwrap();
                loop {
                    tokio::select! {
                        req = streams.incoming.recv() => match req {
                            Some(Request::Clipboard(text)) => { streams.out.send(&HostMsg::Clipboard {text}).unwrap(); }
                            Some(Request::Input(events)) if events == [InputEvent::MouseDelta { dx: 3, dy: -2 }] => { seen.send("input".into()).unwrap(); }
                            None => break,
                            _ => {}
                        },
                        _ = inc.kick.changed() => {
                            streams.out.send(&HostMsg::Bye(*inc.kick.borrow())).unwrap();
                            break;
                        }
                    }
                }
                let _ = streams.close(inc.session_id, Ok(())).await;
            }
        },
        cmds,
        [5; 16],
    ));
    let (messages, mut received) = mpsc::unbounded_channel();
    let ui = Arc::new(Ui(messages));
    let (state, mut ready) = watch::channel(ServerState::Connecting);
    let cfg = LinkConfig::new(format!("direct://localhost:{port}"), "", "phone", "test").unwrap();
    let ctl = ControllerService::start(
        Arc::new(cfg),
        tokio::runtime::Handle::current(),
        Arc::new(move |s| {
            state.send_replace(s);
        }),
        Arc::new(|_| {}),
        Identity::generate(),
    );
    ready
        .wait_for(|s| *s == ServerState::Connected)
        .await
        .unwrap();
    let connect = |opts| ctl.connect("100000", opts, ui.clone(), Frontend::Browser);
    assert!(matches!(
        connect(Default::default()).await,
        Err(Problem::PairingRequired)
    ));
    assert!(matches!(
        connect(ConnectOptions {
            pairing: Some(wrong.into()),
            ..Default::default()
        })
        .await,
        Err(Problem::PairingFailed)
    ));
    let first = connect(ConnectOptions {
        pairing: Some(pairing),
        audio: true,
        ..Default::default()
    })
    .await
    .unwrap();
    assert_eq!(requests.recv().await.unwrap(), "Paired");
    ctl.command(Command::Input {
        sid: first.sid,
        events: vec![InputEvent::MouseDelta { dx: 3, dy: -2 }],
    })
    .unwrap();
    ctl.command(Command::Clipboard {
        sid: first.sid,
        text: "clipboard".into(),
    })
    .unwrap();
    assert_eq!(requests.recv().await.unwrap(), "input");
    let mut seen = vec![];
    for _ in 0..3 {
        seen.push(received.recv().await.unwrap());
    }
    seen.sort();
    assert_eq!(seen, ["audio", "clipboard", "video"]);
    ctl.disconnect(first.sid);
    let saved = ConnectOptions {
        host_key: Some(first.host_key.clone()),
        resume: Some(first.resume),
        ..Default::default()
    };
    let _second = connect(saved).await.unwrap();
    assert_eq!(requests.recv().await.unwrap(), "Known");
    shutdown.send(HostCmd::KickAll).unwrap();
    assert!(matches!(
        connect(ConnectOptions {
            resume: Some(first.resume),
            ..Default::default()
        })
        .await,
        Err(Problem::Kicked)
    ));
    drop(shutdown);
    task.await.unwrap();
}
