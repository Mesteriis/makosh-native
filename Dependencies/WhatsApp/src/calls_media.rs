// Per-call bounded media routing. SDK owns authentication, SRTP and rekeying.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::{Arc, Mutex},
};
use whatsapp_rust::voip::{AudioCodec, AudioRtpProfile, EncodedAudioFrame, VideoFrame};
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
pub struct StreamID {
    pub sender: String,
    pub device: String,
    pub pid: Option<u32>,
}
impl StreamID {
    fn from_video(f: &VideoFrame) -> Option<Self> {
        Some(Self {
            sender: f.sender.as_ref()?.to_non_ad().to_string(),
            device: f.device.as_ref()?.to_string(),
            pid: f.pid,
        })
    }
    fn key(&self) -> String {
        format!("{}|{}|{:?}", self.sender, self.device, self.pid)
    }
}
#[derive(Serialize)]
pub struct ParticipantVideo {
    stream: StreamID,
    keyframe: bool,
    orientation: u8,
    bytes: Vec<u8>,
}
#[derive(Default)]
struct VideoInbox {
    allowed: BTreeSet<StreamID>,
    visible: Vec<StreamID>,
    pending: BTreeMap<StreamID, ParticipantVideo>,
    ready: BTreeSet<StreamID>,
    revision: u64,
    cursor: usize,
}
impl VideoInbox {
    fn roster(&mut self, ids: &[StreamID]) {
        self.allowed = ids.iter().cloned().collect();
        self.pending.retain(|k, _| self.allowed.contains(k));
        self.ready.retain(|k| self.allowed.contains(k));
    }
    fn select(&mut self, ids: &[StreamID], revision: u64) -> Result<(), &'static str> {
        if ids.len() > 9
            || ids.iter().collect::<BTreeSet<_>>().len() != ids.len()
            || ids.iter().any(|id| {
                id.sender.len() > 1024
                    || id.device.len() > 1024
                    || id
                        .sender
                        .parse::<whatsapp_rust::wacore_binary::Jid>()
                        .is_err()
                    || id
                        .device
                        .parse::<whatsapp_rust::wacore_binary::Jid>()
                        .is_err()
            })
            || revision < self.revision
            || (revision == self.revision && ids != self.visible)
        {
            return Err("input");
        }
        // A bounded UI page is intent, not roster authority. Keep departed IDs until
        // the next page revision; push/roster still gate and retire every actual frame.
        self.pending.retain(|k, _| ids.contains(k));
        self.ready.retain(|k| ids.contains(k));
        self.visible = ids.to_vec();
        self.revision = revision;
        Ok(())
    }
    fn push(&mut self, f: VideoFrame) {
        let Some(stream) = StreamID::from_video(&f) else {
            return;
        };
        if f.data.is_empty()
            || f.data.len() > 256 * 1024
            || f.orientation > 3
            || !self.allowed.contains(&stream)
            || !self.visible.contains(&stream)
        {
            return;
        }
        if !self.ready.contains(&stream) && !f.keyframe {
            return;
        }
        // Retain a not-yet-consumed keyframe instead of replacing it with an undecodable delta.
        if self.pending.get(&stream).is_some_and(|v| v.keyframe) && !f.keyframe {
            return;
        }
        if f.keyframe {
            self.ready.insert(stream.clone());
        }
        self.pending.insert(
            stream.clone(),
            ParticipantVideo {
                stream,
                keyframe: f.keyframe,
                orientation: f.orientation,
                bytes: f.data,
            },
        );
    }
    fn take(&mut self) -> Vec<ParticipantVideo> {
        let mut out = vec![];
        let len = self.visible.len();
        for _ in 0..len {
            let index = self.cursor % len;
            self.cursor = (index + 1) % len;
            if let Some(frame) = self.pending.remove(&self.visible[index]) {
                out.push(frame);
                if out.len() == 4 {
                    break;
                }
            }
        }
        out
    }
}
struct AudioDecoder {
    mlow: whatsapp_rust::wacore::voip::mlow::MlowDecoder,
    opus: Option<whatsapp_rust::voip::audio::WaOpusDecoder>,
}
impl Default for AudioDecoder {
    fn default() -> Self {
        Self {
            mlow: whatsapp_rust::wacore::voip::mlow::MlowDecoder::new(),
            opus: None,
        }
    }
}
struct AudioPacket {
    stream: Option<StreamID>,
    codec: AudioCodec,
    profile: AudioRtpProfile,
    payload_type: u8,
    bytes: Vec<u8>,
}
impl From<EncodedAudioFrame> for AudioPacket {
    fn from(f: EncodedAudioFrame) -> Self {
        Self {
            stream: f.sender.zip(f.device).map(|(s, d)| StreamID {
                sender: s.to_non_ad().to_string(),
                device: d.to_string(),
                pid: f.pid,
            }),
            codec: f.codec,
            profile: f.format.rtp_profile,
            payload_type: f.payload_type,
            bytes: f.data.to_vec(),
        }
    }
}
#[derive(Default)]
struct AudioRouting {
    group: bool,
    allowed: BTreeSet<StreamID>,
    decoders: BTreeMap<Option<StreamID>, AudioDecoder>,
    mixer: whatsapp_rust::wacore::voip::ParticipantAudioMixer,
    personal: VecDeque<i16>,
    primed: bool,
    prime: u8,
    foreign_at: Option<std::time::Instant>,
    foreign: Option<Vec<i16>>,
}
impl AudioRouting {
    fn roster(&mut self, ids: &[StreamID]) {
        if !self.group {
            self.personal.clear();
            self.decoders.clear();
            self.primed = false;
            self.foreign_at = None;
            self.foreign = None;
        }
        self.group = true;
        self.allowed = ids.iter().cloned().collect();
        self.decoders
            .retain(|k, _| k.as_ref().is_some_and(|s| self.allowed.contains(s)));
        self.mixer.retain(ids.iter().map(StreamID::key));
    }
    fn push_pcm(&mut self, source: Option<&StreamID>, pcm: &[i16]) -> bool {
        if pcm.is_empty() || pcm.len() > 1920 {
            return false;
        }
        if self.group {
            let Some(source) = source else { return false };
            if !self.allowed.contains(source) {
                return false;
            }
            self.mixer.push(&source.key(), pcm)
        } else {
            if source.is_some() {
                return false;
            }
            self.personal.extend(pcm);
            while self.personal.len() > 2400 {
                self.personal.pop_front();
            }
            true
        }
    }
    fn decode(&mut self, packet: AudioPacket) -> Result<bool, &'static str> {
        if packet.bytes.is_empty()
            || packet.bytes.len() > 4096
            || (self.group
                && packet
                    .stream
                    .as_ref()
                    .is_none_or(|s| !self.allowed.contains(s)))
            || (!self.group && packet.stream.is_some())
        {
            return Ok(false);
        }
        if !self.decoders.contains_key(&packet.stream) && self.decoders.len() >= 32 {
            return Ok(false);
        }
        let decoder = self.decoders.entry(packet.stream.clone()).or_default();
        let pcm = match packet.codec {
            AudioCodec::Mlow => {
                decoder
                    .mlow
                    .set_redundancy(i32::from(packet.payload_type == 121));
                decoder
                    .mlow
                    .decode(&packet.bytes)
                    .iter()
                    .map(|s| (s * 32767.0).clamp(-32768.0, 32767.0) as i16)
                    .collect::<Vec<_>>()
            }
            AudioCodec::Opus => {
                if decoder.opus.is_none() {
                    decoder.opus = Some(
                        whatsapp_rust::voip::audio::WaOpusDecoder::new().map_err(|_| "codec")?,
                    )
                }
                let opus = decoder.opus.as_mut().ok_or("codec")?;
                if packet.profile == AudioRtpProfile::Mlow {
                    opus.decode_mlow_escape(&packet.bytes)
                } else {
                    opus.decode(&packet.bytes)
                }
                .map_err(|_| "input")?
                .to_vec()
            }
            _ => return Err("codec"),
        };
        if !self.group && packet.codec == AudioCodec::Opus {
            self.foreign_at = Some(std::time::Instant::now());
            self.foreign = Some(pcm);
            return Ok(true);
        }
        Ok(self.push_pcm(packet.stream.as_ref(), &pcm))
    }
    fn tick(&mut self) -> Vec<i16> {
        if self.group {
            let mut out = self.mixer.mix_chunk().unwrap_or_else(|| vec![0; 160]);
            out.extend(self.mixer.mix_chunk().unwrap_or_else(|| vec![0; 160]));
            return out;
        }
        if !self.primed {
            if self.personal.len() >= 1920 {
                self.primed = true;
                self.prime = 0
            } else if !self.personal.is_empty() {
                self.prime += 1;
                if self.prime >= 10 {
                    self.primed = true;
                    self.prime = 0
                }
            }
        }
        let mut out = vec![0; 320];
        if self.primed {
            let n = self.personal.len().min(320);
            for v in out.iter_mut().take(n) {
                *v = self.personal.pop_front().unwrap_or(0)
            }
            if n < 320 {
                self.primed = false;
            }
        }
        out
    }
}
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Exchange {
    pub id: String,
    pub epoch: u64,
    #[serde(default)]
    pub audio: Vec<Vec<i16>>,
    #[serde(default)]
    pub video: Vec<u8>,
    pub visible_streams: Option<Vec<StreamID>>,
    pub visibility_revision: Option<u64>,
}
struct Routing {
    audio: AudioRouting,
    video: VideoInbox,
    generation: u64,
}
pub struct MediaQueues {
    pub(super) id: String,
    epoch: u64,
    mic: async_channel::Sender<Vec<i16>>,
    mic_rx: async_channel::Receiver<Vec<i16>>,
    pub(super) encoded_rx: async_channel::Receiver<whatsapp_rust::bytes::Bytes>,
    encoded_tx: async_channel::Sender<whatsapp_rust::bytes::Bytes>,
    pub(super) decoded: async_channel::Sender<EncodedAudioFrame>,
    decoded_rx: async_channel::Receiver<EncodedAudioFrame>,
    speaker: async_channel::Sender<Vec<i16>>,
    speaker_rx: async_channel::Receiver<Vec<i16>>,
    camera: async_channel::Sender<Vec<u8>>,
    pub(super) camera_rx: async_channel::Receiver<Vec<u8>>,
    personal_screen: async_channel::Sender<VideoFrame>,
    personal_screen_rx: async_channel::Receiver<VideoFrame>,
    pub(super) screen: async_channel::Sender<VideoFrame>,
    screen_rx: async_channel::Receiver<VideoFrame>,
    routing: Mutex<Routing>,
}
impl MediaQueues {
    pub fn new(id: String, epoch: u64) -> Self {
        let (mic, mic_rx) = async_channel::bounded(3);
        let (encoded_tx, encoded_rx) = async_channel::bounded(3);
        let (decoded, decoded_rx) = async_channel::bounded(8);
        let (speaker, speaker_rx) = async_channel::bounded(8);
        let (camera, camera_rx) = async_channel::bounded(4);
        let (screen, screen_rx) = async_channel::bounded(8);
        let (personal_screen, personal_screen_rx) = async_channel::bounded(2);
        Self {
            id,
            epoch,
            mic,
            mic_rx,
            encoded_rx,
            encoded_tx,
            decoded,
            decoded_rx,
            speaker,
            speaker_rx,
            camera,
            camera_rx,
            screen,
            screen_rx,
            personal_screen,
            personal_screen_rx,
            routing: Mutex::new(Routing {
                audio: AudioRouting::default(),
                video: VideoInbox::default(),
                generation: 0,
            }),
        }
    }
    pub(super) fn configure_group(&self, g: &super::group::Snapshot) {
        let ids = g
            .participants
            .iter()
            .filter(|p| p.me != Some(true) && p.state.as_deref() == Some("connected"))
            .flat_map(|p| {
                p.devices.iter().map(|d| StreamID {
                    sender: p.jid.clone(),
                    device: d.jid.clone(),
                    pid: d.pid,
                })
            })
            .collect::<Vec<_>>();
        if let Ok(mut r) = self.routing.lock() {
            let set = ids.iter().cloned().collect::<BTreeSet<_>>();
            if r.audio.group && r.audio.allowed == set {
                return;
            }
            r.generation = r.generation.wrapping_add(1);
            r.audio.roster(&ids);
            r.video.roster(&ids);
            while self.decoded_rx.try_recv().is_ok() {}
            while self.screen_rx.try_recv().is_ok() {}
            while self.speaker_rx.try_recv().is_ok() {}
            while self.personal_screen_rx.try_recv().is_ok() {}
        }
    }
    #[cfg(test)]
    pub fn receive_foreign(&self, frame: Vec<i16>) {
        if let Ok(mut r) = self.routing.lock() {
            if r.audio.group {
                return;
            }
            r.audio.foreign_at = Some(std::time::Instant::now());
            push_latest(&self.speaker, &self.speaker_rx, frame);
        }
    }
    #[cfg(test)]
    pub fn receive_decoded(&self, frame: Vec<i16>) {
        if let Ok(r) = self.routing.lock() {
            if r.audio.group {
                return;
            }
            if frame.iter().all(|s| *s == 0)
                && r.audio
                    .foreign_at
                    .is_some_and(|t| t.elapsed().as_millis() < 500)
            {
                return;
            }
            push_latest(&self.speaker, &self.speaker_rx, frame);
        }
    }
    #[cfg(test)]
    pub fn mic_len(&self) -> usize {
        self.mic.len()
    }
    #[cfg(test)]
    pub fn camera_len(&self) -> usize {
        self.camera.len()
    }
    pub fn exchange(&self, r: &Exchange) -> Result<Value, &'static str> {
        if r.id != self.id
            || r.epoch != self.epoch
            || r.audio.len() > 3
            || r.audio.iter().any(|f| f.len() != 960)
            || r.video.len() > 256 * 1024
        {
            return Err("input");
        }
        let mut routing = self.routing.lock().map_err(|_| "internal")?;
        if routing.audio.group {
            if let Some(ids) = &r.visible_streams {
                let changed = r.visibility_revision != Some(routing.video.revision);
                routing
                    .video
                    .select(ids, r.visibility_revision.ok_or("input")?)?;
                if changed {
                    routing.generation = routing.generation.wrapping_add(1);
                    while self.screen_rx.try_recv().is_ok() {}
                }
            } else if r.visibility_revision.is_some() {
                return Err("input");
            }
        }
        for frame in &r.audio {
            push_latest(&self.mic, &self.mic_rx, frame.clone());
        }
        if !r.video.is_empty() {
            push_latest(&self.camera, &self.camera_rx, r.video.clone());
        }
        let mut audio = vec![];
        for _ in 0..8 {
            let Ok(f) = self.speaker_rx.try_recv() else {
                break;
            };
            if f.len() <= 1920 {
                audio.push(f)
            }
        }
        let mut video = None;
        if !routing.audio.group {
            for _ in 0..2 {
                let Ok(f) = self.personal_screen_rx.try_recv() else {
                    break;
                };
                if f.data.len() <= 256 * 1024 && f.orientation <= 3 {
                    video = Some(f)
                }
            }
        }
        let videos = if routing.audio.group {
            routing.video.take()
        } else {
            vec![]
        };
        Ok(
            json!({"audio":audio,"video":video.as_ref().map(|f|&f.data),"keyframe":video.as_ref().is_some_and(|f|f.keyframe),"orientation":video.as_ref().map(|f|f.orientation).unwrap_or(0),"videos":videos,"visibilityRevision":r.visibility_revision}),
        )
    }
    pub(super) fn start(self: &Arc<Self>) -> Vec<tokio::task::JoinHandle<()>> {
        let q = self.clone();
        let encode = tokio::spawn(async move {
            let mut encoder = whatsapp_rust::wacore::voip::mlow::MlowEncoder::new();
            while let Ok(pcm) = q.mic_rx.recv().await {
                let floats = pcm.iter().map(|v| *v as f32 / 32768.0).collect::<Vec<_>>();
                if let Ok(bytes) = encoder.encode(&floats) {
                    push_latest(
                        &q.encoded_tx,
                        &q.encoded_rx,
                        whatsapp_rust::bytes::Bytes::from(bytes),
                    );
                }
            }
        });
        let q = self.clone();
        let decode = tokio::spawn(async move {
            loop {
                let generation = match q.routing.lock() {
                    Ok(r) => r.generation,
                    Err(_) => break,
                };
                let Ok(frame) = q.decoded_rx.recv().await else {
                    break;
                };
                let mut r = match q.routing.lock() {
                    Ok(r) => r,
                    Err(_) => break,
                };
                if r.generation != generation {
                    continue;
                }
                let _ = r.audio.decode(frame.into());
                if let Some(pcm) = r.audio.foreign.take() {
                    push_latest(&q.speaker, &q.speaker_rx, pcm);
                }
            }
        });
        let q = self.clone();
        let clock = tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_millis(20));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let frame = match q.routing.lock() {
                    Ok(mut r) => r.audio.tick(),
                    Err(_) => break,
                };
                q.receive_clock(frame);
            }
        });
        let q = self.clone();
        let video = tokio::spawn(async move {
            loop {
                let generation = match q.routing.lock() {
                    Ok(r) => r.generation,
                    Err(_) => break,
                };
                let Ok(frame) = q.screen_rx.recv().await else {
                    break;
                };
                if let Ok(mut r) = q.routing.lock() {
                    if generation != r.generation {
                        continue;
                    }
                    if r.audio.group {
                        r.video.push(frame)
                    } else {
                        // Personal exchange consumes this queue directly.
                        push_latest(&q.personal_screen, &q.personal_screen_rx, frame);
                    }
                }
            }
        });
        vec![encode, decode, clock, video]
    }
    fn receive_clock(&self, frame: Vec<i16>) {
        if let Ok(r) = self.routing.lock()
            && !r.audio.group
            && frame.iter().all(|s| *s == 0)
            && r.audio
                .foreign_at
                .is_some_and(|t| t.elapsed().as_millis() < 500)
        {
            return;
        }
        push_latest(&self.speaker, &self.speaker_rx, frame);
    }
}
fn push_latest<T>(tx: &async_channel::Sender<T>, rx: &async_channel::Receiver<T>, value: T) {
    if let Err(async_channel::TrySendError::Full(value)) = tx.try_send(value) {
        let _ = rx.try_recv();
        let _ = tx.try_send(value);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use whatsapp_rust::voip::VideoFrame;
    fn id(n: u32, pid: u32) -> StreamID {
        StreamID {
            sender: format!("20{n}@lid"),
            device: format!("20{n}:2@lid"),
            pid: Some(pid),
        }
    }
    fn frame(id: &StreamID, key: bool, n: u8) -> VideoFrame {
        let mut f = VideoFrame::new(vec![0, 0, 0, 1, if key { 0x65 } else { 0x41 }, n]);
        f.sender = Some(id.sender.parse().unwrap());
        f.device = Some(id.device.parse().unwrap());
        f.pid = id.pid;
        f.keyframe = key;
        f
    }
    #[test]
    fn stale_ui_selection_survives_authoritative_departure_and_pid_change() {
        let (a, b, next) = (id(1, 1), id(2, 2), id(1, 7));
        let mut inbox = VideoInbox::default();
        inbox.roster(&[a.clone(), b.clone()]);
        inbox.select(&[a.clone(), b.clone()], 1).unwrap();
        inbox.roster(std::slice::from_ref(&a));
        assert!(
            inbox.select(&[a.clone(), b.clone()], 1).is_ok(),
            "A stale UI page must not terminate the call"
        );
        inbox.push(frame(&a, true, 1));
        inbox.push(frame(&b, true, 2));
        assert_eq!(
            inbox
                .take()
                .into_iter()
                .map(|v| v.stream)
                .collect::<Vec<_>>(),
            vec![a.clone()]
        );
        inbox.roster(std::slice::from_ref(&next));
        assert!(inbox.select(&[a, b], 1).is_ok());
        inbox.push(frame(&next, true, 3));
        assert!(inbox.take().is_empty());
        inbox.select(std::slice::from_ref(&next), 2).unwrap();
        inbox.roster(&[]);
        assert!(inbox.select(std::slice::from_ref(&next), 2).is_ok());
        inbox.roster(std::slice::from_ref(&next));
        inbox.select(std::slice::from_ref(&next), 2).unwrap();
        inbox.push(frame(&next, false, 4));
        assert!(inbox.take().is_empty());
        inbox.push(frame(&next, true, 5));
        assert_eq!(inbox.take()[0].bytes.last(), Some(&5));
    }
    #[test]
    fn group_frames_are_bounded_fair_and_require_keyframe_on_return() {
        let ids = (0..9).map(|n| id(n, n + 1)).collect::<Vec<_>>();
        let mut inbox = VideoInbox::default();
        inbox.roster(&ids);
        inbox.select(&ids, 1).unwrap();
        for stream in &ids {
            inbox.push(frame(stream, true, 1));
        }
        let mut observed = std::collections::BTreeSet::new();
        for _ in 0..3 {
            let out = inbox.take();
            assert!(out.len() <= 4);
            assert!(out.iter().map(|f| f.bytes.len()).sum::<usize>() <= 1024 * 1024);
            observed.extend(out.into_iter().map(|f| f.stream));
        }
        assert_eq!(observed.len(), 9);
        inbox.select(&ids[1..], 2).unwrap();
        inbox.push(frame(&ids[0], true, 2));
        inbox.select(&ids, 3).unwrap();
        inbox.push(frame(&ids[0], false, 3));
        assert!(inbox.take().is_empty());
        inbox.push(frame(&ids[0], true, 4));
        assert_eq!(inbox.take()[0].bytes.last(), Some(&4));
        assert!(inbox.select(&ids, 2).is_err());
        assert!(
            inbox
                .select(&(0..10).map(|n| id(n, n)).collect::<Vec<_>>(), 4)
                .is_err()
        );
    }
    #[test]
    fn pid_migration_departure_and_oversize_flush_the_exact_source() {
        let (a, b, next) = (id(1, 1), id(2, 2), id(1, 7));
        let mut inbox = VideoInbox::default();
        inbox.roster(&[a.clone(), b.clone()]);
        inbox.select(&[a.clone(), b.clone()], 1).unwrap();
        inbox.push(frame(&a, true, 1));
        inbox.push(frame(&b, true, 2));
        inbox.roster(std::slice::from_ref(&next));
        assert!(inbox.take().is_empty());
        inbox.select(std::slice::from_ref(&next), 2).unwrap();
        inbox.push(frame(&a, true, 3));
        let mut big = frame(&next, true, 4);
        big.data.resize(256 * 1024 + 1, 0);
        inbox.push(big);
        assert!(inbox.take().is_empty());
        inbox.push(frame(&next, true, 5));
        assert_eq!(inbox.take()[0].stream, next);
    }
    #[test]
    fn group_pcm_uses_participant_mixer_without_foreign_fallback_cross_talk() {
        let (a, b) = (id(1, 1), id(2, 2));
        let mut audio = AudioRouting::default();
        audio.roster(&[a.clone(), b.clone()]);
        assert!(!audio.push_pcm(None, &vec![30000; 1920]));
        assert!(audio.push_pcm(Some(&a), &vec![20000; 1920]));
        assert!(audio.push_pcm(Some(&b), &vec![20000; 1920]));
        assert_eq!(audio.tick(), vec![i16::MAX; 320]);
        audio.roster(std::slice::from_ref(&a));
        assert!(!audio.push_pcm(Some(&b), &vec![-20000; 1920]));
        assert_eq!(audio.tick(), vec![20000; 320]);
        audio.roster(&[id(1, 7)]);
        assert!(audio.tick().iter().all(|v| *v == 0));
    }
    #[test]
    fn personal_opus_keeps_immediate_playout_and_group_transition_revokes_it() {
        let mut audio = AudioRouting::default();
        let mut encoder = whatsapp_rust::voip::audio::WaOpusEncoder::new_mlow_escape().unwrap();
        let bytes = encoder.encode(&vec![1234; 960]).unwrap();
        assert!(
            audio
                .decode(AudioPacket {
                    stream: None,
                    codec: whatsapp_rust::voip::AudioCodec::Opus,
                    profile: whatsapp_rust::voip::AudioRtpProfile::Mlow,
                    payload_type: 120,
                    bytes
                })
                .unwrap()
        );
        assert!(
            audio.foreign_at.is_some(),
            "Personal foreign Opus must suppress duplicate silence immediately"
        );
        audio.roster(&[id(1, 1)]);
        assert!(audio.foreign_at.is_none());
        assert!(audio.tick().iter().all(|s| *s == 0));
    }
    #[test]
    fn codec_frames_and_dtx_stay_bounded_without_device_access() {
        let a = id(1, 1);
        let mut audio = AudioRouting::default();
        audio.roster(std::slice::from_ref(&a));
        audio.push_pcm(Some(&a), &vec![1234; 960]);
        let out = (0..15).flat_map(|_| audio.tick()).collect::<Vec<_>>();
        assert!(out.contains(&1234));
        let after = (0..30).flat_map(|_| audio.tick()).collect::<Vec<_>>();
        assert!(after.iter().all(|v| *v == 0));
        let input = (0..960)
            .map(|n| ((n as f32 * 0.04).sin() * 10000.0) as i16)
            .collect::<Vec<_>>();
        let mut encoder = whatsapp_rust::wacore::voip::mlow::MlowEncoder::new();
        let floats = input
            .iter()
            .map(|v| *v as f32 / 32768.0)
            .collect::<Vec<_>>();
        let bytes = encoder.encode(&floats).unwrap();
        for _ in 0..2 {
            assert!(
                audio
                    .decode(AudioPacket {
                        stream: Some(a.clone()),
                        codec: whatsapp_rust::voip::AudioCodec::Mlow,
                        profile: whatsapp_rust::voip::AudioRtpProfile::Mlow,
                        payload_type: 120,
                        bytes: bytes.clone()
                    })
                    .unwrap()
            );
        }
        assert!(audio.tick().iter().any(|v| *v != 0));
    }
}
