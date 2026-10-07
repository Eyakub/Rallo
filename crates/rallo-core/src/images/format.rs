//! The image formats Rallo stores (0018), recognised by their first bytes,
//! and the per-image and per-note limits.

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};

pub const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_IMAGES_PER_NOTE: usize = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageKind {
    Png,
    Jpeg,
    Heic,
    Gif,
    Webp,
}

impl ImageKind {
    pub fn sniff(bytes: &[u8]) -> Option<Self> {
        if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Some(Self::Png)
        } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            Some(Self::Jpeg)
        } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
            Some(Self::Gif)
        } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            Some(Self::Webp)
        } else if bytes.len() >= 12
            && &bytes[4..8] == b"ftyp"
            && matches!(&bytes[8..12], b"heic" | b"heix" | b"heim" | b"heis" | b"mif1")
        {
            Some(Self::Heic)
        } else {
            None
        }
    }

    pub fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Heic => "image/heic",
            Self::Gif => "image/gif",
            Self::Webp => "image/webp",
        }
    }

    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Heic => "heic",
            Self::Gif => "gif",
            Self::Webp => "webp",
        }
    }

    pub fn from_mime_type(mime_type: &str) -> Option<Self> {
        [Self::Png, Self::Jpeg, Self::Heic, Self::Gif, Self::Webp]
            .into_iter()
            .find(|kind| kind.mime_type() == mime_type)
    }
}

/// Checks images about to join a note that already holds `existing`.
pub(crate) fn check_batch(images: &[Vec<u8>], existing: usize) -> CoreResult<Vec<ImageKind>> {
    if existing + images.len() > MAX_IMAGES_PER_NOTE {
        return Err(CoreError::invalid(
            ErrorCode::TooManyImages,
            format!("a note can hold {MAX_IMAGES_PER_NOTE} images"),
        ));
    }
    images.iter().map(|bytes| check_one(bytes)).collect()
}

fn check_one(bytes: &[u8]) -> CoreResult<ImageKind> {
    if bytes.len() > MAX_IMAGE_BYTES {
        let megabytes = bytes.len() as f64 / (1024.0 * 1024.0);
        return Err(CoreError::invalid(
            ErrorCode::ImageTooLarge,
            format!("an image is {megabytes:.1} MB; the limit is 10 MB"),
        ));
    }
    ImageKind::sniff(bytes).ok_or_else(|| {
        CoreError::invalid(
            ErrorCode::ImageUnsupported,
            "not an image Rallo can store: use PNG, JPEG, HEIC, GIF or WebP",
        )
    })
}

/// Request-fingerprint entries for images (0003 §7): length and FNV-1a, so a
/// retry with the same files replays and different files conflict.
pub(crate) fn digests(images: &[Vec<u8>]) -> Vec<String> {
    images.iter().map(|bytes| format!("{}:{:016x}", bytes.len(), fnv1a(bytes))).collect()
}

// ponytail: FNV-1a, not cryptographic; it only tells a retry from a different request.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nfake";

    #[test]
    fn check_batch_limits() {
        assert_eq!(check_batch(&[PNG.to_vec()], 0).unwrap(), vec![ImageKind::Png]);
        let eleven = vec![PNG.to_vec(); 11];
        assert_eq!(check_batch(&eleven, 0).unwrap_err().code(), ErrorCode::TooManyImages);
        assert_eq!(check_batch(&[PNG.to_vec()], 10).unwrap_err().code(), ErrorCode::TooManyImages);
        let mut big = PNG.to_vec();
        big.resize(MAX_IMAGE_BYTES + 1, 0);
        assert_eq!(check_batch(&[big], 0).unwrap_err().code(), ErrorCode::ImageTooLarge);
        assert_eq!(check_batch(&[b"text".to_vec()], 0).unwrap_err().code(), ErrorCode::ImageUnsupported);
        assert_eq!(
            check_batch(&[b"text".to_vec()], 0).unwrap_err().to_string(),
            "not an image Rallo can store: use PNG, JPEG, HEIC, GIF or WebP"
        );
    }

    #[test]
    fn digests_are_stable_and_content_sensitive() {
        assert_eq!(digests(&[PNG.to_vec()]), digests(&[PNG.to_vec()]));
        assert_ne!(digests(&[PNG.to_vec()]), digests(&[[PNG, b"x"].concat()]));
        assert_eq!(digests(&[PNG.to_vec()])[0], format!("{}:{:016x}", PNG.len(), fnv1a(PNG)));
    }
}
