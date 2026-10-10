# P0 — Guard emergency acceptance test matrix

**Scope:** isolated Staging test environment, synthetic employees only. Not a claim that tests passed.

| ID | Setup | Expected |
| --- | --- | --- |
| E01 | QR generation succeeds on station A | Manual RPC DENIED; QR remains public |
| E02 | QR generation fails on A; station B healthy | A manual eligible immediately; B denied |
| E03 | Guard toggles emergency with healthy QR | Manual RPC denied regardless of browser state |
| E04 | Browser forges outage flag | Manual RPC denied without server-issued station-bound lease |
| E05 | Valid station A outage and active shared guard session | Employee-number lookup proceeds through existing decision function |
| E06 | Missing, expired or revoked guard token | AUTH_REQUIRED, no photo or employee details |
| E07 | Missing, expired or revoked station credential | Denied, no photo or employee details |
| E08 | Station A QR generation recovers | Emergency lease revoked; new manual requests denied |
| E09 | Polling/photo fails but QR generator succeeds | No emergency eligibility |
| E10 | Device has no backend connectivity | No decision displayed as ALLOWED |
| E11 | Unknown employee number | DENIED without leaking registration existence beyond approved message |
| E12 | National ID supplied instead of employee number | Rejected by manual-entry path |
| E13 | Same request_id and employee number retried | Exact same result, at most one access log/quota debit |
| E14 | Same request_id with different employee number | REQUEST_MISMATCH |
| E15 | Two concurrent requests for final daily slot | At most one slot consumed, consistent result |
| E16 | Concurrent requests from two stations | No quota oversubscription |
| E17 | Allowed/limited/denied response | Correct decision, approved photo only, removed after ten seconds |
| E18 | Unauthorized public page accesses employee photo endpoint | Denied |
| E19 | Shared guard logs in concurrently on two devices | Sessions remain valid; station audit attribution remains distinct |
| E20 | Admin revokes guard session during manual entry | Subsequent request denied |

## Security gates
- Never use local JavaScript flags as proof of QR failure; browser-controlled evidence is not authoritative.
- Station identification cannot depend solely on localStorage IDs or a self-reported failure count.
- Server cannot automatically distinguish genuine local rendering failures from forged reports without trusted attestation. Require independently observed server failure or tightly audited exception policy before enabling manual RPC.
- Public QR generation success is not itself proof that the QR rendered successfully on the device.
- Confirm employee-number-only input against actual registration schema before rejecting legacy identifiers.
- Define operational day and lock granularity before changing quota code.

## Test status
NOT RUN. This matrix is a release checklist, not verification evidence.
