//! Configuration handling for runcvm-fused

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Volume mount configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VolumeConfig {
    /// Source path on host
    pub source: String,
    /// Target path in guest
    pub target: String,
    /// Mount options (optional)
    #[serde(default)]
    pub options: String,
}

/// Main configuration
#[derive(Debug)]
pub struct Config {
    /// Port for vsock server
    pub vsock_port: u32,
    /// Volume configurations
    pub volumes: Vec<VolumeConfig>,
}

/// Load volumes from a config file
/// 
/// Format: each line is "source:target:options"
/// (Same format as /.runcvm/volumes)
pub fn load_volumes(path: &Path) -> Result<Vec<VolumeConfig>> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("Failed to read volumes config: {:?}", path))?;
    
    let mut volumes = Vec::new();
    
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        
        let parts: Vec<&str> = line.splitn(3, ':').collect();
        if parts.len() < 2 {
            log::warn!("Invalid volume config line: {}", line);
            continue;
        }
        
        volumes.push(VolumeConfig {
            source: parts[0].to_string(),
            target: parts[1].to_string(),
            options: parts.get(2).unwrap_or(&"").to_string(),
        });
    }
    
    Ok(volumes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;
    
    #[test]
    fn test_load_volumes() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(file, "/host/data:/data:rw").unwrap();
        writeln!(file, "/host/config:/config:ro").unwrap();
        
        let volumes = load_volumes(file.path()).unwrap();
        assert_eq!(volumes.len(), 2);
        assert_eq!(volumes[0].source, "/host/data");
        assert_eq!(volumes[0].target, "/data");
        assert_eq!(volumes[0].options, "rw");
    }
}
