use serde::Serialize;
use whatsapp_rust::{prelude::*, voip::GroupCallUpdate, wacore_binary::JidExt};
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(rename = "groupJID")]
    pub group_jid: Option<String>,
    pub roster_revision: u64,
    pub participants: Vec<Participant>,
    pub participant_limit: usize,
}
#[derive(Clone, Serialize)]
pub struct Participant {
    pub jid: String,
    pub state: Option<String>,
    pub devices: Vec<Device>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub me: Option<bool>,
}
#[derive(Clone, Serialize)]
pub struct Device {
    pub jid: String,
    pub pid: Option<u32>,
}
pub(super) fn user(item: &str, own: &[Jid]) -> Result<Jid, &'static str> {
    if item.len() > 1024 || item.is_empty() {
        return Err("input");
    }
    let (address, server) = item.split_once('@').ok_or("input")?;
    if server.contains('@') {
        return Err("input");
    }
    if let Some((base, device)) = address.split_once(':')
        && (base.is_empty()
            || !device.bytes().all(|b| b.is_ascii_digit())
            || device.is_empty()
            || device.parse::<u16>().is_err())
    {
        return Err("input");
    }
    let jid: Jid = item.parse().map_err(|_| "input")?;
    if !jid
        .user
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
    {
        return Err("input");
    }
    if !["lid", "s.whatsapp.net"].contains(&jid.server.to_string().as_str()) || jid.user.is_empty()
    {
        return Err("input");
    }
    let jid = jid.to_non_ad();
    if own.iter().any(|j| j.to_non_ad() == jid) {
        return Err("input");
    }
    Ok(jid)
}
pub(super) fn targets(items: &[String], own: &[Jid]) -> Result<Vec<Jid>, &'static str> {
    use whatsapp_rust::wacore::types::group_call::GROUP_CALL_MAX_REMOTE_PARTICIPANTS;
    if !(2..=GROUP_CALL_MAX_REMOTE_PARTICIPANTS).contains(&items.len()) {
        return Err("input");
    }
    let mut result = Vec::with_capacity(items.len());
    for item in items {
        let jid = user(item, own)?;
        if result.contains(&jid) {
            return Err("input");
        }
        result.push(jid);
    }
    Ok(result)
}
pub(super) fn project(update: &GroupCallUpdate) -> Result<Snapshot, &'static str> {
    use whatsapp_rust::voip::GROUP_CALL_MAX_PARTICIPANTS;
    if update.connected_limit == 0
        || update.connected_limit as usize > GROUP_CALL_MAX_PARTICIPANTS
        || update.participants.len() > GROUP_CALL_MAX_PARTICIPANTS
        || update
            .group_jid
            .as_ref()
            .is_some_and(|j| !j.is_group() || j.to_string().len() > 1024)
    {
        return Err("input");
    }
    let mut seen = std::collections::BTreeSet::new();
    let mut participants = Vec::new();
    for p in &update.participants {
        let jid = p.jid.to_non_ad().to_string();
        user(&jid, &[])?;
        if !seen.insert(jid.clone())
            || p.devices.len() > 32
            || p.state
                .as_ref()
                .is_some_and(|v| v.len() > 128 || v.contains('\0'))
        {
            return Err("input");
        }
        let mut devices = Vec::new();
        let mut device_ids = std::collections::BTreeSet::new();
        for device in &p.devices {
            let jid = device.jid.to_string();
            user(&jid, &[])?;
            if !device_ids.insert((jid.clone(), device.pid)) {
                return Err("input");
            }
            devices.push(Device {
                jid,
                pid: device.pid,
            });
        }
        participants.push(Participant {
            jid,
            state: p.state.clone(),
            devices,
            me: None,
        });
    }
    Ok(Snapshot {
        group_jid: update.group_jid.as_ref().map(ToString::to_string),
        roster_revision: update.transaction_id as u64,
        participants,
        participant_limit: update.connected_limit as usize,
    })
}
pub(super) fn project_with_own(
    update: &GroupCallUpdate,
    own: &[Jid],
) -> Result<Snapshot, &'static str> {
    let mut value = project(update)?;
    if !own.is_empty() {
        for (target, source) in value.participants.iter_mut().zip(&update.participants) {
            target.me = Some(own.iter().any(|j| {
                j.to_non_ad() == source.jid.to_non_ad()
                    || source
                        .pn
                        .as_ref()
                        .is_some_and(|pn| pn.to_non_ad() == j.to_non_ad())
            }));
        }
    }
    Ok(value)
}
pub(super) fn apply(
    s: &mut super::State,
    epoch: u64,
    update: &GroupCallUpdate,
) -> Result<(), &'static str> {
    use whatsapp_rust::voip::{GroupCallState, GroupStateApply};
    if s.epoch != epoch
        || s.snapshot.as_ref().is_none_or(|v| {
            v.id != update.call_id || ["ended", "failed"].contains(&v.state.as_str())
        })
    {
        return Err("closed");
    }
    let projection = project_with_own(update, &s.own_users)?;
    let state = s.group_state.get_or_insert_with(|| {
        GroupCallState::new(update.call_id.clone(), update.call_creator.clone())
    });
    match state.apply_update(update.clone()) {
        GroupStateApply::Applied => {
            if let Some(info) = &mut s.snapshot {
                info.group = Some(projection);
                activate(info, s.starting);
            }
            Ok(())
        }
        GroupStateApply::Stale => {
            // Only the retained authoritative roster can affect activation.
            if let Some(info) = &mut s.snapshot {
                activate(info, s.starting);
            }
            Ok(())
        }
        GroupStateApply::InvalidSnapshot => Err("input"),
        _ => Err("closed"),
    }
}
fn activate(info: &mut super::Snapshot, starting: bool) {
    if !starting
        && ["calling", "connecting"].contains(&info.state.as_str())
        && info.group.as_ref().is_some_and(|g| {
            g.participants
                .iter()
                .filter(|p| p.state.as_deref() == Some("connected"))
                .count()
                >= 2
        })
    {
        info.state = "active".into()
    }
}
impl super::Calls {
    pub(super) async fn apply_group_update(
        &self,
        epoch: u64,
        update: &GroupCallUpdate,
    ) -> Result<(), &'static str> {
        apply(&mut *self.state.lock().await, epoch, update)
    }
    pub fn preflight(client: &Client, a: &crate::commands::Action) -> Result<(), &'static str> {
        if ["call_group_start", "call_invite", "call_ring"].contains(&a.op.as_str()) {
            let lid = client.lid().ok_or("offline")?;
            let own = std::iter::once(lid).chain(client.pn()).collect::<Vec<_>>();
            if a.op == "call_group_start" {
                targets(&a.options, &own)?;
            } else {
                user(&a.to, &own)?;
            }
        }
        Ok(())
    }
    pub(super) async fn participant_control(
        self: &std::sync::Arc<Self>,
        client: std::sync::Arc<Client>,
        a: &crate::commands::Action,
        epoch: u64,
    ) -> Result<serde_json::Value, &'static str> {
        Self::preflight(&client, a)?;
        let target = user(&a.to, &[])?;
        let handle = {
            let s = self.state.lock().await;
            if s.epoch != epoch
                || a.call_epoch != Some(epoch)
                || s.snapshot.as_ref().is_none_or(|v| {
                    v.id != a.target || ["ended", "failed"].contains(&v.state.as_str())
                })
            {
                return Err("closed");
            }
            let active = s.active.as_ref().ok_or("input")?;
            if active.handle.call_id() != a.target {
                return Err("input");
            }
            let state = active.handle.group_state();
            let roster = state.as_ref().and_then(|g| g.snapshot());
            let member = roster.and_then(|r| {
                r.participants.iter().find(|p| {
                    p.jid.to_non_ad() == target
                        || p.pn.as_ref().is_some_and(|j| j.to_non_ad() == target)
                })
            });
            if a.op == "call_ring" {
                if member.is_none() {
                    return Err("input");
                }
            } else if member.is_some()
                || roster.is_some_and(|r| {
                    r.participants.len() >= whatsapp_rust::voip::GROUP_CALL_MAX_PARTICIPANTS
                })
            {
                return Err("input");
            }
            active.handle.clone()
        };
        self.during(epoch, async {
            if a.op == "call_ring" {
                handle.ring_participant(&target).await
            } else {
                handle.invite_participant(&target).await
            }
            .map_err(|_| "unknown")
        })
        .await?;
        if !self.is_current(epoch).await {
            return Err("closed");
        }
        Ok(serde_json::Value::Null)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{calls::Calls, commands::Action};
    use serde_json::json;
    use std::sync::Arc;
    use whatsapp_rust::{
        voip::{GroupCallDevice, GroupCallParticipant, GroupCallUpdate},
        wacore::types::call::{CallAction, IncomingCall},
    };
    fn action(op: &str, id: &str, epoch: Option<u64>) -> Action {
        serde_json::from_value(json!({"op":op,"target":id,"callEpoch":epoch,"attempt":"00000000-0000-4000-8000-000000000771"})).unwrap()
    }
    fn roster(call: &str, transaction: u32, group: bool) -> GroupCallUpdate {
        let creator: Jid = "100@lid".parse().unwrap();
        let device = GroupCallDevice::new("200:2@lid".parse().unwrap())
            .with_capability(1, b"PRIVATE_CAPABILITY");
        let mut member = GroupCallParticipant::new("200@lid".parse().unwrap(), vec![device]);
        member.state = Some("future-state".into());
        let mut update = GroupCallUpdate::builder()
            .call_id(call.into())
            .call_creator(creator)
            .transaction_id(transaction)
            .media("audio".into())
            .connected_limit(32)
            .joinable(true)
            .av_upgradable(true)
            .rekey_requested(false)
            .participants(vec![member])
            .build();
        if group {
            update.group_jid = Some("500@g.us".parse().unwrap())
        };
        update
    }
    fn offer(id: &str, group: bool, generation: u64) -> IncomingCall {
        let from: Jid = "100@lid".parse().unwrap();
        let mut value = IncomingCall::builder()
            .from(from.clone())
            .stanza_id("offer".into())
            .timestamp(std::time::SystemTime::now().into())
            .offline(false)
            .action(CallAction::Offer {
                call_id: id.into(),
                call_creator: from,
                caller_pn: None,
                caller_country_code: None,
                device_class: None,
                joinable: true,
                is_video: false,
                audio: vec![],
                group_jid: if group {
                    Some("500@g.us".parse().unwrap())
                } else {
                    None
                },
            })
            .build();
        value.group = Some(Box::new(roster(id, 1, group)));
        value.set_ringing_generation(generation);
        value
    }
    #[test]
    fn group_targets_two_through31_and_own_aliases_rejected() {
        let own: Vec<Jid> = vec![
            "100@lid".parse().unwrap(),
            "700@s.whatsapp.net".parse().unwrap(),
        ];
        for count in [2, 31] {
            let items = (0..count).map(|i| format!("20{i}@lid")).collect::<Vec<_>>();
            assert_eq!(targets(&items, &own).unwrap().len(), count);
        }
        for items in [
            vec!["200@lid".into()],
            (0..32).map(|i| format!("20{i}@lid")).collect(),
            vec!["200@lid".into(), "200:2@lid".into()],
            vec!["100:3@lid".into(), "200@lid".into()],
            vec!["700:4@s.whatsapp.net".into(), "200@lid".into()],
            vec!["700.4@s.whatsapp.net".into(), "200@lid".into()],
            vec!["200:bad@lid".into(), "300@lid".into()],
        ] {
            assert!(targets(&items, &own).is_err())
        }
    }
    #[tokio::test]
    async fn group_offer_and_adhoc_offer_ring_without_clobbering_personal_call() {
        for bound in [true, false] {
            let calls = Calls::default();
            calls
                .observe(&Event::IncomingCall(offer("GROUP", bound, 3)))
                .await;
            let snapshot = calls.snapshot().await.unwrap();
            assert_eq!(snapshot.state, "ringing");
            assert_eq!(snapshot.group.unwrap().participants.len(), 1);
            let epoch = calls
                .admit(
                    "100@lid",
                    &action("call_accept", "GROUP", Some(snapshot.epoch)),
                )
                .await
                .unwrap();
            assert!(calls.is_current(epoch).await);
        }
        let calls = Calls::default();
        let start = action("call_start", "", None);
        calls.admit("200@lid", &start).await.unwrap();
        calls
            .observe(&Event::IncomingCall(offer("GROUP", true, 3)))
            .await;
        assert_eq!(calls.snapshot().await.unwrap().id, start.attempt);
    }
    #[tokio::test]
    async fn offer_notice_alone_cannot_be_accepted() {
        let calls = Calls::default();
        let from: Jid = "100@lid".parse().unwrap();
        let notice = IncomingCall::builder()
            .from(from.clone())
            .stanza_id("notice".into())
            .timestamp(std::time::SystemTime::now().into())
            .offline(false)
            .action(CallAction::OfferNotice {
                call_id: "GROUP".into(),
                call_creator: from,
                is_video: true,
                is_group: true,
            })
            .build();
        calls.observe(&Event::IncomingCall(notice)).await;
        assert!(
            calls
                .admit("100@lid", &action("call_accept", "GROUP", Some(1)))
                .await
                .is_err()
        );
        assert!(calls.snapshot().await.is_none());
    }
    #[tokio::test]
    async fn stale_roster_and_late_accept_cannot_revive_call() {
        let calls = Arc::new(Calls::default());
        calls
            .observe(&Event::IncomingCall(offer("GROUP", true, 3)))
            .await;
        let epoch = calls.snapshot().await.unwrap().epoch;
        calls
            .apply_group_update(epoch, &roster("GROUP", 5, true))
            .await
            .unwrap();
        calls
            .apply_group_update(epoch, &roster("GROUP", 2, true))
            .await
            .unwrap();
        assert_eq!(
            calls
                .snapshot()
                .await
                .unwrap()
                .group
                .unwrap()
                .roster_revision,
            5
        );
        assert!(
            calls
                .apply_group_update(epoch + 1, &roster("GROUP", 6, true))
                .await
                .is_err()
        );
        calls
            .admit("100@lid", &action("call_reject", "GROUP", Some(epoch)))
            .await
            .unwrap();
        calls
            .observe(&Event::IncomingCall(offer("GROUP", true, 3)))
            .await;
        assert_eq!(calls.snapshot().await.unwrap().state, "ended");
        assert!(
            calls
                .admit("100@lid", &action("call_accept", "GROUP", Some(epoch)))
                .await
                .is_err()
        );
        calls
            .observe(&Event::IncomingCall(offer("GROUP", true, 4)))
            .await;
        assert_eq!(
            calls.snapshot().await.unwrap().state,
            "ringing",
            "A new registry-owned invitation is distinct from late signaling"
        );
    }
    #[tokio::test]
    async fn invite_ring_and_leave_bound_to_call_epoch() {
        let calls = Calls::default();
        let mut start = action("call_group_start", "", None);
        start.options = vec!["200@lid".into(), "300@lid".into()];
        let epoch = calls.admit("500@g.us", &start).await.unwrap();
        assert!(
            calls
                .admit(
                    "500@g.us",
                    &action("call_end", &start.attempt, Some(epoch + 1))
                )
                .await
                .is_err()
        );
        calls
            .admit("500@g.us", &action("call_end", &start.attempt, Some(epoch)))
            .await
            .unwrap();
        assert!(!calls.is_current(epoch).await);
        for op in ["call_invite", "call_ring"] {
            let mut a = action(op, &start.attempt, Some(epoch));
            a.to = "400@lid".into();
            assert!(calls.admit("500@g.us", &a).await.is_err());
        }
    }
    #[tokio::test]
    async fn global_accept_does_not_activate_an_unaccepted_group_invitation() {
        let calls = Calls::default();
        let current = offer("GROUP", true, 11);
        calls.observe(&Event::IncomingCall(current.clone())).await;
        let epoch = calls.snapshot().await.unwrap().epoch;
        let mut old = current;
        old.action = CallAction::Accept {
            call_id: "GROUP".into(),
            call_creator: "100@lid".parse().unwrap(),
            audio: vec![],
        };
        old.set_ringing_generation(10);
        calls.observe(&Event::IncomingCall(old)).await;
        assert_eq!(calls.snapshot().await.unwrap().state, "ringing");
        assert!(calls.is_current(epoch).await);
    }
    #[tokio::test]
    async fn old_terminal_callbacks_cannot_end_new_same_id_group_invitation() {
        let calls = Calls::default();
        let old = offer("GROUP", true, 10);
        calls.observe(&Event::IncomingCall(old.clone())).await;
        let first = calls.snapshot().await.unwrap().epoch;
        calls
            .observe(&Event::IncomingCall(offer("GROUP", true, 11)))
            .await;
        let fresh = calls.snapshot().await.unwrap().epoch;
        assert!(
            fresh > first,
            "New registered ringing generation replaces the old invitation"
        );
        let terminal = |generation| {
            let mut v = old.clone();
            v.action = CallAction::Terminate {
                call_id: "GROUP".into(),
                call_creator: "100@lid".parse().unwrap(),
                reason: None,
                duration: None,
                audio_duration: None,
            };
            v.set_ringing_generation(generation);
            v
        };
        calls.observe(&Event::IncomingCall(terminal(10))).await;
        calls
            .observe(&Event::CallEndedElsewhere(
                whatsapp_rust::wacore::types::call::CallEndedElsewhere::new(
                    old.from.clone(),
                    "GROUP".into(),
                    old.timestamp,
                    whatsapp_rust::wacore::types::call::ElsewhereOutcome::Accepted,
                ),
            ))
            .await;
        let mut rejected = old.clone();
        rejected.action = CallAction::Reject {
            call_id: "GROUP".into(),
            call_creator: "100@lid".parse().unwrap(),
            reason: None,
        };
        calls.observe(&Event::IncomingCall(rejected)).await;
        assert_eq!(calls.snapshot().await.unwrap().state, "ringing");
        assert!(calls.is_current(fresh).await);
        calls.observe(&Event::IncomingCall(terminal(11))).await;
        assert_eq!(calls.snapshot().await.unwrap().state, "ended");
    }
    #[test]
    fn malformed_context_is_refused_before_admission() {
        for value in ["", "bad", "00000000-0000-4000-8000-00000000000z"] {
            let mut end = action("call_end", "id", Some(1));
            end.call_context = Some(value.into());
            assert!(end.validate("500@g.us").is_err());
        }
    }
    #[tokio::test]
    async fn context_cancels_only_its_owned_call_before_start_receipt() {
        let calls = Calls::default();
        let context = "00000000-0000-4000-8000-000000000001";
        let make_start = |context| {
            serde_json::from_value::<Action>(json!({"op":"call_group_start","options":["200@lid","300@lid"],"callContext":context,"attempt":"00000000-0000-4000-8000-000000000771"})).unwrap()
        };
        let epoch = calls.admit("500@g.us", &make_start(context)).await.unwrap();
        {
            let mut state = calls.state.lock().await;
            state.starting = false;
            state.snapshot.as_mut().unwrap().id = "ACCEPTED".into();
        }
        let mut end = action("call_end", "", Some(epoch - 1));
        end.call_context = Some("00000000-0000-4000-8000-000000000002".into());
        assert!(calls.admit("500@g.us", &end).await.is_err());
        end.call_context = Some(context.into());
        assert!(calls.admit("600@g.us", &end).await.is_err());
        calls
            .admit("500@g.us", &end)
            .await
            .expect("Owned cancellation must not wait for the receipt");
        assert!(!calls.is_current(epoch).await);
        let fresh = calls
            .admit(
                "500@g.us",
                &make_start("00000000-0000-4000-8000-000000000003"),
            )
            .await
            .unwrap();
        assert!(calls.admit("500@g.us", &end).await.is_err());
        assert!(calls.is_current(fresh).await);
    }
    #[test]
    fn legacy_snapshot_and_projection_do_not_export_relay_secrets() {
        let mut update = roster("GROUP", 1, true);
        update.relay = Some(
            whatsapp_rust::voip::GroupCallRelay::builder()
                .uuid("PRIVATE_RELAY".into())
                .participant_uuid("PRIVATE_PARTICIPANT_UUID".into())
                .attribute_padding(false)
                .key(vec![0x77; 32])
                .tokens(vec![b"PRIVATE_TOKEN".to_vec()])
                .endpoints(vec![])
                .build(),
        );
        let value = project(&update).unwrap();
        let encoded = serde_json::to_string(&value).unwrap();
        for forbidden in ["PRIVATE", "relay", "capability", "token", "uuid", "key"] {
            assert!(!encoded.contains(forbidden));
        }
        assert_eq!(value.participants[0].state.as_deref(), Some("future-state"));
        assert_eq!(value.participants[0].devices[0].jid, "200:2@lid");
    }
}
#[cfg(test)]
mod activation_tests {
    use super::*;
    #[tokio::test]
    async fn authoritative_connected_roster_activates_only_current_call() {
        let calls = super::super::Calls::default();
        let start:crate::commands::Action=serde_json::from_value(serde_json::json!({"op":"call_group_start","options":["200@lid","300@lid"],"attempt":"00000000-0000-4000-8000-000000000779"})).unwrap();
        let epoch = calls.admit("500@g.us", &start).await.unwrap();
        {
            let mut state = calls.state.lock().await;
            state.snapshot.as_mut().unwrap().state = "calling".into();
            state.starting = false;
        }
        let member = |jid: &str, state: &str| {
            let mut p =
                whatsapp_rust::voip::GroupCallParticipant::new(jid.parse().unwrap(), vec![]);
            p.state = Some(state.into());
            p
        };
        let mut update = GroupCallUpdate::builder()
            .call_id(start.attempt.clone())
            .call_creator("100@lid".parse().unwrap())
            .transaction_id(2)
            .media("audio".into())
            .connected_limit(32)
            .joinable(true)
            .av_upgradable(true)
            .rekey_requested(false)
            .participants(vec![
                member("100@lid", "connected"),
                member("200@lid", "future-state"),
            ])
            .build();
        update.group_jid = Some("500@g.us".parse().unwrap());
        calls.apply_group_update(epoch, &update).await.unwrap();
        assert_eq!(calls.snapshot().await.unwrap().state, "calling");
        let mut stale = update.clone();
        stale.transaction_id = 1;
        stale.participants[1].state = Some("connected".into());
        calls.apply_group_update(epoch, &stale).await.unwrap();
        assert_eq!(calls.snapshot().await.unwrap().state, "calling");
        update.transaction_id = 3;
        update.participants[1].state = Some("connected".into());
        calls.apply_group_update(epoch, &update).await.unwrap();
        assert_eq!(calls.snapshot().await.unwrap().state, "active");
    }
}
#[cfg(test)]
mod local_endpoint_tests {
    use super::*;
    #[test]
    fn local_endpoint_is_identified_without_exporting_phone_aliases() {
        let mut p =
            whatsapp_rust::voip::GroupCallParticipant::new("200@lid".parse().unwrap(), vec![]);
        p.pn = Some("700@s.whatsapp.net".parse().unwrap());
        let update = GroupCallUpdate::builder()
            .call_id("GROUP".into())
            .call_creator("100@lid".parse().unwrap())
            .transaction_id(1)
            .media("audio".into())
            .connected_limit(32)
            .joinable(true)
            .av_upgradable(true)
            .rekey_requested(false)
            .participants(vec![p])
            .build();
        let value = project_with_own(&update, &["700:3@s.whatsapp.net".parse().unwrap()]).unwrap();
        assert_eq!(value.participants[0].me, Some(true));
        assert!(!serde_json::to_string(&value).unwrap().contains("700"));
        assert_eq!(
            project_with_own(&update, &["900@lid".parse().unwrap()])
                .unwrap()
                .participants[0]
                .me,
            Some(false)
        );
        assert_eq!(project(&update).unwrap().participants[0].me, None);
    }
}

#[cfg(test)]
mod lane_tests {
    use std::os::unix::fs::PermissionsExt;
    #[tokio::test]
    async fn group_controls_use_the_existing_bounded_lane_and_reserve_termination() {
        let dir = std::env::temp_dir().join(format!(
            "makosh-group-jobs-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let cache =
            crate::cache::Cache::open(dir.join("jobs.db").to_str().unwrap(), vec![0x39; 32])
                .await
                .unwrap();
        let mut jobs = crate::jobs::CommandJobs::default();
        for i in 0..2 {
            jobs.start_control(cache.clone(), format!("group-{i}"), std::future::pending())
                .unwrap();
        }
        for op in ["call_group_start", "call_invite", "call_ring"] {
            assert!(!jobs.can_admit(op));
        }
        assert!(jobs.can_admit("call_end"));
        assert!(jobs.can_admit("call_reject"));
        jobs.shutdown().await;
        drop(cache);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

pub(super) fn initial_snapshot(
    authoritative: Option<Snapshot>,
    pending: Option<Snapshot>,
) -> Option<Snapshot> {
    authoritative.or(pending)
}
#[cfg(test)]
mod pending_media_tests {
    use super::*;
    #[test]
    fn pending_group_keeps_group_media_scope_before_first_authoritative_roster() {
        let pending = Snapshot {
            group_jid: Some("1@g.us".into()),
            roster_revision: 0,
            participants: vec![],
            participant_limit: 32,
        };
        assert!(
            initial_snapshot(None, Some(pending)).is_some(),
            "No legacy personal media path during group setup"
        );
        assert!(initial_snapshot(None, None).is_none());
    }
}

#[cfg(test)]
mod receipt_tests {
    #[test]
    fn accepted_call_receipt_contains_exact_wrapper_epoch_without_private_state() {
        let value = super::super::start_receipt("CALL", 7);
        assert_eq!(value["stanza"], "CALL");
        assert_eq!(value["callEpoch"], 7);
        assert_eq!(value.as_object().unwrap().len(), 2);
    }
}
