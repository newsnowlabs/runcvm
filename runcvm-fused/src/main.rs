//! runcvm-fused: FUSE passthrough daemon for RunCVM
//!
//! This daemon runs on the host and serves filesystem operations to the guest VM
//! over vsock. It provides a simple file passthrough service.

use std::fs::{self, File};
use std::io::{Read, Write, BufReader, BufRead};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use log::{info, error, debug, warn};
use vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

/// Default port for vsock communication
const DEFAULT_VSOCK_PORT: u32 = 5742;

/// Message types
#[repr(u8)]
#[derive(Debug, Clone, Copy)]
enum MsgType {
    ReadFile = 1,
    WriteFile = 2,
    ListDir = 3,
    Stat = 4,
    Mkdir = 5,
    Remove = 6,
    Error = 255,
}

fn main() -> Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    info!("runcvm-fused starting...");

    // Parse command line arguments
    let args: Vec<String> = std::env::args().collect();
    let mut vsock_port = DEFAULT_VSOCK_PORT;
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
                println!("  --vsock-port <PORT>       Port for vsock server (default: 5742)");
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
    if let Some(ref cfg) = volumes_config {
        info!("  volumes config: {:?}", cfg);
    }

    // Start vsock server
    run_server(vsock_port)?;

    Ok(())
}

fn run_server(port: u32) -> Result<()> {
    let addr = VsockAddr::new(VMADDR_CID_ANY, port);
    let listener = VsockListener::bind(&addr)
        .with_context(|| format!("Failed to bind vsock on port {}", port))?;
    
    info!("vsock server listening on port {}", port);

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                info!("New connection from guest");
                
                // Handle connection in a simple request-response loop
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
            }
            Err(e) => {
                error!("Accept error: {}", e);
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
