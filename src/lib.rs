//! # Multibuffer API
//!
//! A high-performance Rust implementation of the multibuffer plugin.
//! This implementation focuses on correctness and parity with the original
//! Lua plugin, providing bidirectional sync and rich UI elements.

use nvim_oxi::{
    api::{self, Buffer, opts::*, types::{AutocmdCallbackArgs}},
    serde::{Deserializer, Serializer},
    Dictionary, Function, Object,
};
use serde::{Deserialize, Serialize};
use std::{cell::RefCell, collections::HashMap};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MultibufRegion {
    pub start_row: usize,
    pub end_row: usize,
}

#[derive(Clone)]
struct RegionState {
    source_buf_handle: i32,
    /// Extmark in the source buffer tracking the original text.
    source_extmark: u32,
}

struct MultibufState {
    handle: Buffer,
    regions: Vec<RegionState>,
    ns_id: u32,
}

thread_local! {
    static MULTIBUFFERS: RefCell<HashMap<i32, MultibufState>> = RefCell::new(HashMap::new());
    static SOURCE_TO_MBUF: RefCell<HashMap<i32, Vec<i32>>> = RefCell::new(HashMap::new());
    static IS_SYNCING: RefCell<bool> = RefCell::new(false);
}

/// Prevents recursive synchronization loops.
struct SyncGuard;
impl SyncGuard {
    fn new() -> Option<Self> {
        IS_SYNCING.with(|s| {
            if *s.borrow() {
                None
            } else {
                *s.borrow_mut() = true;
                Some(SyncGuard)
            }
        })
    }
}
impl Drop for SyncGuard {
    fn drop(&mut self) {
        IS_SYNCING.with(|s| {
            *s.borrow_mut() = false;
        });
    }
}

pub fn multibuf_create(_args: ()) -> nvim_oxi::Result<i32> {
    define_signs();
    let mut buf = api::create_buf(true, false)?;
    let handle = buf.handle();

    buf.set_name(&format!("multibuf://{}", handle))?;
    #[allow(deprecated)]
    buf.set_option("buftype", "acwrite")?;
    #[allow(deprecated)]
    buf.set_option("swapfile", false)?;

    let ns_id = api::create_namespace(&format!("multibuf_{}", handle));

    let state = MultibufState {
        handle: buf,
        regions: Vec::new(),
        ns_id,
    };

    MULTIBUFFERS.with(|mbs| mbs.borrow_mut().insert(handle, state));

    // Handle BufWriteCmd to save changes
    let write_cb = Function::from_fn(move |args: AutocmdCallbackArgs| {
        let _ = multibuf_write(args.buffer.handle());
        Ok::<bool, nvim_oxi::Error>(false)
    });
    
    api::create_autocmd(vec!["BufWriteCmd"], &CreateAutocmdOpts::builder()
        .buffer(Buffer::from(handle))
        .callback(write_cb)
        .build())?;

    Ok(handle)
}

fn define_signs() {
    for i in 0..10 {
        let _ = api::command(&format!("sign define MultibufDigit{} text=0{} texthl=LineNr", i, i));
        let _ = api::command(&format!("sign define MultibufDigit0{} text=0{} texthl=LineNr", i, i));
    }
    for i in 10..100 {
        let _ = api::command(&format!("sign define MultibufDigit{} text={} texthl=LineNr", i, i));
    }
    let _ = api::command("sign define MultibufDigitSpacer text=\\  texthl=LineNr");
}

/// Saves multibuffer content back to source buffers.
pub fn multibuf_write(mbuf_handle: i32) -> nvim_oxi::Result<()> {
    let _guard = match SyncGuard::new() {
        Some(g) => g,
        None => return Ok(()),
    };

    MULTIBUFFERS.with(|all_mbs| -> nvim_oxi::Result<()> {
        let mut all_mbs = all_mbs.borrow_mut();
        let mb = all_mbs.get_mut(&mbuf_handle).ok_or_else(|| api::Error::Other("Multibuffer not found".to_string()))?;
        let ns_id = mb.ns_id;
        let mbuf = mb.handle.clone();

        let mut get_opts = Dictionary::new();
        get_opts.insert("details", true);
        let extmarks_obj: Object = api::call_function("nvim_buf_get_extmarks", (mbuf.handle(), ns_id, 0, -1, get_opts))?;
        
        let extmarks: Vec<Object> = Vec::deserialize(Deserializer::new(extmarks_obj))
            .map_err(|e| api::Error::Other(e.to_string()))?;

        for region in &mb.regions {
            for mark_val in &extmarks {
                let mark: Vec<Object> = Vec::deserialize(Deserializer::new(mark_val.clone()))
                    .map_err(|e| api::Error::Other(e.to_string()))?;
                
                let id = i64::deserialize(Deserializer::new(mark[0].clone())).unwrap() as u32;
                if id == region.source_extmark {
                    let row = i64::deserialize(Deserializer::new(mark[1].clone())).unwrap() as usize;
                    let details: HashMap<String, Object> = HashMap::deserialize(Deserializer::new(mark[3].clone())).unwrap();
                    
                    let end_row = details.get("end_row")
                        .and_then(|v| i64::deserialize(Deserializer::new(v.clone())).ok())
                        .map(|v| v as usize)
                        .unwrap_or(row + 1);

                    let mut source_buf = Buffer::from(region.source_buf_handle);
                    if let Some((src_start, src_end)) = get_extmark_range(&source_buf, ns_id, region.source_extmark) {
                        if let Ok(lines) = mbuf.get_lines(row..end_row, false) {
                            let line_vec: Vec<String> = lines.map(|l| l.to_string()).collect();
                            let _ = source_buf.set_lines(src_start..src_end, false, line_vec);
                        }
                    }
                    break;
                }
            }
        }
        #[allow(deprecated)]
        mb.handle.set_option("modified", false)?;
        Ok(())
    })
}

#[derive(Deserialize)]
struct AddBufferArgs {
    multibuf: i32,
    source_buf: i32,
    regions: Vec<MultibufRegion>,
}

pub fn multibuf_add_buffer(args: Object) -> nvim_oxi::Result<()> {
    let args = AddBufferArgs::deserialize(Deserializer::new(args))
        .map_err(|e| api::Error::Other(e.to_string()))?;

    let mut source_buf = Buffer::from(args.source_buf);
    if !source_buf.is_valid() {
        return Err(api::Error::Other(format!("Invalid source buffer: {}", args.source_buf)).into());
    }

    MULTIBUFFERS.with(|mbs| -> nvim_oxi::Result<()> {
        let mut mbs = mbs.borrow_mut();
        let mb = mbs.get_mut(&args.multibuf).ok_or_else(|| api::Error::Other("Multibuffer not found".to_string()))?;
        let ns_id = mb.ns_id;

        for region in &args.regions {
            let start = region.start_row;
            let end = region.end_row;
            
            if start <= end {
                let src_ext_id = source_buf.set_extmark(ns_id, start, 0, &SetExtmarkOpts::builder()
                    .end_row(end + 1)
                    .strict(false)
                    .build())?;

                mb.regions.push(RegionState {
                    source_buf_handle: args.source_buf,
                    source_extmark: src_ext_id,
                });
            }
        }

        setup_source_sync(args.source_buf, args.multibuf)?;
        multibuf_reload(args.multibuf)?;
        Ok(())
    })
}

fn setup_source_sync(source_handle: i32, mbuf_handle: i32) -> nvim_oxi::Result<()> {
    SOURCE_TO_MBUF.with(|map| {
        let mut map = map.borrow_mut();
        let watchers = map.entry(source_handle).or_insert_with(Vec::new);
        if !watchers.contains(&mbuf_handle) {
            watchers.push(mbuf_handle);
            
            let cb = Function::from_fn(move |args: AutocmdCallbackArgs| {
                let _ = sync_source_to_mbufs(args.buffer.handle());
                Ok::<bool, nvim_oxi::Error>(false)
            });
            let _ = api::create_autocmd(vec!["TextChanged", "TextChangedI"], &CreateAutocmdOpts::builder()
                .buffer(Buffer::from(source_handle))
                .callback(cb)
                .build());
        }
    });
    Ok(())
}

fn sync_source_to_mbufs(source_handle: i32) -> nvim_oxi::Result<()> {
    if IS_SYNCING.with(|s| *s.borrow()) { return Ok(()); }
    
    SOURCE_TO_MBUF.with(|map| {
        let map = map.borrow();
        if let Some(mbufs) = map.get(&source_handle) {
            for &mb_handle in mbufs {
                let _ = multibuf_reload(mb_handle);
            }
        }
    });
    Ok(())
}

/// Completely re-renders the multibuffer based on its current regions.
pub fn multibuf_reload(mbuf_handle: i32) -> nvim_oxi::Result<()> {
    let _guard = match SyncGuard::new() {
        Some(g) => g,
        None => return Ok(()),
    };

    MULTIBUFFERS.with(|mbs| -> nvim_oxi::Result<()> {
        let mut mbs = mbs.borrow_mut();
        let mb = mbs.get_mut(&mbuf_handle).ok_or_else(|| api::Error::Other("Multibuffer not found".to_string()))?;
        let ns_id = mb.ns_id;
        let mut mbuf = mb.handle.clone();

        mbuf.clear_namespace(ns_id, 0..usize::MAX)?;

        let mut all_lines = Vec::new();
        let mut region_metas = Vec::new();

        let mut last_buf = -1;

        for region in &mb.regions {
            let source_buf = Buffer::from(region.source_buf_handle);
            if let Some((src_start, src_end)) = get_extmark_range(&source_buf, ns_id, region.source_extmark) {
                if let Ok(lines) = source_buf.get_lines(src_start..src_end, false) {
                    let start_in_mbuf = all_lines.len();
                    
                    let mut header_needed = false;
                    if region.source_buf_handle != last_buf {
                        header_needed = true;
                        last_buf = region.source_buf_handle;
                    }

                    for line in lines {
                        all_lines.push(line.to_string());
                    }
                    let end_in_mbuf = all_lines.len();
                    region_metas.push((region.clone(), start_in_mbuf, end_in_mbuf, src_start, header_needed));
                }
            }
        }

        // Apply lines
        mbuf.set_lines(0..usize::MAX, false, all_lines)?;

        // Apply UI elements
        for (reg, start, end, src_start, header) in region_metas {
            let _ = mbuf.set_extmark(ns_id, start, 0, &SetExtmarkOpts::builder()
                .id(reg.source_extmark)
                .end_row(end)
                .strict(false)
                .build())?;

            if header {
                let source_buf = Buffer::from(reg.source_buf_handle);
                let name = source_buf.get_name().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "Unknown".into());
                let text = format!(" ─────── Source: {} ─────── ", name);
                let _ = mbuf.set_extmark(ns_id, start, 0, &SetExtmarkOpts::builder()
                    .virt_lines(vec![vec![("", "None")], vec![(&text, "Title")], vec![("", "None")]])
                    .virt_lines_above(true)
                    .build())?;
            }

            for i in start..end {
                let display_lnum = src_start + (i - start) + 1;
                let text = format!("{:>3} ", display_lnum % 1000);
                let _ = mbuf.set_extmark(ns_id, i, 0, &SetExtmarkOpts::builder()
                    .sign_text(text.as_str())
                    .sign_hl_group("LineNr")
                    .priority(100)
                    .build())?;
            }
        }

        #[allow(deprecated)]
        mbuf.set_option("modified", false)?;
        Ok(())
    })
}

fn get_extmark_range(buf: &Buffer, ns_id: u32, ext_id: u32) -> Option<(usize, usize)> {
    let mut opts = Dictionary::new();
    opts.insert("details", true);
    let ext_obj: Object = api::call_function("nvim_buf_get_extmark_by_id", (buf.handle(), ns_id, ext_id, opts)).ok()?;
    let ext: Vec<Object> = Vec::deserialize(Deserializer::new(ext_obj)).ok()?;
    
    let start = i64::deserialize(Deserializer::new(ext[0].clone())).ok()? as usize;
    let details: HashMap<String, Object> = HashMap::deserialize(Deserializer::new(ext[2].clone())).ok()?;
    
    let end = details.get("end_row").and_then(|v| i64::deserialize(Deserializer::new(v.clone())).ok()).map(|v| v as usize)?;
    Some((start, end))
}

pub fn multibuf_get_context(args: (i32, usize)) -> nvim_oxi::Result<Object> {
    let (multibuf, line) = args;
    MULTIBUFFERS.with(|mbs| {
        let mbs = mbs.borrow();
        let mb = mbs.get(&multibuf).ok_or_else(|| api::Error::Other("Multibuffer not found".to_string()))?;
        let ns_id = mb.ns_id;
        
        let mut get_opts = Dictionary::new();
        get_opts.insert("details", true);
        let extmarks_obj: Object = api::call_function("nvim_buf_get_extmarks", (mb.handle.handle(), ns_id, 0, -1, get_opts))?;
        
        let extmarks: Vec<Object> = Vec::deserialize(Deserializer::new(extmarks_obj)).unwrap();

        for mark_val in extmarks {
            let mark: Vec<Object> = Vec::deserialize(Deserializer::new(mark_val)).unwrap();
            let start = i64::deserialize(Deserializer::new(mark[1].clone())).unwrap() as usize;
            let details: HashMap<String, Object> = HashMap::deserialize(Deserializer::new(mark[3].clone())).unwrap();
            let end = details.get("end_row")
                .and_then(|v| i64::deserialize(Deserializer::new(v.clone())).ok())
                .map(|v| v as usize)
                .unwrap_or(start + 1);
            
            if line >= start && line < end {
                let source_ext_id = i64::deserialize(Deserializer::new(mark[0].clone())).unwrap() as u32;
                if let Some(region) = mb.regions.iter().find(|r| r.source_extmark == source_ext_id) {
                    if let Some((src_start, _)) = get_extmark_range(&Buffer::from(region.source_buf_handle), ns_id, region.source_extmark) {
                        let res = ContextResult { buf: region.source_buf_handle, line: src_start + (line - start) };
                        return Ok(res.serialize(Serializer::new()).map_err(|e| api::Error::Other(e.to_string()))?);
                    }
                }
            }
        }
        Ok(Object::nil())
    })
}

#[derive(Serialize)]
struct ContextResult { buf: i32, line: usize }

#[nvim_oxi::plugin]
fn multibuffer() -> Dictionary {
    let mut dict = Dictionary::new();
    dict.insert("create", Function::<(), i32>::from_fn(multibuf_create));
    dict.insert("add_buffer", Function::<Object, ()>::from_fn(multibuf_add_buffer));
    dict.insert("get_context", Function::<(i32, usize), Object>::from_fn(multibuf_get_context));
    dict.insert("write", Function::<i32, ()>::from_fn(multibuf_write));
    dict.insert("reload", Function::<i32, ()>::from_fn(multibuf_reload));
    dict
}
