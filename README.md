# nim-libp2p-network-lab

Small, container-ready Nim nodes used to exercise `nim-libp2p` networks.

## Run the workflow manually

You need GitHub access that allows you to run Actions in this repository. The
repository must have a `TENKSIM_TOKEN` Actions secret with **Actions: write** access
to `iftech/10ksim` so it can dispatch the experiment and read its results. Execution
uses the existing 10ksim infrastructure; no local Nim or Docker setup is needed.

1. Open [Run experiments](https://github.com/iftech/nim-libp2p-network-lab/actions/workflows/run-experiments.yml)
   in GitHub Actions and click **Run workflow**.
2. Select the branch containing the workflow and experiment configuration to use.
3. Choose **Build and publish node images before running the experiment**:
   - **yes** (default): build images from the selected lab revision using the chosen
     `iftech/nim-libp2p` commit, publish them to GHCR, and run with images
     tagged for that lab revision.
   - **no**: reuse the published `main` images referenced by the experiment config.
     Changes to node code on the selected branch will require a build to take effect.
4. Optionally enter a full commit SHA in **nim-libp2p commit**. Leave it empty to
   use the latest commit from `iftech/nim-libp2p` `master`. This input is ignored
   when image building is disabled.
5. Click **Run workflow** to start the run.

## Automatic execution

The workflow is scheduled daily at **06:00 UTC**, using this repository's default
branch. Scheduled runs always build fresh node images against the latest
`iftech/nim-libp2p` `master` commit before dispatching the same GossipSub regression
experiment. All node images in a build use the same resolved `nim-libp2p` commit.

For both manual and scheduled runs, the workflow waits for the 10ksim run to finish
and checks its conclusion and any reported node problems. If the image build fails,
the experiment is not dispatched.

## Results

An unsuccessful experiment, or a failure to analyze a dispatched experiment, opens
an issue in this repository with available diagnostics and links to the 10ksim run
and logs. Successful experiments do not create an issue; inspect the Actions run
for confirmation. Build or dispatch failures are visible in the Actions logs and
do not automatically create an experiment issue.


## GossipSub regression workflow

The [Run experiments workflow](.github/workflows/run-experiments.yml) checks that
`nim-libp2p` peers can discover each other, form a GossipSub mesh, and deliver
messages across a network. It runs the
[GossipSub regression experiment](experiments/gossipsub-regression.yaml) through
the `run-nodes.yml` workflow in [iftech/10ksim](https://github.com/iftech/10ksim),
which deploys the nodes and collects their results.

The current experiment uses:

- **500 nodes over TCP:** one bootstrap node coordinates 499 GossipSub participants.
- **Coordinated phases:** participants register with the bootstrap, discover peers
  through Kad-DHT, and wait for stable GossipSub meshes before publishing begins.
- **Delivery checks:** each participant publishes three messages and must receive
  at least 99% of the expected messages from other participants. Nodes also check
  message validity and self-delivery, then exit successfully only after all
  participants have verified delivery.
- **Bounded execution:** startup has a 10-minute timeout, followed by a 20-minute
  experiment window. Node self-checks have their own timeout so stalled phases
  are reported as failures.
