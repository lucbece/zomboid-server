# Cloud hosting research for a Project Zomboid Build 42 dedicated server (8–16 players)

Research date: **2026-09-03**. All prices are USD/month unless noted, and are what public pricing pages / aggregators showed on the date cited next to each figure. Cloud list prices change often (Hetzner changed prices twice in 2026) — **re-check before committing to a 12-month plan.**

Target specs: Linux x86_64, ~40–80 GB SSD, tier A = 4 vCPU / 8 GB RAM, tier B = 4–8 vCPU / 16 GB RAM. Players assumed mostly in Buenos Aires / Argentina.

---

## 0. The one number that should drive the whole decision: latency

Source: [WonderNetwork ping matrix for Buenos Aires](https://wondernetwork.com/pings/Buenos%20Aires) (accessed 2026-09-03, rolling averages, so treat as indicative not exact):

| From Buenos Aires to | Round-trip ping |
|---|---|
| São Paulo | **30.4 ms** |
| Miami | 134.4 ms |
| New York | 140.2 ms |
| Washington DC (≈ Ashburn) | 140.4 ms |
| Dallas | 151.4 ms |
| Frankfurt | 228.0 ms |
| Nuremberg | 229.5 ms |
| Falkenstein | 230.4 ms |

**This is the single biggest factor in this research.** A São Paulo-region VM gives Buenos Aires players ~30 ms — as good as a well-connected regional LAN party. US East gives ~140 ms. Germany gives ~228 ms. I could not find a directly-measured Buenos Aires→Ashburn number (only Washington DC, which is in the same metro/peering region and a reasonable proxy); treat the 140 ms figure as an estimate, not a lab measurement.

### Is 140–230 ms playable for Project Zomboid?
Community reports (Steam Community discussion threads, searched 2026-09-03) are mixed and mostly anecdotal:
- Players on servers with ~200 ms ping report zombies "teleporting"/disappearing and desync during combat.
- Some servers explicitly raise their configured ping-kick limit to 400 ms, implying plenty of people play well above 150 ms without being auto-disconnected, but not that it feels *good*.
- No rigorous "X ms = unplayable" community benchmark was found. PZ's netcode is server-authoritative for zombies/world state, so higher ping mainly hurts combat responsiveness and occasionally causes visible zombie glitches, rather than causing full desync of the world.
- **My read (moderate confidence, not a hard citation):** 140 ms (US East) is commonly considered "fine but noticeably laggy in melee" for PZ; 228 ms (Germany) is where more players start to complain. 30 ms (São Paulo) removes the question entirely.

Sources: [Steam Community thread on high ping after dedicated server setup](https://steamcommunity.com/app/108600/discussions/0/595157852293937851/), general PZ discussion threads surfaced by search — flagged as anecdotal, not a controlled benchmark.

---

## 1. Providers with a South America region

### AWS (sa-east-1, São Paulo)
- On-demand base reference (us-east-1, 2026-09-03, [economize.cloud](https://www.economize.cloud/resources/aws/pricing/ec2/t3.xlarge/) / [instances.vantage.sh](https://instances.vantage.sh/aws/ec2/t3.xlarge)): t3.large (2 vCPU/8GB) $60.74/mo, t3.xlarge (4 vCPU/16GB) $121.47/mo, t3a.xlarge $109.79/mo.
- **sa-east-1 carries a real premium.** A 2011 comparison found EC2/S3 ~36% pricier in São Paulo ([Hacker News/AWS historic post](https://news.ycombinator.com/item?id=3355098)); a more recent secondary source states an m5.large instance in São Paulo costs **59% more** than us-east-1 ([concurrencylabs.com](https://www.concurrencylabs.com/blog/choose-your-aws-region-wisely/) — undated blog, treat the exact % as uncertain but directionally confirmed).
- One hard, region-specific data point I could confirm: **m5.xlarge (4 vCPU/16GB) in sa-east-1 on-demand = $0.306/hr ≈ $223/mo** ([DoiT Compute pricing page](https://www.doit.com/compute/compute/aws/sa-east-1/m5.xlarge), accessed 2026-09-03).
- Spot: m5.xlarge in sa-east-1 has shown spot prices as low as $0.0306/hr (a ~90% discount), but that's a best-case/minimum, not a stable expectation — Spot capacity for a "keep it running most of the day" game server is risky (can be reclaimed).
- **Estimate for the two target tiers in sa-east-1 (uncertain, extrapolated from the 59% premium since I could not get a live quote for the exact SKUs):** ~4 vCPU/8GB (e.g., c5.xlarge-class) ≈ **$115–140/mo**; ~4 vCPU/16GB (m5.xlarge, confirmed) **$223/mo** on-demand.
- Egress: AWS data-transfer-out is billed per GB beyond a small free tier, and sa-east-1 rates are among AWS's highest tiers; for a small friends server (a few GB/month) this is immaterial, but flag it if you ever add automated backups to S3 in another region.
- AWS EC2 stopped-instance billing: **compute stops billing immediately when stopped**, but attached EBS volumes keep billing at normal per-GB rates, and an Elastic IP costs **$0.005/hr (~$3.6/mo)** the moment it isn't attached to a *running* instance ([AWS docs/re:Post, 2024 pricing change confirmed by search](https://repost.aws/questions/QUhAqGIGcfTS6TI65w9hmM7g/elasticip-attached-to-a-running-instance-is-charged)). This makes AWS one of the few providers where "stop, don't destroy" is a genuinely cheap idle state (just disk cost, no CPU/RAM cost).

### GCP (southamerica-east1, São Paulo)
- Base reference (us-central1, 2026-09-03, [economize.cloud](https://www.economize.cloud/resources/gcp/pricing/compute-engine/e2-standard-4/)): e2-standard-4 (4 vCPU/16GB) $97.84/mo.
- A generic pricing-comparison tool cited South America (São Paulo) as **~1.6x** us-central1 — this is a rough multiplier from an AI-generated summary, **not a verified GCP list price**, so treat the resulting ≈$157/mo estimate for e2-standard-4 in southamerica-east1 as low-confidence.
- GCP lets you build **custom machine types**, so an exact 4 vCPU/8 GB shape is available directly (rather than picking an oversized preset) — worth using to hit the RAM target without paying for unused RAM.
- Preemptible/Spot VMs: **60–91% discount** vs on-demand generally ([multiple cost-optimization blogs, 2026](https://cloud.google.com/solutions/spot-vms)), but Spot VMs can be pre-empted with 30 seconds' notice — bad for a "leave it running for a play session" game server unless you have a restart-on-preemption watchdog and don't mind occasional drops.
- Billing on stop: **no compute charge**, but the persistent disk keeps billing (~$0.04/GB-month for standard PD; SSD PD roughly triples that) ([GCP docs / community answers](https://docs.cloud.google.com/compute/docs/instances/suspend-stop-reset-instances-overview)). Since 2024, GCP also charges for **all external IPv4 addresses**, not just idle ones: $0.005/hr while in use, $0.01/hr (~$7.30/mo) once unused/unattached ([DoiT blog, "No More Free External IPs on Google Cloud"](https://www.doit.com/blog/no-more-free-external-ips-on-google-cloud-how-much-will-it-cost-you)).

### Azure (Brazil South)
- Global list starting price for D4s v5 (4 vCPU/16GB): **$140.16/mo** ([Vantage](https://instances.vantage.sh/azure/vm/d4s-v5), 2026). I could **not** get a confirmed Brazil South-specific number — pricing pages I fetched were paywalled/JS-rendered. Azure documentation and community notes generally say Brazil South is priced **above** the US/EU baseline, similar in spirit to AWS's sa-east-1 premium. **Flag as uncertain — verify with Azure's own pricing calculator before deciding.**
- No reliable data found on Azure spot-VM discount specifically for Brazil South.

### Oracle Cloud Infrastructure (Vinhedo/São Paulo)
- OCI's compute pricing is explicitly **the same list price in every commercial region**, including Vinhedo ([Oracle Cloud pricing summary via search](https://www.oracle.com/cloud/price-list/)): **$0.0255/OCPU-hour + $0.0015/GB-hour** for standard x86 Flex shapes (2026 list price).
- That means, unlike AWS/GCP/Azure, **there is no South America premium** on OCI pay-as-you-go compute. Computed monthly costs (730 hrs) for flexible shapes:
  - 4 OCPU / 8 GB: (4×0.0255 + 8×0.0015) × 730 ≈ **$83/mo**
  - 4 OCPU / 16 GB: (4×0.0255 + 16×0.0015) × 730 ≈ **$92/mo**
  - 6 OCPU / 16 GB: (6×0.0255 + 16×0.0015) × 730 ≈ **$129/mo**
- These are *my calculations* from the quoted per-OCPU/per-GB rates, not a screenshotted invoice — sanity-check on Oracle's own cost estimator before buying.
- Oracle opened its second Brazilian region in **Vinhedo in May 2021** ([Oracle press release](https://www.oracle.com/news/announcement/oracle-opens-second-brazilian-cloud-region-2021-05-12/)), so it's a mature region, not a brand-new one.
- **On-demand OCI x86 in Vinhedo comes out as the cheapest of the four hyperscalers for both target tiers**, because it has no regional premium and its flex-shape pricing is inherently granular (pay only for the exact vCPU/RAM you pick).

### Vultr (São Paulo)
- Vultr has a confirmed São Paulo region ([datacenters.com listing](https://www.datacenters.com/vultr-sao-paulo)), but I could not get region-specific pricing (vultr.com blocked automated fetches with a 403, and search results only surfaced flat "starting from" global prices, which Vultr does **not** guarantee are region-uniform).
- Reference global prices (2026, various aggregators): High Frequency 4 vCPU/8GB ≈ **$48/mo**; by extrapolation 8 vCPU/16GB ≈ **$96/mo**. **These are the un-verified global list prices — Vultr is known to charge more for some regions (typically premium/Tokyo-class markups apply to certain locations); confirm the São Paulo multiplier on vultr.com/pricing directly before buying.**

### Linode / Akamai Cloud (São Paulo) — the one region I got a full confirmed table for
Source: [Akamai Cloud São Paulo pricing page](https://www.akamai.com/cloud/pricing/sao-paulo/) (fetched 2026-09-03):

| Plan | vCPU | RAM | Storage | Transfer | Monthly | Hourly |
|---|---|---|---|---|---|---|
| Shared "Linode 8 GB" | 4 | 8 GB | 160 GB | 5 TB | **$67.20** | $0.101 |
| Shared "Linode 16 GB" | 6 | 16 GB | 320 GB | 8 TB | **$134.40** | $0.202 |
| Dedicated G6 8 GB | 4 | 8 GB | 160 GB | 5 TB | $100.80 | $0.151 |
| Dedicated G6 16 GB | 8 | 16 GB | 320 GB | 6 TB | $201.60 | $0.302 |
| Dedicated G7 8 GB | 4 | 8 GB | 160 GB | 5 TB | $120.96 | $0.181 |
| Dedicated G7 16 GB | 8 | 16 GB | 320 GB | 6 TB | $241.92 | $0.363 |
| Dedicated G8 8x4 | 4 | 8 GB | 80 GB | 0 TB (pay-as-you-go egress) | $144.00 | $0.20 |
| Dedicated G8 16x8 | 8 | 16 GB | 160 GB | 0 TB | $273.60 | $0.38 |

Egress overage (beyond the plan's transfer pool): **$0.007/GB** — a game server for 8–16 friends will not come close to the transfer pool, so egress is a non-issue here.

The **shared "Linode 8 GB" ($67.20/mo)** and **"Linode 16 GB" ($134.40/mo)** plans are the directly relevant, actually-confirmed South America prices for this use case — Linode doesn't need dedicated CPU for a PZ server for 8-16 players.

### Hostinger (São Paulo)
Source: search aggregation of Hostinger's own VPS pages (2026-09-03): KVM 2 (2 vCPU/8GB, 100GB NVMe) **$6.99/mo**, KVM 4 (4 vCPU/16GB, 200GB NVMe) **$9.99/mo**, KVM 8 (8 vCPU/32GB) $19.99/mo. These are exceptionally cheap for a São Paulo/Brazil-hosted VPS.
**Caveats (uncertain, could not verify directly on hostinger.com):** these headline prices are typically tied to long commitment terms (search noted "48-month commitment, renews at $9.99/mo" for the entry plan) — i.e. the advertised price is often a multi-year prepaid rate, and Hostinger's KVM 2 has only 2 vCPU (not 4) for its 8GB tier. If genuine and month-to-month pricing is close to these numbers, Hostinger is by far the cheapest confirmed São Paulo option — but this needs to be verified live on hostinger.com since budget VPS resellers often advertise promo/multi-year pricing as if it were the standard rate.

### Latitude.sh (São Paulo, bare metal)
Has real São Paulo bare-metal facilities, but pricing pages returned only GPU-server pricing in search (no small general-purpose VM/bare-metal monthly price surfaced). Likely more expensive and more oriented at GPU/AI workloads than a small friends' game server — not a strong fit; skip unless you specifically want bare metal.

---

## 2. Cheap EU/US providers without a South America region (for comparison)

### Hetzner Cloud — **prices increased sharply in 2026**, factor this in
Sources: [Hetzner's own price-adjustment docs](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/), [Northflank blog breakdown](https://northflank.com/blog/hetzner-cloud-server-price-increases), [webhosting.today breakdown](https://webhosting.today/2026/06/18/hetzners-price-increases-reached-209-the-30-headline-applied-to-a-different-tier/) (all accessed 2026-09-03).

There were **two 2026 price rounds**: April 1 (modest, ~20-38% on shared/entry tiers) and **June 15 (steep, 107%-204% on CPX/CCX tiers)**. Post-June-15 2026 prices:

| Plan (US region, Ashburn/Hillsboro) | Old price | New price (since 2026-06-15) |
|---|---|---|
| CPX21 (shared, ~3vCPU/4GB) | $13.99 | **$37.49** |
| CPX31 (shared, 4vCPU/8GB) | $24.99 | **$73.49** |
| CPX41 (shared, 8vCPU/16GB) | $46.49 | **$141.49** |

| Plan (EU: Germany/Finland) | Old | New |
|---|---|---|
| CCX13 (dedicated, 2vCPU/8GB) | €15.99 | **€42.99** |
| CCX23 (dedicated, 4vCPU/16GB) | €31.49 | **€85.99** |
| CCX33 (dedicated, 8vCPU/32GB) | €62.49 | **€138.49** |

| Plan (US: dedicated CCX) | Old | New |
|---|---|---|
| CCX13 | $19.99 | **$50.99** |
| CCX23 | $39.99 | **$102.99** |

**This changes the calculus significantly vs. Hetzner's old reputation as the cheapest option.** A CPX31 (4 vCPU/8GB) in the US is now **$73.49/mo** — no longer meaningfully cheaper than AWS/GCP on-demand, and pricier than Linode's equivalent São Paulo shared plan ($67.20/mo) which also gives Buenos Aires players ~30ms instead of ~140-230ms. Germany/Finland CCX23 (4vCPU/16GB, dedicated) at €85.99 (~$93) is still reasonably competitive against Oracle's $92 on-demand estimate, but Germany carries the worst latency of the options surveyed (~228ms).
- **Billing while stopped: Hetzner charges for a Cloud Server as long as the server object exists, even powered off** — you must delete it to stop billing, unlike AWS/GCP where "stop" itself halts compute charges ([multiple sources incl. CloudTally, LowEndTalk threads](https://cloudtally.eu/blog/why-hetzner-charges-for-stopped-servers)). This makes Hetzner a poor fit for a simple "stop when idle" pattern — the snapshot-and-destroy pattern (below) is the only real cost-saver there.
- Floating IPv4: **€3.00/mo** ([search aggregation of Hetzner docs](https://docs.hetzner.com/general/infrastructure-and-availability/ipv4-pricing/)) if you want a stable public IP independent of the server.
- Hetzner also sells **CAX (Ampere ARM) shared-vCPU instances**, which saw a smaller 1.3-1.4x increase — cheaper than CPX, but the same "PZ doesn't run natively on ARM" problem applies (see §3).
- **Hetzner dedicated server auction / Kimsufi / OVH Eco**: entry dedicated hardware from **~$11–35/mo** ([Kimsufi/OVH Eco pages, klymentiev.com summary](https://klymentiev.com/blog/cheap-dedicated-server-2026)), but these are older/surplus hardware with no SLA on which specific CPU you get, HDD by default (NVMe is a $5-15/mo add-on), and typically only in EU/North America data centers — same ~140-230ms latency problem as Hetzner Cloud, plus more operational risk (real hardware failures, no live migration).

### Contabo
- **Cloud VPS 4**: 4 vCPU / 8 GB / 100GB SSD = **€5.50/mo** (first 24 months promo price) — extremely cheap.
- No plan hits exactly 16GB at 4-8vCPU: **Cloud VPS 6** = 6vCPU/12GB/€7.50, **Cloud VPS 8** = 8vCPU/24GB/€14.00 (closest match, oversized on RAM but still cheap) ([Contabo pricing page, fetched 2026-09-03](https://www.contabo.com/en/vps/)).
- Contabo has **no South America region** in its ~9-11 global locations from the fetched page — closest would be US or EU, same latency profile as Hetzner/DO.
- Known industry reputation (not directly verified here) for oversold/variable CPU performance at these prices — worth a mention if reliability for a game server matters.

### Netcup
- **VPS 1000 G12**: 4 vCore / 8GB DDR5 ECC / 256GB NVMe ≈ **€10.37/mo incl. German VAT**.
- **VPS 2000 G12**: 8 vCPU / 16GB / 512GB NVMe ≈ **€14.33/mo**.
(Source: search aggregation of netcup's pricing pages, 2026-09-03.) Excellent value, but German-only data centers → ~228ms from Buenos Aires.

### DigitalOcean
- Basic Droplet 4vCPU/8GB: **$48/mo** (160GB SSD, 5TB transfer); 8vCPU/16GB: **$96/mo** (320GB SSD, 6TB transfer) ([digitalocean.com/pricing/droplets](https://www.digitalocean.com/pricing/droplets), 2026-09-03). No South America region. Billing-while-stopped behavior for DO is generally the same "charged until destroyed" model as Hetzner (not independently re-verified in this pass, flagging as based on general DO knowledge rather than a freshly fetched source).

### OVH / Kimsufi
- Covered above with Hetzner auction — cheap dedicated hardware (~$11-35/mo) but EU/North America only, HDD-by-default on the cheapest tiers.

### Latency summary and playability verdict for this section
Every EU/US option surveyed puts Buenos Aires players at **134-151ms (US East/Miami/Dallas)** or **228-230ms (Germany/Finland)**. Based on the anecdotal PZ community reports above, US East is "workable but not great," Germany is "where complaints start." None of it beats São Paulo's ~30ms.

---

## 3. Oracle Always Free tier — the ARM (Ampere A1) question

**Important and time-sensitive finding: the free tier described in the prompt (4 OCPU / 24 GB Ampere A1) no longer exists as of mid-2026.**

- Oracle **quietly cut the Always Free Ampere A1 allowance from 4 OCPU/24GB to 2 OCPU/12GB, effective June 15, 2026**, with no blog post or advance customer notice ([InfoQ, 2026-07](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/); corroborated by [TerminalBytes](https://terminalbytes.com/oracle-cloud-free-tier-changes-2026/) and a [community.oracle.com discussion thread](https://community.oracle.com/customerconnect/discussion/970310/oci-always-free-updated-ampere-a1-compute-allocation)).
- Existing free-tier instances above the new 2 OCPU/12GB cap were flagged for **forced resize, with termination on or after August 18, 2026** for anyone who hadn't downsized. Given today's date (2026-09-03), this deadline has already passed — any 4 OCPU/24GB free instance still in the wild is likely already gone or resized.
- There's conflicting info (per InfoQ) on whether this cap also applies to Pay-As-You-Go accounts, not just pure free-tier ones — Oracle's docs reportedly say "all tenancies," support staff reportedly said "free-tier only." **Treat this as unresolved/uncertain** and verify directly in the OCI console before planning around it.
- Separately, "Always Free" Ampere A1 capacity has a known **regional availability problem**: US regions frequently show "Out of host capacity" for hours/days, while EU/APAC regions (Frankfurt, Singapore, Tokyo) usually provision within minutes ([search-aggregated community reports](https://zacson.medium.com/easy-way-to-resolve-oracle-cloud-out-of-capacity-error-while-creating-compute-instance-using-d6bd1c42c653)). I found **no specific data on Vinhedo/São Paulo capacity** — flag as unknown.

### Even setting the free-tier cut aside: is ARM viable for PZ B42 at all?
**No, not reliably**, based on the guides and issue threads found:
- A GitHub guide exists for running PZ on Oracle's `VM.Standard.A1.Flex` (Ampere ARM64) using **FEX-Emu** to emulate x86 ([Punkxbass/PZ-Dedicated-Server-on-an-ARM-Arch](https://github.com/Punkxbass/PZ-Dedicated-Server-on-an-ARM-Arch)), and another using **box86/box64**.
- **SteamCMD has zero native ARM64 support**, forcing emulation just to *download* the server via a workaround, and the PZ server binary itself is x86-64 native code (Java + native libs) requiring emulation to run at all.
- Community consensus in the threads found: this works as a proof-of-concept but is **"overly-complex, error-prone, and very unstable"** for actual production use, with degraded performance from the emulation layer on top of an already CPU-hungry Java server.
- **Conclusion: even the old 4 OCPU/24GB free ARM tier was a poor fit for a real 8-16 player B42 server**, and it no longer exists in that size anyway. Skip ARM/Oracle-free for this project; if you want to use Oracle, use paid x86 Flex shapes (§1) instead — they're already the cheapest on-demand hyperscaler option and avoid emulation entirely.

---

## 4. Cost-saving patterns

### Does the provider bill a stopped instance?
| Provider | Compute billed while stopped? | Disk billed while stopped? | Notes |
|---|---|---|---|
| AWS | No | Yes (EBS, normal rate) | Elastic IP starts costing $0.005/hr the moment it's not attached to a *running* instance |
| GCP | No | Yes (persistent disk, ~$0.04/GB-mo standard) | Static external IP: $0.01/hr unused, $0.005/hr in use (all IPv4 now billed, since a 2024 pricing change) |
| Hetzner | **Yes — full price until the server is deleted** | n/a (bundled) | Must delete the server object, not just power it off, to stop billing |
| DigitalOcean | Believed same "billed until destroyed" model as Hetzner (not freshly verified this pass) | — | — |
| Vultr / Linode / Oracle | Not independently verified in this research pass | — | Check each provider's own docs before relying on a stop-not-destroy pattern |

**Practical implication:** the "stop the VM when nobody's playing" pattern only saves real money on **AWS and GCP**. On Hetzner and (likely) most budget VPS providers, you must fully **destroy and recreate** the instance to avoid paying for idle time, which is where snapshots + IaC come in.

### On-demand start patterns
- **Discord bot + serverless start/stop** is a well-trodden pattern on AWS specifically, because stopped EC2 instances are free of compute charges: examples found include [discord-ec2-manager](https://github.com/jacob-card-howe/discord-ec2-manager) (Go Discord bot that starts/stops/creates/terminates EC2), [MineCloud](https://github.com/r1v1r/MineCloud) (AWS CDK project for on-demand game servers, built for Minecraft but adaptable), and a walkthrough at [dev.to/aws](https://dev.to/aws/server-start-how-i-let-my-friends-control-our-minecraft-server-via-discord-38l1). A Lambda function (triggered by a Discord slash command via Discord's HTTP interactions webhook) calls `StartInstances`/`StopInstances`; Lambda itself only costs money while it's invoked (a handful of calls a week is within the free tier).
- **Snapshot-and-destroy** is the right pattern for Hetzner/most VPS providers: take a snapshot (or keep the world save on a small persistent volume/object storage separate from the VM), destroy the VM, and recreate it from the snapshot + cloud-init on demand. Costs then reduce to snapshot/object storage (cents/GB-month) plus the hours actually played.
- Either pattern composes naturally with **Terraform/OpenTofu**: define the VM, its cloud-init user-data (installs Java, SteamCMD, pulls the PZ server files and world save from object storage, starts the systemd service), and a security group/firewall as code. A cron job or the Discord bot then runs `terraform apply` (recreate) / `terraform destroy` (tear down), or for AWS/GCP simply calls the provider API's start/stop rather than full apply/destroy since those two support "stop" as a free idle state natively.
- **20 hrs/week estimate**: 20 hrs × ~4.33 weeks ≈ **87 hours/month** of actual running time, vs. 730 hours/month for an always-on VM — roughly an **8.4x reduction** in compute-hours if billing is hourly and you reliably start/stop around play sessions.

---

## 5. Managed Project Zomboid hosts (baseline for comparison)

| Host | Entry price found | 8-16 player estimate | B42 support | Notes |
|---|---|---|---|---|
| Nitrado | $6.59/30 days (4 slots) | Scales with slot count/RAM; B42-listed explicitly | Yes (search results explicitly mention B42 support) | Flexible prepaid or subscription billing |
| BisectHosting | $11.99/mo (4GB) | 8GB ≈ **$24/mo**, 16GB ≈ **$48/mo** (monthly billing, $3.00/GB); ~20% cheaper on annual billing | Not explicitly confirmed in search results, but industry-standard for this host | $3.00/GB monthly, $2.70 quarterly, $2.55 semi-annual, $2.40 annual; +2GB RAM "boost" bundled on every plan |
| Shockbyte | $11.99/mo (4GB/6-slot) | Scales up per GB, ~$24-40/mo range estimated for 8-16 players (not directly confirmed) | Not explicitly confirmed | AMD EPYC + NVMe, 99.9% uptime SLA |
| Indifferent Broccoli | $5.99/mo (entry) up to $39.99/mo (64 players) | Slot-based, not RAM-capped — likely **$15-25/mo** for 8-16 players (interpolated, not a direct quote) | Yes — has dedicated Build 42 wiki pages | Uncapped RAM, limits by player slots instead |
| G-Portal | From $1.89/3 days (promo) | Not confirmed for 8-16 slot monthly rate | Claims to be "the largest PZ host" | Promotional short-term pricing found, not a stable monthly baseline |

**General note (not independently verified per-host in this pass, but standard across the managed-PZ-hosting industry):** all of these typically expose a web control panel that lets you edit `servertest.ini`/sandbox options and install Steam Workshop mods without shell access — that's their whole value proposition vs. self-hosting. If exact ini-level or mod-loader control matters, verify per-host before committing, since panel restrictiveness varies.

**Comparison takeaway:** self-hosting a Linode 8GB São Paulo VM ($67.20/mo always-on, or far less with stop/start) is priced similarly to or above BisectHosting's managed 8GB plan ($24/mo) — the money case for self-hosting only really wins if you (a) use the on-demand stop/start pattern to cut hours dramatically, or (b) specifically want root-level control, Terraform-managed reproducibility, or a São Paulo-region latency edge that a given managed host's own São Paulo/Brazil availability doesn't already offer (some managed hosts, e.g. G-Portal/Nitrado, do have Brazil-region servers — not individually confirmed here for each host).

---

## 6. IaC and stable public IP / DNS

### Terraform/OpenTofu providers for the top candidates
- **Oracle (OCI)**: `hashicorp/oci` (Terraform Registry) — supports Flex shapes, VCN, and the Vinhedo region like any other.
- **Hetzner Cloud**: `hetznercloud/hcloud`, available on both the [Terraform Registry and OpenTofu Registry](https://search.opentofu.org/provider/hetznercloud/hcloud/latest), actively maintained, supports servers/networks/load balancers/cloud-init as code, configured via an `HCLOUD_TOKEN` env var.
- **Linode/Akamai**: `linode/linode` provider, also present on both registries (not fetched in detail this pass, but well-established).
- **GCP**: `hashicorp/google` (and OpenTofu's own `opentofu/google`), weekly minor releases, supports `google_compute_instance`, custom machine types, and southamerica-east1 like any region.
- **AWS**: standard `hashicorp/aws` provider, sa-east-1 works like any other region.

### Cheapest way to get a stable address
- **Cloudflare + dynamic DNS script** is the cheapest option across the board: create a free Cloudflare API token scoped to "Edit zone DNS," then run a small script (existing open-source options: [fire1ce/DDNS-Cloudflare-Bash](https://github.com/fire1ce/DDNS-Cloudflare-Bash), [timothymiller/cloudflare-ddns](https://github.com/timothymiller/cloudflare-ddns)) on a cron job (e.g. every 5 minutes) that detects the box's current public IP (via icanhazip.com/ifconfig.me) and PATCHes the DNS A record via Cloudflare's API. **Cost: $0** beyond owning the domain — this works even when the VM's IP changes on every stop/start cycle (since ephemeral public IPs are typically free, unlike reserved/floating IPs).
- **Provider floating/reserved IP** costs money only if you want the IP to *stay the same* without a DNS update step: AWS Elastic IP (free while attached to a running instance, $0.005/hr = ~$3.6/mo once detached/idle), GCP static external IP ($0.005/hr in use, $0.01/hr idle = ~$3.6-7.3/mo), Hetzner Floating IPv4 (**€3.00/mo flat**). For an on-demand server whose IP changes every session anyway, **DNS + a fresh ephemeral IP each boot is strictly cheaper** than paying for a static IP you don't need between sessions.
- Recommended combo for the on-demand pattern: cloud-init sets up the game server on first boot, a small startup script self-registers its new ephemeral IP with Cloudflare on boot (no cron needed if the VM only gets a new IP when explicitly started), and the Discord bot / cron trigger handles the actual start/stop or apply/destroy.

---

## Bottom line / recommendation

See the summary response for the final 2-3 option recommendation table with monthly estimates for always-on vs. ~20hr/week on-demand use, at both the 8GB and 16GB tiers.

## Key uncertainties flagged in this document (do not treat as confirmed before spending money)
1. AWS/GCP/Azure exact sa-east-1 / southamerica-east1 / Brazil South prices for the *exact* target SKUs (4vCPU/8GB and 4-8vCPU/16GB) — I could only get confirmed numbers for adjacent SKUs (m5.xlarge, e2-standard-4, D4s_v5) and had to extrapolate regional premiums from secondary sources.
2. Vultr São Paulo-specific pricing (site blocked automated fetch; only global "starting from" prices found).
3. Hostinger's advertised São Paulo VPS prices may be long-term-commitment promo rates, not month-to-month.
4. Whether Oracle's June 2026 Always-Free A1 cut (4 OCPU/24GB → 2 OCPU/12GB) also applies to Pay-As-You-Go tenancies, and Ampere A1 capacity availability specifically in Vinhedo.
5. Exact Buenos Aires → Ashburn latency (used Washington DC as a proxy); PZ ms-to-playability thresholds are anecdotal, not benchmarked.
6. Whether managed PZ hosts other than the ones with explicit B42 mentions found (Nitrado, Indifferent Broccoli) support B42 and full ini/mod editing — assumed industry-standard but not verified per-host.
7. DigitalOcean/Vultr/Linode/Oracle exact billing behavior for a *stopped-but-not-destroyed* instance was not independently re-verified this pass (only Hetzner's "billed until deleted" and AWS/GCP's "free while stopped" were confirmed from primary-ish sources).

## Addendum 2026-09-03: opciones con datacenter en Argentina

Verificado tras confirmar que todos los jugadores están en Argentina.

- **AWS Local Zone Buenos Aires (`us-east-1-bue-1`)**: 16 tipos de instancia; relevantes: t3.medium (2 vCPU/4 GB) $0.0773/h ≈ $56/mes; **t3.xlarge (4 vCPU/16 GB) $0.3091/h ≈ $226/mes**; r5.xlarge (4/32) $0.462/h; c5.2xlarge (8/16) $0.603/h. EBS solo `gp2` a $0.247/GB-mes (80 GB ≈ $20/mes). Sin Spot ni Reservadas. Latencia esperada desde BA: ~5-15 ms (estimación, no medida). On-demand 87 h/mes con t3.xlarge ≈ $27 + $20 EBS ≈ $47/mes. Fuente: https://aws-pricing.com/us-east-1-bue-1.html (2026-09-03).
- **Proveedores con datacenter en Argentina** según https://getdeploying.com/datacenters-in-argentina (2026-09-03): Cloudflare (edge), Bunny CDN (edge), Gcore (cloud, Buenos Aires), Latitude.sh (bare metal/VM, Buenos Aires), Zenlayer (edge cloud). Solo Gcore y Latitude.sh podrían dar una VM/bare metal x86 utilizable; **no investigados en detalle**, verificar oferta y precio si se quiere ping mínimo sin AWS.
- Regiones en Santiago de Chile (OCI `sa-santiago-1`, GCP `southamerica-west1`): latencia comparable a São Paulo (~25-35 ms estimado), sin ventaja clara y menos oferta de shapes. No priorizadas.
