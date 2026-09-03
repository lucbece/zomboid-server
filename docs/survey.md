# Rules survey

`tools/encuesta/` is an optional web survey for deciding the sandbox rules as a group before the
world is created. Players open a link, answer 31 questions grouped into 5 sections, and the
tally can be written straight into `config/`.

It is off by default and requires opening a port, so read
[Security considerations](#security-considerations) before running it.

The survey page and its questions are currently in Spanish; see
[`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## Components

| File | Role |
|---|---|
| `tools/encuesta/preguntas.json` | Source of truth: the questions, their options, and which config key each one maps to |
| `tools/encuesta/index.html` | The page players open. Mobile-first; loads the questions from `/preguntas.json` |
| `tools/encuesta/server.py` | A `http.server` from the standard library. Serves the page and accepts votes. No pip, no virtualenv |
| `tools/encuesta/tally.py` | Counts the votes and proposes — or applies — the configuration change |
| `infra/systemd/zomboid-encuesta.service` | The unit. Not installed by cloud-init; `make encuesta-up` installs it |

There is no database. Each vote is one JSON line appended to `data/encuesta/votos.jsonl`.

## Running it

The survey runs on the same machine as the game server. On a cloud VM the port has to be opened
first; it is closed by default.

```hcl
# infra/terraform/envs/prod/terraform.tfvars
survey_port = 8080
```

```bash
make infra-apply     # adds the ingress rule for TCP 8080 from 0.0.0.0/0
```

Then, from the administrator's machine:

```bash
make encuesta-up          # syncs the tool, installs the unit, starts it, prints the URL
make encuesta-estado      # unit status and how many people have voted
make encuesta-down        # stops the survey; the votes stay on the machine
```

`make encuesta-up` prints `http://<address>:8080`. That is the link to hand out. The default port
can be changed with `ENCUESTA_PUERTO`.

Every question comes with the game's own default preselected, so the form can be submitted
without changing anything. Answers are kept as a draft in the browser's `localStorage` while
someone fills it in.

Each person identifies themselves with a name or an email address. The identifier is normalised —
lowercased, accents stripped, whitespace collapsed — so voting again under the same name replaces
the previous vote at tally time. The file itself is only ever appended to.

## Tallying and applying

```bash
make encuesta-resultados  # copies votos.jsonl locally, prints the counts and the proposed changes
make encuesta-aplicar     # the same, but writes the changes into config/ and shows the diff
```

The tally reports, per question, the votes for each option and the winner. **Ties are resolved in
favour of the game's default**, so a tie never changes anything. Only the keys where the winner
differs from what is currently in `config/` are listed, split between
`servertest_SandboxVars.lua` and `servertest.ini.tpl`.

Two questions behave specially:

- The overall loot question applies one multiplier to every `*LootNew` key in the sandbox file
  (19 of them). Its default option, "as the game ships it", touches none.
- The sleep question writes both `SleepAllowed` and `SleepNeeded` at once.

`tally.py` resolves keys within their nested table, so `ZombieLore.Speed` is looked up inside the
`ZombieLore = { … }` block and is not confused with the `Strength` in `MultiplierConfig`. Without
`--aplicar` it writes nothing.

After applying:

```bash
git diff config/
make sync RESTART=1       # or make restart, running locally
```

Remember that several rules — initial zombie population, loot map, erosion — are fixed when the
world is generated. If the world already exists, applying them requires a wipe; see
[`runbook.md`](runbook.md).

## Closing it

When the vote is over, stop the survey and close the port again:

```bash
make encuesta-down
```

```hcl
# infra/terraform/envs/prod/terraform.tfvars
survey_port = 0
```

```bash
make infra-apply
```

`make encuesta-down` stops the unit and removes the host firewall rule, but the security group
rule stays until `survey_port` is set back to `0` and applied. Leaving the port open leaves a
public HTTP service exposed with no reason to be running.

## Security considerations

The survey is plain HTTP with no TLS and no login, reachable from anywhere while the port is
open. The consequences are worth stating explicitly:

- **Traffic is unencrypted.** The identifier a player types and the options they choose travel in
  clear text and are visible to anyone able to observe the connection. No passwords are involved:
  the survey never asks for one, and it has no access to the game server's credentials.
- **There is no authentication.** Anyone with the link can vote, and anyone who knows or guesses
  another participant's identifier can overwrite that person's vote. It is a convenience tool for
  a group that already trusts each other, not a ballot.
- **Do not put anything sensitive in the questions or in the free-text comment field.**

What the implementation does provide: `votos.jsonl` is never served over HTTP — requests for it
return 404, and the votes are retrieved over `scp` — request bodies are capped at 16 KB, and
there is a rate limit of 30 requests per minute per source address, beyond which it answers 429.

Keep the exposure short. Open the port, collect the votes, close it.

## Testing locally

```bash
python3 tools/encuesta/server.py --puerto 18080 --host 127.0.0.1 --datos /tmp/encuesta

curl -sS -X POST http://127.0.0.1:18080/votar -H 'Content-Type: application/json' \
  -d '{"identificador":"test","respuestas":{"zombies_cantidad":"3"},"comentario":""}'

python3 tools/encuesta/tally.py --votos /tmp/encuesta/votos.jsonl \
  --sandbox /tmp/sb.lua --ini /tmp/s.ini.tpl
```

Point `--sandbox` and `--ini` at copies, not at the files in `config/`.
