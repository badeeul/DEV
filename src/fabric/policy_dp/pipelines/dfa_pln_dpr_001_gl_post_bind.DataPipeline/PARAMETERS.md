# GL Post Bind Pipeline — Parameters

Pipeline: `dfa_pln_dpr_001_gl_post_bind`

This pipeline runs two notebook activities:

1. **LN Call** — `den_nbk_pd_001_gl_post_bind` (LexisNexis post-bind NAICS enrichment).
2. **LN NAICS Response Emails** — `den_nbk_001_gl_ln_naics_response_notification` (sends the notification email with the Excel attachment). Runs only after **LN Call** succeeds.

## User-facing parameters

| Parameter | Default | Used by | Purpose |
|---|---|---|---|
| `proxy_env` | `test` | LN Call | Selects the LexisNexis proxy endpoint. |
| `to_email_override` | `` (empty) | Emails | Replaces the **To** recipient list. |
| `cc_email_override` | `` (empty) | Emails | Replaces the **CC** recipient list. |
| `to_email_extra` | `` (empty) | Emails | Appends extra addresses to the **To** list. |
| `cc_email_extra` | `` (empty) | Emails | Appends extra addresses to the **CC** list. |
| `skip_email` | `false` | Emails | Dry-run switch — build everything but do not send. |

### `proxy_env`

Controls which LexisNexis proxy endpoint the **LN Call** notebook hits.

- `test` &rarr; `.../api/proxy/call-test`
- `prod` &rarr; `.../api/proxy/call`

Any value other than `prod` (case-insensitive) routes to the **test** endpoint.

### `to_email_override` / `cc_email_override`

Replace the recipient list entirely (To and CC respectively). Accepts a `;` or
`,` separated list.

- Empty &rarr; use the recipients from the metadata template.
- A list of addresses &rarr; send to those addresses instead of the template.
- The literal value `none` &rarr; clears the list (no recipients on that line).

### `to_email_extra` / `cc_email_extra`

Append addresses on top of whatever the template/override resolved to, then
de-duplicate case-insensitively (order preserved). Use these to add recipients
without losing the default ones. Accepts a `;` or `,` separated list.

### `skip_email`

Dry-run switch for the email activity.

- `true`, `1`, or `yes` (case-insensitive) &rarr; the notebook still queries the
  data and generates the Excel attachment, but **does not send** the email.
- Any other value &rarr; the email is sent normally.

## Override vs. extra (mental model)

- **override** = *replace* the recipient list (`none` = clear it).
- **extra** = *add to* the recipient list.
- They compose: override sets the base, extra adds on top, duplicates removed.

## Auto-filled (system) parameters

These are populated by pipeline expressions and are not set manually:

| Parameter | Expression | Used by |
|---|---|---|
| `pipeline_name` | `@pipeline().PipelineName` | both |
| `workspace_id` | `@pipeline().DataFactory` | both |
| `pipeline_id` | `@pipeline().Pipeline` | LN Call |
| `run_id` | `@pipeline().RunId` | both |
| `trigger_time` | `@utcNow()` | Emails |

> `proxy_env` flows only into **LN Call**. The email parameters
> (`to/cc_email_override`, `to/cc_email_extra`, `skip_email`) flow only into
> **LN NAICS Response Emails**.
