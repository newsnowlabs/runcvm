//! runcvm-fuse-client: File access client for RunCVM guest VM
//!
//! This client runs inside the guest VM and provides access to host files
//! via vsock connection to runcvm-fused daemon.

use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::os::unix::fs::symlink;

use anyhow::{Context, Result, bail};
use log::{debug, error, info, warn};
use vsock::{VsockAddr, VsockStream};

/// Default host CID (hypervisor/host)
const DEFAULT_HOST_CID: u32 = 2;
/// Default port
const DEFAULT_PORT: u32 = 5742;

fn main() -> Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();
    
    let args: Vec<String> = std::env::args().collect();
    
    let mut host_cid = DEFAULT_HOST_CID;
    let mut port = DEFAULT_PORT;
    let mut mount_point: Option<PathBuf> = None;
    let mut source_path: Option<String> = None;
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--host-cid" => {
                i += 1;
                if let Some(s) = args.get(i) {
                    host_cid = s.parse().unwrap_or(DEFAULT_HOST_CID);
                }
            }
            "--port" => {
                i += 1;
                if let Some(s) = args.get(i) {
                    port = s.parse().unwrap_or(DEFAULT_PORT);
                }
            }
            "--mount" => {
                i += 1;
                if let Some(s) = args.get(i) {
                    mount_point = Some(PathBuf::from(s));
                }
            }
            "--source" => {
                i += 1;
                if let Some(s) = args.get(i) {
                    source_path = Some(s.clone());
                }
            }
            "--help" | "-h" => {
                println!("runcvm-fuse-client - File access client for RunCVM guest");
                println!();
                println!("Usage: runcvm-fuse-client [OPTIONS]");
                println!();
                println!("Options:");
                println!("  --host-cid <CID>   Host CID (default: 2)");
                println!("  --port <PORT>      Port (default: 5742)");
                println!("  --mount <PATH>     Mount point in guest");
                println!("  --source <PATH>    Source path on host");
                return Ok(());
            }
            _ => {}
        }
        i += 1;
    }
    
    let mount = mount_point.context("Missing --mount argument")?;
    let source = source_path.context("Missing --source argument")?;
    
    info!("runcvm-fuse-client starting...");
    info!("  Host CID: {}", host_cid);
    info!("  Port: {}", port);
    info!("  Mount: {:?}", mount);
    info!("  Source: {}", source);
    
    // Create mount point
    fs::create_dir_all(&mount)?;
    
    // Connect to host daemon
    let addr = VsockAddr::new(host_cid, port);
    info!("Connecting to host at {:?}", addr);
    
    let mut stream = VsockStream::connect(&addr)
        .with_context(|| format!("Failed to connect to host CID {} port {}", host_cid, port))?;
    
    info!("Connected to host daemon");
    
    // Do initial sync: list remote directory and create local structure
    info!("Syncing directory structure...");
    sync_directory(&mut stream, &source, &mount)?;
    
    info!("Initial sync complete. Mount accessible at {:?}", mount);
    
    // Keep running to handle file requests
    // In a real implementation, this would set up inotify watches
    // For now, just sleep
    loop {
        std::thread::sleep(std::time::Duration::from_secs(60));
    }
}

fn sync_directory(stream: &mut VsockStream, remote_path: &str, local_path: &PathBuf) -> Result<()> {
    // Send list dir request
    let mut request = vec![3u8]; // MsgType::ListDir
    let path_bytes = remote_path.as_bytes();
    request.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
    request.extend_from_slice(path_bytes);
    
    stream.write_all(&request)?;
    
    // Read response
    let mut status = [0u8; 1];
    stream.read_exact(&mut status)?;
    
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf) as usize;
    
    let mut data = vec![0u8; len];
    stream.read_exact(&mut data)?;
    
    if status[0] != 0 {
        let msg = String::from_utf8_lossy(&data);
        warn!("Failed to list {}: {}", remote_path, msg);
        return Ok(());
    }
    
    // Parse entries
    let entries_str = String::from_utf8_lossy(&data);
    for entry in entries_str.lines() {
        if entry.is_empty() {
            continue;
        }
        
        let entry_path = local_path.join(entry);
        debug!("Creating entry: {:?}", entry_path);
        
        // For now, just create placeholder files
        // A real implementation would check file type and sync content
        if !entry_path.exists() {
            // Create as empty file (placeholder)
            fs::write(&entry_path, b"")?;
        }
    }
    
    info!("  Synced {} entries from {}", entries_str.lines().count(), remote_path);
    
    Ok(())
}
