// Runs when the Enshrouded instance reaches the "stopped" state.
// Takes a snapshot of the data volume (a clean copy, since nothing is writing),
// then prunes older post-shutdown snapshots: anything older than RETENTION_DAYS,
// but always keeping the newest MIN_KEEP regardless of age.
import {
  EC2Client,
  CreateSnapshotCommand,
  DescribeSnapshotsCommand,
  DeleteSnapshotCommand,
} from "@aws-sdk/client-ec2";

const ec2 = new EC2Client({});
const KIND = "post-shutdown";

async function listOurSnapshots(volumeId, project) {
  const found = [];
  let token;
  do {
    const r = await ec2.send(
      new DescribeSnapshotsCommand({
        OwnerIds: ["self"],
        NextToken: token,
        Filters: [
          { Name: "tag:SnapshotKind", Values: [KIND] },
          { Name: "tag:Project", Values: [project] },
          { Name: "volume-id", Values: [volumeId] },
        ],
      }),
    );
    found.push(...(r.Snapshots ?? []));
    token = r.NextToken;
  } while (token);
  return found.sort((a, b) => new Date(b.StartTime) - new Date(a.StartTime)); // newest first
}

export async function handler(event) {
  const volumeId = process.env.VOLUME_ID;
  const project = process.env.PROJECT;
  const retentionDays = Number(process.env.RETENTION_DAYS ?? 14);
  const minKeep = Number(process.env.MIN_KEEP ?? 3);

  const state = event?.detail?.state;
  if (state && state !== "stopped") {
    console.log(JSON.stringify({ skipped: true, state }));
    return;
  }

  const created = await ec2.send(
    new CreateSnapshotCommand({
      VolumeId: volumeId,
      Description: `Post-shutdown ${new Date().toISOString()}`,
      TagSpecifications: [
        {
          ResourceType: "snapshot",
          Tags: [
            { Key: "SnapshotKind", Value: KIND },
            { Key: "Project", Value: project },
            { Key: "Name", Value: `${project}-post-shutdown` },
          ],
        },
      ],
    }),
  );
  console.log(JSON.stringify({ created: created.SnapshotId }));

  const cutoff = Date.now() - retentionDays * 86400 * 1000;
  const snaps = await listOurSnapshots(volumeId, project);
  const doomed = snaps
    .filter((s) => s.SnapshotId !== created.SnapshotId)
    .slice(Math.max(minKeep - 1, 0)) // keep the newest MIN_KEEP overall (the new one counts as one)
    .filter((s) => new Date(s.StartTime).getTime() < cutoff);

  for (const s of doomed) {
    try {
      await ec2.send(new DeleteSnapshotCommand({ SnapshotId: s.SnapshotId }));
      console.log(JSON.stringify({ deleted: s.SnapshotId, started: s.StartTime }));
    } catch (err) {
      console.error("delete failed", s.SnapshotId, err.name);
    }
  }
}
