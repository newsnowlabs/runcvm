//! runcvm-fused: FUSE passthrough daemon for RunCVM
//!
//! This daemon runs on the host (container) and serves filesystem operations
//! to the Firecracker guest VM. It uses Unix domain sockets to communicate
//! with Firecracker's vsock bridge.
//!
//! Firecracker vsock architecture:
//!   Guest (vsock CID 2, port 5742) -> Firecracker -> UDS /run/firecracker.vsock -> Host
//!
//! The host connects to the UDS when the guest initiates a connection.

use std::fs::{self, File};
use std::io::{Read, Write, BufRead, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::thread;

use anyhow::{Context, Result};
use log::{info, error, debug, warn};

/// Default port for vsock communication
const DEFAULT_VSOCK_PORT: u32 = 5742;

fn main() -> Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    info!("runcvm-fused starting...");

    // Parse command line arguments
    let args: Vec<String> = std::env::args().collect();
    let mut vsock_port = DEFAULT_VSOCK_PORT;
    let mut vsock_uds_path = PathBuf::from("/run/firecracker.vsock");
    let mut volumes_config: Option<PathBuf> = None;
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vsock-port" => {
                i += 1;
                if let Some(port_str) = args.get(i) {
                    vsock_port = port_str.parse().unwrap_or(DEFAULT_VSOCK_PORT);
                }
            }
            "--vsock-uds" => {
                i += 1;
                if let Some(path) = args.get(i) {
                    vsock_uds_path = PathBuf::from(path);
                }
            }
            "--volumes-config" => {
                i += 1;
                if let Some(path) = args.get(i) {
                    volumes_config = Some(PathBuf::from(path));
                }
            }
            "--help" | "-h" => {
                println!("runcvm-fused - FUSE passthrough daemon for RunCVM");
                println!();
                println!("Usage: runcvm-fused [OPTIONS]");
                println!();
                println!("Options:");
                println!("  --vsock-port <PORT>       Port for vsock (default: 5742)");
                println!("  --vsock-uds <PATH>        Firecracker vsock UDS path (default: /run/firecracker.vsock)");
                println!("  --volumes-config <FILE>   Path to volumes configuration file");
                println!("  --help, -h                Show this help message");
                return Ok(());
            }
            _ => {}
        }
        i += 1;
    }

    info!("Configuration:");
    info!("  vsock port: {}", vsock_port);
    info!("  vsock UDS: {:?}", vsock_uds_path);
    if let Some(ref cfg) = volumes_config {
        info!("  volumes config: {:?}", cfg);
    }

    // For Firecracker vsock, we need to listen on the UDS path with port suffix
    // When guest connects to vsock port X, Firecracker creates UDS at: <uds_path>_<port>
    let listen_path = format!("{}_{}", vsock_uds_path.display(), vsock_port);
    
    info!("Listening on Unix socket: {}", listen_path);
    
    // Remove existing socket file if present
    let _ = fs::remove_file(&listen_path);
    
    // Create Unix socket listener
    let listener = UnixListener::bind(&listen_path)
        .with_context(|| format!("Failed to bind Unix socket at {}", listen_path))?;
    
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
            Err(e) => {
                error!("Accept error: {}", e);
            }
        }
    }

    Ok(())
}

fn handle_connection(mut stream: UnixStream) -> Result<()> {
    let mut buf = vec![0u8; 64 * 1024]; // 64KB buffer
    
    loop {
        // Read message type and path length
        let mut header = [0u8; 5];
        if stream.read_exact(&mut header).is_err() {
            debug!("Connection closed");
            break;
        }
        
        let msg_type = header[0];
        let path_len = u32::from_le_bytes([header[1], header[2], header[3], header[4]]) as usize;
        
        // Read path
        if path_len > buf.len() {
            error!("Path too long: {}", path_len);
            continue;
        }
        
        if stream.read_exact(&mut buf[..path_len]).is_err() {
            break;
        }
        
        let path = String::from_utf8_lossy(&buf[..path_len]).to_string();
        debug!("Request: type={}, path={}", msg_type, path);
        
        // Handle request
        let response = match msg_type {
            1 => handle_read_file(&path),
            3 => handle_list_dir(&path),
            4 => handle_stat(&path),
            _ => Err(anyhow::anyhow!("Unknown message type: {}", msg_type)),
        };
        
        // Send response
        match response {
            Ok(data) => {
                let len = (data.len() as u32).to_le_bytes();
                let _ = stream.write_all(&[0]); // Success
                let _ = stream.write_all(&len);
                let _ = stream.write_all(&data);
            }
            Err(e) => {
                let msg = e.to_string();
                let len = (msg.len() as u32).to_le_bytes();
                let _ = stream.write_all(&[255]); // Error
                let _ = stream.write_all(&len);
                let _ = stream.write_all(msg.as_bytes());
            }
        }
    }
    
    Ok(())
}

fn handle_read_file(path: &str) -> Result<Vec<u8>> {
    let data = fs::read(path)?;
    Ok(data)
}

fn handle_list_dir(path: &str) -> Result<Vec<u8>> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        entries.push(name);
    }
    Ok(entries.join("\n").into_bytes())
}

fn handle_stat(path: &str) -> Result<Vec<u8>> {
    let metadata = fs::metadata(path)?;
    let info = format!(
        "size:{}\ntype:{}\n",
        metadata.len(),
        if metadata.is_dir() { "dir" } else { "file" }
    );
    Ok(info.into_bytes())
}
