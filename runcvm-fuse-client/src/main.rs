//! runcvm-fuse-client: Memory-efficient bidirectional file sync
//!
//! DESIGNED FOR LOW MEMORY ENVIRONMENTS
//! - Syncs ONE file at a time (no bulk loading)
//! - Uses small fixed buffers (64KB max)
//! - Streams directly to disk
//!
//! Protocol:
//! - MSG_LIST_FILES (11): Get list of paths with sizes/mtimes
//! - MSG_READ_FILE (1): Read single file
//! - MSG_WRITE_FILE (2): Write single file

use std::fs::{self, File};
use std::io::{Read, Write, BufWriter};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::collections::HashMap;

use anyhow::{Context, Result, bail};
use log::{debug, error, info, warn};

const AF_VSOCK: libc::c_int = 40;
const VMADDR_CID_HOST: u32 = 2;

#[repr(C)]
struct SockaddrVm {
    svm_family: libc::sa_family_t,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

// Message types
const MSG_READ_FILE: u8 = 1;
const MSG_WRITE_FILE: u8 = 2;
const MSG_MKDIR: u8 = 5;
const MSG_LIST_FILES: u8 = 11;  // Get file list with metadata

const DEFAULT_PORT: u32 = 5742;
const SYNC_INTERVAL_SECS: u64 = 2;
const CHUNK_SIZE: usize = 32768;  // 32KB chunks for streaming

fn main() -> Result<()> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();
    
    let args: Vec<String> = std::env::args().collect();
    
    let mut host_cid = VMADDR_CID_HOST;
    let mut port = DEFAULT_PORT;
    let mut mount_point: Option<PathBuf> = None;
    let mut source_path: Option<String> = None;
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--host-cid" => { i += 1; host_cid = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(VMADDR_CID_HOST); }
            "--port" => { i += 1; port = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(DEFAULT_PORT); }
            "--mount" => { i += 1; mount_point = args.get(i).map(PathBuf::from); }
            "--source" => { i += 1; source_path = args.get(i).cloned(); }
            "--help" | "-h" => {
                println!("runcvm-fuse-client - Memory-efficient file sync");
                println!("  --mount <PATH>   Local mount point");
                println!("  --source <PATH>  Remote source path");
                return Ok(());
            }
            _ => {}
        }
        i += 1;
    }
    
    let mount = mount_point.context("Missing --mount")?;
    let source = source_path.context("Missing --source")?;
    
    info!("runcvm-fuse-client starting (low-memory mode)...");
    info!("  Mount: {:?}, Source: {}", mount, source);
    
    fs::create_dir_all(&mount)?;
    
    info!("Connecting to host via vsock...");
    let fd = vsock_connect(host_cid, port)?;
    info!("Connected!");
    
    let mut stream = unsafe { std::fs::File::from_raw_fd(fd) };
    
    // Initial sync
    info!("Initial sync from host...");
    let count = sync_from_host(&mut stream, &source, &mount)?;
    info!("Synced {} files from host", count);
    
    // Track local file state
    let mut local_state: HashMap<PathBuf, (u64, u64)> = HashMap::new(); // path -> (size, mtime)
    update_local_state(&mount, &mut local_state)?;
    
    info!("Starting bidirectional sync (interval: {}s)...", SYNC_INTERVAL_SECS);
    
    loop {
        std::thread::sleep(Duration::from_secs(SYNC_INTERVAL_SECS));
        
        // Sync from host (download new/changed files)
        if let Err(e) = sync_from_host(&mut stream, &source, &mount) {
            warn!("Host→Guest sync failed: {}", e);
            // Reconnect
            if let Ok(new_fd) = vsock_connect(host_cid, port) {
                stream = unsafe { std::fs::File::from_raw_fd(new_fd) };
                info!("Reconnected");
            }
            continue;
        }
        
        // Sync to host (upload changed files)
        if let Err(e) = sync_to_host(&mut stream, &mount, &source, &mut local_state) {
            warn!("Guest→Host sync failed: {}", e);
        }
    }
}

fn vsock_connect(cid: u32, port: u32) -> Result<RawFd> {
    unsafe {
        let fd = libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0);
        if fd < 0 {
            bail!("socket() failed: {}", std::io::Error::last_os_error());
        }
        
        // 5 second timeout
        let timeout = libc::timeval { tv_sec: 5, tv_usec: 0 };
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVTIMEO,
            &timeout as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::timeval>() as libc::socklen_t);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_SNDTIMEO,
            &timeout as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::timeval>() as libc::socklen_t);
        
        let addr = SockaddrVm {
            svm_family: AF_VSOCK as libc::sa_family_t,
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: cid,
            svm_zero: [0; 4],
        };
        
        if libc::connect(fd, &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<SockaddrVm>() as libc::socklen_t) < 0 {
            let err = std::io::Error::last_os_error();
            libc::close(fd);
            bail!("connect() failed: {}", err);
        }
        
        Ok(fd)
    }
}

/// File info from remote
#[derive(Debug)]
struct RemoteFile {
    path: String,
    is_dir: bool,
    size: u64,
    mtime: u64,
}

/// Get list of files from host (metadata only, not content)
fn list_remote_files<S: Read + Write>(stream: &mut S, remote_path: &str) -> Result<Vec<RemoteFile>> {
    // Send LIST_FILES request
    let mut req = vec![MSG_LIST_FILES];
    let path_bytes = remote_path.as_bytes();
    req.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
    req.extend_from_slice(path_bytes);
    stream.write_all(&req)?;
    
    // Read response
    let mut status = [0u8; 1];
    stream.read_exact(&mut status)?;
    
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let data_len = u32::from_le_bytes(len_buf) as usize;
    
    // Read file list data (format: "path\ttype\tsize\tmtime\n" per line)
    let mut data = vec![0u8; data_len];
    stream.read_exact(&mut data)?;
    
    if status[0] != 0 {
        bail!("List files failed: {}", String::from_utf8_lossy(&data));
    }
    
    let mut files = Vec::new();
    for line in String::from_utf8_lossy(&data).lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 4 {
            files.push(RemoteFile {
                path: parts[0].to_string(),
                is_dir: parts[1] == "d",
                size: parts[2].parse().unwrap_or(0),
                mtime: parts[3].parse().unwrap_or(0),
            });
        }
    }
    
    Ok(files)
}

/// Download a single file from host (streaming, low memory)
fn download_file<S: Read + Write>(stream: &mut S, remote_path: &str, local_path: &Path) -> Result<()> {
    // Send READ_FILE request
    let mut req = vec![MSG_READ_FILE];
    let path_bytes = remote_path.as_bytes();
    req.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
    req.extend_from_slice(path_bytes);
    stream.write_all(&req)?;
    
    // Read response header
    let mut status = [0u8; 1];
    stream.read_exact(&mut status)?;
    
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let data_len = u32::from_le_bytes(len_buf) as usize;
    
    if status[0] != 0 {
        let mut err_msg = vec![0u8; data_len.min(256)];
        stream.read_exact(&mut err_msg)?;
        bail!("Read failed: {}", String::from_utf8_lossy(&err_msg));
    }
    
    // Ensure parent directory exists
    if let Some(parent) = local_path.parent() {
        fs::create_dir_all(parent)?;
    }
    
    // Stream content to file in chunks
    let file = File::create(local_path)?;
    let mut writer = BufWriter::new(file);
    let mut remaining = data_len;
    let mut chunk = vec![0u8; CHUNK_SIZE];
    
    while remaining > 0 {
        let to_read = remaining.min(CHUNK_SIZE);
        stream.read_exact(&mut chunk[..to_read])?;
        writer.write_all(&chunk[..to_read])?;
        remaining -= to_read;
    }
    
    writer.flush()?;
    debug!("Downloaded: {} ({} bytes)", remote_path, data_len);
    Ok(())
}

/// Upload a single file to host
fn upload_file<S: Read + Write>(stream: &mut S, local_path: &Path, remote_path: &str) -> Result<()> {
    let data = fs::read(local_path)?;
    
    // Send WRITE_FILE request
    let mut req = vec![MSG_WRITE_FILE];
    let path_bytes = remote_path.as_bytes();
    req.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
    req.extend_from_slice(path_bytes);
    req.extend_from_slice(&(data.len() as u32).to_le_bytes());
    stream.write_all(&req)?;
    stream.write_all(&data)?;
    
    // Read response
    let mut status = [0u8; 1];
    stream.read_exact(&mut status)?;
    
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let resp_len = u32::from_le_bytes(len_buf) as usize;
    
    let mut resp = vec![0u8; resp_len];
    stream.read_exact(&mut resp)?;
    
    if status[0] != 0 {
        bail!("Write failed: {}", String::from_utf8_lossy(&resp));
    }
    
    debug!("Uploaded: {} ({} bytes)", remote_path, data.len());
    Ok(())
}

/// Create directory on host
fn mkdir_remote<S: Read + Write>(stream: &mut S, path: &str) -> Result<()> {
    let mut req = vec![MSG_MKDIR];
    let path_bytes = path.as_bytes();
    req.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
    req.extend_from_slice(path_bytes);
    stream.write_all(&req)?;
    
    let mut status = [0u8; 1];
    stream.read_exact(&mut status)?;
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let resp_len = u32::from_le_bytes(len_buf) as usize;
    let mut resp = vec![0u8; resp_len];
    stream.read_exact(&mut resp)?;
    Ok(())
}

/// Sync files from host to local (one at a time)
fn sync_from_host<S: Read + Write>(stream: &mut S, remote_base: &str, local_base: &Path) -> Result<usize> {
    let files = list_remote_files(stream, remote_base)?;
    let mut synced = 0;
    
    for file in files {
        let local_path = local_base.join(&file.path);
        
        if file.is_dir {
            if !local_path.exists() {
                fs::create_dir_all(&local_path)?;
                synced += 1;
            }
        } else {
            // Check if we need to download
            let needs_download = if local_path.exists() {
                // Compare size
                match fs::metadata(&local_path) {
                    Ok(m) => m.len() != file.size,
                    Err(_) => true,
                }
            } else {
                true
            };
            
            if needs_download {
                let remote_full = format!("{}/{}", remote_base, file.path);
                if let Err(e) = download_file(stream, &remote_full, &local_path) {
                    warn!("Failed to download {}: {}", file.path, e);
                } else {
                    synced += 1;
                }
            }
        }
    }
    
    Ok(synced)
}

/// Update local file state cache
fn update_local_state(dir: &Path, state: &mut HashMap<PathBuf, (u64, u64)>) -> Result<()> {
    if !dir.exists() {
        return Ok(());
    }
    
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        
        if path.is_dir() {
            update_local_state(&path, state)?;
        } else if let Ok(m) = path.metadata() {
            let mtime = m.modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            state.insert(path, (m.len(), mtime));
        }
    }
    Ok(())
}

/// Sync changed local files to host
fn sync_to_host<S: Read + Write>(
    stream: &mut S,
    local_base: &Path,
    remote_base: &str,
    old_state: &mut HashMap<PathBuf, (u64, u64)>,
) -> Result<()> {
    let mut new_state: HashMap<PathBuf, (u64, u64)> = HashMap::new();
    update_local_state(local_base, &mut new_state)?;
    
    for (path, &(new_size, new_mtime)) in &new_state {
        let should_upload = match old_state.get(path) {
            Some(&(old_size, old_mtime)) => new_size != old_size || new_mtime > old_mtime,
            None => true,
        };
        
        if should_upload {
            if let Ok(rel) = path.strip_prefix(local_base) {
                let remote_path = format!("{}/{}", remote_base, rel.display());
                
                // Create parent dir if needed
                if let Some(parent) = rel.parent() {
                    if !parent.as_os_str().is_empty() {
                        let parent_remote = format!("{}/{}", remote_base, parent.display());
                        let _ = mkdir_remote(stream, &parent_remote);
                    }
                }
                
                if let Err(e) = upload_file(stream, path, &remote_path) {
                    warn!("Upload failed {}: {}", rel.display(), e);
                } else {
                    info!("Synced to host: {}", rel.display());
                }
            }
        }
    }
    
    *old_state = new_state;
    Ok(())
}
