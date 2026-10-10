//! `eye_breaks.settings` (0022 §9): defaults, round trip, rejections, revision.

mod support;

use rallo_core::ErrorCode;
use rallo_core::preferences::EyeBreakSettings;

#[test]
fn unset_means_the_defaults_and_eye_breaks_are_off() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let settings = store.eye_break_settings().unwrap();
    assert_eq!(settings, EyeBreakSettings::default());
    assert_eq!(
        settings,
        EyeBreakSettings {
            enabled: false,
            interval_minutes: 20,
            length_seconds: 20,
            warn_seconds: 10,
            allow_skip: true,
            hold_on_call: true,
        }
    );
}

#[test]
fn settings_round_trip_and_survive_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let wanted = EyeBreakSettings {
        enabled: true,
        interval_minutes: 45,
        length_seconds: 60,
        warn_seconds: 0,
        allow_skip: false,
        hold_on_call: false,
    };
    {
        let mut store = support::open(temp.path());
        assert!(store.set_eye_break_settings(wanted.clone()).unwrap());
    }
    assert_eq!(support::open(temp.path()).eye_break_settings().unwrap(), wanted);
}

#[test]
fn an_identical_save_does_not_bump_the_revision() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let on = EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() };
    assert!(store.set_eye_break_settings(on.clone()).unwrap());
    let revision = store.change_revision().unwrap();
    assert!(!store.set_eye_break_settings(on).unwrap());
    assert_eq!(store.change_revision().unwrap(), revision);
}

#[test]
fn values_outside_the_choices_are_rejected_and_nothing_is_saved() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let base = EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() };
    let bad = [
        EyeBreakSettings { interval_minutes: 25, ..base.clone() },
        EyeBreakSettings { interval_minutes: 0, ..base.clone() },
        EyeBreakSettings { length_seconds: 15, ..base.clone() },
        EyeBreakSettings { warn_seconds: 3, ..base.clone() },
    ];
    for settings in bad {
        let error = store.set_eye_break_settings(settings.clone()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidInput, "{settings:?}");
    }
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    assert_eq!(store.change_revision().unwrap(), 0);
}

#[test]
fn an_unreadable_partial_or_out_of_range_stored_value_reads_safely() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let write = |raw: &str| {
        support::raw_connection(temp.path())
            .execute(
                "INSERT OR REPLACE INTO preferences (key, value, revision, updated_at_ms)
                 VALUES ('eye_breaks.settings', ?1, 1, 0)",
                [raw],
            )
            .unwrap();
    };
    write("42");
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    write(r#"{"enabled":true,"interval_minutes":7}"#);
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    // A field this build doesn't know, and fields it lacks, both read through serde's defaults.
    write(r#"{"enabled":true,"future_field":1}"#);
    assert_eq!(
        store.eye_break_settings().unwrap(),
        EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() }
    );
}
