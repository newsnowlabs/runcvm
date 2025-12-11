//! runcvm-fuse-client: File access client for RunCVM guest VM
//!
//! This client runs inside the Firecracker guest VM and provides access to host files
//! via vsock connection to runcvm-fused daemon.
//!
//! Uses raw libc sockets for vsock to work with Firecracker's virtio-vsock device.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::PathBuf;
use std::net::Shutdown;

use anyhow::{Context, Result, bail};
use log::{debug, error, info, warn};

/// AF_VSOCK address family
const AF_VSOCK: libc::c_int = 40;
/// VMADDR_CID_HOST (CID 2 = hypervisor/host)
const VMADDR_CID_HOST: u32 = 2;

/// sockaddr_vm structure for vsock
#[repr(C)]
struct SockaddrVm {
    svm_family: libc::sa_family_t,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

/// Default port
const DEFAULT_PORT: u32 = 5742;

fn main() -> Result<()> {
    // Initialize logging
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
            "--host-cid" => {
                i += 1;
                if let Some(s) = args.get(i) {
                    host_cid = s.parse().unwrap_or(VMADDR_CID_HOST);
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
    
    // Connect to host daemon using raw vsock socket
    info!("Connecting to host via vsock (CID {} port {})...", host_cid, port);
    
    let fd = vsock_connect(host_cid, port)?;
    info!("Connected to host daemon!");
    
    // Wrap in a File for easier I/O
    let mut stream = unsafe { std::fs::File::from_raw_fd(fd) };
    
    // Do initial sync: list remote directory and create local structure
    info!("Syncing directory structure...");
    sync_directory(&mut stream, &source, &mount)?;
    
    info!("Initial sync complete. Mount accessible at {:?}", mount);
    
    // Keep running to handle file requests
    loop {
        std::thread::sleep(std::time::Duration::from_secs(60));
    }
}

/// Connect to a vsock address using raw libc sockets
fn vsock_connect(cid: u32, port: u32) -> Result<RawFd> {
    unsafe {
        // Create vsock socket
        let fd = libc::socket(AF_VSOCK, libc::SOCK_STREAM, 0);
        if fd < 0 {
            bail!("Failed to create vsock socket: {}", std::io::Error::last_os_error());
        }
        
        // Build sockaddr_vm
        let addr = SockaddrVm {
            svm_family: AF_VSOCK as libc::sa_family_t,
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: cid,
            svm_zero: [0; 4],
        };
        
        // Connect
        let addr_ptr = &addr as *const SockaddrVm as *const libc::sockaddr;
        let addr_len = std::mem::size_of::<SockaddrVm>() as libc::socklen_t;
        
        let ret = libc::connect(fd, addr_ptr, addr_len);
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            libc::close(fd);
            bail!("Failed to connect to vsock CID {} port {}: {}", cid, port, err);
        }
        
        Ok(fd)
    }
}

fn sync_directory<S: Read + Write>(stream: &mut S, remote_path: &str, local_path: &PathBuf) -> Result<()> {
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
