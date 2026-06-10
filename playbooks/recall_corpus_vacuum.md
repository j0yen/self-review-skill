# playbook: recall-corpus-vacuum

Trigger: weekly heartbeat (every 7th invocation of self-review,
or first invocation after Sunday 06:00 local).

Action: run `recall vacuum --dry-run --format json | jq '.candidates'`.
If count > 0, surface in "Pending your call":
> recall vacuum: <N> memories surfaced >=20 times with 0 use.
> Run `recall vacuum --apply` to decay them, or
> `recall vacuum --apply --action archive` to move them out.

Not auto-applied. The user owns the apply step.
