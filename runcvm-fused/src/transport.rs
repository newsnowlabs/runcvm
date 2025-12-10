//! vsock transport layer for FUSE messages
//!
//! Handles communication between host (CID 2) and guest (CID 3) over vsock.

use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::Arc;
use std::thread;

use anyhow::{Context, Result};
use log::{debug, error, info, warn};
use vsock::{VsockAddr, VsockListener, VsockStream, VMADDR_CID_ANY, VMADDR_CID_HOST};

use fuse_backend_rs::api::server::Server;
use fuse_backend_rs::transport::{FuseChannel, Reader, Writer};

use crate::passthrough::PassthroughFs;

/// FUSE message header (matches kernel's fuse_in_header)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseInHeader {
    pub len: u32,
    pub opcode: u32,
    pub unique: u64,
    pub nodeid: u64,
    pub uid: u32,
    pub gid: u32,
    pub pid: u32,
    pub padding: u32,
}

/// FUSE output header
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseOutHeader {
    pub len: u32,
    pub error: i32,
    pub unique: u64,
}

/// vsock server for FUSE operations
pub struct VsockServer {
    port: u32,
    filesystems: Vec<Arc<PassthroughFs>>,
}

impl VsockServer {
    /// Create a new vsock server
    pub fn new(port: u32, filesystems: Vec<Arc<PassthroughFs>>) -> Result<Self> {
        Ok(Self { port, filesystems })
    }
    
    /// Run the vsock server (blocking)
    pub fn run(&self) -> Result<()> {
        // Listen on vsock
        // CID_ANY means we accept connections from any CID (the guest)
        let addr = VsockAddr::new(VMADDR_CID_ANY, self.port);
        let listener = VsockListener::bind(&addr)
            .with_context(|| format!("Failed to bind vsock on port {}", self.port))?;
        
        info!("vsock server listening on port {}", self.port);
        
        // Accept connections
        loop {
            match listener.accept() {
                Ok((stream, peer_addr)) => {
                    info!("New connection from CID {} port {}", 
                          peer_addr.cid(), peer_addr.port());
                    
                    let filesystems = self.filesystems.clone();
                    
                    // Handle connection in a new thread
                    thread::spawn(move || {
                        if let Err(e) = handle_connection(stream, filesystems) {
                            error!("Connection handler error: {}", e);
                        }
                    });
                }
                Err(e) => {
                    error!("Accept error: {}", e);
                }
            }
        }
    }
}

/// Handle a single vsock connection
fn handle_connection(mut stream: VsockStream, filesystems: Vec<Arc<PassthroughFs>>) -> Result<()> {
    info!("Handling FUSE connection");
    
    // Read-write loop for FUSE messages
    let mut buffer = vec![0u8; 1024 * 1024]; // 1MB buffer for large reads/writes
    
    loop {
        // Read FUSE message header
        let header_size = std::mem::size_of::<FuseInHeader>();
        if stream.read_exact(&mut buffer[..header_size]).is_err() {
            info!("Connection closed");
            break;
        }
        
        // Parse header
        let header: FuseInHeader = unsafe {
            std::ptr::read(buffer.as_ptr() as *const FuseInHeader)
        };
        
        debug!("FUSE request: opcode={}, len={}, nodeid={}", 
               header.opcode, header.len, header.nodeid);
        
        // Read rest of message if needed
        let body_len = header.len as usize - header_size;
        if body_len > 0 {
            stream.read_exact(&mut buffer[header_size..header.len as usize])?;
        }
        
        // Process the FUSE operation
        // For now, use first filesystem (TODO: route based on path)
        if let Some(fs) = filesystems.first() {
            // Forward to fuse-backend-rs for handling
            let response = process_fuse_request(&header, &buffer[..header.len as usize], fs)?;
            
            // Send response
            stream.write_all(&response)?;
        } else {
            // No filesystem configured, send error
            let err_response = create_error_response(header.unique, -libc::ENOENT);
            stream.write_all(&err_response)?;
        }
    }
    
    Ok(())
}

/// Process a FUSE request using fuse-backend-rs
fn process_fuse_request(
    header: &FuseInHeader, 
    request: &[u8], 
    fs: &PassthroughFs
) -> Result<Vec<u8>> {
    // This is a simplified implementation
    // Full implementation would use fuse-backend-rs Server with custom Reader/Writer
    
    // For now, return a placeholder error (ENOSYS = function not implemented)
    // This will be replaced with proper passthrough handling
    debug!("Processing opcode {}", header.opcode);
    
    Ok(create_error_response(header.unique, -libc::ENOSYS))
}

/// Create an error response
fn create_error_response(unique: u64, error: i32) -> Vec<u8> {
    let header = FuseOutHeader {
        len: std::mem::size_of::<FuseOutHeader>() as u32,
        error,
        unique,
    };
    
    let bytes = unsafe {
        std::slice::from_raw_parts(
            &header as *const FuseOutHeader as *const u8,
            std::mem::size_of::<FuseOutHeader>(),
        )
    };
    
    bytes.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_header_size() {
        assert_eq!(std::mem::size_of::<FuseInHeader>(), 40);
        assert_eq!(std::mem::size_of::<FuseOutHeader>(), 16);
    }
}
