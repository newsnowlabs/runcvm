//! runcvm-fused: FUSE passthrough daemon for RunCVM
//!
//! This daemon runs on the host and serves filesystem operations to the guest VM
//! over vsock. It uses fuse-backend-rs for the FUSE protocol implementation.

mod passthrough;
mod transport;
mod config;

use std::sync::Arc;
use std::path::PathBuf;

use anyhow::{Context, Result};
use log::{info, error, debug};

use crate::config::Config;
use crate::passthrough::PassthroughFs;
use crate::transport::VsockServer;

/// Default port for vsock communication
const DEFAULT_VSOCK_PORT: u32 = 5742;

fn main() -> Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();

    info!("runcvm-fused starting...");

    // Parse command line arguments
    let config = parse_args()?;
    
    info!("Configuration:");
    info!("  vsock port: {}", config.vsock_port);
    info!("  volumes: {:?}", config.volumes);

    // Create passthrough filesystem for each volume
    let filesystems: Vec<Arc<PassthroughFs>> = config.volumes
        .iter()
        .map(|vol| {
            info!("Creating passthrough FS for: {} -> {}", vol.source, vol.target);
            Arc::new(PassthroughFs::new(&vol.source, &vol.target))
        })
        .collect();

    // Start vsock server
    info!("Starting vsock server on port {}", config.vsock_port);
    let server = VsockServer::new(config.vsock_port, filesystems)?;
    
    // Run the server (blocks until shutdown)
    server.run()?;

    info!("runcvm-fused shutdown complete");
    Ok(())
}

fn parse_args() -> Result<Config> {
    let args: Vec<String> = std::env::args().collect();
    
    let mut vsock_port = DEFAULT_VSOCK_PORT;
    let mut volumes_config: Option<PathBuf> = None;
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vsock-port" => {
                i += 1;
                vsock_port = args.get(i)
                    .context("Missing vsock port value")?
                    .parse()
                    .context("Invalid vsock port")?;
            }
            "--volumes-config" => {
                i += 1;
                volumes_config = Some(PathBuf::from(
                    args.get(i).context("Missing volumes config path")?
                ));
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
                std::process::exit(0);
            }
            _ => {
                error!("Unknown argument: {}", args[i]);
                std::process::exit(1);
            }
        }
        i += 1;
    }
    
    // Load volumes from config file
    let volumes = if let Some(config_path) = volumes_config {
        config::load_volumes(&config_path)?
    } else {
        // Default: no volumes (for testing)
        debug!("No volumes config specified, using empty list");
        Vec::new()
    };
    
    Ok(Config {
        vsock_port,
        volumes,
    })
}
