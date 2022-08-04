#!/usr/bin/bash

# called by dracut
check() {
   [[ $hostonly ]] || [[ $mount_needs ]] && {
       for fs in "${host_fs_types[@]}"; do
           [[ "$fs" == "virtiofs" ]] && return 0
       done
       return 255
   }

   is_qemu_virtualized && return 0

   return 255
}

# called by dracut
depends() {
   return 0
}

# called by dracut
installkernel() {
   instmods virtiofs

    # qemu specific modules
    hostonly='' instmods \
        ata_piix ata_generic pata_acpi cdrom sr_mod ahci \
        virtio_blk virtio virtio_ring virtio_pci \
        virtio_scsi virtio_console virtio_rng virtio_mem \
        virtio_net \
        spapr-vscsi \
        qemu_fw_cfg
}

# called by dracut
install() {
   inst_hook cmdline 95 "$moddir/parse-virtiofs.sh"
   inst_hook pre-mount 99 "$moddir/mount-virtiofs.sh"
}

