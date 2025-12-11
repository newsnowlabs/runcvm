//! runcvm-fused: Memory-efficient FUSE daemon for RunCVM
//!
//! Serves filesystem operations to Firecracker guest VM via vsock.
//! Designed for low-memory guests - sends metadata separately from content.
//!
//! Operations:
//! - MSG_READ_FILE (1): Read single file
//! - MSG_WRITE_FILE (2): Write single file  
//! - MSG_MKDIR (5): Create directory
//! - MSG_LIST_FILES (11): List all files with metadata (no content)

use std::fs::{self, File};
use std::io::{Read, Write, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::UNIX_EPOCH;

use anyhow::{Context, Result};
use log::{info, error, debug, warn};

const MSG_READ_FILE: u8 = 1;
const MSG_WRITE_FILE: u8 = 2;
const MSG_LIST_DIR: u8 = 3;
const MSG_STAT: u8 = 4;
const MSG_MKDIR: u8 = 5;
const MSG_SYNC_ALL: u8 = 10;
const MSG_LIST_FILES: u8 = 11;

const DEFAULT_VSOCK_PORT: u32 = 5742;
const CHUNK_SIZE: usize = 32768;

fn main() -> Result<()> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    info!("runcvm-fused starting (low-memory mode)...");

    let args: Vec<String> = std::env::args().collect();
    let mut vsock_port = DEFAULT_VSOCK_PORT;
    let mut vsock_uds_path = PathBuf::from("/run/firecracker.vsock");
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vsock-port" => { i += 1; vsock_port = args.get(i).and_then(|s| s.parse().ok()).unwrap_or(DEFAULT_VSOCK_PORT); }
            "--vsock-uds" => { i += 1; vsock_uds_path = args.get(i).map(PathBuf::from).unwrap_or(vsock_uds_path); }
            "--help" | "-h" => {
                println!("runcvm-fused - FUSE daemon for RunCVM");
                println!("  --vsock-port <PORT>  Port (default: 5742)");
                println!("  --vsock-uds <PATH>   UDS path");
                return Ok(());
            }
            _ => {}
        }
        i += 1;
    }

    let listen_path = format!("{}_{}", vsock_uds_path.display(), vsock_port);
    info!("Listening on: {}", listen_path);
    
    let _ = fs::remove_file(&listen_path);
    let listener = UnixListener::bind(&listen_path)
        .with_context(|| format!("Failed to bind {}", listen_path))?;
    
    info!("Waiting for guest connections...");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                info!("New connection from guest");
                thread::spawn(move || {
                    if let Err(e) = handle_connection(stream) {
                        error!("Connection error: {}", e);
                    }
                });
            }
            Err(e) => error!("Accept error: {}", e),
        }
    }

    Ok(())
}

fn handle_connection(mut stream: UnixStream) -> Result<()> {
    let mut buf = vec![0u8; CHUNK_SIZE];
    
    loop {
        // Read message header
        let mut header = [0u8; 5];
        if stream.read_exact(&mut header).is_err() {
            debug!("Connection closed");
            break;
        }
        
        let msg_type = header[0];
        let path_len = u32::from_le_bytes([header[1], header[2], header[3], header[4]]) as usize;
        
        if path_len > buf.len() {
            buf.resize(path_len, 0);
        }
        
        if stream.read_exact(&mut buf[..path_len]).is_err() {
            break;
        }
        
        let path = String::from_utf8_lossy(&buf[..path_len]).to_string();
        debug!("Request: type={}, path={}", msg_type, path);
        
        match msg_type {
            MSG_READ_FILE => {
                if let Err(e) = handle_read_file(&path, &mut stream) {
                    warn!("Read file error: {}", e);
                }
            }
            MSG_WRITE_FILE => {
                if let Err(e) = handle_write_file(&path, &mut stream) {
                    warn!("Write file error: {}", e);
                }
            }
            MSG_LIST_DIR => {
                match list_dir(&path) {
                    Ok(data) => send_success(&mut stream, &data)?,
                    Err(e) => send_error(&mut stream, &e.to_string())?,
                }
            }
            MSG_STAT => {
                match stat_file(&path) {
                    Ok(data) => send_success(&mut stream, &data)?,
                    Err(e) => send_error(&mut stream, &e.to_string())?,
                }
            }
            MSG_MKDIR => {
                match fs::create_dir_all(&path) {
                    Ok(_) => send_success(&mut stream, b"OK")?,
                    Err(e) => send_error(&mut stream, &e.to_string())?,
                }
            }
            MSG_LIST_FILES => {
                if let Err(e) = handle_list_files(&path, &mut stream) {
                    warn!("List files error: {}", e);
                }
            }
            MSG_SYNC_ALL => {
                // Legacy bulk sync - redirect to list_files
                if let Err(e) = handle_list_files(&path, &mut stream) {
                    warn!("Sync all error: {}", e);
                }
            }
            _ => {
                send_error(&mut stream, "Unknown message type")?;
            }
        }
    }
    
    Ok(())
}

fn send_success(stream: &mut UnixStream, data: &[u8]) -> Result<()> {
    stream.write_all(&[0])?;
    stream.write_all(&(data.len() as u32).to_le_bytes())?;
    stream.write_all(data)?;
    Ok(())
}

fn send_error(stream: &mut UnixStream, msg: &str) -> Result<()> {
    stream.write_all(&[255])?;
    stream.write_all(&(msg.len() as u32).to_le_bytes())?;
    stream.write_all(msg.as_bytes())?;
    Ok(())
}

/// Read file and stream to client
fn handle_read_file(path: &str, stream: &mut UnixStream) -> Result<()> {
    let metadata = fs::metadata(path)?;
    let file_size = metadata.len() as usize;
    
    // Send success + size
    stream.write_all(&[0])?;
    stream.write_all(&(file_size as u32).to_le_bytes())?;
    
    // Stream file content in chunks
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut buf = vec![0u8; CHUNK_SIZE];
    let mut remaining = file_size;
    
    while remaining > 0 {
        let to_read = remaining.min(CHUNK_SIZE);
        reader.read_exact(&mut buf[..to_read])?;
        stream.write_all(&buf[..to_read])?;
        remaining -= to_read;
    }
    
    debug!("Sent file: {} ({} bytes)", path, file_size);
    Ok(())
}

/// Receive file from client and write to disk
fn handle_write_file(path: &str, stream: &mut UnixStream) -> Result<()> {
    // Read data length
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let data_len = u32::from_le_bytes(len_buf) as usize;
    
    // Ensure parent exists
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent)?;
    }
    
    // Read and write in chunks to keep memory low
    let mut file = File::create(path)?;
    let mut buf = vec![0u8; CHUNK_SIZE];
    let mut remaining = data_len;
    
    while remaining > 0 {
        let to_read = remaining.min(CHUNK_SIZE);
        stream.read_exact(&mut buf[..to_read])?;
        file.write_all(&buf[..to_read])?;
        remaining -= to_read;
    }
    
    file.flush()?;
    
    info!("Wrote file: {} ({} bytes)", path, data_len);
    send_success(stream, b"OK")
}

/// List all files recursively with metadata (no content)
fn handle_list_files(base_path: &str, stream: &mut UnixStream) -> Result<()> {
    let mut output = String::new();
    collect_file_list(Path::new(base_path), base_path, &mut output)?;
    
    let data = output.as_bytes();
    stream.write_all(&[0])?;  // Success
    stream.write_all(&(data.len() as u32).to_le_bytes())?;
    stream.write_all(data)?;
    
    debug!("Listed {} bytes of file metadata", data.len());
    Ok(())
}

/// Recursively collect file metadata
/// Format per line: "rel_path\ttype\tsize\tmtime\n"
fn collect_file_list(path: &Path, base: &str, output: &mut String) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    
    if path.is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let entry_path = entry.path();
            let rel_path = entry_path.strip_prefix(base).unwrap_or(&entry_path);
            
            if entry_path.is_dir() {
                output.push_str(&format!("{}\td\t0\t0\n", rel_path.display()));
                collect_file_list(&entry_path, base, output)?;
            } else if let Ok(m) = entry_path.metadata() {
                let mtime = m.modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                output.push_str(&format!("{}\tf\t{}\t{}\n", rel_path.display(), m.len(), mtime));
            }
        }
    }
    
    Ok(())
}

fn list_dir(path: &str) -> Result<Vec<u8>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        entries.push(entry.file_name().to_string_lossy().to_string());
    }
    Ok(entries.join("\n").into_bytes())
}

fn stat_file(path: &str) -> Result<Vec<u8>> {
    let m = fs::metadata(path)?;
    Ok(format!("size:{}\ntype:{}\n", m.len(), if m.is_dir() { "dir" } else { "file" }).into_bytes())
}
