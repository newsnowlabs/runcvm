//! Passthrough filesystem implementation using fuse-backend-rs
//!
//! This module wraps fuse-backend-rs's passthrough driver to serve
//! host directories to the guest VM.

use std::ffi::CStr;
use std::io::{Read, Write};
use std::os::unix::io::RawFd;
use std::path::Path;
use std::sync::Arc;

use fuse_backend_rs::api::filesystem::{
    Context, DirEntry, Entry, FileSystem, FsOptions, GetxattrReply,
    ListxattrReply, OpenOptions, SetattrValid, ZeroCopyReader, ZeroCopyWriter,
};
use fuse_backend_rs::passthrough::{Config as PassthroughConfig, PassthroughFs as FusePassthrough};
use fuse_backend_rs::transport::FuseChannel;

use log::{debug, info, error};

/// Passthrough filesystem wrapper
pub struct PassthroughFs {
    /// Source path on host
    source: String,
    /// Target path in guest  
    target: String,
    /// Inner fuse-backend-rs passthrough
    inner: FusePassthrough,
}

impl PassthroughFs {
    /// Create a new passthrough filesystem
    pub fn new(source: &str, target: &str) -> Self {
        info!("Creating PassthroughFs: {} -> {}", source, target);
        
        let config = PassthroughConfig {
            root_dir: source.to_string(),
            // Enable various features for better compatibility
            do_import: true,
            writeback: true,
            no_open: false,
            no_opendir: false,
            killpriv_v2: false,
            no_readdir: false,
            xattr: true,
            ..Default::default()
        };
        
        let inner = FusePassthrough::new(config).expect("Failed to create passthrough FS");
        
        Self {
            source: source.to_string(),
            target: target.to_string(),
            inner,
        }
    }
    
    /// Get the source path
    pub fn source(&self) -> &str {
        &self.source
    }
    
    /// Get the target path
    pub fn target(&self) -> &str {
        &self.target
    }
    
    /// Get the inner passthrough filesystem
    pub fn inner(&self) -> &FusePassthrough {
        &self.inner
    }
}

/// Message types for FUSE protocol over vsock
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FuseOpcode {
    Lookup = 1,
    Forget = 2,
    Getattr = 3,
    Setattr = 4,
    Readlink = 5,
    Symlink = 6,
    Mknod = 8,
    Mkdir = 9,
    Unlink = 10,
    Rmdir = 11,
    Rename = 12,
    Link = 13,
    Open = 14,
    Read = 15,
    Write = 16,
    Statfs = 17,
    Release = 18,
    Fsync = 20,
    Setxattr = 21,
    Getxattr = 22,
    Listxattr = 23,
    Removexattr = 24,
    Flush = 25,
    Init = 26,
    Opendir = 27,
    Readdir = 28,
    Releasedir = 29,
    Fsyncdir = 30,
    Getlk = 31,
    Setlk = 32,
    Setlkw = 33,
    Access = 34,
    Create = 35,
    Interrupt = 36,
    Bmap = 37,
    Destroy = 38,
    Ioctl = 39,
    Poll = 40,
    NotifyReply = 41,
    BatchForget = 42,
    Fallocate = 43,
    Readdirplus = 44,
    Rename2 = 45,
    Lseek = 46,
    CopyFileRange = 47,
    SetupMapping = 48,
    RemoveMapping = 49,
}
