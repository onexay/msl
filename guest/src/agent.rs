// SPDX-License-Identifier: Apache-2.0
//! The in-distro Agent gRPC service.

use crate::pb::{self, agent_server::Agent};
use crate::{config, session};
use std::pin::Pin;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

pub struct AgentService {
    pub distro: String,
}

type EventStream<T> = Pin<Box<dyn futures_util::Stream<Item = Result<T, Status>> + Send>>;

#[tonic::async_trait]
impl Agent for AgentService {
    type RunStream = EventStream<pb::RunEvent>;

    async fn run(&self, req: Request<pb::RunRequest>) -> Result<Response<Self::RunStream>, Status> {
        let (tx, rx) = tokio::sync::mpsc::channel(4);
        let req = req.into_inner();
        let distro = self.distro.clone();
        tokio::spawn(async move {
            if let Err(e) = session::run(req, tx.clone(), distro).await {
                let _ = tx.send(Err(e)).await;
            }
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn resize(&self, req: Request<pb::ResizeRequest>) -> Result<Response<pb::Empty>, Status> {
        let r = req.into_inner();
        session::resize(r.session_id, r.rows, r.cols)?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn signal(&self, req: Request<pb::SignalRequest>) -> Result<Response<pb::Empty>, Status> {
        let r = req.into_inner();
        session::signal(r.session_id, r.signal)?;
        Ok(Response::new(pb::Empty {}))
    }

    async fn lookup_user(&self, req: Request<pb::LookupUserRequest>) -> Result<Response<pb::LookupUserReply>, Status> {
        let u = crate::users::by_name("", &req.into_inner().name);
        Ok(Response::new(pb::LookupUserReply { found: u.is_some(), uid: u.map(|u| u.uid).unwrap_or(0) }))
    }

    async fn info(&self, _: Request<pb::Empty>) -> Result<Response<pb::DistroInfo>, Status> {
        let conf = config::distro_conf("");
        let os = config::Ini::parse(&format!("[os]\n{}", std::fs::read_to_string("/etc/os-release").unwrap_or_default()));
        Ok(Response::new(pb::DistroInfo {
            default_user: conf.get("user.default").unwrap_or_default().to_string(),
            systemd: conf.bool("boot.systemd", false),
            distribution_conf: Some(config::distribution_conf("")),
            os_pretty_name: os.get("os.pretty_name").unwrap_or_default().to_string(),
        }))
    }
}

/// Serve the Agent on `port` forever (current-thread runtime).
pub fn serve(port: u32, distro: String, on_ready: impl FnOnce()) -> ! {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
    rt.block_on(async move {
        let incoming = match crate::rpc::incoming(port) {
            Ok(i) => i,
            Err(e) => {
                crate::sys::log(&format!("agent: listen vsock:{port}: {e}"));
                std::process::exit(1);
            }
        };
        on_ready();
        let svc = pb::agent_server::AgentServer::new(AgentService { distro });
        if let Err(e) = tonic::transport::Server::builder().add_service(svc).serve_with_incoming(incoming).await {
            crate::sys::log(&format!("agent: server: {e}"));
        }
    });
    std::process::exit(1)
}
