use super::model::{CancellationStatus, SchedulingStatus};
use super::repository;
use crate::items::model::ItemView;
use crate::shared::errors::CoreResult;
use crate::storage::database::Store;

impl Store {
    /// Scheduling status for an item's reminder, or `None` without one.
    pub fn scheduling_status(&self, item: &ItemView) -> CoreResult<Option<SchedulingStatus>> {
        repository::scheduling_status(self.conn(), item.reminder.as_ref())
    }

    /// Cancellation status for an item's reminder, or `None` without one.
    pub fn cancellation_status(&self, item: &ItemView) -> CoreResult<Option<CancellationStatus>> {
        repository::cancellation_status(self.conn(), item.reminder.as_ref())
    }
}
