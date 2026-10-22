# Restoring the world from a snapshot

Snapshots come from two places, both tagged `Project=enshrouded`:
- **Post-shutdown** (`SnapshotKind=post-shutdown`): taken every time the instance stops, kept 14 days (and at least the newest 3).
- **Daily** (DLM): taken 08:00 UTC, kept 7.

Use the admin profile for everything here (`--profile enshrouded-admin`). Replace anything in `<angle brackets>`, and leave the brackets out.

## A. Practice restore (non-destructive; proves a snapshot contains your world)
Nothing on the live volume is touched.

1. List snapshots and pick one (newest last):
   `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Project,Values=enshrouded --query 'sort_by(Snapshots,&StartTime)[].[SnapshotId,StartTime,Description]' --output table --profile enshrouded-admin`
2. Start the server (`/enshrouded start`) and wait for the "up" message. Find its availability zone:
   `aws ec2 describe-instances --instance-ids <instance-id> --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text --profile enshrouded-admin`
3. Make a volume from the snapshot, in that same zone. Note the `VolumeId` it prints (`vol-` plus letters/digits):
   `aws ec2 create-volume --snapshot-id <snapshot-id> --availability-zone <zone> --volume-type gp3 --profile enshrouded-admin`
4. Attach it as a second disk:
   `aws ec2 attach-volume --volume-id <volume-id> --instance-id <instance-id> --device /dev/sdg --profile enshrouded-admin`
5. Open a shell on the server: `aws ssm start-session --target <instance-id> --profile enshrouded-admin`. Then mount it read-only. The device name is the volume ID with the hyphen removed (for `vol-0abc123` it is `vol0abc123`):
   `sudo mkdir -p /mnt/restore && sudo mount -o ro,noload /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume-id-without-hyphen> /mnt/restore`
6. Find the save folder, and check it has recent files:
   `sudo find /mnt/restore -maxdepth 4 -iname '*savegame*'` then `sudo ls -la <that-path>`
7. Clean up: `sudo umount /mnt/restore`, then `exit`, then from your Mac
   `aws ec2 detach-volume --volume-id <volume-id> --profile enshrouded-admin`, wait a minute, then
   `aws ec2 delete-volume --volume-id <volume-id> --profile enshrouded-admin`.

## B. Real restore (replaces the current world)
Do steps 1-6 of the practice restore first, with the snapshot you want. Then, in the shell on the server:

1. Stop the game so nothing writes: `sudo systemctl stop enshrouded`
2. Move the current saves aside rather than deleting them, using the live save path (the same folder name as found in step 6, but under `/mnt/data` instead of `/mnt/restore`):
   `sudo mv <live-save-path> <live-save-path>.before-restore`
3. Copy the old saves in and fix ownership (the game runs as user ID 4711):
   `sudo cp -a <restore-save-path> <live-save-path> && sudo chown -R 4711:4711 <live-save-path>`
4. Start it again: `sudo systemctl start enshrouded`, wait for the "up" message, and join to check the world is right.
5. Clean up the extra volume as in step 7 above. Keep `.before-restore` until you're sure.

## If the whole data volume is lost
Create a volume from the newest snapshot and swap it in for the Terraform-managed one. That involves Terraform state, so ask for a walkthrough rather than improvising.
