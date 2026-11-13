//! Rust core of the Android app: OCR region merging, speech-bubble layout and
//! text-only translation. Kotlin owns the UI, OCR engine and page rendering and
//! calls into this crate through UniFFI-generated bindings.

uniffi::setup_scaffolding!();

pub mod anime;
pub mod backend;
pub mod bubble;
pub mod config;
pub mod geometry;
pub mod rawkuma;
pub mod regions;
pub mod translate;
