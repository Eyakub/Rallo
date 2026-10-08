//! Folders (0019): flat, one per note at most. A note with no folder is in
//! the built-in "Notes", which is not a row.

pub mod model;
pub(crate) mod repository;
pub mod service;

pub use model::{
    DeleteNotes, Folder, FolderCount, FolderDeleteOutcome, FolderOutcome, FolderRef, FolderSelector, MAX_NAME_CHARS,
    NotesDisposition, validate_name,
};
