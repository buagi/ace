kind: replay

# Reject malformed input in parse()

`parse()` in `parse.sh` accepts empty / non-`KEY=VALUE` input silently. Make it reject input
that has no `=` (print an error to stderr, return non-zero) while still parsing valid pairs.
