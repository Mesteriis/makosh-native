#[path = "calls_group.rs"]
mod group;
#[path = "calls_media.rs"]
mod media;
// Owned per-account call state. No media globals or device access in the worker.
use serde::Serialize;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::Mutex;
use whatsapp_rust::wacore_binary::JidExt;
use whatsapp_rust::{
    prelude::*,
    voip::{CallEvent, CallHandle, VideoUpgradeToken},
    wacore::types::call::{CallAction, IncomingCall, VideoState},
};

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub group: Option<group::Snapshot>,
    pub id: String,
    pub epoch: u64,
    pub peer: String,
    pub state: String,
    pub incoming: bool,
    pub video: bool,
    pub remote_video: bool,
    pub video_requested: bool,
    pub muted: bool,
}
pub use media::{Exchange, MediaQueues};
pub struct EndSignal {
    id: String,
    peer: Jid,
    creator: Jid,
}
struct Active {
    handle: CallHandle,
    queues: Arc<MediaQueues>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    upgrade: Arc<Mutex<Option<VideoUpgradeToken>>>,
}
#[derive(Default)]
struct State {
    epoch: u64,
    snapshot: Option<Snapshot>,
    incoming: Option<IncomingCall>,
    active: Option<Active>,
    starting: bool,
    call_context: Option<(String, u64)>,
    group_state: Option<whatsapp_rust::voip::GroupCallState>,
    own_users: Vec<Jid>,
    ringing_generation: Option<u64>,
    last_ended: Option<(String, u64)>,
    rejecting: Option<IncomingCall>,
    accepted: std::collections::BTreeSet<String>,
}
#[derive(Default)]
pub struct Calls {
    state: Mutex<State>,
    changed: tokio::sync::Notify,
}
impl Calls {
    pub async fn during<T>(
        &self,
        epoch: u64,
        work: impl std::future::Future<Output = Result<T, &'static str>>,
    ) -> Result<T, &'static str> {
        let revoked = self.changed.notified();
        tokio::pin!(revoked);
        revoked.as_mut().enable();
        if !self.is_current(epoch).await {
            return Err("closed");
        }
        tokio::select! {biased;_=revoked=>Err("closed"),result=work=>result}
    }
    pub async fn is_current(&self, epoch: u64) -> bool {
        self.state.lock().await.epoch == epoch
    }
    pub async fn admit(
        &self,
        chat: &str,
        a: &crate::commands::Action,
    ) -> Result<u64, &'static str> {
        let mut s = self.state.lock().await;
        match a.op.as_str() {
            "call_start" | "call_accept" | "call_group_start" => {
                if !codec_version()?.contains("libopus 1.6.1") {
                    return Err("codec");
                }
                let peer: Jid = chat.parse().map_err(|_| "input")?;
                if (peer.is_group() != (a.op == "call_group_start"))
                    || peer.is_status_broadcast()
                    || peer.is_newsletter()
                    || s.active.is_some()
                    || s.starting
                {
                    return Err("input");
                }
                if a.op == "call_group_start" {
                    group::targets(&a.options, &[])?;
                }
                if a.op == "call_accept" {
                    if s.snapshot.as_ref().is_some_and(|v| v.group.is_some())
                        && a.call_epoch != Some(s.epoch)
                    {
                        return Err("input");
                    }
                    let i = s.incoming.as_ref().ok_or("input")?;
                    if !matches!(i.action, CallAction::Offer { .. })
                        || i.action.call_id() != a.target
                        || i.from.to_non_ad() != peer.to_non_ad()
                    {
                        return Err("input");
                    }
                } else if s.incoming.is_some() {
                    return Err("busy");
                }
                let group = if a.op == "call_accept" {
                    s.snapshot.as_ref().and_then(|v| v.group.clone())
                } else if a.op == "call_group_start" {
                    Some(group::Snapshot {
                        group_jid: Some(chat.into()),
                        participant_limit: whatsapp_rust::voip::GROUP_CALL_MAX_PARTICIPANTS,
                        ..Default::default()
                    })
                } else {
                    None
                };
                if a.op != "call_accept" {
                    s.group_state = None;
                    s.ringing_generation = None;
                    s.rejecting = None;
                }
                s.epoch = s.epoch.wrapping_add(1);
                s.starting = true;
                s.call_context = a.call_context.as_ref().map(|v| (v.clone(), s.epoch));
                s.snapshot = Some(Snapshot {
                    id: if a.op == "call_accept" {
                        a.target.clone()
                    } else {
                        a.attempt.clone()
                    },
                    epoch: s.epoch,
                    peer: chat.into(),
                    group,
                    state: "preparing".into(),
                    incoming: a.op == "call_accept",
                    video: a.on,
                    ..Default::default()
                });
            }
            "call_end" => {
                let owned_context = if let Some(context) = &a.call_context {
                    if s.call_context
                        .as_ref()
                        .is_none_or(|(owner, epoch)| owner != context || *epoch != s.epoch)
                        || s.snapshot.as_ref().is_none_or(|i| {
                            i.peer != chat || (!a.target.is_empty() && i.id != a.target)
                        })
                    {
                        return Err("input");
                    }
                    true
                } else {
                    false
                };
                if !owned_context
                    && (a.call_epoch.is_some_and(|e| e != s.epoch)
                        || (s.snapshot.as_ref().is_some_and(|v| v.group.is_some())
                            && !s.starting
                            && a.call_epoch != Some(s.epoch)))
                {
                    return Err("input");
                }
                if !owned_context
                    && !s.starting
                    && s.snapshot.as_ref().is_some_and(|i| i.id != a.target)
                {
                    return Err("input");
                }
                Self::remember_ended(&mut s);
                s.epoch = s.epoch.wrapping_add(1);
                self.changed.notify_waiters();
                s.starting = false;
                if let Some(info) = &mut s.snapshot {
                    info.state = "ended".into()
                };
            }
            "call_reject" => {
                if a.call_epoch.is_some_and(|e| e != s.epoch)
                    || (s.snapshot.as_ref().is_some_and(|v| v.group.is_some())
                        && a.call_epoch != Some(s.epoch))
                {
                    return Err("input");
                }
                if s.incoming
                    .as_ref()
                    .is_none_or(|i| i.action.call_id() != a.target)
                    || s.snapshot.as_ref().is_none_or(|i| i.state != "ringing")
                {
                    return Err("input");
                };
                Self::remember_ended(&mut s);
                s.rejecting = s.incoming.take();
                s.epoch = s.epoch.wrapping_add(1);
                self.changed.notify_waiters();
                s.starting = false;
                if let Some(info) = &mut s.snapshot {
                    info.state = "ended".into()
                }
            }
            "call_invite" | "call_ring" => {
                if a.call_epoch != Some(s.epoch)
                    || s.active
                        .as_ref()
                        .is_none_or(|v| v.handle.call_id() != a.target)
                    || s.snapshot
                        .as_ref()
                        .is_none_or(|v| ["ended", "failed"].contains(&v.state.as_str()))
                {
                    return Err("input");
                }
                group::user(&a.to, &[])?;
            }
            "call_mute" | "call_video" => {
                if a.call_epoch.is_some_and(|e| e != s.epoch)
                    || (s.snapshot.as_ref().is_some_and(|v| v.group.is_some())
                        && a.call_epoch != Some(s.epoch))
                {
                    return Err("input");
                }
                if s.active
                    .as_ref()
                    .is_none_or(|c| c.handle.call_id() != a.target)
                {
                    return Err("input");
                }
            }
            _ => return Err("input"),
        }
        Ok(s.epoch)
    }
    fn remember_ended(s: &mut State) {
        if let Some(info) = &s.snapshot {
            s.last_ended = Some((info.id.clone(), s.ringing_generation.unwrap_or(0)))
        }
    }
    pub async fn snapshot(&self) -> Option<Snapshot> {
        let roster = {
            let s = self.state.lock().await;
            s.active
                .as_ref()
                .and_then(|a| a.handle.group_state())
                .and_then(|g| g.snapshot().cloned())
                .map(|g| (s.epoch, g))
        };
        if let Some((epoch, roster)) = roster
            && self.apply_group_update(epoch, &roster).await == Err("input")
        {
            let mut s = self.state.lock().await;
            if s.epoch == epoch
                && let Some(info) = &mut s.snapshot
            {
                info.state = "failed".into()
            }
        }
        let ended = {
            let s = self.state.lock().await;
            (s.active.is_some()
                && s.snapshot
                    .as_ref()
                    .is_some_and(|i| ["ended", "failed"].contains(&i.state.as_str())))
            .then_some(s.epoch)
        };
        if let Some(epoch) = ended {
            let _ = self.stop_epoch(Some(epoch)).await;
        };
        self.state.lock().await.snapshot.clone()
    }
    pub async fn media(&self, r: &Exchange) -> Result<Value, &'static str> {
        let s = self.state.lock().await;
        if s.epoch != r.epoch {
            return Err("closed");
        };
        let active = s.active.as_ref().ok_or("closed")?;
        active.queues.exchange(r)
    }
    pub async fn observe(&self, event: &Event) {
        let mut s = self.state.lock().await;
        match event {
            Event::IncomingCall(incoming) => match &incoming.action {
                CallAction::Offer {
                    call_id,
                    is_video,
                    group_jid,
                    ..
                } if !incoming.offline => {
                    if s.last_ended.as_ref().is_some_and(|(id, g)| {
                        id == call_id && incoming.ringing_generation().unwrap_or(0) <= *g
                    }) {
                        return;
                    }
                    let newer_ringing = s.incoming.as_ref().is_some_and(|old| {
                        old.action.call_id() == call_id
                            && old.group.is_some()
                            && incoming.group.is_some()
                            && incoming
                                .ringing_generation()
                                .zip(s.ringing_generation)
                                .is_some_and(|(next, old)| next > old)
                    });
                    if s.active.is_none() && !s.starting && (s.incoming.is_none() || newer_ringing)
                    {
                        let grouped = group_jid.is_some() || incoming.group.is_some();
                        if grouped
                            && (incoming.group.is_none() || incoming.ringing_generation().is_none())
                        {
                            return;
                        }
                        if let Some(update) = incoming.group.as_deref() {
                            if update.call_id != *call_id
                                || update.call_creator.to_non_ad()
                                    != incoming.action.call_creator().to_non_ad()
                                || group_jid
                                    .as_ref()
                                    .is_some_and(|j| update.group_jid.as_ref() != Some(j))
                            {
                                return;
                            }
                            if group::project(update).is_err() {
                                return;
                            }
                        }
                        s.epoch = s.epoch.wrapping_add(1);
                        s.group_state = None;
                        s.rejecting = None;
                        s.ringing_generation = incoming.ringing_generation();
                        s.snapshot = Some(Snapshot {
                            id: call_id.clone(),
                            epoch: s.epoch,
                            peer: incoming.from.to_non_ad().to_string(),
                            state: "ringing".into(),
                            incoming: true,
                            video: *is_video,
                            ..Default::default()
                        });
                        if let Some(update) = incoming.group.as_deref() {
                            let epoch = s.epoch;
                            if group::apply(&mut s, epoch, update).is_err() {
                                s.snapshot = None;
                                return;
                            }
                        }
                        s.incoming = Some(incoming.clone());
                    }
                }
                CallAction::Accept { call_id, .. }
                    if s.snapshot.as_ref().is_none_or(|v| v.group.is_none()) =>
                {
                    if s.snapshot.as_ref().is_some_and(|i| {
                        i.id == *call_id && ["ended", "failed"].contains(&i.state.as_str())
                    }) {
                        return;
                    }
                    if s.accepted.len() >= 16 {
                        s.accepted.clear()
                    };
                    s.accepted.insert(call_id.clone());
                    if let Some(info) = &mut s.snapshot
                        && info.id == *call_id
                    {
                        info.state = "active".into()
                    }
                }
                CallAction::Terminate { call_id, .. }
                | CallAction::Reject {
                    call_id,
                    reason: None,
                    ..
                } if s.snapshot.as_ref().is_some_and(|i| i.id == *call_id)
                    && (s.snapshot.as_ref().is_some_and(|i| i.group.is_none())
                        || (matches!(incoming.action, CallAction::Terminate { .. })
                            && s.ringing_generation.is_some()
                            && incoming.ringing_generation() == s.ringing_generation)) =>
                {
                    if let Some(info) = &mut s.snapshot {
                        info.state = "ended".into()
                    };
                    Self::remember_ended(&mut s);
                    s.group_state = None;
                    s.rejecting = None;
                    s.own_users.clear();
                    s.incoming = None;
                    s.starting = false;
                    s.epoch = s.epoch.wrapping_add(1);
                    self.changed.notify_waiters();
                }
                _ => {}
            },
            Event::CallEndedElsewhere(end)
                if s.snapshot
                    .as_ref()
                    .is_some_and(|i| i.id == end.call_id && i.group.is_none()) =>
            {
                if let Some(info) = &mut s.snapshot {
                    info.state = "ended".into()
                };
                Self::remember_ended(&mut s);
                s.group_state = None;
                s.rejecting = None;
                s.own_users.clear();
                s.incoming = None;
                s.starting = false;
                s.epoch = s.epoch.wrapping_add(1);
                self.changed.notify_waiters();
            }
            _ => {}
        }
    }
    pub async fn stop(&self) {
        let _ = self.stop_epoch(None).await;
    }
    async fn stop_epoch(&self, expected: Option<u64>) -> Option<EndSignal> {
        let active = {
            let mut s = self.state.lock().await;
            if expected.is_some_and(|e| e != s.epoch) {
                return None;
            };
            Self::remember_ended(&mut s);
            s.group_state = None;
            s.rejecting = None;
            s.own_users.clear();
            s.epoch = s.epoch.wrapping_add(1);
            self.changed.notify_waiters();
            s.starting = false;
            s.incoming = None;
            s.accepted.clear();
            if let Some(info) = &mut s.snapshot {
                info.state = "ended".into()
            };
            s.active.take()
        };
        let handle = active.as_ref().map(|a| EndSignal {
            id: a.handle.call_id().to_owned(),
            peer: a.handle.peer_jid(),
            creator: a.handle.call_creator().clone(),
        });
        if let Some(active) = active {
            for task in &active.tasks {
                task.abort()
            }
            active.handle.hangup().await;
            for task in active.tasks {
                let _ = task.await;
            }
        }
        handle
    }
    pub async fn end_local(&self, epoch: u64) -> Option<EndSignal> {
        self.stop_epoch(Some(epoch)).await
    }
    pub async fn signal_end(
        client: Arc<Client>,
        handle: Option<EndSignal>,
    ) -> Result<Value, &'static str> {
        if let Some(handle) = handle {
            client
                .voip()
                .terminate(&handle.id, &handle.peer, &handle.creator)
                .await
                .map_err(|_| "unknown")?;
        }
        Ok(Value::Null)
    }
    pub async fn execute(
        self: &Arc<Self>,
        client: Arc<Client>,
        chat: &str,
        a: &crate::commands::Action,
        epoch: u64,
    ) -> Result<Value, &'static str> {
        if !self.is_current(epoch).await {
            return Err("closed");
        }
        match a.op.as_str() {
            "call_start" | "call_accept" | "call_group_start" => {
                self.start(client, chat, a, epoch).await
            }
            "call_invite" | "call_ring" => self.participant_control(client, a, epoch).await,
            "call_reject" => {
                let incoming = {
                    let mut s = self.state.lock().await;
                    let i = s.rejecting.as_ref().ok_or("input")?;
                    if i.action.call_id() != a.target {
                        return Err("input");
                    };
                    s.rejecting.take().ok_or("input")?
                };
                client
                    .voip()
                    .reject(&incoming)
                    .await
                    .map_err(|_| "unknown")?;
                let _ = self.stop_epoch(Some(epoch)).await;
                Ok(Value::Null)
            }
            "call_end" => {
                let handle = self.end_local(epoch).await;
                Self::signal_end(client, handle).await
            }
            "call_mute" => {
                let mut s = self.state.lock().await;
                let active = s.active.as_ref().ok_or("input")?;
                if active.handle.call_id() != a.target {
                    return Err("input");
                };
                active.handle.set_muted(a.on);
                if let Some(info) = &mut s.snapshot {
                    info.muted = a.on
                };
                Ok(Value::Null)
            }
            "call_video" => {
                let (handle, queues, upgrade, epoch) = {
                    let s = self.state.lock().await;
                    let active = s.active.as_ref().ok_or("input")?;
                    if active.handle.call_id() != a.target {
                        return Err("input");
                    };
                    (
                        active.handle.clone(),
                        active.queues.clone(),
                        active.upgrade.clone(),
                        s.epoch,
                    )
                };
                if a.on {
                    let token = upgrade.lock().await.take();
                    if let Some(token) = token {
                        handle
                            .accept_video(token, queues.camera_rx.clone(), queues.screen.clone())
                            .await
                    } else {
                        handle
                            .start_video(queues.camera_rx.clone(), queues.screen.clone())
                            .await
                    }
                    .map_err(|_| "unknown")?;
                } else {
                    handle.stop_video().await.map_err(|_| "unknown")?;
                }
                let mut s = self.state.lock().await;
                if s.epoch != epoch {
                    return Err("closed");
                };
                if let Some(info) = &mut s.snapshot {
                    info.video = a.on;
                    info.video_requested = false
                };
                Ok(Value::Null)
            }
            _ => Err("command"),
        }
    }
    async fn start(
        self: &Arc<Self>,
        client: Arc<Client>,
        chat: &str,
        a: &crate::commands::Action,
        epoch: u64,
    ) -> Result<Value, &'static str> {
        let peer: Jid = chat.parse().map_err(|_| "input")?;
        if (peer.is_group() != (a.op == "call_group_start"))
            || peer.is_status_broadcast()
            || peer.is_newsletter()
        {
            return Err("input");
        }
        let incoming = {
            let mut s = self.state.lock().await;
            if s.epoch != epoch || !s.starting {
                return Err("closed");
            };
            if a.op == "call_accept" {
                Some(
                    s.incoming
                        .take()
                        .filter(|i| {
                            i.action.call_id() == a.target && i.from.to_non_ad() == peer.to_non_ad()
                        })
                        .ok_or("closed")?,
                )
            } else {
                None
            }
        };
        Self::preflight(&client, a)?;
        {
            let mut s = self.state.lock().await;
            if s.epoch != epoch {
                return Err("closed");
            }
            s.own_users = client.lid().into_iter().chain(client.pn()).collect();
        }
        let targets = if a.op == "call_group_start" {
            group::targets(&a.options, &[])?
        } else {
            vec![]
        };
        let pending_group = {
            let s = self.state.lock().await;
            s.snapshot.as_ref().and_then(|i| i.group.clone())
        };
        let endpoints = Arc::new(MediaQueues::new(String::new(), epoch));
        if let Some(g) = &pending_group {
            endpoints.configure_group(g)
        }
        let voip = client.voip();
        let result = self
            .during(epoch, async {
                if let Some(incoming) = &incoming {
                    let mut b = voip.accept(incoming).encoded_audio(
                        whatsapp_rust::voip::AudioFormat::MLOW_16KHZ_60MS,
                        endpoints.encoded_rx.clone(),
                        endpoints.decoded.clone(),
                    );
                    if a.on {
                        b = b.video(endpoints.camera_rx.clone(), endpoints.screen.clone())
                    };
                    b.start().await
                } else if a.op == "call_group_start" {
                    let mut b = voip.group_call(&targets).group(peer.clone()).encoded_audio(
                        whatsapp_rust::voip::AudioFormat::MLOW_16KHZ_60MS,
                        endpoints.encoded_rx.clone(),
                        endpoints.decoded.clone(),
                    );
                    if a.on {
                        b = b.video(endpoints.camera_rx.clone(), endpoints.screen.clone())
                    }
                    b.start().await
                } else {
                    let mut b = voip.call(&peer).encoded_audio(
                        whatsapp_rust::voip::AudioFormat::MLOW_16KHZ_60MS,
                        endpoints.encoded_rx.clone(),
                        endpoints.decoded.clone(),
                    );
                    if a.on {
                        b = b.video(endpoints.camera_rx.clone(), endpoints.screen.clone())
                    };
                    b.start().await
                }
                .map_err(|_| "unknown")
            })
            .await;
        let handle = match result {
            Ok(handle) => handle,
            Err(_) => {
                let mut s = self.state.lock().await;
                if s.epoch == epoch {
                    s.starting = false;
                    Self::remember_ended(&mut s);
                    s.group_state = None;
                    if let Some(info) = &mut s.snapshot {
                        info.state = "failed".into()
                    }
                };
                return Err("unknown");
            }
        };
        let mut queues = Arc::try_unwrap(endpoints).map_err(|_| "internal")?;
        queues.id = handle.call_id().to_owned();
        let queues = Arc::new(queues);
        let id = handle.call_id().to_owned();
        let upgrade = Arc::new(Mutex::new(None));
        let mut s = self.state.lock().await;
        if s.epoch != epoch {
            drop(s);
            handle.hangup().await;
            return Err("closed");
        }
        s.starting = false;
        let authoritative = handle.group_state();
        let group = match authoritative
            .as_ref()
            .and_then(|g| g.snapshot())
            .map(|update| group::project_with_own(update, &s.own_users))
            .transpose()
        {
            Ok(value) => value,
            Err(_) => {
                s.starting = false;
                Self::remember_ended(&mut s);
                if let Some(info) = &mut s.snapshot {
                    info.state = "failed".into()
                };
                drop(s);
                handle.hangup().await;
                return Err("unknown");
            }
        };
        let group = group::initial_snapshot(group, pending_group);
        s.group_state = authoritative;
        s.snapshot = Some(Snapshot {
            group,
            id: id.clone(),
            epoch,
            peer: chat.into(),
            state: if incoming.is_some() || s.accepted.contains(&id) {
                "active"
            } else {
                "calling"
            }
            .into(),
            incoming: incoming.is_some(),
            video: a.on,
            remote_video: a.on,
            ..Default::default()
        });
        if let Some(g) = s.snapshot.as_ref().and_then(|i| i.group.as_ref()) {
            queues.configure_group(g)
        }
        let mut tasks = queues.start();
        let events = handle.events();
        let weak = Arc::downgrade(self);
        let speaker = queues.clone();
        let upgrade_copy = upgrade.clone();
        let watcher = tokio::spawn(async move {
            while let Ok(event) = events.recv().await {
                let Some(calls) = weak.upgrade() else { break };
                let mut s = calls.state.lock().await;
                if s.epoch != epoch {
                    break;
                }
                if let CallEvent::GroupUpdated(update) = &event {
                    if group::apply(&mut s, epoch, update) == Err("input")
                        && let Some(info) = &mut s.snapshot
                    {
                        info.state = "failed".into()
                    }
                    if let Some(g) = s.snapshot.as_ref().and_then(|i| i.group.as_ref()) {
                        speaker.configure_group(g)
                    }
                    continue;
                }
                if let Some(info) = &mut s.snapshot {
                    match event {
                        CallEvent::VideoStateChanged {
                            state,
                            upgrade_token,
                            ..
                        } => match state {
                            VideoState::UpgradeRequest | VideoState::UpgradeRequestV2 => {
                                *upgrade_copy.lock().await = upgrade_token;
                                info.video_requested = true;
                            }
                            VideoState::Enabled | VideoState::UpgradeAccept => {
                                info.remote_video = true
                            }
                            VideoState::Disabled | VideoState::Stopped => info.remote_video = false,
                            _ => {}
                        },
                        CallEvent::GroupRekeyFailed => info.state = "failed".into(),
                        CallEvent::RelayAllocated => {
                            if info.state != "active" {
                                info.state = "connecting".into()
                            }
                        }
                        CallEvent::RelayAllocateFailed(_) | CallEvent::RelayAllocateTimedOut => {
                            info.state = "failed".into()
                        }
                        _ => {}
                    }
                }
            }
        });
        let ended = handle.clone();
        let weak = Arc::downgrade(self);
        let end_watcher = tokio::spawn(async move {
            ended.wait_ended().await;
            if let Some(calls) = weak.upgrade() {
                let mut s = calls.state.lock().await;
                if s.epoch == epoch
                    && let Some(info) = &mut s.snapshot
                {
                    info.state = "ended".into()
                }
            }
        });
        tasks.extend([watcher, end_watcher]);
        s.active = Some(Active {
            handle,
            queues,
            tasks,
            upgrade,
        });
        Ok(start_receipt(&id, epoch))
    }
}

pub fn codec_version() -> Result<&'static str, &'static str> {
    unsafe extern "C" {
        fn opus_get_version_string() -> *const std::ffi::c_char;
    }
    // SAFETY: the pinned Opus ABI returns an immutable process-lifetime C string.
    // A null pointer and invalid UTF-8 fail closed before dereferencing/copying.
    let pointer = unsafe { opus_get_version_string() };
    if pointer.is_null() {
        return Err("codec");
    }
    unsafe { std::ffi::CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| "codec")
}

pub fn validate_group_targets(items: &[String]) -> Result<(), &'static str> {
    group::targets(items, &[]).map(|_| ())
}

fn start_receipt(id: &str, epoch: u64) -> Value {
    json!({"stanza":id,"callEpoch":epoch})
}
