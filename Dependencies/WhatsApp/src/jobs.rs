use crate::cache::Cache;
use serde_json::Value;
use std::future::Future;
#[derive(Default)]
pub struct CommandJobs {
    tasks: Vec<(u8, tokio::task::JoinHandle<()>)>,
}
impl CommandJobs {
    pub fn start(
        &mut self,
        cache: Cache,
        ticket: String,
        work: impl Future<Output = Result<Value, &'static str>> + Send + 'static,
    ) -> Result<(), &'static str> {
        self.start_inner(0, cache, ticket, work)
    }
    pub fn has_capacity(&mut self, control: bool) -> bool {
        self.tasks.retain(|(_, task)| !task.is_finished());
        self.tasks
            .iter()
            .filter(|(kind, _)| *kind == u8::from(control))
            .count()
            < 2
    }
    pub fn can_admit(&mut self, op: &str) -> bool {
        self.tasks.retain(|(_, task)| !task.is_finished());
        if op == "call_end" {
            true
        } else if op == "call_reject" {
            !self.tasks.iter().any(|(kind, _)| *kind == 2)
        } else {
            self.has_capacity(op.starts_with("call_"))
        }
    }
    pub fn start_termination(
        &mut self,
        cache: Cache,
        ticket: String,
        work: impl Future<Output = Result<Value, &'static str>> + Send + 'static,
    ) -> Result<(), &'static str> {
        self.start_inner(2, cache, ticket, work)
    }
    pub fn start_control(
        &mut self,
        cache: Cache,
        ticket: String,
        work: impl Future<Output = Result<Value, &'static str>> + Send + 'static,
    ) -> Result<(), &'static str> {
        self.start_inner(1, cache, ticket, work)
    }
    fn start_inner(
        &mut self,
        lane: u8,
        cache: Cache,
        ticket: String,
        work: impl Future<Output = Result<Value, &'static str>> + Send + 'static,
    ) -> Result<(), &'static str> {
        self.tasks.retain(|(_, task)| !task.is_finished());
        let maximum = if lane == 2 { 1 } else { 2 };
        if self.tasks.iter().filter(|(kind, _)| *kind == lane).count() >= maximum {
            return Err("unknown");
        }
        self.tasks.push((
            lane,
            tokio::spawn(async move {
                match work.await {
                    Ok(value) => {
                        let _ = cache.finish_command(&ticket, &value).await;
                    }
                    Err(_) => {
                        let _ = cache.fail_command(&ticket).await;
                    }
                }
            }),
        ));
        Ok(())
    }
    pub async fn shutdown(&mut self) {
        let tasks = std::mem::take(&mut self.tasks);
        for (_, task) in &tasks {
            task.abort();
        }
        for (_, task) in tasks {
            let _ = task.await;
        }
    }
}
impl Drop for CommandJobs {
    fn drop(&mut self) {
        for (_, task) in &self.tasks {
            task.abort();
        }
    }
}
