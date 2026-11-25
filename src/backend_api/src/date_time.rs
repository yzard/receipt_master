use crate::db::{Result, invalid, io_error};
use jiff::{
    Timestamp,
    civil::{Date, DateTime},
    tz::{AmbiguousOffset, Offset, TimeZone},
};

const MIN_YEAR: i32 = -262_143;
const MAX_YEAR: i32 = 262_142;
const MIN_UTC_MS: i64 = -8_334_601_228_800_000;
const MAX_UTC_MS: i64 = 8_210_266_876_799_999;
pub(crate) const YEARS_PER_CYCLE: i32 = 400;
const MILLIS_PER_CYCLE: i64 = 146_097 * 86_400_000;
const TZ_CUTOFF: Timestamp = Timestamp::constant(4_102_444_800, 0); // 2100-01-01 UTC

pub(crate) fn time_zone(name: &str) -> Result<TimeZone> {
    let (iana_name, data) = jiff_tzdb::get(name).ok_or_else(invalid)?;
    // The API requires exact IANA spellings and never accepted the "Factory" placeholder.
    if iana_name != name || name == "Factory" {
        return Err(invalid());
    }
    TimeZone::tzif(iana_name, data).map_err(|_| invalid())
}

fn zone_at_year(zone: &TimeZone, year: i32) -> TimeZone {
    // The previous transition tables end in 2099. Retain each zone's final offset.
    if year >= 2100 {
        zone.to_offset(TZ_CUTOFF).to_time_zone()
    } else if year < -8000 {
        zone.to_offset(Timestamp::MIN).to_time_zone()
    } else {
        zone.clone()
    }
}

pub(crate) fn timestamp_millis(timestamp: Timestamp) -> i64 {
    // Storage uses floor division, including for fractions before the Unix epoch.
    timestamp.as_nanosecond().div_euclid(1_000_000) as i64
}

pub struct LocalDateTime {
    pub(crate) civil: DateTime,
    pub(crate) year_shift: i32,
    pub(crate) leap_second: bool,
}

impl LocalDateTime {
    pub(crate) fn project_year(year: i32) -> Option<(i16, i32)> {
        (MIN_YEAR..=MAX_YEAR)
            .contains(&year)
            .then(|| Self::split_year(year))
    }

    fn split_year(year: i32) -> (i16, i32) {
        // Gregorian dates and weekdays repeat every 400 years. Project extended
        // years into Jiff's range and keep the shift for formatting and UTC conversion.
        let civil_year = if (-8000..=8000).contains(&year) {
            year
        } else {
            2000 + year.rem_euclid(YEARS_PER_CYCLE)
        };
        (civil_year as i16, year - civil_year)
    }

    pub(crate) fn from_utc_millis(at: i64, zone: &TimeZone) -> Result<Self> {
        if !(MIN_UTC_MS..=MAX_UTC_MS).contains(&at) {
            return Err(invalid());
        }
        let (timestamp, year_shift) = if let Ok(timestamp) = Timestamp::from_millisecond(at) {
            (timestamp, 0)
        } else {
            let cycles = at.div_euclid(MILLIS_PER_CYCLE) as i32;
            let timestamp = Timestamp::from_millisecond(at.rem_euclid(MILLIS_PER_CYCLE))
                .map_err(|_| invalid())?;
            (timestamp, cycles * YEARS_PER_CYCLE)
        };
        let utc_year = i32::from(Offset::UTC.to_datetime(timestamp).year()) + year_shift;
        let zone = zone_at_year(zone, utc_year);
        let civil = zone.to_offset(timestamp).to_datetime(timestamp);
        let (year, year_shift) = Self::split_year(i32::from(civil.year()) + year_shift);
        let civil = civil.with().year(year).build().map_err(|_| invalid())?;
        Ok(Self {
            civil,
            year_shift,
            leap_second: false,
        })
    }

    pub(crate) fn year(&self) -> i32 {
        i32::from(self.civil.year()) + self.year_shift
    }

    pub(crate) fn checked_date(&self) -> Result<Date> {
        // CSV can format the local day past the UTC limit. Reports require a
        // date inside the legacy civil range and returned a storage error here.
        if !(MIN_YEAR..=MAX_YEAR).contains(&self.year()) {
            return Err(io_error("local date outside supported range"));
        }
        Ok(self.civil.date())
    }

    pub(crate) fn year_text(&self) -> String {
        let year = self.year();
        if (0..=9999).contains(&year) {
            format!("{year:04}")
        } else {
            format!("{year:+05}")
        }
    }

    pub(crate) fn date_text(&self) -> String {
        format!("{}{}", self.year_text(), self.civil.strftime("-%m-%d"))
    }

    pub(crate) fn utc_rfc3339(&self) -> String {
        let fraction = self.civil.subsec_nanosecond();
        let suffix = if fraction == 0 {
            self.civil.strftime("T%H:%M:%S").to_string()
        } else {
            self.civil.strftime("T%H:%M:%S%.3f").to_string()
        };
        format!("{}{suffix}+00:00", self.date_text())
    }

    pub(crate) fn instants(&self, zone: &TimeZone) -> LocalInstants {
        let Some((year, year_shift)) = Self::project_year(self.year()) else {
            return LocalInstants::Gap;
        };
        let Ok(civil) = self.civil.with().year(year).build() else {
            return LocalInstants::Gap;
        };
        let zone = zone_at_year(zone, self.year());
        let ambiguous = zone.to_ambiguous_timestamp(civil);
        let to_millis = |ts: std::result::Result<Timestamp, jiff::Error>| {
            let instant = timestamp_millis(ts.ok()?)
                + i64::from(year_shift / YEARS_PER_CYCLE) * MILLIS_PER_CYCLE;
            (MIN_UTC_MS..=MAX_UTC_MS)
                .contains(&instant)
                .then_some(instant + 1000 * i64::from(self.leap_second))
        };
        match ambiguous.offset() {
            AmbiguousOffset::Unambiguous { .. } => {
                to_millis(ambiguous.unambiguous()).map_or(LocalInstants::Gap, LocalInstants::Single)
            }
            AmbiguousOffset::Fold { .. } => {
                match (to_millis(ambiguous.earlier()), to_millis(ambiguous.later())) {
                    (Some(earlier), Some(later)) => LocalInstants::Fold(earlier, later),
                    _ => LocalInstants::Gap,
                }
            }
            AmbiguousOffset::Gap { .. } => LocalInstants::Gap,
        }
    }
}

pub(crate) enum LocalInstants {
    Single(i64),
    Fold(i64, i64),
    Gap,
}
