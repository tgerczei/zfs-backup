# zfs-backup
home-brew solution for ZFS snapshot replication and rotation supporting local or remote destination via SSH; ideally used as a daily cron job
tested on Oracle Solaris 1[01] and Joyent's SmartOS

usage: zfs-backup.sh [-h] [-m <e-mail_address>] -f <fully_qualified_configuration_file_name>

A configuration (f)ile must be supplied. An e-(m)ail address for reporting is optional. Please refer to the attached example file 'zfs-backup.cfg' for configuration.
