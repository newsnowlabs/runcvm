//! runcvm-fuse-client: FUSE client for RunCVM guest VM
//!
//! This client runs inside the guest VM and mounts host directories
//! via FUSE over vsock. It forwards FUSE kernel requests to the host
//! daemon (runcvm-fused) for processing.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Parser;
use log::{debug, error, info, warn};
use nix::mount::{mount, MsFlags};
use nix::sys::stat::Mode;
use vsock::{VsockAddr, VsockStream};

/// FUSE client for RunCVM guest VM
#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Host CID (usually 2 for hypervisor/host)
    #[arg(long, default_value = "2")]
    host_cid: u32,
    
    /// Port to connect to on host
    #[arg(long, default_value = "5742")]
    port: u32,
    
    /// Mount point in guest
    #[arg(long)]
    mount: PathBuf,
    
    /// Source path on host
    #[arg(long)]
    source: String,
    
    /// Allow other users to access the mount
    #[arg(long, default_value = "true")]
    allow_other: bool,
}

/// FUSE device path
const FUSE_DEV: &str = "/dev/fuse";

/// FUSE in header (from kernel)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct FuseInHeader {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
}

/// FUSE out header (to kernel)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct FuseOutHeader {
    len: u32,
    error: i32,
    unique: u64,
}

fn main() -> Result<()> {
    // Initialize logging
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info")
    ).init();
    
    let args = Args::parse();
    
    info!("runcvm-fuse-client starting...");
    info!("  Host CID: {}", args.host_cid);
    info!("  Port: {}", args.port);
    info!("  Mount: {:?}", args.mount);
    info!("  Source: {}", args.source);
    
    // Connect to host daemon via vsock
    let host_addr = VsockAddr::new(args.host_cid, args.port);
    info!("Connecting to host at {:?}", host_addr);
    
    let mut stream = VsockStream::connect(&host_addr)
        .with_context(|| format!("Failed to connect to host CID {} port {}", 
                                  args.host_cid, args.port))?;
    
    info!("Connected to host daemon");
    
    // Open FUSE device
    let fuse_fd = open_fuse_device()?;
    info!("Opened FUSE device, fd={}", fuse_fd);
    
    // Mount FUSE filesystem
    mount_fuse(&args.mount, fuse_fd, args.allow_other)?;
    info!("Mounted FUSE at {:?}", args.mount);
    
    // Main loop: forward messages between kernel and host
    run_fuse_loop(fuse_fd, &mut stream)?;
    
    Ok(())
}

/// Open the FUSE device
fn open_fuse_device() -> Result<RawFd> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(FUSE_DEV)
        .context("Failed to open /dev/fuse")?;
    
    Ok(file.into_raw_fd())
}

/// Mount FUSE filesystem
fn mount_fuse(mountpoint: &PathBuf, fd: RawFd, allow_other: bool) -> Result<()> {
    // Create mount point if it doesn't exist
    std::fs::create_dir_all(mountpoint)
        .context("Failed to create mount point")?;
    
    // Build mount options
    let mut opts = format!("fd={},rootmode=40000,user_id=0,group_id=0", fd);
    if allow_other {
        opts.push_str(",allow_other");
    }
    
    // Mount the FUSE filesystem
    mount(
        Some("runcvm-fuse"),
        mountpoint,
        Some("fuse"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        Some(opts.as_str()),
    ).context("Failed to mount FUSE filesystem")?;
    
    Ok(())
}

/// Run the FUSE message forwarding loop
fn run_fuse_loop(fuse_fd: RawFd, stream: &mut VsockStream) -> Result<()> {
    let mut fuse_file = unsafe { File::from_raw_fd(fuse_fd) };
    let mut buffer = vec![0u8; 1024 * 1024]; // 1MB buffer
    
    info!("Starting FUSE message loop");
    
    loop {
        // Read request from kernel (FUSE device)
        let n = match fuse_file.read(&mut buffer) {
            Ok(0) => {
                info!("FUSE device closed");
                break;
            }
            Ok(n) => n,
            Err(e) if e.raw_os_error() == Some(libc::ENODEV) => {
                info!("FUSE filesystem unmounted");
                break;
            }
            Err(e) => {
                error!("Error reading from FUSE: {}", e);
                continue;
            }
        };
        
        // Parse header for logging
        if n >= std::mem::size_of::<FuseInHeader>() {
            let header: FuseInHeader = unsafe {
                std::ptr::read(buffer.as_ptr() as *const FuseInHeader)
            };
            debug!("FUSE request: opcode={}, len={}, nodeid={}", 
                   header.opcode, header.len, header.nodeid);
        }
        
        // Forward to host daemon
        stream.write_all(&buffer[..n])
            .context("Failed to send to host")?;
        
        // Read response from host
        let header_size = std::mem::size_of::<FuseOutHeader>();
        stream.read_exact(&mut buffer[..header_size])
            .context("Failed to read response header")?;
        
        // Parse response header to get full length
        let out_header: FuseOutHeader = unsafe {
            std::ptr::read(buffer.as_ptr() as *const FuseOutHeader)
        };
        
        // Read rest of response if needed
        let remaining = out_header.len as usize - header_size;
        if remaining > 0 {
            stream.read_exact(&mut buffer[header_size..out_header.len as usize])
                .context("Failed to read response body")?;
        }
        
        debug!("FUSE response: len={}, error={}", out_header.len, out_header.error);
        
        // Write response to kernel
        fuse_file.write_all(&buffer[..out_header.len as usize])
            .context("Failed to write to FUSE")?;
    }
    
    Ok(())
}
